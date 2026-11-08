#!/usr/bin/env python3
"""Fail the build if the BIOS memory layout violates known invariants.

Runs after `build_memory_map.py` has parsed `build/bios.lst`. Checks that:

  - The system bank 4 image fits in 16 KB.
  - The common memory stub fits within F600..FFFF.
  - Critical sized buffers have the expected byte count.
  - Critical buffers sit inside the common memory range.
  - The CPM3.SYS head (init + bank-4 image) fits the C000..FFFF window.
  - The common stub fits its F600..FFFF window.
  - The bank-5 screen code fits 62C0..7FFF, and CPM3C.SYS (screen code +
    common stub) fits its bank-5 boot staging area.

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
    file_section, system_section, common_section, screen5_section = sections

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

    screen5_image = labels.get("screen5_image")
    common_image = labels.get("common_image")
    common_image_end = labels.get("common_image_end")
    if screen5_image and common_image and common_image_end:
        head = screen5_image.addr - file_section.base
        screen5 = common_image.addr - screen5_image.addr
        common = common_image_end.addr - common_image.addr
        if head > 0x10000 - file_section.base:
            errors.append(
                f"CPM3.SYS head is {head} bytes - overflows the C000-FFFF window")
        if common > 0x10000 - common_section.base:
            errors.append(
                f"common stub is {common} bytes - overflows the F600-FFFF window")
        if screen5 > screen5_section.limit - screen5_section.base:
            errors.append(
                f"bank-5 screen code is {screen5} bytes - overflows 62C0-7FFF")
        # The loader truncates its byte budget to whole 512-byte sectors.
        budget = (screen5_section.limit - screen5_section.base) & ~0x1FF
        if screen5 + common > budget:
            errors.append(
                f"CPM3C.SYS is {screen5 + common} bytes - overflows its "
                f"{budget}-byte bank-5 staging area")

    # --- Buffer sizes (expected fixed layout) --------------------------------
    expected_sizes = [
        # (start_label, end_label, expected_bytes, description)
        ("dirbuf",         "fcb_user_addr",    128, "directory buffer"),
        ("xfer_staging",   "ccp_fcb",           32, "inter-bank transfer staging"),
        ("ccp_fcb",        "start_tpa",         36, "CCP COM-loader FCB"),
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
    for name in ("dirbuf", "xfer_staging", "ccp_fcb",
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

    required = ("system_image", "system_image_end", "screen5_image",
                "common_image", "common_image_end")
    if not all(name in labels for name in required):
        return errors

    # init must copy the common stub from the bank-6 staging area; reading it
    # back out of the CPM3.SYS blob would mean the old single-file layout.
    if _first_active_source_line(listing, "ld hl, SYS2_STAGE") is None:
        errors.append(
            "init does not copy the common stub from SYS2_STAGE "
            "(CPM3C.SYS staging)")

    return errors


def summary(sections: list[Section]) -> list[str]:
    rows: list[str] = []
    labels = _labels_by_name(sections)
    file_section, system_section, common_section, screen5_section = sections

    def _pct(used: int, total: int) -> str:
        return f"{used} / {total} bytes ({100.0 * used / total:.1f}%)"

    if "system_end" in labels:
        used = labels["system_end"].addr - system_section.base
        rows.append(f"  bank 4 used: {_pct(used, system_section.limit - system_section.base)}")
    if "bdos_stack_base" in labels:
        used = labels["bdos_stack_base"].addr + 128 - common_section.base
        rows.append(f"  common used: {_pct(used, 0x10000 - common_section.base)}")
    if all(n in labels for n in ("screen5_image", "common_image", "common_image_end")):
        head = labels["screen5_image"].addr - file_section.base
        screen5 = labels["common_image"].addr - labels["screen5_image"].addr
        common = labels["common_image_end"].addr - labels["common_image"].addr
        budget = (screen5_section.limit - screen5_section.base) & ~0x1FF
        rows.append(f"  CPM3.SYS head: {head} bytes (C000..{file_section.base + head - 1:04X}),"
                    f" slack {0x10000 - file_section.base - head} bytes")
        rows.append(f"  common stub: {common} bytes, slack {0x10000 - common_section.base - common} bytes")
        rows.append(f"  bank-5 screen code: {screen5} bytes ({screen5_section.base:04X}.."
                    f"{screen5_section.base + screen5 - 1:04X}),"
                    f" CPM3C.SYS {screen5 + common} of {budget} staging bytes")
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
