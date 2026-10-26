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


class Issue02IsrVector(unittest.TestCase):
    """The bank-4 BIOS jump table must not overlap the IM 1 vector at 0038h."""

    def test_jump_table_starts_after_vector(self):
        text = source("src/bios/bios.zpa")
        self.assertIn("BIOS4_BASE  equ 0x0040", text)
        self.assertRegex(text, r"block BIOS4_BASE, 0")

    def test_listing_entries_do_not_cover_0038(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["bios_base"].addr, 0x0040)
        for name, lbl in table.items():
            if not name.startswith("fn_"):
                continue
            self.assertFalse(
                lbl.addr <= 0x0038 < lbl.addr + 3,
                f"{name} at 0x{lbl.addr:04X} overlaps the IM1 vector at 0038h")

    def test_trampoline_block_covers_fn32(self):
        text = source("src/bios/common.zpa")
        self.assertIn("dup 31", text)
        self.assertIn("31 * 3", text)


class Issue03DeblockCache(unittest.TestCase):
    """The deblock cache key must only be published after a successful read."""

    def test_publish_happens_after_read(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index("ensure_sector:"):text.index(".already_buffered:")]
        read = body.index("call fdc_read_sector")
        publish = body.rindex("ld (deblock_drv), a")
        self.assertLess(read, publish)
        # A failed read/seek must invalidate, not advertise, the cache.
        self.assertIn("ld a, 0xFF\n    ld (deblock_drv), a", body)
        self.assertLess(body.index("ld a, 0xFF"), read)

    def test_flush_error_is_propagated(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index(".need_read:"):text.index(".already_buffered:")]
        self.assertRegex(body, r"call flush_deblock_body\s*\n\s*pop bc\s*\n\s*or a\s*\n\s*ret nz")


if __name__ == "__main__":
    unittest.main()
