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
