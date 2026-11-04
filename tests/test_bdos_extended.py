"""CP/M 3 extended BDOS functions: F44/F46/F47/F59/F98/F107/F108/F111/F112."""

from __future__ import annotations

import unittest

from .layout import labels, source


class ExtendedDispatch(unittest.TestCase):
    def test_low_table_entries(self):
        text = source("src/bdos/bdos.zpa")
        table = text[text.index("dispatch_low:"):text.index("dispatch_ext:")]
        for fn in ("bf_f44", "bf_f45", "bf_f46", "bf_f47", "bf_f48", "bf_f49", "bf_f50"):
            self.assertIn(fn, table, f"{fn} missing from dispatch_low")

    def test_ext_table_entries(self):
        text = source("src/bdos/bdos.zpa")
        table = text[text.index("dispatch_ext:"):text.index("; @proc bdos_ret")]
        for fn in ("bf_f107", "bf_f108", "bf_f111", "bf_f112"):
            self.assertIn(fn, table, f"{fn} missing from dispatch_ext")

    def test_load_overlay_and_rsx(self):
        text = source("src/bdos/bdos.zpa")
        mid = text[text.index(".mid:"):text.index(".low:")]
        self.assertIn("jp z, bf_f59", mid)
        self.assertIn("jp z, bdos_efail", mid)      # F60: no RSXs resident
        self.assertIn("jp z, bf_f98", mid)


class MultiSectorCount(unittest.TestCase):
    def test_reads_transfer_the_full_count(self):
        # F20 applies F44's count: the loop moves up to ms_left records,
        # advances the DMA and reports H = records moved.
        text = source("src/bdos/bdos.zpa")
        read = text[text.index("multi_read:"):text.index("multi_write:")]
        self.assertIn("call multi_init", read)
        self.assertIn("call multi_record_done", read)
        self.assertIn("jr c,", read)
        self.assertIn("ld h, a", read)          # H = ms_done
        self.assertIn("ld l, 0", read)
        done = text[text.index("multi_record_done:"):
                    text.index("sync_page0_du:")]
        self.assertIn("ld (bdos_dma), hl", done)
        self.assertIn("ld (scb_dma), hl", done)
        self.assertIn("ld de, 128", done)
        # The DMA only advances for a true multi-sector call.
        self.assertIn("ms_adv", done)
        self.assertIn(".mrd_no_dma", done)

    def test_writes_transfer_the_full_count(self):
        # F21 applies the same count as F20: the loop moves up to ms_left
        # records, advances the DMA and reports H = records moved.
        text = source("src/bdos/bdos.zpa")
        write = text[text.index("multi_write:"):text.index("multi_init:")]
        self.assertIn("call multi_init", write)
        self.assertIn("call f21_body", write)
        self.assertIn("call multi_record_done", write)
        self.assertIn("jr c, .mw_loop", write)
        self.assertIn("ld h, a", write)
        # Invalid counts fall back to one record (PIP asks for 128).
        f44 = text[text.index("bf_f44:"):text.index("; F45: Set BDOS Error Mode")]
        self.assertIn("cp 128", f44)
        bad = f44[f44.index(".f44_bad:"):]
        self.assertIn("ld (scb_multi), a", bad)
        # The on-disk tests expect four records in one call each way.
        tester = source("src/test/disktest.asm")
        self.assertIn("the whole F44 count was transferred", tester)
        self.assertIn("all four records moved in one call", tester)
        self.assertIn(".t23_cmp", tester)

    def test_f44_validates_and_stores(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f44:"):text.index("; F45: Set BDOS Error Mode")]
        self.assertIn("ld (scb_multi), a", body)
        self.assertIn("cp 128", body)            # 1..127; PIP's 128 falls back
        self.assertIn(".f44_bad", body)

    def test_warm_boot_resets_count(self):
        text = source("src/bios/bios.zpa")
        start = text.index("warm_boot:")
        body = text[start:start + 1200]
        self.assertIn("ld (scb_multi), a", body)

    def test_count_is_seeded_from_the_scb(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("multi_init:"):
                    text.index("multi_record_done:")]
        self.assertIn("(scb_multi)", body)
        self.assertIn("ld (ms_left), a", body)
        self.assertIn("ld (ms_done), a", body)
        # A corrupt zero count is treated as one, never as 256.
        self.assertIn("jr nz, .mi_ok", body)


class ChainAndReturnCode(unittest.TestCase):
    def test_schema_has_chain_and_rc_fields(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["scb_chain"].addr, 0xF607)
        self.assertEqual(table["scb_rc"].addr, 0xF608)

    def test_f47_sets_flag_and_warm_boots(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f47:"):text.index("; F48: Flush Buffers")]
        self.assertIn("ld (scb_chain), a", body)
        self.assertIn("jp fn_wboot", body)

    def test_ccp_consumes_chain_flag(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("CCP_CHAIN_ADDR equ 0xF607", text)
        self.assertIn("ld a, (CCP_CHAIN_ADDR)", text)
        self.assertIn("ld (CCP_CHAIN_ADDR), a", text)


class TruncateFile(unittest.TestCase):
    def test_f99_is_dispatched(self):
        text = source("src/bdos/bdos.zpa")
        table = text[text.index("dispatch_ext:"):text.index("; @proc bdos_ret")]
        self.assertIn("bf_f99", table)

    def test_f99_frees_blocks_and_cuts_rc(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f99:"):text.index("; F120: Get SETDEF order byte")]
        self.assertIn("call clear_alloc_bit", body)     # via f99_free_from
        self.assertIn("call write_dir_entry", body)
        self.assertIn("ld (hl), 0xE5", body)            # drop whole extents
        self.assertIn("call find_fcb_extent", body)     # re-sync the FCB
        self.assertIn(".f99_err", body)

    def test_disktest_covers_f99(self):
        text = source("src/test/disktest.asm")
        body = text[text.index("test29:"):text.index("; --- shared helpers")]
        self.assertIn("ld c, 99", body)                 # F99
        self.assertIn("ld c, 35", body)                 # F35 size check
        self.assertIn("ld c, 46", body)                 # F46 free-space check
        self.assertIn("cp 0xFF", body)                  # extension rejected


class LoadOverlay(unittest.TestCase):
    def test_f59_reads_load_address_from_fcb(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f59:"):text.index("; F98: Clean Up Disc")]
        self.assertIn("f59_dest", body)
        self.assertIn("call f20_body", body)
        self.assertIn("ld a, 0xFE", body)

    def test_bdostest_loads_a_real_overlay(self):
        tester = source("src/test/bdostest.asm")
        body = tester[tester.index("tst_f59:"):tester.index("tst_f104:")]
        self.assertIn("ld c, 59", body)
        self.assertIn("0x005C + 33", body)
        self.assertIn("0xE000", body)
        self.assertIn("F59 LOADOVL", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("F59 LOADOVL", smoke)


class PrintBlock(unittest.TestCase):
    def test_f111_prints_from_a_control_block(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f111:"):text.index("; F112: Send Block")]
        self.assertIn("f111_addr", body)
        self.assertIn("f111_len", body)
        self.assertIn("bdos_con_out", body)

        tester = source("src/test/bdostest.asm")
        self.assertIn("ld c, 111", tester)
        self.assertIn("F111OK", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("F111 PRTBLK", smoke)


class DiskTestScreenWidth(unittest.TestCase):
    def test_t18_accepts_every_supported_width(self):
        # conwidth is columns - 1, so 31/50/63 for the 32/51/64 modes.  The
        # suite must not fail just because the screen is not 51 columns.
        text = source("src/test/disktest.asm")
        body = text[text.index("test18:"):text.index("test19:")]
        for value in ("cp 31", "cp 50", "cp 63"):
            self.assertIn(value, body)
        self.assertIn("t18_conwidth", body)
        self.assertIn("msg_t18_cw", text)


if __name__ == "__main__":
    unittest.main()
