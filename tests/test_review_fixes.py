"""One regression test class per review finding.

The numbering follows docs/review-findings.md.
"""

from __future__ import annotations

import re
import unittest

from .layout import ROOT, labels, source


class Issue01TpaStackTop(unittest.TestCase):
    """The initial SP and scb_tpa must be COMMON_BASE, not bdos_stub."""

    def test_ccp_sets_sp_to_tpa_top(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("TPA_TOP equ 0xF600", text)
        self.assertRegex(text, r"ld sp,\s*TPA_TOP")
        self.assertNotRegex(text, r"ld sp,\s*\(0x0006\)")

    def test_bios_patches_scb_tpa_with_tpa_top(self):
        text = source("src/bios/bios.zpa")
        self.assertRegex(text, r"TPA_TOP\s+equ COMMON_BASE")
        self.assertRegex(text, r"ld hl, TPA_TOP\s*\n\s*ld \(scb_tpa\), hl")
        self.assertIn("TPA_KB equ (TPA_TOP - 0x0100) / 1024", text)

    def test_listing_places_common_at_f600(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["scb_base"].addr, 0xF600)
        self.assertGreater(table["bdos_stub"].addr, 0xF600)
        # The BDOS entry may sit after the SCB, but never below it.
        self.assertGreaterEqual(table["bdos_stub"].addr, table["scb_base"].addr)


if __name__ == "__main__":
    unittest.main()
