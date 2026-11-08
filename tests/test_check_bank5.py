"""tools/check_bank5.py: the paging rules for the bank-5 screen code.

Bank 5 is only mapped while the screen is paged in; in system mode the same
addresses are the C: RAM disk in bank 7.  The checker must pass the real
build and must catch both ways of getting that wrong, so each test feeds it
a copy of build/bios.lst with one line broken.
"""

from __future__ import annotations

import re
import sys
import tempfile
import unittest
from pathlib import Path

from .layout import ROOT

TOOLS = str(ROOT / "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import check_bank5  # noqa: E402

LST = ROOT / "build" / "bios.lst"


def _code(line: str) -> str:
    return line[24:].split(";", 1)[0].strip() if len(line) > 24 else ""


class CheckBank5(unittest.TestCase):
    def setUp(self):
        if not LST.exists():
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.lines = LST.read_text(encoding="utf-8", errors="replace").splitlines()

    def run_on(self, lines):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bios.lst"
            path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            return check_bank5.check(path)

    def index_of(self, code: str, after: str | None = None) -> int:
        start = 0
        if after:
            start = next(i for i, l in enumerate(self.lines) if l.startswith(after))
        for i in range(start, len(self.lines)):
            if _code(self.lines[i]) == code:
                return i
        self.fail(f"{code!r} not in the listing")

    def test_the_build_is_clean(self):
        self.assertEqual(self.run_on(self.lines), [])

    def test_unpaged_jump_into_bank5_is_caught(self):
        # Drop the `call _page_in` in front of _clear_screen's bank-5 jump.
        i = self.index_of("jp _clear_screen_b5")
        self.assertEqual(_code(self.lines[i - 1]), "call _page_in")
        broken = self.lines[:i - 1] + self.lines[i:]
        errors = self.run_on(broken)
        self.assertTrue(any("_clear_screen_b5" in e for e in errors), errors)

    def test_unpaged_data_access_is_caught(self):
        # Turn the page-in into a load that names a bank-5 address: both it
        # and the following jump are unpaged.
        i = self.index_of("jp _clear_screen_b5")
        broken = list(self.lines)
        broken[i - 1] = broken[i - 1].replace("call _page_in", "ld hl, (_put_attr)")
        errors = self.run_on(broken)
        self.assertTrue(any("_put_attr" in e for e in errors), errors)

    def test_paged_marker_allows_a_reference(self):
        i = self.index_of("jp _clear_screen_b5")
        broken = self.lines[:i - 1] + [self.lines[i] + "  ; paged"] + self.lines[i + 1:]
        self.assertEqual(self.run_on(broken), [])

    def test_bank5_call_that_pages_out_is_caught(self):
        # A `call _page_out` from bank 5 returns into an unmapped bank.
        i = self.index_of("call _render_char", after="# file opened: screen5.asm")
        broken = list(self.lines)
        broken[i] = re.sub(r"call _render_char\b", "call _page_out", broken[i])
        errors = self.run_on(broken)
        self.assertTrue(any("_page_out" in e and "write_1ffd" in e for e in errors), errors)

    def test_bank5_call_through_a_paging_stub_is_caught(self):
        # Calling a bank-4 stub that pages in and out is just as fatal.
        i = self.index_of("call _render_char", after="# file opened: screen5.asm")
        broken = list(self.lines)
        broken[i] = re.sub(r"call _render_char\b", "call _clear_screen", broken[i])
        errors = self.run_on(broken)
        self.assertTrue(any("_clear_screen" in e for e in errors), errors)

    def test_build_runs_it(self):
        for script in ("build.cmd", "build.sh"):
            text = (ROOT / script).read_text(encoding="utf-8")
            self.assertIn("check_bank5.py", text, script)


if __name__ == "__main__":
    unittest.main()
