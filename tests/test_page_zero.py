"""Page zero compatibility: (0006h) must be the top of the TPA.

CP/M 3 defines 0005h as `jp BDOS` and lets transient programs treat the
word at 0006h as the memory ceiling.  Real-world programs (WordStar 3.0,
MBASIC 5.21, Turbo Pascal 3.0) compute their top-of-memory from it, so it
must be the BDOS entry *inside the common area's first bytes* - i.e. the
common base - and not `bdos_stub` further up inside the system stub.
"""

from __future__ import annotations

import unittest

from .layout import labels, source


class PageZeroMemoryCeiling(unittest.TestCase):
    def test_common_base_holds_bdos_vector(self):
        text = source("src/bios/common.zpa")
        self.assertIn("bdos_vector:", text)
        self.assertRegex(text, r"bdos_vector:\s*\n\s*jp bdos_stub")

    def test_page_zero_six_is_bdos_vector(self):
        text = source("src/bios/common.zpa")
        self.assertRegex(text, r"ld hl, bdos_vector\b")
        self.assertRegex(text, r"ld hl, bdos_vector\b[^\n]*\n\s*ld \(0x0006\), hl")

    def test_bdos_vector_at_common_base(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["scb_base"].addr, 0xF600)
        self.assertEqual(table["bdos_vector"].addr, 0xF600)
        self.assertGreater(table["bdos_stub"].addr, table["bdos_vector"].addr)


class Adm3aEscapes(unittest.TestCase):
    """WordStar/Turbo Pascal need ADM-3A/Kaypro cursor codes."""

    def test_escape_table_has_adm3a_codes(self):
        text = source("src/bios/screen.zpa")
        for cmd in ("'='", "'+'", "'*'", "'T'"):
            self.assertIn(f"db {cmd}", text, f"missing ADM-3A ESC {cmd}")
        self.assertIn(".esc_star:", text)


if __name__ == "__main__":
    unittest.main()
