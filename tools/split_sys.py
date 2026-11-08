#!/usr/bin/env python3
"""Split build/bios.bin into the two boot files.

The raw assembly output is one linear blob:

    [ init ][ bank-4 system image ][ bank-5 screen code ][ common stub ]

The stage-2 loader loads the last two as one file, to bank 5 at 62C0 where
the screen code runs, so the blob is split at `screen5_image`:

    build/CPM3.SYS   init + bank-4 image          (loaded at C000)
    build/CPM3C.SYS  screen code + common stub    (loaded to bank 5; init
                                                   copies the stub to F600)

Splitting the file is what lets CPM3.SYS use the whole C000-FFFF window: the
common stub no longer has to be staged inside it.  See docs/boot.md.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from build_memory_map import parse_listing  # noqa: E402

FILE_BASE = 0xC000


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lst", default="build/bios.lst", type=Path)
    parser.add_argument("--src", default="build/bios.bin", type=Path)
    parser.add_argument("--head", default="build/CPM3.SYS", type=Path)
    parser.add_argument("--common", default="build/CPM3C.SYS", type=Path)
    args = parser.parse_args(argv)

    for path in (args.lst, args.src):
        if not path.exists():
            print(f"error: missing {path}", file=sys.stderr)
            return 2

    sections = parse_listing(args.lst)
    labels = {label.name: label.addr for label in sections[0].labels}
    for name in ("screen5_image", "common_image", "common_image_end"):
        if name not in labels:
            print(f"error: {name} not found in {args.lst}", file=sys.stderr)
            return 2

    head_size = labels["screen5_image"] - FILE_BASE
    common_size = labels["common_image_end"] - labels["screen5_image"]
    data = args.src.read_bytes()

    if head_size <= 0 or common_size <= 0:
        print("error: empty head or common image", file=sys.stderr)
        return 2
    if len(data) != head_size + common_size:
        print(f"error: {args.src} is {len(data)} bytes, expected "
              f"{head_size + common_size} (head {head_size} + common {common_size})",
              file=sys.stderr)
        return 2
    if head_size > 0x10000 - FILE_BASE:
        print(f"error: CPM3.SYS head {head_size} bytes overflows C000-FFFF",
              file=sys.stderr)
        return 2

    args.head.write_bytes(data[:head_size])
    args.common.write_bytes(data[head_size:])
    print(f"  CPM3.SYS:  {head_size} bytes (C000..{FILE_BASE + head_size - 1:04X})")
    print(f"  CPM3C.SYS: {common_size} bytes (bank-5 screen code + common stub)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
