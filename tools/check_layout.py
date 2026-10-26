#!/usr/bin/env python3
"""Fail the build if the BIOS memory layout violates known invariants.

Runs after `build_memory_map.py` has parsed `build/bios.lst`. Checks that:

  - The system bank 4 image fits in 16 KB.
  - The common memory stub fits within F600..FFFF.
  - Critical sized buffers have the expected byte count.
  - Critical buffers sit inside the common memory range.
  - The CPM3.SYS file (C000..common_image_end) stays below 0x10000.

These invariants are already asserted by sjasmplus at assembly time for the
sizes that are statically known. This checker gives us a single place to look
when something drifts, and can flag tight slack before it becomes a bug.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from build_memory_map import Label, Section, SOURCE_COL, parse_listing


class LayoutError(Exception):
    pass


def _labels_by_name(sections: list[Section]) -> dict[str, Label]:
    out: dict[str, Label] = {}
    for s in sections:
        for lbl in s.labels:
            out[lbl.name] = lbl
    return out


def _require(labels: dict[str, Label], name: str) -> Label:
    if name not in labels:
        raise LayoutError(f"missing expected label: {name}")
    return labels[name]


def _size_between(labels: dict[str, Label], start: str, end: str) -> int:
    a = _require(labels, start)
    b = _require(labels, end)
    return b.addr - a.addr


def _find_label_after(section: Section, lbl: Label) -> Label | None:
    ordered = sorted(section.labels, key=lambda l: l.addr)
    for i, x in enumerate(ordered):
        if x is lbl:
            return ordered[i + 1] if i + 1 < len(ordered) else None
    return None


def _ranges_overlap(a0: int, a1: int, b0: int, b1: int) -> bool:
    return a0 < b1 and b0 < a1


def _first_active_source_line(path: Path, needle: str) -> int | None:
    for idx, raw in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1):
        source = raw[SOURCE_COL:] if len(raw) > SOURCE_COL else ""
        if needle not in source:
            continue
        # sjasmplus marks inactive IF/ELSE listing lines with `~`; those do
        # not describe emitted init code and must not drive order checks.
        prefix = raw[:SOURCE_COL]
        if "~" in prefix:
            continue
        return idx
    return None


def check(sections: list[Section]) -> list[str]:
    errors: list[str] = []
    labels = _labels_by_name(sections)
    file_section, system_section, common_section = sections

    # --- Section fit ---------------------------------------------------------
    system_end = labels.get("system_end")
    if system_end and system_end.addr > system_section.limit:
        errors.append(
            f"system_end 0x{system_end.addr:04X} exceeds bank 4 limit 0x{system_section.limit:04X}")

    # The IM 1 vector lives at 0038h in bank 4.  No BIOS jump-table entry
    # (fn_*) may cover those three bytes, or the ISR write corrupts it.
    bios_base = labels.get("bios_base")
    if bios_base and bios_base.addr <= 0x0038:
        errors.append(
            f"bios_base 0x{bios_base.addr:04X} overlaps the IM1 vector at 0038h")
    for name, lbl in labels.items():
        if name.startswith("fn_") and lbl.addr <= 0x0038 < lbl.addr + 3:
            errors.append(
                f"{name} at 0x{lbl.addr:04X} overlaps the IM1 vector at 0038h")

    bdos_stack_base = labels.get("bdos_stack_base")
    bdos_stack_top = bdos_stack_base.addr + 128 if bdos_stack_base else None
    if bdos_stack_top and bdos_stack_top > 0x10000:
        errors.append(f"bdos_stack top 0x{bdos_stack_top:04X} exceeds 0xFFFF")

    common_image_end = labels.get("common_image_end")
    if common_image_end and common_image_end.addr > 0x10000:
        errors.append(
            f"common_image_end 0x{common_image_end.addr:04X} — CPM3.SYS overflows bank 3 window")

    # --- Buffer sizes (expected fixed layout) --------------------------------
    expected_sizes = [
        # (start_label, end_label, expected_bytes, description)
        ("dirbuf",         "fcb_buf",          128, "directory buffer"),
        ("fcb_buf",        "fcb_user_addr",     36, "FCB shadow buffer"),
        ("xfer_staging",   "ccp_fcb",           32, "inter-bank transfer staging"),
        ("ccp_fcb",        "bdos_stack_base",   36, "CCP COM-loader FCB"),
        ("xdpb_a",         "xdpb_b",            27, "xdpb_a"),
        ("xdpb_b",         "xdpb_c",            27, "xdpb_b"),
    ]
    for start, end, want, desc in expected_sizes:
        if start not in labels or end not in labels:
            continue
        got = _size_between(labels, start, end)
        if got != want:
            errors.append(
                f"{desc}: {start}..{end} = {got} bytes, expected {want}")

    # xdpb_c has no adjacent sibling label; compare against dirbuf (next in map).
    # The gap includes the 1-byte motor_running flag.
    if "xdpb_c" in labels and "dirbuf" in labels:
        got = labels["dirbuf"].addr - labels["xdpb_c"].addr
        if got != 28:
            errors.append(f"xdpb_c..dirbuf = {got} bytes, expected 28 (27 + motor_running)")

    # --- Buffers must sit inside common memory range -------------------------
    for name in ("dirbuf", "fcb_buf", "xfer_staging", "ccp_fcb",
                 "bdos_stack_base",
                 "xdpb_a", "xdpb_b", "xdpb_c",
                 "xdph_a", "xdph_b", "xdph_c"):
        lbl = labels.get(name)
        if lbl and not (0xF600 <= lbl.addr < 0x10000):
            errors.append(f"{name} at 0x{lbl.addr:04X} — expected inside common memory (F600..FFFF)")

    return errors


def check_listing_invariants(sections: list[Section], listing: Path) -> list[str]:
    errors: list[str] = []
    labels = _labels_by_name(sections)
    _file_section, _system_section, common_section = sections

    required = ("system_image", "system_image_end", "common_image", "common_image_end")
    if not all(name in labels for name in required):
        return errors

    sys_src0 = labels["system_image"].addr
    sys_src1 = labels["system_image_end"].addr
    common_size = labels["common_image_end"].addr - labels["common_image"].addr
    common_dst0 = common_section.base
    common_dst1 = common_dst0 + common_size

    if _ranges_overlap(sys_src0, sys_src1, common_dst0, common_dst1):
        system_copy = _first_active_source_line(listing, "ld hl, system_image")
        common_copy = _first_active_source_line(listing, "ld hl, common_image")
        if system_copy is None or common_copy is None:
            errors.append(
                "init copy-order check could not find active system/common copy instructions")
        elif common_copy < system_copy:
            errors.append(
                "init copies common before system while COMMON_BASE overlaps the physical "
                "system_image source; this corrupts bank-4 code before it is relocated")

    return errors


def summary(sections: list[Section]) -> list[str]:
    rows: list[str] = []
    labels = _labels_by_name(sections)
    file_section, system_section, common_section = sections

    def _pct(used: int, total: int) -> str:
        return f"{used} / {total} bytes ({100.0 * used / total:.1f}%)"

    if "system_end" in labels:
        used = labels["system_end"].addr - system_section.base
        rows.append(f"  bank 4 used: {_pct(used, system_section.limit - system_section.base)}")
    if "bdos_stack_base" in labels:
        used = labels["bdos_stack_base"].addr + 128 - common_section.base
        rows.append(f"  common used: {_pct(used, 0x10000 - common_section.base)}")
    if "common_image_end" in labels:
        size = labels["common_image_end"].addr - file_section.base
        rows.append(f"  CPM3.SYS image: {size} bytes (C000..{labels['common_image_end'].addr:04X})")
    return rows


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lst", default="build/bios.lst", type=Path)
    args = parser.parse_args(argv)

    if not args.lst.exists():
        print(f"error: listing not found: {args.lst}", file=sys.stderr)
        return 2

    sections = parse_listing(args.lst)
    errors = check(sections)
    errors.extend(check_listing_invariants(sections, args.lst))

    for row in summary(sections):
        print(row)

    if errors:
        print("  layout errors:", file=sys.stderr)
        for e in errors:
            print(f"    - {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
