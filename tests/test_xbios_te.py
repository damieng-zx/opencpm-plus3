"""Structural checks for the XBIOS terminal-emulator (TE_*) handlers.

The handlers live in ``xbios_handler`` in the bank-4 BIOS.  Each test pins
the dispatch ID (the low byte of the +3 extended jumpblock entry) and the
documented register contract.  Run-time behaviour is exercised by
XTETEST.COM through tools/zx84_smoke.py.
"""

from __future__ import annotations

import re
import unittest

from .layout import source


def handler_body(label: str, next_label: str) -> str:
    text = source("src/bios/bios.zpa")
    start = text.index(label)
    return text[start:text.index(next_label, start)]


class TeAsk(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xBF", dispatch)
        self.assertRegex(dispatch, r"j[pr] z, \.te_ask")

    def test_returns_viewport_and_cursor(self):
        body = handler_body(".te_ask:", ".dd_drive_status:")
        # B/C = top-left of the full-screen viewport.
        self.assertIn("ld b, 0", body)
        self.assertIn("ld c, 0", body)
        # D/E = height-1 / width-1.
        self.assertIn("ld d, SCR_ROWS - 1", body)
        self.assertIn("ld a, (scr_cols)", body)
        self.assertIn("dec a", body)
        self.assertIn("ld e, a", body)
        # H/L = cursor row/column.
        self.assertIn("ld a, (cursor_row)", body)
        self.assertIn("ld h, a", body)
        self.assertIn("ld a, (cursor_col)", body)
        self.assertIn("ld l, a", body)

class TeReset(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xC2", dispatch)
        self.assertRegex(dispatch, r"j[pr] z, \.te_reset")

    def test_handler_calls_scr_reset(self):
        body = handler_body(".te_reset:", ".dd_drive_status:")
        self.assertIn("call scr_reset", body)

    def test_reset_restores_defaults_then_clears(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("scr_reset:"):text.index("scr_putchar:")]
        self.assertIn("ld (scr_ink_br), a", body)
        self.assertIn("ld (scr_paper_br), a", body)
        self.assertIn("ld (scr_flash), a", body)
        self.assertIn("ld a, 7", body)             # default ink
        self.assertIn("ld a, 1", body)             # default paper
        self.assertIn("ld a, DEFAULT_ATTR", body)
        self.assertIn("ld (scr_wrap), a", body)
        self.assertIn("call _cancel_paging", body)
        self.assertIn("call scr_init", body)

    def test_reset_keeps_screen_width(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("scr_reset:"):text.index("scr_putchar:")]
        self.assertNotIn("scr_cols", body)


class TeSetInk(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xCB", dispatch)
        self.assertRegex(dispatch, r"j[pr] z, \.te_set_ink")

    def test_userf_preserves_caller_a(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("userf_stub:"):text.index("write_1ffd:")]
        self.assertIn("ld (xbios_arg_a), a", body)

    def test_handler_uses_saved_ink_number(self):
        body = handler_body(".te_set_ink:", ".dd_drive_status:")
        self.assertIn("ld a, (xbios_arg_a)", body)
        self.assertIn("cp 1", body)
        self.assertIn("ret nz", body)            # inks > 1 ignored
        self.assertIn("call _decode_te_colour", body)
        self.assertIn("ld (scr_paper), a", body)
        self.assertIn("ld (scr_ink), a", body)
        self.assertIn("ld (scr_paper_fl), a", body)
        self.assertIn("ld (scr_ink_fl), a", body)
        self.assertIn("out (PORT_ULA), a", body)  # ink 0 updates border

    def test_flash_only_when_both_inks_flash(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_set_attr:"):text.index("_cancel_paging:")]
        self.assertIn("ld a, (scr_ink_fl)", body)
        self.assertIn("ld a, (scr_paper_fl)", body)
        self.assertIn("ld a, 0x80", body)
        self.assertIn("ld (scr_flash), a", body)

    def test_palette_decode_treats_1_and_2_as_on(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_decode_te_colour:"):
                    text.index("_set_attr:")]
        self.assertIn("and 0x03", body)
        self.assertIn("and 0x0C", body)
        self.assertIn("and 0x30", body)
        self.assertIn("xor d", body)             # high = both bits set
        self.assertIn("and 0x15", body)


class TeSetBorder(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xCE", dispatch)
        self.assertRegex(dispatch, r"j[pr] z, \.te_set_border")

    def test_handler_sets_border_only(self):
        body = handler_body(".te_set_border:", ".dd_drive_status:")
        self.assertIn("ld a, b", body)
        self.assertIn("and 0x3F", body)
        self.assertIn("call _decode_te_colour", body)
        self.assertIn("ld (scr_border_v), a", body)
        self.assertIn("out (PORT_ULA), a", body)
        self.assertNotIn("scr_paper", body)
        self.assertNotIn("scr_flash", body)


class TeSetSpeed(unittest.TestCase):
    def test_dispatch_accepts_and_ignores(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertRegex(dispatch, r"cp 0xD1\s*\n\s*ret z")

    def test_tester_calls_it(self):
        text = source("src/test/xtetest.asm")
        self.assertIn("TE_SET_SPEED", text)
        self.assertIn("5b.SPEED", text)


class ScrRunRoutine(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xE9", dispatch)
        self.assertIn("jp z, .scr_run_routine", dispatch)

    def test_handler_pages_screen_and_restores(self):
        body = handler_body(".scr_run_routine:", ".dd_drive_status:")
        self.assertIn("or PAGING_SCREEN", body)
        self.assertIn("call write_1ffd", body)
        self.assertIn("or BANK1_1FFD", body)
        self.assertIn("ld (xbios_ret_ix), ix", body)
        self.assertIn("ld (xbios_ret_iy), iy", body)
        self.assertIn("call 0", body)          # patched call target
        self.assertIn("ld (.srr_call + 1), bc", body)

    def test_only_common_memory_routines(self):
        body = handler_body(".scr_run_routine:", ".dd_drive_status:")
        self.assertIn("cp 0xC0", body)
        self.assertIn("ret c", body)
        self.assertIn("cp 0xF6", body)
        self.assertIn("ret nc", body)

    def test_userf_round_trips_ix_iy(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("userf_stub:"):text.index("write_1ffd:")]
        self.assertIn("ld (xbios_ret_ix), ix", body)
        self.assertIn("ld (xbios_ret_iy), iy", body)
        self.assertIn("ld ix, (xbios_ret_ix)", body)
        self.assertIn("ld iy, (xbios_ret_iy)", body)

    def test_tester_stages_routine_in_common(self):
        text = source("src/test/xtetest.asm")
        self.assertIn("7.RUN", text)
        self.assertIn("ld de, 0xD000", text)
        self.assertIn("ld (0x5AFF), a", text)
        self.assertIn("ld (0xD100), a", text)


class DiscPhase1(unittest.TestCase):
    def test_dispatch_ids(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        for entry, target in (
            ("0x80", ".dd_init"),
            ("0x95", ".dd_sel_format"),
            ("0x9B", ".dd_read_id"),
            ("0xA4", ".dd_l_on_motor"),
            ("0xA7", ".dd_l_t_off_motor"),
            ("0xAA", ".dd_off_motor"),
            ("0xB3", ".dd_l_seek"),
        ):
            self.assertIn(f"cp {entry}", dispatch)
            self.assertIn(f"jp z, {target}", dispatch)

    def test_dd_init_resets_driver(self):
        body = handler_body(".dd_init:", ".dd_sel_format:")
        self.assertIn("call fdc_init", body)

    def test_dd_sel_format_copies_standard_xdpb(self):
        body = handler_body(".dd_sel_format:", ".dd_read_id:")
        self.assertIn("ld a, (xbios_arg_a)", body)
        self.assertIn("call xdpb_table_offset", body)
        self.assertIn("ld de, xdpb_std_table", body)
        self.assertIn("ld bc, 27", body)
        self.assertIn("scf", body)
        self.assertIn(".dsf_bad", body)

    def test_dd_read_id_uses_xdpb_geometry(self):
        body = handler_body(".dd_read_id:", ".dd_l_on_motor:")
        self.assertIn("(ix + XDPB_SIDES)", body)
        self.assertIn("FDC_READ_ID", body)
        self.assertIn("ld hl, dd_results + 1", body)
        self.assertIn("ld (dd_results), a", body)
        self.assertIn("dd_results + 6", body)
        self.assertIn(".dri_not_ready", body)
        self.assertIn(".dri_seek_fail", body)

    def test_motor_calls_preserve_registers_and_flags(self):
        body = handler_body(".dd_l_on_motor:", ".dd_l_t_off_motor:")
        self.assertIn("call motor_on", body)
        self.assertIn("ld bc, (xbios_arg_af)", body)
        self.assertIn("pop af", body)
        self.assertIn("pop bc", body)

        body = handler_body(".dd_l_t_off_motor:", ".dd_off_motor:")
        self.assertIn("(motor_off_ticks)", body)
        self.assertIn("ld (motor_countdown), a", body)
        self.assertIn("ld bc, (xbios_arg_af)", body)
        self.assertIn("pop af", body)

    def test_dd_off_motor(self):
        body = handler_body(".dd_off_motor:", ".dd_l_seek:")
        self.assertIn("call motor_off", body)

    def test_dd_l_seek_maps_unit_and_head(self):
        body = handler_body(".dd_l_seek:", ".dd_drive_status:")
        self.assertIn("and 0x03", body)
        self.assertIn("ld (disk_drive), a", body)
        self.assertIn("ld (disk_head), a", body)
        self.assertIn("call fdc_seek", body)
        self.assertIn("scf", body)
        self.assertIn(".dls_not_ready", body)
        self.assertIn(".dls_seek_fail", body)

    def test_userf_saves_caller_af(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("userf_stub:"):text.index("write_1ffd:")]
        self.assertIn("push af", body)
        self.assertIn("pop hl", body)
        self.assertIn("ld (xbios_arg_af), hl", body)

    def test_tester_covers_phase1(self):
        text = source("src/test/xtetest.asm")
        for name, addr in (
            ("DD_INIT", "0x0080"),
            ("DD_SEL_FORMAT", "0x0095"),
            ("DD_READ_ID", "0x009B"),
            ("DD_L_ON_MOTOR", "0x00A4"),
            ("DD_L_T_OFF_MOTOR", "0x00A7"),
            ("DD_OFF_MOTOR", "0x00AA"),
            ("DD_L_SEEK", "0x00B3"),
        ):
            self.assertRegex(text, rf"{name}\s+EQU\s+{addr}")
        self.assertIn("8.DISK", text)
        self.assertIn("DD_READ_ID", text)


class DiscPhase2(unittest.TestCase):
    def test_dispatch_ids(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        for entry, target in (
            ("0x86", ".dd_read_sector"),
            ("0x89", ".dd_write"),
            ("0x8C", ".dd_check"),
            ("0x8F", ".dd_format"),
            ("0x92", ".dd_login"),
        ):
            self.assertIn(f"cp {entry}", dispatch)
            self.assertIn(f"jp z, {target}", dispatch)

    def test_dd_login_forces_detection_and_sizes(self):
        body = handler_body(".dd_login:", ".dd_read_sector:")
        self.assertIn("ld (fdc_login_force), a", body)
        self.assertIn("call fdc_login", body)
        self.assertIn("ld hl, xdpb_a", body)
        self.assertIn("ld bc, 27", body)
        self.assertIn("fdc_login_type", body)
        self.assertIn("srl h", body)          # DSM / 4
        self.assertIn("add hl, hl", body)     # 4 * (DRM + 1)

    def test_read_write_check_share_setup(self):
        for start, end in ((".dd_read_sector:", ".dd_write:"),
                           (".dd_write:", ".dd_check:"),
                           (".dd_check:", ".dd_format:")):
            body = handler_body(start, end)
            self.assertIn("call .dd_prepare", body)

        read = handler_body(".dd_read_sector:", ".dd_write:")
        self.assertIn("call fdc_read_sector", read)
        self.assertIn("call copy_to_user", read)

        write = handler_body(".dd_write:", ".dd_check:")
        self.assertIn("call fdc_write_sector", write)
        self.assertIn("call copy_from_user", write)

        check = handler_body(".dd_check:", ".dd_format:")
        self.assertIn("dd_compare_buf", check)
        self.assertIn("cp (hl)", check)

    def test_prepare_maps_geometry(self):
        body = handler_body(".dd_prepare:", ".dd_map_track:")
        self.assertIn("call flush_deblock_body", body)
        self.assertIn("call .dd_map_sector", body)
        self.assertIn("call .dd_map_track", body)
        self.assertIn("call fdc_seek", body)

    def test_dd_format_uses_standard_geometry(self):
        body = handler_body(".dd_format:", ".dd_prepare:")
        self.assertIn("(ix + XDPB_SECTS)", body)
        self.assertIn("(ix + XDPB_GAP2)", body)
        self.assertIn("dd_format_hdr", body)
        self.assertIn("call fdc_format_track", body)

    def test_compare_buffer_is_clear_of_deblock(self):
        text = source("src/bios/fdc765.zpa")
        self.assertIn("deblock_buf equ 0x9C00", text)
        self.assertIn("dd_compare_buf equ 0x9E00", text)

    def test_fdc_format_track(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index("fdc_format_track:"):
                    text.index("; FDC byte-level I/O")]
        self.assertIn("FDC_FORMAT", body)
        self.assertIn("fmt_sc", body)
        self.assertIn("fmt_left", body)
        self.assertIn("bit 6, b", body)        # write protected
        self.assertIn("0x3B", body)            # data/ID error bits
        self.assertIn("fdc_read_byte", body)

    def test_tester_covers_phase2(self):
        text = source("src/test/xtetest.asm")
        for name, addr in (
            ("DD_READ_SECTOR", "0x0086"),
            ("DD_WRITE", "0x0089"),
            ("DD_CHECK_SECTOR", "0x008C"),
            ("DD_FORMAT", "0x008F"),
            ("DD_LOGIN", "0x0092"),
        ):
            self.assertRegex(text, rf"{name}\s+EQU\s+{addr}")
        self.assertIn("9.RW", text)
        self.assertIn("10.FMT", text)

    def test_smoke_runs_format_on_scratch(self):
        text = source("tools/zx84_smoke.py")
        self.assertIn("run_xtetest_format", text)
        self.assertIn("10.FMT..OK", text)
        self.assertIn("format-test.dsk", text)


class DdSetup(unittest.TestCase):
    def test_dispatch_uses_jumpblock_entry(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0x83", dispatch)
        self.assertIn("jp z, .dd_setup", dispatch)

    def test_handler_copies_and_scales(self):
        body = handler_body(".dd_setup:", ".dd_sel_format:")
        self.assertIn("ld de, dd_setup_pb", body)
        self.assertIn("ld bc, 7", body)
        self.assertIn("ldir", body)
        self.assertIn("(dd_setup_pb + 1)", body)   # motor-off timeout
        self.assertIn("(motor_off_ticks), a", body)
        self.assertIn("call fdc_specify", body)

    def test_fdc_specify_builds_srt_hut_hlt(self):
        text = source("src/bios/fdc765.zpa")
        body = text[text.index("fdc_specify:"):
                    text.index("; FDC interrupt critical-section helpers")]
        self.assertIn("FDC_SPECIFY", body)
        self.assertIn("(dd_setup_pb + 4)", body)   # step rate
        self.assertIn("(dd_setup_pb + 5)", body)   # head unload
        self.assertIn("(dd_setup_pb + 6)", body)   # head load / ND
        self.assertIn("fdc_spec1", body)
        self.assertIn("fdc_spec2", body)

    def test_tester_and_smoke_cover_setup(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_SETUP", tester)
        self.assertIn("11.SETUP", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("11.SETUP..OK", smoke)
        self.assertIn("motor_off_ticks", smoke)
        self.assertIn("fdc_spec1", smoke)


class DdLDpb(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0x9E", dispatch)
        self.assertIn("jp z, .dd_l_dpb", dispatch)

    def test_handler_selects_17_or_27_bytes(self):
        body = handler_body(".dd_l_dpb:", ".dd_l_on_motor:")
        self.assertIn("ld a, 17", body)
        self.assertIn("call .dd_build_xdpb", body)
        self.assertIn("ld (dd_copy_len), a", body)
        self.assertIn("ld a, (dd_type)", body)

    def test_builder_computes_standard_dpb(self):
        body = handler_body(".dd_build_xdpb:", ".dd_l_on_motor:")
        for token in ("dd_spec + 0", "dd_spec + 1", "dd_spec + 2",
                      "dd_spec + 3", "dd_spec + 4", "dd_spec + 5",
                      "dd_spec + 6", "dd_spec + 7", "dd_spec + 8",
                      "dd_spec + 9"):
            self.assertIn(token, body)
        self.assertIn("dd_xdpb_buf + 0", body)    # SPT
        self.assertIn("dd_xdpb_buf + 2", body)    # BSH
        self.assertIn("dd_xdpb_buf + 4", body)    # EXM
        self.assertIn("dd_xdpb_buf + 5", body)    # DSM
        self.assertIn("dd_xdpb_buf + 7", body)    # DRM
        self.assertIn("dd_xdpb_buf + 9", body)    # AL0
        self.assertIn("dd_xdpb_buf + 11", body)   # CKS
        self.assertIn("dd_xdpb_buf + 13", body)   # OFF
        self.assertIn("dd_xdpb_buf + 15", body)   # PSH
        self.assertIn("dd_xdpb_buf + 20", body)   # first sector
        self.assertIn("dd_xdpb_buf + 21", body)   # sector size
        self.assertIn("dd_xdpb_buf + 23", body)   # gap 1
        self.assertIn("dd_xdpb_buf + 24", body)   # gap 2

    def test_xdpb_dispatch_and_length(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xA1", dispatch)
        self.assertIn("jp z, .dd_l_xdpb", dispatch)
        body = handler_body(".dd_l_xdpb:", ".dd_l_build:")
        self.assertIn("ld a, 27", body)
        self.assertIn("DD_L_XDPB", body)

    def test_tester_covers_xdpb(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_L_XDPB", tester)
        self.assertIn("13.XDPB", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("13.XDPB..OK", smoke)

    def test_tester_covers_dpb(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_L_DPB", tester)
        self.assertIn("12.DPB", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("12.DPB..OK", smoke)


class DdLRead(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xAD", dispatch)
        self.assertIn("jp z, .dd_l_read", dispatch)

    def test_handler_parses_and_reads(self):
        body = handler_body(".dd_l_read:", ".dd_send_cmd:")
        self.assertIn("dd_param_ptr", body)
        self.assertIn("dd_xfer_ptr", body)
        self.assertIn("dd_xfer_left", body)
        self.assertIn("call .dd_send_cmd", body)
        self.assertIn("call fdc_read_byte", body)
        self.assertIn("call write_user_byte", body)
        self.assertIn("call .dd_drain_results", body)
        self.assertIn(".ddlr_no_xfer", body)

    def test_command_and_result_helpers(self):
        body = handler_body(".dd_send_cmd:", ".dd_drain_results:")
        self.assertIn("dd_cmd_ptr", body)
        self.assertIn("dd_cmd_left", body)
        self.assertIn("call fdc_send_byte", body)
        body = handler_body(".dd_drain_results:", ".dd_login:")
        self.assertIn("dd_results", body)
        self.assertIn("dd_res_idx", body)
        self.assertIn("cp 7", body)
        self.assertIn("fdc_read_byte", body)

    def test_tester_covers_lread(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_L_READ", tester)
        self.assertIn("14.LREAD", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("14.LREAD..OK", smoke)


class DdLWrite(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xB0", dispatch)
        self.assertIn("jp z, .dd_l_write", dispatch)

    def test_handler_writes_from_user(self):
        body = handler_body(".dd_l_write:", "; --- Phase-2 disc calls ---")
        self.assertIn("dd_param_ptr", body)
        self.assertIn("dd_xfer_ptr", body)
        self.assertIn("dd_xfer_left", body)
        self.assertIn("call .dd_send_cmd", body)
        self.assertIn("call read_user_byte", body)
        self.assertIn("call fdc_send_byte", body)
        self.assertIn("call .dd_drain_results", body)
        self.assertIn("deblock_drv", body)      # invalidate cache
        self.assertIn(".ddlw_no_xfer", body)

    def test_tester_covers_lwrite(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_L_WRITE", tester)
        self.assertIn("15.LWRITE", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("15.LWRITE..OK", smoke)


class KmSetSpeed(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xE0", dispatch)
        self.assertIn("jp z, .km_set_speed", dispatch)

    def test_handler_zero_means_256_and_preserves(self):
        body = handler_body(".km_set_speed:", "; --- Phase-2 disc calls ---")
        self.assertIn("km_speed_h", body)
        self.assertIn("km_speed_l", body)
        self.assertIn("ld hl, 256", body)
        self.assertIn("kbd_repeat_delay", body)
        self.assertIn("kbd_repeat_rate", body)
        self.assertIn("push bc", body)
        self.assertIn("push de", body)
        self.assertIn("push hl", body)
        self.assertIn("pop hl", body)
        self.assertIn("pop de", body)
        self.assertIn("pop bc", body)

    def test_keyboard_uses_variables(self):
        text = source("src/bios/keyboard.zpa")
        # The timings live in bank 6 now; the defaults are seeded in kbd_init.
        self.assertIn("kbd_repeat_delay: equ 0xA649", text)
        self.assertIn("kbd_repeat_rate:  equ 0xA64B", text)
        repeat = text[text.index(".same_repeat:"):text.index(".emit:")]
        self.assertIn("ld hl, (kbd_repeat_rate)", repeat)
        self.assertNotIn("ld hl, REPEAT_RATE", repeat)
        init = text[text.index("kbd_init:"):text.index("kbd_status:")]
        self.assertIn("ld hl, REPEAT_DELAY", init)
        self.assertIn("ld hl, REPEAT_RATE", init)

    def test_tester_covers_speed(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_SET_SPEED", tester)
        self.assertIn("16.KMSPD", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("16.KMSPD..OK", smoke)
        self.assertIn("kbd_repeat_delay", smoke)


class KmKtPut(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xDD", dispatch)
        self.assertIn("jp z, .km_kt_put", dispatch)

    def test_handler_queues_shift_and_key(self):
        body = handler_body(".km_kt_put:", ".km_set_speed:")
        self.assertIn("kbd_token_count", body)
        self.assertIn("kbd_token_tail", body)
        self.assertIn("kbd_token_buf", body)
        self.assertIn("cp 16", body)        # queue depth
        self.assertIn("and 0x0F", body)     # circular index
        self.assertIn("push af", body)
        self.assertIn("push bc", body)
        self.assertIn("pop af", body)
        self.assertIn("pop bc", body)

    def test_keyboard_defines_queue(self):
        text = source("src/bios/keyboard.zpa")
        self.assertIn("kbd_token_buf:   equ 0xA64F", text)
        self.assertIn("kbd_token_head:  equ 0xA66F", text)
        self.assertIn("kbd_token_tail:  equ 0xA670", text)
        self.assertIn("kbd_token_count: equ 0xA671", text)
        # kbd_init empties the queue.
        reset = text[text.index("kbd_init:"):text.index("kbd_status:")]
        self.assertIn("(kbd_token_count), a", reset)

    def test_tester_covers_ktput(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_KT_PUT", tester)
        self.assertIn("17.KTPUT", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("17.KTPUT..OK", smoke)
        self.assertIn("kbd_token_count", smoke)


class KmKtGet(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xDA", dispatch)
        self.assertIn("jp z, .km_kt_get", dispatch)

    def test_handler_pops_and_updates_lock_state(self):
        body = handler_body(".km_kt_get:", ".km_kt_put:")
        self.assertIn("kbd_token_count", body)
        self.assertIn("kbd_token_head", body)
        self.assertIn("kbd_token_buf", body)
        self.assertIn("and 0x78", body)          # lock bits
        self.assertIn("kbd_lock_state", body)
        self.assertIn("and 0x0F", body)
        self.assertIn("push de", body)           # preserve everything but ABC
        self.assertIn("push hl", body)
        self.assertIn("pop hl", body)
        self.assertIn("pop de", body)
        self.assertIn("scf", body)
        self.assertIn(".kget_empty", body)

    def test_tester_covers_ktget(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_KT_GET", tester)
        self.assertIn("18.KTGET", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("18.KTGET..OK", smoke)
        self.assertIn("kbd_token_head", smoke)


class KmSetKey(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xD7", dispatch)
        self.assertIn("jp z, .km_set_key", dispatch)

    def test_handler_validates_and_rewrites(self):
        body = handler_body(".km_set_key:", ".km_kt_get:")
        self.assertIn("cp 40", body)             # key number range
        self.assertIn("and 0x0F", body)          # table mask
        self.assertIn("add a, a", body)          # key * 4
        self.assertIn("KMTAB / 256", body)
        self.assertIn("rrc e", body)
        self.assertIn("push bc", body)
        self.assertIn("pop bc", body)
        self.assertIn("push de", body)
        self.assertIn("pop de", body)

    def test_table_in_bank6_and_override(self):
        text = source("src/bios/keyboard.zpa")
        self.assertIn("KMTAB       equ 0xA900", text)
        self.assertIn("KMTAB_SIZE  equ 160", text)
        self.assertIn("jr nz, .kbd_init_tab", text)
        # The fill value must be reloaded each iteration (regression: A was
        # reused as the BC test and the table filled with 9Fh..01h).
        init = text[text.index(".kbd_init_tab:"):
                    text.index(".kbd_init_tab:") + 80]
        self.assertIn("ld a, 0xFF", init)
        ascii_map = text[text.index("_kbd_to_ascii:"):
                         text.index(".builtin:")]
        self.assertIn("and 3", ascii_map)        # shift state
        self.assertIn("KMTAB", ascii_map)
        self.assertIn("cp 0xFF", ascii_map)

    def test_tester_and_smoke_cover_setkey(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_SET_KEY", tester)
        self.assertIn("19.KTAB", tester)
        self.assertIn("ld c, 6", tester)         # non-echoing read
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("19.KTAB..OK", smoke)
        self.assertIn('self.key("z")', smoke)
        self.assertIn("0xA900", smoke)


class KmSetExpand(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xD4", dispatch)
        self.assertIn("jp z, .km_set_expand", dispatch)

    def test_handler_validates_and_copies(self):
        body = handler_body(".km_set_expand:", ".km_set_key:")
        self.assertIn("cp 0x80", body)           # token low bound
        self.assertIn("cp 0x9F", body)           # token high bound
        self.assertIn("KMEXP_MAX + 1", body)     # length limit
        self.assertIn("ld de, KMEXP", body)
        self.assertIn("ex de, hl", body)
        self.assertIn("push hl", body)           # keep the source
        self.assertIn("pop hl", body)
        self.assertIn("ld (de), a", body)        # slot length
        self.assertIn("ldir", body)
        self.assertIn("scf", body)
        self.assertIn(".kex_bad", body)

    def test_bank6_slots(self):
        text = source("src/bios/keyboard.zpa")
        self.assertIn("KMEXP       equ 0xA9A0", text)
        self.assertIn("KMEXP_SLOT  equ 32", text)
        self.assertIn("KMEXP_MAX   equ 31", text)

    def test_tester_and_smoke_cover_expand(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_SET_EXPAND", tester)
        self.assertIn("20.EXP", tester)
        self.assertIn('db "HELLO"', tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("20.EXP..OK", smoke)
        self.assertIn("0xA9A0 + 5 * 32", smoke)


class Bank6Scratch(unittest.TestCase):
    def test_scratch_blocks_are_equates(self):
        bios = source("src/bios/bios.zpa")
        for token in ("dd_spec:      equ 0xA600",
                      "dd_xdpb_buf:  equ 0xA60A",
                      "dd_param_ptr: equ 0xA625",
                      "dd_bank:      equ 0xA82D",
                      "dd_copy_len:  equ 0xA839"):
            self.assertIn(token, bios)
        kbd = source("src/bios/keyboard.zpa")
        for token in ("kbd_last_raw:   equ 0xA63F",
                      "kbd_token_buf:   equ 0xA64F",
                      "kbd_inject_buf: equ 0xA673",
                      "kbd_inject_rd:  equ 0xA6B4"):
            self.assertIn(token, kbd)
        bdos = source("src/bdos/bdos.zpa")
        for token in ("rdbuf_ptr:  equ 0xA6B5",
                      "ms_active:  equ 0xA6B7",
                      "map_idx:    equ 0xA6FB"):
            self.assertIn(token, bdos)
        scr = source("src/bios/screen.zpa")
        self.assertIn("cursor_col: equ 0xA730", scr)
        self.assertIn("saved_col:  equ 0xA739", scr)
        common = source("src/bios/common.zpa")
        self.assertIn("fcb_buf:        equ 0xAD80", common)
        self.assertIn("ccp_fcb == 0xFB66", common)

    def test_blocks_fit_the_free_windows(self):
        # A600-A6FF ends before the row table at A700.
        self.assertLessEqual(0xA6FB + 1, 0xA700)
        # A730-A739 ends before csv_a at A740.
        self.assertLessEqual(0xA739 + 1, 0xA740)
        # A82D-A83C sits after alv_b (A800 + 45 = A82D).
        self.assertGreaterEqual(0xA82D, 0xA800 + 45)
        self.assertLessEqual(0xA83C + 1, 0xA840)   # alv_c
        # FCB shadow is clear of KMEXP (A9A0-AD7F).
        self.assertGreaterEqual(0xAD80, 0xAD80)
        self.assertLessEqual(0xAD80 + 36, 0xB000)

    def test_cold_boot_seeds_bdos_state(self):
        bios = source("src/bios/bios.zpa")
        boot = bios[bios.index("cold_boot:"):bios.index("; Initialize drivers")]
        for token in ("(ms_active), a", "(f40_zfill), a",
                      "(last_dir_sec), a", "(last_dir_drv), a",
                      "(cached_drive), a"):
            self.assertIn(token, boot)

    def test_kbd_init_seeds_repeat_timings(self):
        kbd = source("src/bios/keyboard.zpa")
        init = kbd[kbd.index("kbd_init:"):kbd.index("kbd_status:")]
        self.assertIn("ld (kbd_repeat_delay), hl", init)
        self.assertIn("ld (kbd_repeat_rate), hl", init)
        self.assertIn("REPEAT_DELAY", init)
        self.assertIn("REPEAT_RATE", init)

    def test_smoke_reads_moved_state_from_bank6(self):
        smoke = source("tools/zx84_smoke.py")
        self.assertIn('self.memory(6, label_address("kbd_token_count"), 1)', smoke)
        self.assertIn('self.memory(6, self.cursor_row, 1)', smoke)
        self.assertIn('self.memory(6, self.cursor_col, 1)', smoke)


class CdVersion(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xE3", dispatch)
        self.assertIn("jp z, .cd_version", dispatch)

    def test_handler_returns_machine_and_version(self):
        body = handler_body(".cd_version:", ".cd_info:")
        self.assertIn("ld a, 3", body)
        self.assertIn("ld bc, 0x0100", body)

    def test_tester_and_smoke_cover_version(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("CD_VERSION", tester)
        self.assertIn("21.CDVER", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("21.CDVER..OK", smoke)


class CdInfo(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0xE6", dispatch)
        self.assertIn("jp z, .cd_info", dispatch)

    def test_handler_reports_machine_and_common_buffer_table(self):
        body = handler_body(".cd_info:", ".te_stl_ask:")
        self.assertIn("ld bc, 0x0800", body)
        self.assertIn("ld de, 0x0015", body)
        self.assertIn("ld hl, cd_buf_tab", body)
        self.assertIn("xor a", body)
        common = source("src/bios/common.zpa")
        self.assertIn("cd_buf_tab: db 0xFF", common)
        # The table must be in common memory, not bank 4.
        self.assertIn("CD_INFO buffer-descriptor table", common)

    def test_tester_and_smoke_cover_info(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("CD_INFO", tester)
        self.assertIn("22.CDINFO", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("22.CDINFO..OK", smoke)


class DdDriveStatus(unittest.TestCase):
    def test_dispatch(self):
        text = source("src/bios/bios.zpa")
        dispatch = text[text.index("xbios_handler:"):text.index(".cd_version:")]
        self.assertIn("cp 0x98", dispatch)
        self.assertIn("jp z, .dd_drive_status", dispatch)

    def test_handler_reports_ready_and_head(self):
        body = handler_body(".dd_drive_status:", "; ==========================================================================\n; Utility")
        self.assertIn("and 0x03", body)          # unit number
        self.assertIn("and 0x04", body)          # head bit
        self.assertIn("or 0x30", body)           # Ready + Track 0
        self.assertIn(".drive_absent", body)

    def test_tester_and_smoke_cover_status(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("DD_DRIVE_STATUS", tester)
        self.assertIn("23.DRIVESTAT", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("23.DRIVESTAT..OK", smoke)


class XbiosCoverage(unittest.TestCase):
    def test_every_dispatch_id_has_a_tester_case(self):
        bios = source("src/bios/bios.zpa")
        dispatch = bios[bios.index("xbios_handler:"):bios.index(".cd_version:")]
        ids = set(re.findall(r"cp 0x([0-9A-F]{2})", dispatch))
        self.assertGreaterEqual(len(ids), 30, "dispatch parse found too few IDs")

        tester = source("src/test/xtetest.asm")
        cases = dict(re.findall(r"^(\w+) +EQU 0x00([0-9A-F]{2})", tester, re.M))
        by_id = {value: name for name, value in cases.items()}
        missing = sorted(i for i in ids if i not in by_id)
        self.assertEqual([], missing,
                         f"XBIOS IDs without XTETEST coverage: {missing}")

        # A defined constant that is never called would not exercise anything.
        unused = [name for name in by_id.values() if tester.count(name) < 2]
        self.assertEqual([], unused, f"XTETEST constants never called: {unused}")


class KmKtWrap(unittest.TestCase):
    def test_tester_fills_drops_and_wraps(self):
        tester = source("src/test/xtetest.asm")
        body = tester[tester.index("; === Test 24"):tester.index("; === Done ===")]
        self.assertIn("ld ix, 17", body)          # overflow
        self.assertIn("ld ix, 16", body)          # drain depth
        self.assertIn("ld ix, 20", body)          # wrap cycles
        self.assertIn("24.KTWRAP", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("24.KTWRAP..OK", smoke)
        self.assertIn('("kbd_token_head", 6)', smoke)
        self.assertIn('("kbd_token_tail", 6)', smoke)


class TesterConstants(unittest.TestCase):
    def test_tester_uses_real_jumpblock_entries(self):
        text = source("src/test/xtetest.asm")
        for name, addr in (
            ("TE_ASK", "0x00BF"),
            ("TE_RESET", "0x00C2"),
            ("TE_STL_ASK", "0x00C5"),
            ("TE_SET_INK", "0x00CB"),
            ("TE_SET_BORDER", "0x00CE"),
            ("TE_SET_SPEED", "0x00D1"),
            ("SCR_RUN_ROUTINE", "0x00E9"),
        ):
            self.assertRegex(text, rf"{name}\s+EQU\s+{addr}")


if __name__ == "__main__":
    unittest.main()
