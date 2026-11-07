"""Boot image split: CPM3.SYS (head) + CPM3C.SYS (common stub).

CPM3.SYS is loaded at C000 and is relocated by `init`, so it must fit the
16K bank-3 window.  The common stub used to live in the tail of the same
file, which capped the whole system at 16K; it is now staged separately in
bank 6 and copied to F600.  These tests pin the split and the headroom.
"""

from __future__ import annotations

import unittest

from .layout import ROOT, labels, source


class BootSplit(unittest.TestCase):
    def test_built_files_reassemble(self):
        names = ("CPM3.SYS", "CPM3C.SYS", "bios.bin")
        if not all((ROOT / "build" / name).exists() for name in names):
            self.skipTest("build outputs missing; run build.cmd first")
        head = (ROOT / "build" / "CPM3.SYS").read_bytes()
        common = (ROOT / "build" / "CPM3C.SYS").read_bytes()
        blob = (ROOT / "build" / "bios.bin").read_bytes()
        self.assertTrue(head)
        self.assertTrue(common)
        self.assertEqual(head + common, blob)

    def test_head_and_common_fit_their_windows(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        head = table["common_image"].addr - 0xC000
        common = table["common_image_end"].addr - table["common_image"].addr
        self.assertGreater(head, 0)
        self.assertGreater(common, 0)
        self.assertLessEqual(head, 0x10000 - 0xC000)
        self.assertLessEqual(common, 0x10000 - 0xF600)

    def test_loader_stages_the_common_boot_file(self):
        text = source("src/boot/loader.asm")
        self.assertIn('db "CPM3C   SYS"', text)
        self.assertRegex(text, r"SYS2_STAGE\s+equ 0x9C00")
        self.assertRegex(text, r"SYS2_BLOCKS\s+equ 3")

    def test_init_copies_from_the_staging_area(self):
        text = source("src/bios/bios.zpa")
        self.assertRegex(text, r"SYS2_STAGE\s+equ 0x9C00")
        self.assertRegex(text, r"ld hl, SYS2_STAGE")
        self.assertNotRegex(text, r"ld hl, common_image")
        # 3 blocks fit below the loader's LF_FLAGS at A860 and row table A890.
        self.assertLessEqual(0x9C00 + 3 * 1024, 0xA860)


class Headroom(unittest.TestCase):
    """The BDOS directory/FCB block lives in the common stub for headroom."""

    RELOCATED = ("find_free_block", "read_dir_entry", "write_dir_entry",
                 "dir_sector_to_bios", "search_next_entry", "match_fcb",
                 "bf_f15", "bf_f16", "bf_f17", "bf_f18", "close_dir_update")

    def test_relocated_helpers_are_in_common_memory(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        for name in self.RELOCATED:
            self.assertIn(name, table)
            self.assertGreaterEqual(table[name].addr, 0xF600, name)

    def test_head_keeps_a_working_margin(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        head = table["common_image"].addr - 0xC000
        self.assertGreaterEqual(0x4000 - head, 256,
                                "head slack dropped below 256 bytes")

    def test_fixed_common_addresses_did_not_move(self):
        # RAMDISK.FID hardcodes the copy routines and miniccp.zpa the FCB;
        # the relocation is appended after these, so they must not shift.
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["copy_record_to_tpa"].addr, 0xF97A)
        self.assertEqual(table["copy_record_from_tpa"].addr, 0xF980)
        self.assertEqual(table["ccp_fcb"].addr, 0xFB21)
        # Moved down by 36 bytes when the unused dd_reserved cushion was
        # removed; miniccp.zpa's CCP_RUN_PROG is kept in step by an assert.
        self.assertEqual(table["ccp_run_prog"].addr, 0xFCA6)

    def test_common_window_still_has_room(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        common = table["common_image_end"].addr - table["common_image"].addr
        self.assertLessEqual(common, 0x10000 - 0xF600)
        self.assertLessEqual(common, 0xC00)          # 3-block staging area


if __name__ == "__main__":
    unittest.main()
