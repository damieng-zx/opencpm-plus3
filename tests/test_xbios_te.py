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
