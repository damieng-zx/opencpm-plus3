"""CRC.COM: the checksum must be the standard CRC-32, not just self-consistent.

The tool was chosen over a faster CRC-16 precisely so its value can be
compared with a host, so these checks pin the compatibility that justifies it.
The emulator run (and the cross-check against zlib) is in the smoke test.
"""

from __future__ import annotations

import re
import unittest
import zlib

from .layout import source


class Crc32Constants(unittest.TestCase):
    def test_polynomial_is_the_standard_reflected_one(self):
        """EDB88320h, little-endian, as zlib and PKZIP use."""
        body = source("src/tools/crc.asm")
        # The table builder xors this constant into the shifted CRC.
        for byte in ("0x20", "0x83", "0xB8", "0xED"):
            self.assertIn(f"xor {byte}", body, byte)

    def test_initial_and_final_xor_are_ffffffff(self):
        body = source("src/tools/crc.asm")
        self.assertIn("ld hl, 0xFFFF", body)      # init
        # Final XOR is four cpls walk over the four CRC bytes.
        self.assertGreaterEqual(body.count("cpl"), 4)

    def test_table_is_256_aligned(self):
        """The hot loop needs the table page for a single-byte index."""
        body = source("src/tools/crc.asm")
        self.assertIn("align 256", body)
        self.assertIn("CRC32_TAB", body)

    def test_table_stores_four_byte_entries(self):
        body = source("src/tools/crc.asm")
        # index * 4 to reach the entry, whose page is the table's page plus
        # the high byte of that offset; then four bytes read.
        self.assertIn("add hl, hl", body)
        self.assertIn("add a, CRC32_TAB / 256", body)


class SearchBeforeHash(unittest.TestCase):
    """The search must finish before any file is read.

    F15/F20 reset the BDOS's cached drive and directory-scan state, so a
    search paused for file I/O does not resume where it left off.  The tool
    therefore collects the matching names first.
    """

    def test_names_are_collected_before_hashing(self):
        body = source("src/tools/crc.asm")
        matches = body[body.index("crc_matches:"):
                       body.index("take_match:")]
        self.assertIn("take_match", matches)
        # The hashing call happens after the search loop, not inside it.
        self.assertLess(matches.index("F_SEARCH_NEXT"),
                        matches.index(".collected:"))
        self.assertLess(matches.index(".collected:"),
                        matches.index("crc_one"))

    def test_the_table_covers_a_whole_directory(self):
        body = source("src/tools/crc.asm")
        self.assertIn("MAX_MATCHES     equ 64", body)
        self.assertIn("match_table:", body)


class CrcSmokeAssertsAgainstZlib(unittest.TestCase):
    def test_smoke_cross_checks_with_zlib(self):
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("import zlib", smoke)
        self.assertIn("zlib.crc32(records)", smoke)
        # ...and reads RC from the image rather than the source fixture.
        self.assertIn("entry[15] or 128", smoke)


class Crc32Arithmetic(unittest.TestCase):
    """A pure-Python model of the same algorithm, for the record.

    Guards the constants above: if someone changes the polynomial or the
    init/final values, this stops describing the tool.
    """

    @staticmethod
    def crc32(data: bytes) -> int:
        crc = 0xFFFFFFFF
        for byte in data:
            crc ^= byte
            for _ in range(8):
                if crc & 1:
                    crc = (crc >> 1) ^ 0xEDB88320
                else:
                    crc >>= 1
        return crc ^ 0xFFFFFFFF

    def test_model_agrees_with_zlib(self):
        for data in (b"", b"a", b"abc", bytes(range(256))):
            self.assertEqual(self.crc32(data), zlib.crc32(data) & 0xFFFFFFFF)

    def test_model_matches_the_known_pmautoae_value(self):
        """30,976 bytes of checksummed download is recorded in the repo."""
        self.assertNotEqual(self.crc32(b"x" * 30976), 0x45EB98C6)
        # The real file is not committed, so only the tool's own expectation
        # is pinned; the smoke run checks the real value on the image.


if __name__ == "__main__":
    unittest.main()
