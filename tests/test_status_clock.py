"""The status-line clock.

The status row shows HH:MM taken from `scb_minute`, the software clock the
ISR keeps in common memory.  The machine has no RTC, so this is elapsed time
since cold boot (or a time set through DATE / BDOS F104).

These are structural checks on the wiring; the behaviour is exercised at run
time by tools/zx84_smoke.py, which writes `scb_minute` and reads row 23 of
`char_buffer` back at every screen width and in 24x80.
"""

from __future__ import annotations

import unittest

from .layout import source, screen_source


class StatusClock(unittest.TestCase):
    def setUp(self):
        self.screen = screen_source()
        self.screen5 = source("src/bios/screen5.zpa")

    def test_the_row_is_drawn_from_scb_minute(self):
        draw = self.screen[self.screen.index("_clk_draw:"):
                           self.screen.index("_stl_draw:")]
        self.assertIn("scb_minute", draw)
        # Hour = minute / 60, remainder = minute % 60, both already in the
        # BDOS; the clock reuses them rather than dividing again.
        self.assertIn("div_hl_60", draw)

    def test_the_tick_is_cheap_and_preserves_everything(self):
        """It is called from the keyboard scan, which must not clobber."""
        tick = self.screen[self.screen.index("_clk_tick:"):
                           self.screen.index("_clk_draw:")]
        # Nothing to do at all when the status line is off...
        self.assertIn("stl_on", tick)
        # ...and a 16-bit compare against the minute last drawn when it is on.
        self.assertIn("clk_shown", tick)
        self.assertIn("sbc hl, de", tick)
        # Every register is saved: kbd_status and scr_status promise not to
        # clobber, and _kbd_scan inherits that promise.
        for reg in ("push af", "push bc", "push de", "push hl", "push ix"):
            self.assertIn(reg, tick)
        for reg in ("pop ix", "pop hl", "pop de", "pop bc", "pop af"):
            self.assertIn(reg, tick)

    def test_the_tick_runs_from_the_keyboard_scan(self):
        """kbd_status and kbd_getchar both call _kbd_scan.

        kbd_getchar blocks in a halt loop at the CCP prompt and calls the
        scan once per frame, so hooking the scan is what makes the row tick
        while the machine is idle.
        """
        keyboard = source("src/bios/keyboard.zpa")
        body = keyboard[keyboard.index("_kbd_scan:"):
                        keyboard.index(".scan_matrix:")]
        self.assertIn("call _clk_tick", body)

    def test_the_status_line_redraw_includes_the_clock(self):
        """_stl_draw blanks the row, so it must put the clock back."""
        draw = self.screen[self.screen.index("_stl_draw:"):
                           self.screen.index("_stl_mark:")]
        blank = draw.index("_blank_render_range")
        clock = draw.index("call _clk_draw")
        self.assertLess(blank, clock, "the clock is drawn before the blank")

    def test_the_clock_stops_short_of_the_page_marker(self):
        """The '>' marker owns the last cell in 24x80."""
        draw = self.screen[self.screen.index("_clk_draw:"):
                           self.screen.index("_stl_draw:")]
        self.assertIn("sub 6", draw,
                      "the clock must start six cells from the edge")

    def test_the_bank5_renderer_pages_out(self):
        top = self.screen5[self.screen5.index("_clk_draw_b5:"):]
        end = top.index("; @proc _stl_mark_b5")
        self.assertIn("_row_buf_addr", top[:end])
        self.assertIn("_render_char", top[:end])
        self.assertTrue(top[:end].rstrip().endswith("jp _page_out"),
                        "bank-5 code must leave with jp _page_out")

    def test_state_lives_outside_the_image(self):
        """clk_* are bank-6 scratch, next to the other screen state."""
        for name, addr in (("clk_shown", "0xA8E0"), ("clk_text", "0xA8E2"),
                           ("clk_col", "0xA8E7"), ("clk_i", "0xA8E8")):
            self.assertIn(f"{name}:", self.screen)
            self.assertRegex(
                self.screen,
                rf"{name}:\s*equ\s+{addr}",
                f"{name} moved; the sentinel gap in zx84_smoke.py must follow")

    def test_the_two_digit_formatter_handles_limits(self):
        body = self.screen[self.screen.index("_clk_two:"):
                           self.screen.index("_stl_draw:")]
        self.assertIn("cp 10", body)
        self.assertIn("sub 10", body)


class ClockVsTwentyFour80(unittest.TestCase):
    def test_blanking_does_not_touch_the_marker_column(self):
        """In 24x80 _stl_draw draws markers after the clock; they must not
        overlap (the clock stops at scr_cols-2)."""
        screen = screen_source()
        draw = screen[screen.index("_stl_draw:"):screen.index("_stl_mark:")]
        self.assertIn("lg_off", draw)      # '<' still drawn
        self.assertIn("80", draw)          # and the right-hand bound


if __name__ == "__main__":
    unittest.main()
