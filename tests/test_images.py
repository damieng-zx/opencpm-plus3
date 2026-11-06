"""The two built images: distribution (no tests) and test (distribution+tests)."""

from __future__ import annotations

import unittest

from .layout import ROOT, dsk_directory

DIST = ROOT / "build" / "cpm3.dsk"
TEST = ROOT / "build" / "cpm3-test.dsk"
BBC = ROOT / "references" / "binaries" / "BBCBASIC.COM"


def names(path) -> set[bytes]:
    return {entry[1:12] for entry in dsk_directory(path)
            if entry[0] != 0xE5}


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
        for stripped in (b"BDOSTESTCOM", b"XTETEST COM", b"STLTEST COM",
                         b"M80TEST COM", b"M80BIT  COM", b"DISKTESTCOM",
                         b"TERMTESTCOM", b"SYSTEST COM", b"REGTEST COM",
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


@unittest.skipUnless(TEST.exists(),
                     "build/cpm3-test.dsk is missing (run build.cmd)")
class TestImage(unittest.TestCase):
    def test_is_the_distribution_plus_the_test_programs(self):
        names11 = names(TEST)
        for wanted in (b"BDOSTESTCOM", b"XTETEST COM", b"STLTEST COM",
                       b"M80TEST COM", b"M80BIT  COM", b"DISKTESTCOM",
                       b"TERMTESTCOM", b"SYSTEST COM", b"REGTEST COM",
                       b"SMOKE   TXT", b"PAGE    TXT",
                       b"SMOKE   SUB", b"PARAM   SUB"):
            self.assertIn(wanted, names11)

    def test_keeps_the_distribution_files(self):
        if not DIST.exists():
            self.skipTest("build/cpm3.dsk is missing")
        self.assertLessEqual(names(DIST), names(TEST))

    def test_nulu11_is_not_shipped(self):
        self.assertNotIn(b"NULU11  COM", names(TEST))


if __name__ == "__main__":
    unittest.main()
