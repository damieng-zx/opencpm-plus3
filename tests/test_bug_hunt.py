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


class ExtentReuse(unittest.TestCase):
    def setUp(self):
        self.text = read("src/bdos/bdos.zpa")

    def test_f21_reuses_an_existing_extent(self):
        b = body(self.text, ".wseq_new_extent:", "; @proc wseq_close_cur")
        self.assertIn("call next_extent", b)
        self.assertLess(b.index("call find_fcb_extent"),
                        b.index("call create_fcb_extent"))

    def test_extents_carry_into_s2(self):
        b = body(self.text, "next_extent:", "; F33: Read Random")
        self.assertIn("inc (ix + 14)", b)
        self.assertIn("ld (ix + 14), a", body(self.text, "rand_to_seq:", ".rand_overflow:"))
        self.assertIn("and 0x3F", body(self.text, "match_fcb_user:", ".no_match:"))


class RandomIo(unittest.TestCase):
    def setUp(self):
        self.text = read("src/bdos/bdos.zpa")

    def test_f33_checks_rc(self):
        b = body(self.text, "bf_f33:", ".rdrand_read_err:")
        self.assertIn("cp (ix + 15)", b)

    def test_random_write_keeps_cr(self):
        b = body(self.text, ".wseq_no_rc:", ".wseq_no_adv:")
        self.assertIn("and WR_RANDOM", b)
        self.assertIn("ld a, WR_RANDOM", body(self.text, "bf_f34:", "wr_random:"))


class CloseAndNames(unittest.TestCase):
    def setUp(self):
        self.text = read("src/bdos/bdos.zpa")

    def test_close_writes_only_changes(self):
        b = body(self.text, "close_dir_update:", ".cl_changed:")
        self.assertIn(".cl_cmp:", b)
        self.assertNotIn("call write_dir_entry", b)

    def test_make_and_rename_refuse_existing_names(self):
        self.assertIn("ld h, 8", body(self.text, "bf_f22:", ".mk_scan:"))
        self.assertIn("ld h, 8", body(self.text, "bf_f23:", "; Random access helpers"))

    def test_rename_keeps_attributes(self):
        b = body(self.text, ".ren_copy:", "djnz .ren_copy")
        self.assertEqual(b.count("xor (hl)"), 2)

    def test_f35_masks_the_fcb(self):
        b = body(self.text, ".fsz_cmp:", "djnz .fsz_cmp")
        self.assertEqual(b.count("and 0x7F"), 2)

    def test_delete_checks_before_deleting(self):
        b = body(self.text, "bf_f19:", ".del_ro_err:")
        self.assertIn(".del_counted:", b)
        self.assertIn("ld bc, 1", b)

    def test_f37_clears_read_only(self):
        self.assertIn("ld hl, ro_vec", body(self.text, "bf_f37:", ".f37_clear:"))

    def test_f14_refuses_missing_drive(self):
        b = body(self.text, "bf_f14:", "; F24:")
        self.assertIn("drive_table", b)
        self.assertIn("ld h, 4", b)

    def test_open_falls_back_to_user_0_system_files(self):
        b = body(self.text, "bf_f15:", "; F16: Close File")
        self.assertIn("set 7, (ix + 8)", b)
        self.assertIn("set 7, (ix + 9)", b)
        self.assertIn("call fcb_user", body(self.text, "find_fcb_entry:", "; @proc fcb_user"))

    def test_dir_sector_uses_the_high_byte(self):
        b = body(self.text, "read_dir_entry:", ".need_read:")
        self.assertEqual(b.count("srl d"), 2)

    def test_ctl_c_only_on_an_empty_line(self):
        b = body(self.text, ".ctlc:", "jp fn_wboot")
        self.assertIn("ld a, (f10_len)", b)


class CcpParsing(unittest.TestCase):
    def setUp(self):
        self.text = read("src/ccp/miniccp.zpa")

    def test_type_rest_is_skipped(self):
        b = body(self.text, ".pfe_star:", ".parse_done:")
        self.assertIn(".skip_ext:", b)

    def test_cpm3_delimiters(self):
        self.assertIn('"=,;<>[]|/"', self.text)
        self.assertIn("call is_delim", body(self.text, ".com_skip_space2:", ".com_parse_arg2:"))

    def test_program_size_checked(self):
        b = body(self.text, ".com_do_load:", ".com_fits:")
        self.assertIn("MAX_COM_RECS", b)
        self.assertIn("pop hl", b)

    def test_submit_location_kept(self):
        b = body(self.text, "try_sub:", ".opened:")
        self.assertIn("CCP_SUB_ADDR", b)
        self.assertIn("CCP_SUBU_ADDR", b)
        self.assertIn("scb_subdrv == 0xF60B", read("src/bios/common.zpa"))

    def test_invalid_drive_reported(self):
        b = body(self.text, ".do_drive_switch:", ".check_builtins:")
        self.assertIn("jp .com_unknown", b)

    def test_fixtest_on_test_image(self):
        self.assertIn("fixtest.com src", read("build.cmd"))
        self.assertIn("run_fixtest", read("tools/zx84_smoke.py"))


class BiosMemory(unittest.TestCase):
    def test_move_without_xmove_stays_in_the_tpa(self):
        b = body(read("src/bios/bios.zpa"), "bios_move:", "; @proc bios_xmove")
        self.assertIn("ld (xmove_src), a", b)
        self.assertIn("jp interbank_move", b)
        self.assertNotIn("ldir", b)

    def test_interbank_move_keeps_interrupts_off(self):
        b = body(read("src/bios/common.zpa"), "interbank_move:", "_ibm_src_bank:")
        self.assertIn("ld a, i", b)
        self.assertIn("di", b)
        self.assertIn("ret po", b)

    def test_selmem_preserves_bc(self):
        b = body(read("src/bios/common.zpa"), "bank_sel_cpm:", "; tpa_in / tpa_out")
        self.assertIn("push bc", b)
        self.assertIn("pop bc", b)

    def test_motor_timer_armed_before_flag(self):
        b = body(read("src/bios/fdc765.zpa"), "motor_on:", ".already_on:")
        self.assertLess(b.index("ld (motor_countdown), a"),
                        b.index("ld (motor_flag), a"))


if __name__ == "__main__":
    unittest.main()
