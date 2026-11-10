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

    def phase_move(self) -> None:
        self.s.log("ANSI: CUU/CUD/CUF/CUB")
        self.s.esc("E")
        self.s.esc("[10;10H")
        lines = self.send("[2A", "U")
        self.check_at("CUU", lines, 7, 9, "U")

        lines = self.send("[3B", "D")
        self.check_at("CUD", lines, 10, 10, "D")

        lines = self.send("[4C", "F")
        self.check_at("CUF", lines, 10, 15, "F")

        lines = self.send("[2D", "B")
        self.check_at("CUB", lines, 10, 14, "B")

        # Clamp at the top and at the bottom/right/left edges.
        lines = self.send("[99A", "T")
        self.check_at("CUU clamp", lines, 0, 15, "T")
        self.s.esc("[99B")
        row = self.s.memory(6, 0xA731, 1)[0]
        self.s.esc("[99C")
        col = self.s.memory(6, 0xA730, 1)[0]
        if (row, col) != (23, 50):
            raise SmokeError(
                f"movement clamp: cursor at row {row} col {col}, "
                "expected 23/50")
        self.s.esc("[99D")
        if self.s.memory(6, 0xA730, 1)[0] != 0:
            raise SmokeError("CUB clamp did not stop at column 0")

        self.s.finish_prompt()

    def phase_erase(self) -> None:
        self.s.log("ANSI: ED/EL")
        self.s.esc("E")
        self.s.esc("[1;1H")
        self.s.mcp.call("type", {"text": "ABCDE"})
        self.s.esc("[1;3H")
        self.s.esc("[0K")
        lines = self.s.screen()
        if lines[0].rstrip() != "AB":
            raise SmokeError("EL 0 left " + repr(lines[0]))

        self.s.esc("E")
        self.s.esc("[1;1H")
        self.s.mcp.call("type", {"text": "AB"})
        self.s.esc("[1;2H")
        self.s.esc("[1K")
        if self.s.screen()[0].strip():
            raise SmokeError("EL 1 did not erase to the start of the line")

        self.s.esc("E")
        self.s.esc("[1;1H")
        self.s.mcp.call("type", {"text": "XYZ"})
        self.s.esc("[1;2H")
        self.s.esc("[2K")
        if self.s.screen()[0].strip():
            raise SmokeError("EL 2 did not erase the whole line")

        self.s.esc("[5;5H")
        self.s.mcp.call("type", {"text": "MID"})
        self.s.esc("[2J")
        if any(line.strip() for line in self.s.screen()):
            raise SmokeError("ED 2 did not clear the viewport")

        self.s.esc("[1;1H")
        self.s.mcp.call("type", {"text": "TOP"})
        self.s.esc("[10;1H")
        self.s.mcp.call("type", {"text": "HERE"})
        self.s.esc("[10;1H")
        self.s.esc("[0J")
        lines = self.s.screen()
        if lines[0].rstrip() != "TOP":
            raise SmokeError("ED 0 disturbed the rows above the cursor")
        if any(line.strip() for line in lines[9:]):
            raise SmokeError("ED 0 did not erase from the cursor to the end")

        self.s.finish_prompt()

    def phase_save(self) -> None:
        self.s.log("ANSI: DECSC/DECRC")
        self.s.esc("E")
        self.s.esc("[5;10H")
        self.s.esc("[s")
        self.s.esc("[1;1H")
        self.s.esc("[u")
        self.s.mcp.call("type", {"text": "SAV"})
        self.s.mcp.call("run", {"frames": 100})
        self.s.record()
        self.check_at("DECRC", self.s.screen(), 4, 9, "SAV")
        self.s.finish_prompt()

    def phase_sgr(self) -> None:
        self.s.log("ANSI: SGR")
        self.s.esc("[0m")
        self.check_attr("SGR 0 resets to white on blue", 0x0F)

        self.s.esc("[31m")                      # red ink
        self.check_attr("SGR 31 red ink", 0x0A)

        self.s.esc("[42m")                      # green paper (ANSI 2 -> GRB 4)
        self.check_attr("SGR 42 green paper", 0x22)

        self.s.esc("[1m")                       # bold: both inks bright
        self.check_attr("SGR 1 bold", 0x62)

        self.s.esc("[0;37;44m")                 # white on blue
        self.check_attr("SGR 0;37;44", 0x0F)

        self.s.esc("[7m")                       # reverse: white on blue
        self.check_attr("SGR 7 reverse", 0x39)

        self.s.esc("[27m")
        self.check_attr("SGR 27 reverse off", 0x0F)

        self.s.esc("[5m")                       # blink needs both flash bits
        self.check_attr("SGR 5 blink", 0x8F)

        self.s.esc("[25m")
        self.check_attr("SGR 25 blink off", 0x0F)

        self.s.esc("[90m")                      # bright black ink
        self.check_attr("SGR 90 bright black", 0x48)

        # 38/48 introduce extended colour; the trailing numbers must not be
        # read as attributes of their own (5 would be blink).
        self.s.esc("[0m")
        self.s.esc("[38;5;9m")
        self.check_attr("SGR 38 extended colour ignored", 0x0F)

        self.s.esc("[m")                        # empty parameter = 0
        self.check_attr("SGR empty parameter resets", 0x0F)

        # End to end: a character drawn after SGR 31 m must carry the red
        # attribute in the screen's attribute file (0x5800 in bank 5).
        self.s.esc("[0m")
        self.s.esc("E")
        self.s.esc("[1;1H")
        self.s.esc("[31m")
        self.s.mcp.call("type", {"text": "R"})
        self.s.mcp.call("run", {"frames": 300})
        self.s.record()
        cell = self.s.memory(5, 0x5800, 1)[0]
        if cell != 0x0A:
            raise SmokeError(
                f"SGR 31 m did not reach the screen: attribute {cell:02X}, "
                "expected 0A")

        self.s.finish_prompt()

    def check_attr(self, label: str, want: int) -> None:
        got = self.s.memory(4, self.s.scr_attr, 1)[0]
        if got != want:
            raise SmokeError(f"{label}: attribute {got:02X}, expected {want:02X}")

    def phase_mode(self) -> None:
        self.s.log("ANSI: private modes")
        self.s.esc("[?3l")
        self.s.esc("[?3h")
        if self.s.memory(4, self.s.scr_cols, 1)[0] != 51:
            raise SmokeError("ESC [ ? 3 h/l changed the column count")
        self.s.esc("[?8h")
        self.s.esc("[?8l")
        self.s.finish_prompt()

        # ?7 is autowrap: the same state ESC v/w drives.  Use 32 columns so
        # a short line fills a row.
        self.s.esc("30")
        self.s.finish_prompt()

        self.s.esc("[?7l")
        if self.s.memory(4, self.s.scr_wrap, 1)[0] != 0:
            raise SmokeError("ESC [ ? 7 l did not clear the wrap flag")
        self.s.esc("H")
        self.s.mcp.call("type", {"text": "X" * 40})
        self.s.mcp.call("run", {"frames": 1200})
        row = self.s.memory(6, self.s.cursor_row, 1)[0]
        col = self.s.memory(6, self.s.cursor_col, 1)[0]
        if (row, col) != (0, 31):
            raise SmokeError(f"ESC [ ? 7 l: cursor {row}/{col}, expected 0/31")
        self.s.finish_prompt()

        self.s.esc("v")                         # wrap back on for the test
        self.s.esc("[?7h")
        if self.s.memory(4, self.s.scr_wrap, 1)[0] != 1:
            raise SmokeError("ESC [ ? 7 h did not set the wrap flag")
        self.s.esc("H")
        self.s.mcp.call("type", {"text": "X" * 40})
        self.s.mcp.call("run", {"frames": 1200})
        if self.s.memory(6, self.s.cursor_row, 1)[0] == 0:
            raise SmokeError("ESC [ ? 7 h: a 40-character line did not wrap")
        self.s.finish_prompt()

        self.s.esc("31")
        self.s.esc("[0m")                       # leave the palette as found
        self.check_attr("SGR reset at end of the mode phase", 0x0F)

    def run(self) -> None:
        self.phase_cup()
        self.phase_move()
        self.phase_erase()
        self.phase_save()
        self.phase_sgr()
        self.phase_mode()


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
