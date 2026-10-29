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
        self.assertIn("jr z, .te_ask", dispatch)

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
        self.assertIn("jr z, .te_reset", dispatch)

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
        self.assertIn("jr z, .te_set_ink", dispatch)

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
        self.assertIn("MOTOR_OFF_DELAY", body)
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
