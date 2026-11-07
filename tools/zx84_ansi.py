#!/usr/bin/env python3
"""ANSI/VT-100 CSI subset tests for the +3 screen driver.

The sequences are typed at the CCP prompt.  The line editor echoes each
character through the console output path, so the CSI bytes reach the same
``scr_putchar`` parser a program would use.  After each phase the harness
reads the character buffer and checks the cursor result.

Usage:
    python3 tools/zx84_ansi.py
    python3 tools/zx84_ansi.py --zx84 F:/src/zx/zx84
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from zx84_smoke import MCP, Smoke, SmokeError, find_zx84  # noqa: E402


class AnsiTests:
    def __init__(self, smoke: Smoke):
        self.s = smoke

    def send(self, seq: str, marker: str, frames: int = 100) -> list[str]:
        """Send ESC + seq, then type a marker at the resulting cursor."""
        self.s.esc(seq)
        self.s.mcp.call("type", {"text": marker})
        self.s.mcp.call("run", {"frames": frames})
        self.s.record()
        return self.s.screen()

    def check_at(self, label: str, lines: list[str], row: int, col: int,
                 text: str) -> None:
        got = lines[row][col:col + len(text)]
        if got != text:
            raise SmokeError(
                f"{label}: expected {text!r} at row {row} col {col}, "
                f"got {got!r}\n" + "\n".join(lines))

    def phase_cup(self) -> None:
        self.s.log("ANSI: CUP/HVP")
        self.s.esc("E")                         # clear with the +3 sequence
        lines = self.send("[5;10H", "CUP")
        self.check_at("CUP", lines, 4, 9, "CUP")

        lines = self.send("[7;20f", "HVP")
        self.check_at("HVP", lines, 6, 19, "HVP")

        # Inspect the cursor directly: typing in the last cell wraps and
        # scrolls, which would move the marker before we could check it.
        self.s.esc("[99;99H")
        row = self.s.memory(6, 0xA731, 1)[0]
        col = self.s.memory(6, 0xA730, 1)[0]
        if (row, col) != (23, 50):
            raise SmokeError(
                f"CUP clamp: cursor at row {row} col {col}, expected 23/50")

        lines = self.send("[H", "HOM")
        self.check_at("CUP home", lines, 0, 0, "HOM")

        lines = self.send("[0;0H", "ZRO")
        self.check_at("CUP zero defaults", lines, 0, 0, "ZRO")

        self.s.finish_prompt()

    def run(self) -> None:
        self.phase_cup()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3-test.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    args = ap.parse_args()

    dsk = Path(args.dsk)
    if not dsk.is_absolute():
        dsk = ROOT / dsk
    if not dsk.exists():
        print(f"error: {dsk} does not exist; run build.cmd first",
              file=sys.stderr)
        return 2

    try:
        mcp = MCP(find_zx84(args.zx84), args.model)
        try:
            smoke = Smoke(mcp, dsk)
            smoke.boot()
            AnsiTests(smoke).run()
        finally:
            mcp.close()
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    print("[ansi] all checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
