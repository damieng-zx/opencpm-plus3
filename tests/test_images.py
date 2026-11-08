"""The two built images: distribution (no tests) and test (distribution+tests)."""

from __future__ import annotations

import unittest

from .layout import ROOT, dsk_directory, dsk_sectors

DIST = ROOT / "build" / "cpm3.dsk"
DIST720 = ROOT / "build" / "cpm3-dist720.dsk"
TEST = ROOT / "build" / "cpm3-test.dsk"
BBC = ROOT / "references" / "binaries" / "BBCBASIC.COM"


def names(path) -> set[bytes]:
    return {entry[1:12] for entry in dsk_directory(path)
            if entry[0] != 0xE5}


def free_blocks(path) -> int:
    """Free 1K-or-2K blocks, the same count STAT F46 derives at run time."""
    import sys
    sys.path.insert(0, str(ROOT / "tools"))
    import mkdsk  # noqa: E402

    image = mkdsk.DSKImage().load(path)
    used = image._get_used_blocks()
    return image.dsm + 1 - len(used) - image.dir_blocks


@unittest.skipUnless(DIST.exists(), "build/cpm3.dsk is missing (run build.cmd)")
class DistributionImage(unittest.TestCase):
    def test_carries_the_system_and_built_in_utilities(self):
        names11 = names(DIST)
        for wanted in (b"CPM3    SYS", b"CPM3C   SYS", b"CCP     COM",
                       b"FONT51  BIN", b"RAMDISK FID",
                       b"SUBMIT  COM", b"SCREEN  COM", b"SET24X80COM",
                       b"SETDEF  COM", b"DATE    COM", b"DUMP    COM",
                       b"FORMAT  COM", b"DISKCOPYCOM", b"STAT    COM",
                       b"SYSGEN  COM",
                       b"SHOWXDPBCOM"):
            self.assertIn(wanted, names11)

    def test_has_no_test_programs_or_fixtures(self):
        names11 = names(DIST)
        for stripped in (b"BDOSTESTCOM", b"XTETEST COM", b"DISKTESTCOM",
                         b"TERMTESTCOM", b"SYSTEST COM", b"REGTEST COM",
                         b"BIOSTESTCOM", b"CHAINTESCOM",
                         b"SMOKE   TXT", b"PAGE    TXT",
                         b"SMOKE   SUB", b"PARAM   SUB"):
            self.assertNotIn(stripped, names11)

    def test_bbc_basic_is_on_the_distribution_image(self):
        if not BBC.exists():
            self.skipTest("references/binaries/BBCBASIC.COM is not present")
        self.assertIn(b"BBCBASICCOM", names(DIST))

    def test_nulu11_is_not_shipped(self):
        # NULU11.COM is a local LBR manager the project does not distribute.
        self.assertNotIn(b"NULU11  COM", names(DIST))


@unittest.skipUnless(DIST720.exists(),
                     "build/cpm3-dist720.dsk is missing (run build.cmd)")
class Distribution720Image(unittest.TestCase):
    """A 720K distribution disc: the same files as the 180K one, more room."""

    def test_is_a_720k_double_sided_image(self):
        raw = DIST720.read_bytes()
        self.assertEqual(raw[0x30], 80)          # cylinders
        self.assertEqual(raw[0x31], 2)           # sides

    def test_uses_the_720k_boot_chain(self):
        boot = dsk_sectors(DIST720)[0][0]
        self.assertEqual(boot[0], 3)             # disc type
        self.assertEqual(boot[1], 1)             # alternating sides
        self.assertEqual(boot[2], 80)            # tracks per side
        self.assertEqual(boot[3], 9)             # sectors per track
        self.assertEqual(boot[6], 4)             # 2K blocks
        self.assertEqual(sum(boot) & 0xFF, 3)    # boot checksum

    def test_carries_the_same_files_as_the_180k_distribution(self):
        self.assertEqual(names(DIST720), names(DIST))

    def test_carries_no_test_programs_or_third_party_toolkit(self):
        names11 = names(DIST720)
        for stripped in (b"BDOSTESTCOM", b"XTETEST COM", b"DISKTESTCOM",
                         b"TERMTESTCOM", b"SYSTEST COM", b"REGTEST COM",
                         b"BIOSTESTCOM", b"CHAINTESCOM", b"SCREENBMCOM",
                         b"SMOKE   TXT", b"PAGE    TXT",
                         b"SMOKE   SUB", b"PARAM   SUB",
                         b"PMAUTOAECOM"):
            self.assertNotIn(stripped, names11)

    def test_has_room_for_a_larger_tool_set(self):
        # The point of the 720K distribution: far more free space than the
        # 180K one (250+ free 2K blocks).
        self.assertGreaterEqual(free_blocks(DIST720), 250)
        # The 180K disc is nearly full - at most 57 free 1K blocks - but only
        # with the git-ignored third-party toolkit (BBC BASIC, ED, PIP...) on
        # it.  A checkout without references/binaries, such as CI, has ~120.
        if BBC.exists():
            self.assertLessEqual(free_blocks(DIST), 57)


@unittest.skipUnless(TEST.exists(),
                     "build/cpm3-test.dsk is missing (run build.cmd)")
class TestImage(unittest.TestCase):
    def test_is_a_720k_double_sided_image(self):
        raw = TEST.read_bytes()
        self.assertEqual(raw[0x30], 80)          # cylinders
        self.assertEqual(raw[0x31], 2)           # sides
        import sys
        sys.path.insert(0, str(ROOT / "tools"))
        import mkdsk  # noqa: E402
        image = mkdsk.DSKImage().load(TEST)
        self.assertEqual(image.block_bits, 16)
        self.assertEqual(image.dir_entries, 128)

    def test_uses_the_720k_boot_chain(self):
        # Track 0 carries the -DDS720 boot sector, whose disc spec tells the
        # BIOS login it is a 720K DS/DD disk (type 3, 80 tracks, 2K blocks).
        boot = dsk_sectors(TEST)[0][0]
        self.assertEqual(boot[0], 3)             # disc type
        self.assertEqual(boot[1], 1)             # alternating sides
        self.assertEqual(boot[2], 80)            # tracks per side
        self.assertEqual(boot[3], 9)             # sectors per track
        self.assertEqual(boot[6], 4)             # 2K blocks
        self.assertEqual(sum(boot) & 0xFF, 3)    # boot checksum

    def test_is_the_distribution_plus_the_test_programs(self):
        names11 = names(TEST)
        for wanted in (b"BDOSTESTCOM", b"XTETEST COM", b"DISKTESTCOM",
                       b"TERMTESTCOM", b"SYSTEST COM", b"REGTEST COM",
                       b"BIOSTESTCOM", b"CHAINTESCOM",
                       b"SMOKE   TXT", b"PAGE    TXT",
                       b"SMOKE   SUB", b"PARAM   SUB"):
            self.assertIn(wanted, names11)

    def test_keeps_the_distribution_files(self):
        if not DIST.exists():
            self.skipTest("build/cpm3.dsk is missing")
        self.assertLessEqual(names(DIST), names(TEST))

    def test_nulu11_is_not_shipped(self):
        self.assertNotIn(b"NULU11  COM", names(TEST))

    def test_pmautoae_ships_on_the_test_image_when_fetched(self):
        # PMAUTOAE.COM is third-party and git-ignored; when the local copy
        # is present the test image must carry it, and never the
        # distribution image.
        if not (ROOT / "references" / "binaries" / "PMAUTOAE.COM").exists():
            self.skipTest("references/binaries/PMAUTOAE.COM is not present")
        self.assertIn(b"PMAUTOAECOM", names(TEST))
        if DIST.exists():
            self.assertNotIn(b"PMAUTOAECOM", names(DIST))


if __name__ == "__main__":
    unittest.main()
