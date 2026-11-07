"""720K test image: the stage-2 loader and boot sector are built twice.

`build/cpm3-test.dsk` is a PCW DS/DD 720K disk: 80 cylinders, two
alternating sides, 9 sectors, 2K blocks and 16-bit block numbers.  The
180K distribution image keeps the +3 single-sided layout.  Both boot
chains come from the same sources with `-DDS720` selecting the 720K
variant, so these checks pin the parts that differ.
"""

from __future__ import annotations

import unittest

from .layout import ROOT, source


class LoaderFormats(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.loader = source("src/boot/loader.asm")

    def test_the_two_layouts_are_defined_side_by_side(self):
        for token in (
                "IFDEF DS720",
                "BLK_SECTORS equ 4", "BLK_SECTORS equ 2",
                "DIR_SECTORS equ 8", "DIR_SECTORS equ 4",
                "BLK16       equ 1", "BLK16       equ 0",
                "SIDED       equ 1", "SIDED       equ 0"):
            self.assertIn(token, self.loader, token)

    def test_16bit_block_numbers_are_high_byte_first(self):
        body = self.loader[self.loader.index("block_number:"):
                            self.loader.index("NAME_SYS:")]
        self.assertIn("ld d, (ix + 16)", body)
        self.assertIn("ld e, (ix + 17)", body)

    def test_sided_disks_select_the_head_per_logical_track(self):
        body = self.loader[self.loader.index("seek_logical:"):
                            self.loader.index("div_hl_c:")]
        self.assertIn("and 1", body)
        self.assertIn("ld (cur_head), a", body)
        self.assertIn("srl a", body)

    def test_walks_further_extents(self):
        # A 2K-block disk holds only eight block numbers per directory
        # entry, so CPM3.SYS needs more than one extent.
        body = self.loader[self.loader.index("load_file:"):
                           self.loader.index("block_number:")]
        self.assertIn("call find_extent", body)
        self.assertIn(".lf_next_extent:", body)
        self.assertIn("ld (want_ext), a", body)

    def test_budget_is_sector_aligned(self):
        # The common stub is staged in a 0xC60-byte gap, smaller than one
        # 2K block, so a partial sector must never be read past the target.
        body = self.loader[self.loader.index("load_file:"):
                           self.loader.index("block_number:")]
        self.assertIn("and 0xFE", body)
        self.assertIn("ld c, 0", body)
        self.assertIn("0 - 512", body)

    def test_boot_sector_declares_each_layout(self):
        boot = source("src/boot/bootsect.asm")
        self.assertIn("IFDEF DS720", boot)
        # 180K: type 0, single sided, 40 tracks, 1K blocks.
        self.assertIn("db 0, 0, 40, 9, 2, 1, 3, 2", boot)
        # 720K: type 3, alternating sides, 80 tracks, 2K blocks.
        self.assertIn("db 3, 1, 80, 9, 2, 1, 4, 2", boot)

    def test_build_scripts_assemble_both_variants(self):
        for name in ("build.cmd", "build.sh"):
            text = source(name)
            self.assertIn("-DDS720", text, name)
            self.assertIn("bootsect720", text, name)
            self.assertIn("loader720", text, name)
            self.assertIn("--format 720k", text, name)


class TestImageIs720k(unittest.TestCase):
    @staticmethod
    def _image_block(text: str, image: str, next_image: str) -> str:
        flat = text.replace("\\", "/")
        start = flat.index(f"mkdsk.py create build/{image}")
        end = flat.index(f"mkdsk.py create build/{next_image}")
        return flat[start:end]

    def test_build_scripts_use_the_720k_boot_chain_for_the_test_image(self):
        for name in ("build.cmd", "build.sh"):
            block = self._image_block(source(name), "cpm3-test.dsk",
                                      "cpm3_720.dsk")
            self.assertIn("bootsect720", block, name)
            self.assertIn("loader720", block, name)

    def test_the_distribution_image_keeps_the_180k_chain(self):
        for name in ("build.cmd", "build.sh"):
            block = self._image_block(source(name), "cpm3.dsk",
                                      "cpm3-test.dsk")
            self.assertIn("bootsect.bin", block, name)
            self.assertIn("loader.bin", block, name)
            self.assertNotIn("bootsect720", block, name)
            self.assertNotIn("loader720", block, name)
            self.assertNotIn("--format 720k", block, name)


if __name__ == "__main__":
    unittest.main()
