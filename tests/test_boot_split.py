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


if __name__ == "__main__":
    unittest.main()
