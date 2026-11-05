"""mkdsk.delete_cpm_file (used by the smoke runner to keep the image roomy)."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

from .layout import ROOT

sys.path.insert(0, str(ROOT / "tools"))
import mkdsk  # noqa: E402


class DeleteFile(unittest.TestCase):
    def test_delete_frees_blocks_and_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "del.dsk"
            dsk = mkdsk.DSKImage("180k")
            dsk.set_disc_spec()
            payload = bytes(range(256)) * 8          # 2K = 2 blocks
            self.assertTrue(dsk.add_cpm_file("GONE.TXT", payload))
            self.assertTrue(dsk.add_cpm_file("KEEP.TXT", payload))
            before = len(dsk._get_used_blocks())

            self.assertTrue(dsk.delete_cpm_file("GONE.TXT"))
            self.assertEqual(len(dsk._get_used_blocks()), before - 2)
            self.assertFalse(dsk.delete_cpm_file("GONE.TXT"))

            dsk.save(path)
            loaded = mkdsk.DSKImage().load(path)
            names = [loaded._read_dir_entry(i)[1:12]
                     for i in range(mkdsk.DIR_ENTRIES)
                     if loaded._read_dir_entry(i)[0] != 0xE5]
            self.assertIn(b"KEEP    TXT", names)

    def test_delete_is_case_insensitive_and_masks_attributes(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "del2.dsk"
            dsk = mkdsk.DSKImage("180k")
            dsk.set_disc_spec()
            self.assertTrue(dsk.add_cpm_file("RO.TXT", b"x" * 128))
            # Set the R/O attribute bit on the filetype byte, like SET does.
            entry = dsk._read_dir_entry(0)
            entry = bytearray(entry)
            entry[9] |= 0x80
            dsk._write_dir_entry(0, entry)

            self.assertTrue(dsk.delete_cpm_file("ro.txt"))
            self.assertFalse(dsk.delete_cpm_file("RO.TXT"))


if __name__ == "__main__":
    unittest.main()
