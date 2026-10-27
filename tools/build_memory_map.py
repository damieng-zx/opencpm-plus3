#!/usr/bin/env python3
"""Parse build/bios.lst and emit build/memory.map.

Walks the sjasmplus listing, tracks PHASE / DEPHASE blocks, and collects every
top-level label with its logical address. Groups them into sections:

  - Init           : physical file addresses before the first PHASE
  - System bank 4  : PHASE 0x0000 .. DEPHASE (logical 0x0000..0x3FFF)
  - Common stub    : PHASE 0xF600 .. DEPHASE (logical 0xF600..0xFFFF)
  - Image tail     : physical addresses after the last DEPHASE

Each section is printed with label, logical address, span-to-next-label,
and slack / usage totals.

Exports parse_listing() for reuse by tools/check_layout.py.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path

# sjasmplus listing format: `[indent][linenum][+]* [addr] [bytes...] source`
# with source text starting at column 24 (fixed-width). We slice at that
# column to isolate the source, avoiding confusion with bytes like `C3 70 00`.
LINE_RE = re.compile(r"^\s*\d+\+*\s+([0-9A-Fa-f]{4,8})\b")
LABEL_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):")
SOURCE_COL = 24


@dataclass
class Label:
    name: str
    addr: int
    section: str
    file_line: int


@dataclass
class Section:
    name: str
    base: int
    limit: int           # exclusive upper bound for the bank / region
    labels: list[Label]


def _match_directive(rest: str) -> tuple[str, int | None] | None:
    """Return ('phase', base) / ('dephase', None) if the source line is one."""
    text = rest.strip()
    if not text or text.startswith(";"):
        return None
    lowered = text.split(";", 1)[0].strip().lower()
    if lowered.startswith("phase "):
        num = lowered.split(None, 1)[1].rstrip(",")
        try:
            base = int(num, 0)
        except ValueError:
            if num.upper() == "COMMON_BASE":
                base = 0xF600
            else:
                return None
        return ("phase", base)
    if lowered == "dephase":
        return ("dephase", None)
    return None


def parse_listing(path: Path) -> list[Section]:
    """Return [file, system, common] sections from a bios.lst.

    - file:   physical CPM3.SYS layout (addresses at `org 0xC000` and later)
    - system: PHASE 0x0000 block (bank 4 runtime labels)
    - common: PHASE 0xF600 block (common memory stub runtime labels)
    """
    file_section = Section("CPM3.SYS file layout", base=0xC000, limit=0x10000, labels=[])
    system_section = Section("System bank 4", base=0x0000, limit=0x4000, labels=[])
    common_section = Section("Common memory", base=0xF600, limit=0x10000, labels=[])

    section_stack: list[Section] = [file_section]

    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        m = LINE_RE.match(raw)
        if not m:
            continue
        addr_hex = m.group(1)
        addr = int(addr_hex, 16)
        source = raw[SOURCE_COL:] if len(raw) > SOURCE_COL else ""

        directive = _match_directive(source)
        if directive is not None:
            kind, base = directive
            if kind == "phase":
                assert base is not None
                if base == 0x0000:
                    section_stack.append(system_section)
                elif base == 0xF600:
                    section_stack.append(common_section)
                else:
                    raise SystemExit(f"Unexpected PHASE base 0x{base:04X}")
            else:  # dephase
                if len(section_stack) > 1:
                    section_stack.pop()
            continue

        label_match = LABEL_RE.match(source)
        if not label_match:
            continue
        name = label_match.group(1)
        if name.startswith("_"):
            # Skip internal/local labels — keep the map readable.
            continue
        # Skip EQU constants: the listing's address column is the current PC,
        # not the constant's value, so they are not useful in a memory map.
        if re.match(r"^\s*[A-Za-z_][A-Za-z0-9_]*:?\s+equ\b", source, re.I):
            continue

        current = section_stack[-1]
        if not (current.base <= addr < current.limit):
            # An EQU or alias outside this section's address window.
            continue
        current.labels.append(Label(name=name, addr=addr, section=current.name, file_line=0))

    return [file_section, system_section, common_section]


def _format_section(section: Section) -> list[str]:
    lines: list[str] = []
    lines.append(f"Section: {section.name}")
    lines.append(f"  Range: 0x{section.base:04X} - 0x{section.limit - 1:04X}"
                 f"  ({section.limit - section.base} bytes available)")
    if not section.labels:
        lines.append("  (no labels)")
        lines.append("")
        return lines

    # Sort by address then keep original order for stable ties.
    ordered = sorted(section.labels, key=lambda l: l.addr)
    # Compute span to next label in same section; last label spans to its top.
    top = max(l.addr for l in ordered)
    lines.append("    addr    size  label")
    for i, lbl in enumerate(ordered):
        if i + 1 < len(ordered):
            size = ordered[i + 1].addr - lbl.addr
        else:
            size = 0  # final label — size unknown from listing alone
        lines.append(f"    {lbl.addr:04X}   {size:5d}  {lbl.name}")
    used = top - section.base
    limit_bytes = section.limit - section.base
    slack = section.limit - top
    pct = 100.0 * used / limit_bytes if limit_bytes else 0.0
    lines.append(f"  top: 0x{top:04X}   used≈{used} bytes ({pct:.1f}%)   slack to limit: {slack} bytes")
    lines.append("")
    return lines


def write_map(sections: list[Section], out: Path) -> None:
    rows: list[str] = ["CP/M 3.1 memory layout map",
                       "==========================",
                       ""]
    for s in sections:
        rows.extend(_format_section(s))
    out.write_text("\n".join(rows), encoding="utf-8")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lst", default="build/bios.lst", type=Path)
    parser.add_argument("--out", default="build/memory.map", type=Path)
    args = parser.parse_args(argv)

    if not args.lst.exists():
        print(f"error: listing not found: {args.lst}", file=sys.stderr)
        return 2

    sections = parse_listing(args.lst)
    write_map(sections, args.out)
    print(f"  memory.map: {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
