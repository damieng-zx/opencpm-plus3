"""Regression checks for bugs found reading the BDOS, BIOS and CCP."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def body(text: str, start: str, end: str) -> str:
    a = text.index(start)
    return text[a:text.index(end, a + len(start))]


class BuildAlv(unittest.TestCase):
    def setUp(self):
        self.b = body(read("src/bdos/bdos.zpa"), ".dir_scan:", ".dir_next:")

    def test_only_file_entries_own_blocks(self):
        # Labels (20h), date stamps (21h), XFCBs and garbage hold no map.
        self.assertIn("cp 16", self.b)
        self.assertNotIn("cp 0xE5", self.b)

    def test_blocks_past_dsm_are_ignored(self):
        self.assertIn("ld hl, (cached_dsm)", self.b)
        self.assertIn("call nc, set_alloc_bit", self.b)


class Delete(unittest.TestCase):
    def setUp(self):
        self.b = body(read("src/bdos/bdos.zpa"), "bf_f19:", ".del_ro_err")

    def test_scan_index_survives_ro_check(self):
        ro = self.b[self.b.index("ld de, 9"):]
        self.assertLess(self.b.rindex("push de", 0, self.b.index("ld de, 9")),
                        self.b.index("ld de, 9"))
        self.assertIn("pop de", ro[:ro.index("bit 7, a")])

    def test_every_extent_deleted(self):
        self.assertIn("ld (ix + 12), '?'", self.b)


class ExtentMatch(unittest.TestCase):
    def test_match_fcb_compares_ex(self):
        b = body(read("src/bdos/bdos.zpa"), "match_fcb:", ".match_all:")
        self.assertIn(".ex_ok:", b)
        self.assertIn("and 0x1F", b)

    def test_stat_asks_for_every_extent(self):
        self.assertIn("ld (FCB1 + 12), a", read("src/tools/stat.asm"))


class GetDateTime(unittest.TestCase):
    def test_f105_writes_the_dat_at_de(self):
        b = body(read("src/bdos/bdos.zpa"), "bf_f105:", "jp bdos_ret")
        self.assertNotIn("bdos_dma", b)
        self.assertEqual(b.count("write_user_byte"), 4)

    def test_bdostest_moves_dma_away(self):
        self.assertIn("ld de, 0x0080", read("src/test/bdostest.asm"))


class Xbios(unittest.TestCase):
    def setUp(self):
        self.text = read("src/bios/bios.zpa")

    def test_not_ready_stops_the_caller(self):
        b = body(self.text, ".ddp_not_ready:", "ret")
        self.assertIn("or a", b)
        self.assertNotIn("xor a", b)

    def test_dispatcher_restores_disk_drive(self):
        b = body(self.text, "xbios_handler:", ".xb_bad:")
        self.assertIn("call 0", b)
        self.assertIn("ld (.xb_drive + 1), a", b)
        self.assertIn("ld (disk_drive), a", b)


class Ccp(unittest.TestCase):
    def test_wildcard_command_rejected(self):
        b = body(read("src/ccp/miniccp.zpa"), ".do_load_com:", ".com_use_setdef_path")
        self.assertIn(".com_wild:", b)
        self.assertIn("jp z, .com_wild_bad", b)


if __name__ == "__main__":
    unittest.main()
