#!/usr/bin/env python3
"""Increment and persist the build number.

The counter lives in build/buildnum (ignored by git), so building never
dirties a tracked source file.  A clean build directory starts at 1.
"""
from __future__ import annotations

from pathlib import Path

COUNTER = Path("build/buildnum")


def main() -> int:
    try:
        current = int(COUNTER.read_text(encoding="ascii").strip())
    except (OSError, ValueError):
        current = 0
    number = current + 1
    COUNTER.parent.mkdir(parents=True, exist_ok=True)
    COUNTER.write_text(f"{number}\n", encoding="ascii")
    print(number)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
