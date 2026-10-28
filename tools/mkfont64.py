#!/usr/bin/env python3
"""Build src/bios/font64.bin from the Compression .ch8 source.

64 columns x 4 pixels = 256, exactly the Spectrum line width, so 64x24 is the
widest mode that still fits a legible 4-pixel pitch (the +3's 51-column mode
uses 5 pixels; 80 columns would need 3).

The typeface is "Compression" from the ZX Origins collection by Damien Guard
(https://damieng.com/typography/zx-origins/compression/), drawn for exactly
this: 4-pixel cells rendered half-width.  The .ch8 is 96 glyphs covering
0x20-0x7F, one byte per scan line, pixels in bits 7..4, with a 1-pixel left
bearing so consecutive glyphs keep a gap.

Everything outside ASCII is left blank.  The typeface has no 3-pixel
line-drawing or accented set, and cropping the 5-pixel CPC glyphs down to
four columns turns boxes and shades into noise; 51-column mode keeps the
full set.  Blank is at least honest.

Usage:
    python3 tools/mkfont64.py            # write src/bios/font64.bin
    python3 tools/mkfont64.py --check    # verify the committed binary
    python3 tools/mkfont64.py --sheet    # print an ASCII proof sheet
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "src" / "bios" / "compression.ch8"
OUTPUT = ROOT / "src" / "bios" / "font64.bin"

GLYPHS = 256
ROWS = 8
FIRST = 0x20          # the .ch8 covers 0x20-0x7F
COUNT = 96


def build() -> bytes:
    src = SOURCE.read_bytes()
    if len(src) != COUNT * ROWS:
        raise SystemExit(f"{SOURCE}: expected {COUNT * ROWS} bytes, got {len(src)}")

    out = bytearray(GLYPHS * ROWS)
    for i in range(COUNT):
        code = FIRST + i
        for row in range(ROWS):
            value = src[i * ROWS + row]
            if value & 0x0F:
                raise SystemExit(
                    f"{SOURCE}: glyph {code:#04x} row {row} has pixels below bit 4")
            out[(code * ROWS) + row] = value
    return bytes(out)


def sheet(data: bytes) -> None:
    def glyph(code: int) -> list[str]:
        rows = data[code * ROWS:(code + 1) * ROWS]
        return ["".join("#" if row & (0x80 >> x) else "." for x in range(4))
                for row in rows]

    for start in range(32, 128, 16):
        codes = list(range(start, start + 16))
        for row in range(ROWS):
            print("  ".join(glyph(c)[row] for c in codes))
        print("  ".join(f"{(chr(c) if 32 < c < 127 else hex(c)):<4}" for c in codes))
        print()


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--check", action="store_true",
                    help="verify the committed font64.bin instead of writing it")
    ap.add_argument("--sheet", action="store_true", help="print a proof sheet")
    ap.add_argument("--out", type=Path, default=OUTPUT)
    args = ap.parse_args(argv)

    data = build()
    if args.sheet:
        sheet(data)
        return 0
    if args.check:
        if not args.out.exists():
            print(f"{args.out}: missing", file=sys.stderr)
            return 1
        if args.out.read_bytes() != data:
            print(f"{args.out}: out of date; run tools/mkfont64.py", file=sys.stderr)
            return 1
        print(f"{args.out}: up to date ({len(data)} bytes)")
        return 0

    args.out.write_bytes(data)
    print(f"{args.out}: {len(data)} bytes "
          f"(ASCII 0x20-0x7f from Compression, rest blank)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
