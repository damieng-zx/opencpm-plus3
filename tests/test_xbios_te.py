"""Structural checks for the XBIOS terminal-emulator (TE_*) handlers.

The handlers live in ``xbios_handler`` in the bank-4 BIOS.  Each test pins
the dispatch ID (the low byte of the +3 extended jumpblock entry) and the
documented register contract.  Run-time behaviour is exercised by
XTETEST.COM through tools/zx84_smoke.py.
"""

from __future__ import annotations

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
        self.assertIn("kbd_repeat_delay: dw REPEAT_DELAY", text)
        self.assertIn("kbd_repeat_rate:  dw REPEAT_RATE", text)
        self.assertIn("ld hl, (kbd_repeat_delay)", text)
        self.assertIn("ld hl, (kbd_repeat_rate)", text)
        self.assertNotIn("ld hl, REPEAT_DELAY", text)
        self.assertNotIn("ld hl, REPEAT_RATE", text)

    def test_tester_covers_speed(self):
        tester = source("src/test/xtetest.asm")
        self.assertIn("KM_SET_SPEED", tester)
        self.assertIn("16.KMSPD", tester)
        smoke = source("tools/zx84_smoke.py")
        self.assertIn("16.KMSPD..OK", smoke)
        self.assertIn("kbd_repeat_delay", smoke)


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
