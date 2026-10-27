"""One regression test class per review finding.

The numbering follows docs/review-findings.md.
"""

from __future__ import annotations

import re
import unittest

from .layout import ROOT, labels, source


class Issue01TpaStackTop(unittest.TestCase):
    """The initial SP and scb_tpa must be COMMON_BASE, not bdos_stub."""

    def test_ccp_sets_sp_to_tpa_top(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("TPA_TOP equ 0xF600", text)
        self.assertRegex(text, r"ld sp,\s*TPA_TOP")
        self.assertNotRegex(text, r"ld sp,\s*\(0x0006\)")

    def test_bios_patches_scb_tpa_with_tpa_top(self):
        text = source("src/bios/bios.zpa")
        self.assertRegex(text, r"TPA_TOP\s+equ COMMON_BASE")
        self.assertRegex(text, r"ld hl, TPA_TOP\s*\n\s*ld \(scb_tpa\), hl")
        self.assertIn("TPA_KB equ (TPA_TOP - 0x0100) / 1024", text)

    def test_listing_places_common_at_f600(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["scb_base"].addr, 0xF600)
        self.assertGreater(table["bdos_stub"].addr, 0xF600)
        # The BDOS entry may sit after the SCB, but never below it.
        self.assertGreaterEqual(table["bdos_stub"].addr, table["scb_base"].addr)


class Issue02IsrVector(unittest.TestCase):
    """The bank-4 BIOS jump table must not overlap the IM 1 vector at 0038h."""

    def test_jump_table_starts_after_vector(self):
        text = source("src/bios/bios.zpa")
        self.assertIn("BIOS4_BASE  equ 0x0040", text)
        self.assertRegex(text, r"block BIOS4_BASE, 0")

    def test_listing_entries_do_not_cover_0038(self):
        table = labels()
        if not table:
            self.skipTest("build/bios.lst not present; run build.cmd first")
        self.assertEqual(table["bios_base"].addr, 0x0040)
        for name, lbl in table.items():
            if not name.startswith("fn_"):
                continue
            self.assertFalse(
                lbl.addr <= 0x0038 < lbl.addr + 3,
                f"{name} at 0x{lbl.addr:04X} overlaps the IM1 vector at 0038h")

    def test_trampoline_block_covers_fn32(self):
        text = source("src/bios/common.zpa")
        self.assertIn("dup 31", text)
        self.assertIn("31 * 3", text)


class Issue03DeblockCache(unittest.TestCase):
    """The deblock cache key must only be published after a successful read."""

    def test_publish_happens_after_read(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index("ensure_sector:"):text.index(".already_buffered:")]
        read = body.index("call fdc_read_sector")
        publish = body.rindex("ld (deblock_drv), a")
        self.assertLess(read, publish)
        # A failed read/seek must invalidate, not advertise, the cache.
        self.assertIn("ld a, 0xFF\n    ld (deblock_drv), a", body)
        self.assertLess(body.index("ld a, 0xFF"), read)

    def test_flush_error_is_propagated(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index(".need_read:"):text.index(".already_buffered:")]
        self.assertRegex(body, r"call flush_deblock_body\s*\n\s*pop bc\s*\n\s*or a\s*\n\s*ret nz")


class Issue04RandomExtent(unittest.TestCase):
    """F34/F40 must resolve the target extent, not reuse the current map."""

    def test_random_write_looks_up_or_creates_extent(self):
        text = source("src/bdos/bdos.zpa")
        f34 = text[text.index("bf_f34:"):text.index("; F35:")]
        f40 = text[text.index("bf_f40:"):text.index("; @proc div_hl_bc")]
        for body in (f34, f40):
            self.assertIn("call find_fcb_extent", body)
            self.assertIn("call create_fcb_extent", body)
            self.assertLess(body.index("call find_fcb_extent"),
                            body.index("jp bf_f21_core"))

    def test_random_test_covers_second_extent(self):
        text = source("src/test/disktest.asm")
        self.assertIn("; --- Write record 200 with 'C'", text)
        self.assertIn("ld a, 200", text)
        self.assertIn("; Clear DMA and read record 200: expect 'C'", text)


class Issue05SelectDriveErrors(unittest.TestCase):
    """File functions must not continue after a failed drive select."""

    def test_every_select_fcb_drive_checks_carry(self):
        text = source("src/bdos/bdos.zpa")
        calls = list(re.finditer(r"call select_fcb_drive\n((?:.*\n){0,3})", text))
        self.assertGreaterEqual(len(calls), 7)
        for m in calls:
            self.assertRegex(
                m.group(1), r"\b(jp|jr|ret)\s+c\b",
                "select_fcb_drive call is not followed by a carry check")

    def test_old_duplicated_select_blocks_are_gone(self):
        text = source("src/bdos/bdos.zpa")
        for label in ("f16_drv", "del_drv", "f20_drv", "f21_drv",
                      "mk_drv", "ren_drv", "f33_drv", "fsz_drv"):
            self.assertNotIn(label, text)


class Issue06GetDpb(unittest.TestCase):
    """F31/F27 must refresh cached_* for the current drive."""

    def test_f31_and_f27_select_current_drive(self):
        text = source("src/bdos/bdos.zpa")
        bodies = [
            text[text.index("bf_f27:"):text.index("; F28:")],
            text[text.index("bf_f31:"):text.index("; F32:")],
        ]
        for body in bodies:
            self.assertIn("ld a, (cur_disk)", body)
            self.assertIn("call select_drive", body)

    def test_showxdpb_test_covers_a_and_c(self):
        text = source("src/test/disktest.asm")
        self.assertIn("T14 F31 tracks drive", text)
        self.assertIn("ld (dpb_c14), hl", text)


class Issue07WriteProtect(unittest.TestCase):
    """F28 must actually block writes and F45 must select return/abort."""

    def test_write_functions_check_readonly(self):
        text = source("src/bdos/bdos.zpa")
        for start, end in (
            ("bf_f16:", "; @proc close_dir_update"),
            ("bf_f19:", "; F20:"),
            ("bf_f21:", "; F22:"),
            ("bf_f22:", "; F23:"),
            ("bf_f23:", "; =========================================================================="),
            ("bf_f30:", "; F31:"),
        ):
            body = text[text.index(start):text.index(end, text.index(start))]
            self.assertIn("call is_fcb_readonly", body, start)

    def test_ro_error_honours_error_mode(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("ro_error:"):text.index("msg_ro:")]
        self.assertIn("ld a, (error_mode)", body)
        self.assertIn("jp warm_boot", body)

    def test_disktest_has_ro_case(self):
        self.assertIn("T15 R/O protect+F45", source("src/test/disktest.asm"))


class Issue08AlvSize(unittest.TestCase):
    """DSM > 255 must not be handled with 8-bit arithmetic."""

    def test_alv_size_uses_16bit_dsm(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("build_alv:"):text.index(".mark_dir:")]
        self.assertIn("srl h", body)
        self.assertIn("rr l", body)
        self.assertIn("(cached_dsm + 1)", body)

    def test_16bit_drive_is_rejected(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("select_fcb_drive:"):text.index("; @proc drive_ro_status")]
        self.assertIn("(cached_dsm + 1)", body)
        self.assertIn("scf", body)

    def test_readme_qualifies_pcw(self):
        text = source("README.md")
        self.assertIn("16-bit block file I/O is not implemented", text)


class Issue09BiosMove(unittest.TestCase):
    """BIOS MOVE uses HL=dst, DE=src; HL must survive bios_call_bank4."""

    def test_bios_move_swaps_for_ldir(self):
        text = source("src/bios/bios.zpa")
        body = text[text.index("bios_move:"):text.index("; @proc bios_xmove")]
        self.assertIn("ex de, hl", body)
        self.assertIn("ldir", body)

    def test_bios_call_bank4_preserves_hl(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("bios_call_bank4:"):text.index(".jp_iy:")]
        self.assertIn("push hl", body)
        self.assertIn("pop hl", body)
        self.assertIn("ld iy, (_bc4_target)", body)

    def test_stacktest_checks_move(self):
        self.assertIn("MOVE OK", source("src/test/stacktest.asm"))


class Issue10LoaderScan(unittest.TestCase):
    """The loader's 16-entry scan counter must survive LD DE,32."""

    def test_counter_is_in_memory_not_d(self):
        text = source("src/boot/loader.asm")
        body = text[text.index(".dir_entry:"):text.index("; Found CPM3.SYS")]
        self.assertIn("ld (entry_count), a", body)
        self.assertNotIn("dec d", body)
        self.assertIn("entry_count:  db 0", text)


class Issue11SubDma(unittest.TestCase):
    """try_sub must restore DMA and look on the current drive."""

    def test_try_sub_restores_dma(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index("try_sub:"):text.index("echo_sub_line:")]
        self.assertGreaterEqual(body.count("call restore_dma"), 2)
        self.assertIn("ld de, 0x0080", text)

    def test_try_sub_uses_current_drive(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index("try_sub:"):text.index(".opened:")]
        self.assertIn("ld c, 25", body)
        self.assertIn("ld (sub_fcb), a", body)


class Issue12TpaClock(unittest.TestCase):
    """The tick ISR must run in TPA mode so the clock does not freeze."""

    def test_start_tpa_installs_real_isr(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("start_tpa:"):text.index("bank_sel:")]
        self.assertIn("ld hl, isr_handler", body)
        self.assertIn("(0x0038)", body)
        self.assertNotIn("0xFB", body)

    def test_stacktest_checks_clock(self):
        self.assertIn("CLOCK OK", source("src/test/stacktest.asm"))
        self.assertIn("(0xF63A)", source("src/test/stacktest.asm"))


class Issue13SubEcho(unittest.TestCase):
    def test_echo_uses_display_bit(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index("try_sub:"):text.index("echo_sub_line:")]
        self.assertIn("and CON_MODE_DISPLAY", body)
        self.assertNotIn("xor a\n    call nz, echo_sub_line", body)


class Issue14ComFcb(unittest.TestCase):
    """The COM loader FCB must live in common memory, not the TPA top."""

    def test_ccp_uses_common_fcb(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("CCP_FCB_ADDR equ 0xFB95", text)
        self.assertIn("ld hl, CCP_FCB_ADDR", text)
        self.assertNotIn("0xF600 - 36", text)

    def test_common_reserves_fcb(self):
        text = source("src/bios/common.zpa")
        self.assertIn("ccp_fcb: ds 36", text)
        self.assertIn("ccp_fcb == 0xFB95", text)


class Issue15FdcTimeouts(unittest.TestCase):
    """FDC polling must be bounded; the data loop must not race EXM."""

    def test_transfer_loops_have_poll_timeouts(self):
        text = source("src/bios/fdc765.zpa")
        read = text[text.index("fdc_read_sector:"):text.index("fdc_write_sector:")]
        write = text[text.index("fdc_write_sector:"):text.index("fdc_send_byte:")]
        for body in (read, write):
            self.assertIn("fdc_poll", body)
            # EXM is 0 during the command phase; aborting there caused
            # zero-byte reads.  The loop counts 512 bytes instead.
            self.assertNotIn("bit 5, a", body)

    def test_command_and_seek_polls_have_timeouts(self):
        text = source("src/bios/fdc765.zpa")
        self.assertGreaterEqual(text.count("(fdc_poll), a"), 2)
        self.assertIn("fdc_seek_timeout", text)
        self.assertIn("0x2000", text)

    def test_loader_checks_exm(self):
        self.assertIn("bit 5, a", source("src/boot/loader.asm"))


class Issue16MotorSpinup(unittest.TestCase):
    def test_isr_clears_common_motor_flag(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("isr_handler:"):text.index("start_tpa:")]
        self.assertIn("ld (motor_running), a", body)
        self.assertIn("motor_running: db 0", text)

    def test_motor_on_uses_common_flag(self):
        text = source("src/bios/fdc765.zpa")
        self.assertIn("ld a, (motor_running)", text)
        self.assertNotIn("fdc_motor_on", text)


class Issue17AttributeExtent(unittest.TestCase):
    """F20/F33 extent comparisons must mask the FCB attribute bit too."""

    def test_f20_masks_both_sides(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".next_ext_cmp:"):text.index(".next_ext_name_fail")]
        self.assertEqual(body.count("and 0x7F"), 2)

    def test_f33_masks_both_sides(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".rdrand_cmp:"):text.index(".rdrand_cmp_fail")]
        self.assertEqual(body.count("and 0x7F"), 2)

    def test_disktest_covers_attr_extents(self):
        self.assertIn("Attribute-bit extent test",
                      source("src/test/disktest.asm"))


class Issue18ScbWrite(unittest.TestCase):
    """Writing one SCB field must not reset cur_disk/cur_user/DMA."""

    def test_only_the_written_field_is_pulled_back(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("scb_write_field:"):text.index("; F50: Direct BIOS Call")]
        for needle in ("scb_dma - scb_base", "scb_curdsk - scb_base",
                       "scb_user - scb_base"):
            self.assertIn(needle, body)

    def test_disktest_covers_scb_isolation(self):
        self.assertIn("T16 SCB write isolation", source("src/test/disktest.asm"))


class Issue19F30User(unittest.TestCase):
    def test_f30_checks_directory_user(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f30:"):text.index("; F31:")]
        self.assertIn("ld a, (cur_user)", body)
        self.assertIn("cp (hl)", body)

    def test_disktest_covers_user_area(self):
        self.assertIn("T17 F30 user area", source("src/test/disktest.asm"))


class Issue20BshZero(unittest.TestCase):
    """BSH=0 must not shift 256 times, and no IXH/IXL opcodes."""

    def test_every_bsh_shift_is_zero_safe(self):
        text = source("src/bdos/bdos.zpa")
        occurrences = list(re.finditer(r"ld a, \(cached_bsh\)\n((?:.*\n){0,4})", text))
        self.assertGreaterEqual(len(occurrences), 6)
        for m in occurrences:
            self.assertRegex(m.group(1), r"\bor a\b")
            self.assertRegex(m.group(1), r"\bjr z\b")

    def test_no_undocumented_ixh_ixl(self):
        text = source("src/bdos/bdos.zpa")
        self.assertNotIn("ixh", text.lower())
        self.assertNotIn("ixl", text.lower())


class VerificationDirCacheKey(unittest.TestCase):
    """The directory sector number must survive the BIOS call.

    Regression found by DISKTEST T4: the sector was read from BC after
    set_dma/disk_read had already replaced BC with the dirbuf address, so
    write_dir_entry wrote the directory to track 7 and file creation was
    silently lost.
    """

    def test_sector_is_saved_before_bios_calls(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("read_dir_entry:"):text.index("write_dir_entry:")]
        self.assertRegex(
            body, r"\.need_read:\s*\n\s*ld a, b\s*\n\s*push af")
        self.assertRegex(
            body,
            r"pop hl[^\n]*\n\s*ld \(bdos_dma\), hl[^\n]*\n\s*pop bc[^\n]*\n"
            r"\s*ld a, b[^\n]*\n\s*ld \(last_dir_sec\), a")
        self.assertIn("ld a, (disk_drive)\n    ld (last_dir_drv), a", body)

    def test_error_path_pops_the_saved_sector(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".read_error_dma:"):text.index("write_dir_entry:")]
        self.assertRegex(body, r"pop hl[^\n]*\n\s*ld \(bdos_dma\), hl")
        self.assertRegex(body, r"pop bc[^\n]*\n\s*pop af")


class VerificationExtentFlush(unittest.TestCase):
    """F21 must persist RC/allocation after every write.

    Regression found by DISKTEST T11: writing records in EX=0 and then a
    record in EX=1 left EX=0's directory entry at RC=0/allocation=0,
    because only the final extent was flushed by close.
    """

    def test_write_flushes_current_extent(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".wseq_no_rc:"):text.index(".wseq_alloc:")]
        self.assertRegex(body, r"call writeback_fcb\(\)[^\n]*\n"
                               r"\s*call close_dir_update[^\n]*\n"
                               r"\s*jp bdos_eok")

    def test_f34_still_uses_the_random_write_path(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f34:"):text.index("; F35:")]
        self.assertIn("jp bf_f21_core", body)


class VerificationStackTestMath(unittest.TestCase):
    """STKTEST's BIOS entry calculation must use 3 bytes per entry."""

    def test_compute_bios_entry_is_three_times_fn(self):
        text = source("src/test/stacktest.asm")
        body = text[text.index("compute_bios_entry:"):text.index("call_bios_ent:")]
        self.assertRegex(
            body,
            r"ld e, l[^\n]*\n\s*ld d, h[^\n]*\n\s*add hl, hl[^\n]*\n\s*add hl, de")

    def test_move_selects_tpa_banks_with_xmove(self):
        text = source("src/test/stacktest.asm")
        self.assertIn("ld a, 29", text)
        self.assertIn("B = dest bank 0 (TPA), C = src bank 0", text)


class VerificationF46Stub(unittest.TestCase):
    """F46 is a documented stub; the runtime test must assert that contract."""

    def test_disktest_checks_stub_contract(self):
        text = source("src/test/disktest.asm")
        body = text[text.index("test10:"):text.index("test11:")]
        self.assertIn("0xAA", body)          # DMA sentinel
        self.assertIn("or a", body)          # A = 0
        self.assertIn("or l", body)          # HL = 0
        self.assertIn("T10 F46 stub", text)


class P2WriteReturnCodes(unittest.TestCase):
    """F21/F34/F40 distinguish directory-full from disk-full."""

    def test_f21_disk_full_returns_2(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".wseq_alloc:"):text.index(".wseq_new_extent:")]
        self.assertIn("jp c, .wseq_diskfull", body)
        disk = body[body.index(".wseq_diskfull:"):body.index(".wseq_ret:")]
        self.assertIn("ld a, 2", disk)

    def test_f21_directory_full_returns_1(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".wseq_full:"):text.index(".wseq_diskfull:")]
        self.assertIn("ld a, 1", body)

    def test_f34_directory_full_returns_1(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f34:"):text.index("; F35:")]
        full = body[body.index(".wrrand_full:"):body.index(".wrrand_range:")]
        self.assertIn("ld a, 1", full)

    def test_f40_directory_full_returns_5(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f40:"):text.index("; @proc div_hl_bc")]
        full = body[body.index(".wrrand0_full:"):body.index(".wrrand0_range:")]
        self.assertIn("ld a, 5", full)

    def test_write_error_uses_shared_fail_stub(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".wseq_error:"):text.index(".wseq_new_extent:")]
        self.assertIn("jp bdos_efail", body)


class P2F36Returns(unittest.TestCase):
    """F36 must leave a defined success result in A/HL."""

    def test_f36_returns_eok(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f36:"):text.index("; F40:")]
        self.assertIn("ld (ix + 33), l", body)
        self.assertIn("ld (ix + 34), h", body)
        self.assertIn("ld (ix + 35), 0", body)
        self.assertIn("jp bdos_eok", body)
        self.assertNotIn("jp bdos_ret", body)


if __name__ == "__main__":
    unittest.main()
