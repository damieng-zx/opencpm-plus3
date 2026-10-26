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


class Issue04RandomExtent(unittest.TestCase):
    """F34/F40 must resolve the target extent, not reuse the current map."""

    def test_random_write_looks_up_or_creates_extent(self):
        text = source("src/bdos/bdos.zpa")
        f34 = text[text.index("bf_f34:"):text.index("; F35:")]
        f40 = text[text.index("bf_f40:"):text.index("; @proc div_hl_bc")]
        for body in (f34, f40):
            self.assertIn("call find_fcb_extent", body)
            self.assertIn("call create_fcb_extent", body)
            self.assertLess(body.index("call find_fcb_extent"),
                            body.index("jp bf_f21_core"))

    def test_random_test_covers_second_extent(self):
        text = source("src/test/disktest.asm")
        self.assertIn("; --- Write record 200 with 'C'", text)
        self.assertIn("ld a, 200", text)
        self.assertIn("; Clear DMA and read record 200: expect 'C'", text)


class Issue05SelectDriveErrors(unittest.TestCase):
    """File functions must not continue after a failed drive select."""

    def test_every_select_fcb_drive_checks_carry(self):
        text = source("src/bdos/bdos.zpa")
        calls = list(re.finditer(r"call select_fcb_drive\n((?:.*\n){0,3})", text))
        self.assertGreaterEqual(len(calls), 7)
        for m in calls:
            self.assertRegex(
                m.group(1), r"\b(jp|jr|ret)\s+c\b",
                "select_fcb_drive call is not followed by a carry check")

    def test_old_duplicated_select_blocks_are_gone(self):
        text = source("src/bdos/bdos.zpa")
        for label in ("f16_drv", "del_drv", "f20_drv", "f21_drv",
                      "mk_drv", "ren_drv", "f33_drv", "fsz_drv"):
            self.assertNotIn(label, text)


class Issue06GetDpb(unittest.TestCase):
    """F31/F27 must refresh cached_* for the current drive."""

    def test_f31_and_f27_select_current_drive(self):
        text = source("src/bdos/bdos.zpa")
        bodies = [
            text[text.index("bf_f27:"):text.index("; F28:")],
            text[text.index("bf_f31:"):text.index("; F32:")],
        ]
        for body in bodies:
            self.assertIn("ld a, (cur_disk)", body)
            self.assertIn("call select_drive", body)

    def test_showxdpb_test_covers_a_and_c(self):
        text = source("src/test/disktest.asm")
        self.assertIn("T14 F31 tracks drive", text)
        self.assertIn("ld (dpb_c14), hl", text)


if __name__ == "__main__":
    unittest.main()
