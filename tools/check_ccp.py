#!/usr/bin/env python3
"""Check that CCP.COM fits the bank-6 staging window.

The BIOS reads CCP.COM from the boot disk into `CCP_STAGE` (bank 6) using
`CCP_MAX_BLK` 1K blocks.  A CCP larger than that window would be silently
truncated, so the build fails here instead.  Both constants come from the
listing, which is authoritative after `build_memory_map.py`.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

EQU_RE = (r"^\s*\d+\+*\s+[0-9A-Fa-f]{4}\s+.*\b"
          r"NAME\s+equ\s+(0x[0-9A-Fa-f]+|\d+)")


def const(text: str, name: str) -> int | None:
    pattern = EQU_RE.replace("NAME", re.escape(name))
    m = re.search(pattern, text, re.M)
    return int(m.group(1), 0) if m else None


def check(listing: Path, ccp: Path) -> list[str]:
    errors: list[str] = []
    if not listing.exists():
        return [f"listing not found: {listing}"]
    if not ccp.exists():
        return [f"CCP binary not found: {ccp} (build it first)"]

    text = listing.read_text(encoding="utf-8", errors="replace")
    stage = const(text, "CCP_STAGE")
    blocks = const(text, "CCP_MAX_BLK")
    if stage is None or blocks is None:
        return ["CCP_STAGE / CCP_MAX_BLK not found in the listing"]

    window = blocks * 1024
    size = ccp.stat().st_size
    if size > window:
        errors.append(
            f"CCP.COM is {size} bytes but the staging window at "
            f"0x{stage:04X} holds only {window} bytes (CCP_MAX_BLK={blocks})")
    if not (0xB000 <= stage and stage + window <= 0xC000):
        errors.append(
            f"CCP staging window 0x{stage:04X}..0x{stage + window - 1:04X} "
            "is outside the free top of bank 6 (B000-BFFF)")
    return errors


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--lst", default="build/bios.lst", type=Path)
    ap.add_argument("--ccp", default="build/CCP.COM", type=Path)
    args = ap.parse_args(argv)

    errors = check(args.lst, args.ccp)
    if errors:
        for e in errors:
            print(f"  CCP error: {e}", file=sys.stderr)
        return 1
    text = args.lst.read_text(encoding="utf-8", errors="replace")
    window = (const(text, "CCP_MAX_BLK") or 0) * 1024
    size = args.ccp.stat().st_size
    print(f"  CCP.COM: {size} bytes (staging window {window} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
