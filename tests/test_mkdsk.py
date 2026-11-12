"""Host-side mkdsk tests: directory extents, block accounting and round-trips."""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

from .layout import ROOT

sys.path.insert(0, str(ROOT / "tools"))
import mkdsk  # noqa: E402

RECORD = 128


def entries_for(dsk: mkdsk.DSKImage, name: bytes) -> list[tuple[int, bytes]]:
    """(directory index, raw entry) for every extent of a CP/M name."""
    out = []
    for i in range(dsk.dir_entries):
        entry = dsk._read_dir_entry(i)
        if entry[0] != 0xE5 and bytes(entry[1:12]) == name:
            out.append((i, entry))
    return out


def file_bytes(dsk: mkdsk.DSKImage, name: bytes, length: int) -> bytes:
    """Read a file's data through its extent allocation maps."""
    per_block = dsk.block_size // RECORD
    out = bytearray()
    for _, entry in entries_for(dsk, name):
        for block in dsk._entry_blocks(entry):
            for r in range(per_block):
                out.extend(dsk._read_record(block * per_block + r))
    return bytes(out[:length])


class AddAndDelete(unittest.TestCase):
    def test_reuses_a_deleted_entry_and_its_blocks(self):
        dsk = mkdsk.DSKImage("180k")
        dsk.set_disc_spec()
        payload = bytes(range(256)) * 8          # 2K = 2 blocks

        self.assertTrue(dsk.add_cpm_file("GONE.TXT", payload))
        self.assertTrue(dsk.add_cpm_file("KEEP.TXT", payload))
        used_with_both = len(dsk._get_used_blocks())

        self.assertTrue(dsk.delete_cpm_file("GONE.TXT"))
        self.assertEqual(len(dsk._get_used_blocks()), used_with_both - 2)
        self.assertFalse(entries_for(dsk, b"GONE    TXT"))

        self.assertTrue(dsk.add_cpm_file("NEW.TXT", payload))
        self.assertEqual(len(dsk._get_used_blocks()), used_with_both)
        self.assertFalse(entries_for(dsk, b"GONE    TXT"))
        self.assertEqual(file_bytes(dsk, b"NEW     TXT", len(payload)), payload)

        # The freed directory slot is reused.
        self.assertEqual(entries_for(dsk, b"NEW     TXT")[0][0], 0)

    def test_full_directory_reports_an_error(self):
        dsk = mkdsk.DSKImage("180k")
        dsk.set_disc_spec()
        for i in range(dsk.dir_entries):
            self.assertTrue(dsk.add_cpm_file(f"F{i:02d}.TXT", b"x"))
        self.assertIsNone(dsk._find_free_dir_entry())
        with self.assertRaises(ValueError):
            dsk.add_cpm_file("OVER.TXT", b"x")

        # Deleting one entry makes room again.
        self.assertTrue(dsk.delete_cpm_file("F00.TXT"))
        self.assertTrue(dsk.add_cpm_file("OVER.TXT", b"x"))


class Extents(unittest.TestCase):
    def test_a_file_over_16k_gets_a_second_extent(self):
        dsk = mkdsk.DSKImage("180k")
        dsk.set_disc_spec()
        data = bytes((i * 7) & 0xFF for i in range(20 * 1024))

        self.assertTrue(dsk.add_cpm_file("BIG.BIN", data))
        extents = entries_for(dsk, b"BIG     BIN")
        self.assertEqual(len(extents), 2)
        self.assertEqual([e[12] for _, e in extents], [0, 1])
        self.assertEqual([e[15] for _, e in extents], [128, 32])
        self.assertEqual(sum(len(dsk._entry_blocks(e)) for _, e in extents), 20)
        self.assertEqual(len(dsk._get_used_blocks()), 20)

        self.assertEqual(file_bytes(dsk, b"BIG     BIN", len(data)), data)

    def test_16bit_blocks_are_stored_big_endian(self):
        dsk = mkdsk.DSKImage("720k")
        dsk.set_disc_spec()
        data = b"\xA5" * (520 * 1024)             # 260 x 2K blocks

        self.assertTrue(dsk.add_cpm_file("HUGE.BIN", data))
        self.assertEqual(dsk.dsm, 351)
        self.assertEqual(dsk.block_bits, 16)
        self.assertEqual(dsk.dir_entries, 128)
        self.assertEqual(len(dsk._get_used_blocks()), 260)

        extents = entries_for(dsk, b"HUGE    BIN")
        self.assertEqual(len(extents), 33)
        high_seen = False
        for _, entry in extents:
            blocks = dsk._entry_blocks(entry)
            for i, block in enumerate(blocks):
                self.assertEqual(entry[16 + 2 * i], block & 0xFF)
                self.assertEqual(entry[17 + 2 * i], (block >> 8) & 0xFF)
                high_seen |= block > 0xFF
        self.assertTrue(high_seen, "no allocation block above 255")
        self.assertEqual(extents[-1][1][15], 64)  # four 2K blocks = 64 records


class RoundTrip(unittest.TestCase):
    def test_save_and_load_preserve_directory_and_data(self):
        dsk = mkdsk.DSKImage("180k")
        dsk.set_disc_spec()
        data = bytes((i * 13 + 5) & 0xFF for i in range(3000))
        self.assertTrue(dsk.add_cpm_file("ROUND.BIN", data))

        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "round.dsk"
            dsk.save(path)
            loaded = mkdsk.DSKImage().load(path)

        self.assertEqual(loaded.dsm, 174)
        self.assertEqual(file_bytes(loaded, b"ROUND   BIN", len(data)), data)
        # The AMSDOS spec written by set_disc_spec survives the round trip.
        self.assertEqual(loaded.tracks[0][0][0], 0)
        self.assertEqual(loaded.tracks[0][0][7], loaded.dir_blocks)


if __name__ == "__main__":
    unittest.main()
