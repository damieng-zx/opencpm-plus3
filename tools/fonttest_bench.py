#!/usr/bin/env python3
"""Time how long FONTTEST.COM takes to draw each page at 32, 51 and 64 columns.

FONTTEST writes 1 to MARKER (0x3F00) as a page draw starts and 2 when it has
finished (see src/test/fonttest.asm).  This boots the test image, runs
FONTTEST, jumps to each page with its number key, and reads the emulator's
T-state counter at every marker write, so the figures are Z80 T-states of real
work and independent of how long the program then waits for a key.

Usage:
    python3 tools/fonttest_bench.py                 # build/cpm3-test.dsk
    python3 tools/fonttest_bench.py --dsk X.dsk
    python3 tools/fonttest_bench.py --json out.json

Exit codes: 0 = measured, 1 = failure.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

from zx84_smoke import MCP, ROOT, SmokeError, find_zx84, prepare_test_image

MARKER = 0x3F00
FRAME_T = 70908          # T-states in one 50 Hz frame
PAGES = 7                # pages 0-6
WIDTHS = (51, 64, 32)    # the order W cycles through, starting at 51


def tstates(mcp: MCP) -> int:
    m = re.search(r"T-states:\s*(\d+)", mcp.call("registers", {}))
    if not m:
        raise SmokeError("no T-states in the register dump")
    return int(m.group(1))


def draw_time(mcp: MCP, pending: str = "") -> int:
    """T-states from the next marker 1 to the following marker 2.

    Typing a key runs frames itself and stops at the first marker write, so
    that marker arrives in the result of the typing call (`pending`) rather
    than from a `continue`.
    """
    marks: dict[int, int] = {}
    while len(marks) < 2:
        hit = (pending if "Memory watchpoint" in pending
               else mcp.call("continue", {"max_frames": 20000}))
        pending = ""
        m = re.search(r"=\s*([0-9A-F]{2})\s+PC=", hit)
        if "Memory watchpoint" not in hit or not m:
            raise SmokeError(f"no marker write: {hit[:200]!r}")
        marks[int(m.group(1), 16)] = tstates(mcp)
    if set(marks) != {1, 2}:
        raise SmokeError(f"expected markers 1 and 2, saw {sorted(marks)}")
    return marks[2] - marks[1]


def measure(dsk: Path) -> dict[int, dict[int, int]]:
    mcp = MCP(find_zx84(None), "zx128kplus3")
    try:
        mcp.call("model", {"target": "zx128kplus3"})
        mcp.call("load", {"file": str(dsk)})
        mcp.call("disk_boot", {})
        mcp.call("run", {"frames": 1500})
        mcp.call("delete_memory_watchpoint", {})
        mcp.call("memory_watchpoint", {
            "address": f"{MARKER:04X}", "length": 1, "mode": "write"})
        mcp.call("type", {"text": "FONTTEST"})
        mcp.call("key", {"name": "enter"})

        result: dict[int, dict[int, int]] = {}
        for n, width in enumerate(WIDTHS):
            if n:
                press = mcp.call("type", {"text": "w"})
                draw_time(mcp, press)      # the redraw after the width change
            result[width] = {}
            for page in range(PAGES):
                if n == 0 and page == 0:
                    result[width][page] = draw_time(mcp)   # first draw
                    continue
                press = mcp.call("type", {"text": str(page)})
                result[width][page] = draw_time(mcp, press)
        return result
    finally:
        mcp.call("delete_memory_watchpoint", {})
        mcp.close()


def report(result: dict[int, dict[int, int]]) -> None:
    print(f"{'T-states per page draw':<24}" + "".join(f"{w:>12} col" for w in sorted(result)))
    for page in range(PAGES):
        print(f"  page {page:<17}" + "".join(
            f"{result[w][page]:>16,}" for w in sorted(result)))
    print(f"  {'total':<22}" + "".join(
        f"{sum(result[w].values()):>16,}" for w in sorted(result)))
    print(f"  {'avg ms/page':<22}" + "".join(
        f"{sum(result[w].values()) / PAGES / 3546.9:>16.0f}" for w in sorted(result)))
    print(f"  {'avg frames/page':<22}" + "".join(
        f"{sum(result[w].values()) / PAGES / FRAME_T:>16.1f}" for w in sorted(result)))


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dsk", type=Path, default=ROOT / "build" / "cpm3-test.dsk")
    ap.add_argument("--json", type=Path, help="also write the figures here")
    args = ap.parse_args(argv)
    try:
        result = measure(prepare_test_image(args.dsk))
    except SmokeError as exc:
        print(f"fonttest_bench: {exc}", file=sys.stderr)
        return 1
    report(result)
    if args.json:
        args.json.write_text(json.dumps(
            {str(w): {str(p): t for p, t in pages.items()}
             for w, pages in result.items()}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
