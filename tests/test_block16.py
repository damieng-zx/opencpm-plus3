"""16-bit block-number support (CP/M 3, DSM > 255).

A 720K PCW DS/DD disk has 2K blocks and 352 blocks, so the directory and
FCB allocation maps hold eight 16-bit block numbers, high byte first.
These checks pin the BDOS accessors and the mkdsk 720K builder.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

from .layout import ROOT, source

sys.path.insert(0, str(ROOT / "tools"))
import mkdsk  # noqa: E402


class BlockAccessors(unittest.TestCase):
    def test_drive_select_caches_the_map_width(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("select_drive:"):text.index("; @proc select_fcb_drive")]
        self.assertIn("cached_blk16", body)
        self.assertIn("cached_dsm", body)

    def test_16bit_drives_are_not_rejected(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("select_fcb_drive:"):text.index("; @proc drive_ro_status")]
        self.assertNotIn("scf", body)

    def test_map_slot_count(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("map_count:"):text.index("map_block_addr:")]
        self.assertIn("cached_blk16", body)
        self.assertIn("ld a, 16", body)
        self.assertIn("ld a, 8", body)

    def test_fcb_and_dir_reads_are_big_endian(self):
        text = source("src/bdos/bdos.zpa")
        for name, end in (("get_fcb_block:", "put_fcb_block:"),
                          ("get_dir_block:", "set_alloc_bit:")):
            body = text[text.index(name):text.index(end)]
            self.assertIn("ld a, (hl)", body, name)
            self.assertIn("ld l, (hl)", body, name)
            self.assertIn("ld h, a", body, name)

    def test_fcb_store_is_big_endian(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("put_fcb_block:"):text.index("get_dir_block:")]
        self.assertIn("ld a, d", body)
        self.assertIn("ld (hl), a", body)
        self.assertIn("ld a, e", body)

    def test_alloc_vector_ops_take_16bit_blocks(self):
        text = source("src/bdos/bdos.zpa")
        for name in ("set_alloc_bit:", "clear_alloc_bit:"):
            body = text[text.index(name):text.index("; @proc ", text.index(name) + 1)]
            self.assertIn("srl h", body, name)
            self.assertIn("rr l", body, name)

    def test_find_free_block_returns_hl(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("find_free_block:"):text.index("; Internal: Directory operations")]
        self.assertIn("ld h, b", body)
        self.assertIn("ld l, c", body)
        self.assertIn("(cached_dsm)", body)

    def test_alv_is_cleared_for_every_format(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("build_alv:"):text.index(".mark_dir:")]
        self.assertNotIn("all_used", body)
        self.assertIn("xor a", body)


class MkDsk720k(unittest.TestCase):
    def test_format_geometry(self):
        fmt = mkdsk.FORMATS["720k"]
        self.assertEqual(fmt["cylinders"], 80)
        self.assertEqual(fmt["sides"], 2)
        self.assertEqual(fmt["block_size"], 2048)
        self.assertEqual(fmt["dsm"], 351)
        self.assertEqual(fmt["disc_type"], 3)

    def test_image_and_directory_entry(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "test720.dsk"
            dsk = mkdsk.DSKImage("720k")
            dsk.set_disc_spec()
            payload = bytes(range(128)) * 8           # 8 records = 1 block
            self.assertTrue(dsk.add_cpm_file("B16.TXT", payload))
            dsk.save(path)

            data = path.read_bytes()
            self.assertEqual(data[0x30], 80)          # cylinders
            self.assertEqual(data[0x31], 2)           # sides

            loaded = mkdsk.DSKImage().load(path)
            self.assertEqual(loaded.block_bits, 16)
            entry = loaded._read_dir_entry(0)
            self.assertEqual(entry[1:12], b"B16     TXT")
            self.assertEqual(entry[15], 8)            # RC
            # Big-endian block number in the first slot (block 2).
            self.assertEqual((entry[16], entry[17]), (0x00, 0x02))
            self.assertEqual(loaded._entry_blocks(entry), [2])

    def test_multiple_blocks_and_extent_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "big.dsk"
            dsk = mkdsk.DSKImage("720k")
            payload = b"Z" * (128 * 20)               # 20 records = 2 blocks
            self.assertTrue(dsk.add_cpm_file("BIG.TXT", payload))
            entry = dsk._read_dir_entry(0)
            self.assertEqual(dsk._entry_blocks(entry), [2, 3])


class TestTool(unittest.TestCase):
    def test_b16test_covers_the_16bit_operations(self):
        text = source("src/tools/b16test.asm")
        for fn in ("ld c, 22", "ld c, 21", "ld c, 35", "ld c, 46",
                   "ld c, 33", "ld c, 99"):
            self.assertIn(fn, text)
        self.assertIn("B16 PASS", text)
        self.assertIn('db "B16A    TMP"', text)


if __name__ == "__main__":
    unittest.main()
