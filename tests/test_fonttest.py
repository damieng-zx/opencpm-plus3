"""FONTTEST.COM: the character-set proof sheet draws the full set at every width.

All three fonts carry 256 glyphs, so the program has no 64-column special
case: the same box-drawing frame and junction tables, the same pages and no
"ASCII only" label.  The runtime coverage (every printable code in the text
buffer at 32, 51 and 64 columns) is in tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import source


class SixtyFourColumns(unittest.TestCase):
    def text(self) -> str:
        return source("src/test/fonttest.asm")

    def test_there_is_no_ascii_fallback(self):
        text = self.text()
        for stale in ("box_ascii", "s_ascii_only", "s_p2_64", "ASCII ONLY",
                      "fallback"):
            self.assertNotIn(stale, text)

    def test_the_64_column_layout_uses_the_box_drawing_frame(self):
        text = self.text()
        body = text[text.index(".w64:"):text.index("; cycle_width")]
        self.assertIn("ld hl, box_single", body)

    def test_the_double_line_table_is_not_width_dependent(self):
        text = self.text()
        body = text[text.index("page_boxes:"):text.index("; 3 - accents")]
        self.assertIn("ld hl, box_double", body)
        self.assertNotIn("cp 64", body)

    def test_the_header_is_the_same_at_every_width(self):
        text = self.text()
        body = text[text.index("print_header:"):text.index("; print_help")]
        self.assertNotIn("cp 64", body)

    def test_the_64_column_grids_fit_the_frame(self):
        """12 cells of 5 columns from column 2, 7 control cells of 8 from 4."""
        text = self.text()
        body = text[text.index(".w64:"):text.index("; cycle_width")]
        for line in ("ld a, 12", "ld (cells), a", "ld a, 7", "ld (ctl_cells), a",
                     "ld a, 2", "ld (grid_left), a", "ld a, 4", "ld (ctl_left), a"):
            self.assertIn(line, body)
        self.assertLessEqual(2 + 12 * 5, 64 - 2)
        self.assertLessEqual(4 + 7 * 8, 64 - 2)

    def test_pages_cover_every_printable_range(self):
        text = self.text()
        self.assertIn("ld a, 0x20\n    ld b, 96", text)    # ASCII 20-7F
        self.assertIn("ld a, 0xC0\n    ld b, 64", text)    # accents C0-FF
        for name in ("box_single", "box_double", "tpiece_bytes", "stub_bytes"):
            self.assertIn(name + ":", text)               # 80-9F
        self.assertIn("th_symbols", text)                  # A0-BF in context


class Output(unittest.TestCase):
    """A page is sent with one BDOS call, not one per byte."""

    def text(self) -> str:
        return source("src/test/fonttest.asm")

    def test_putc_queues_instead_of_calling_the_bdos(self):
        text = self.text()
        body = text[text.index("\nputc:"):text.index("; flush - send")]
        self.assertIn("ld (optr), hl", body)
        self.assertNotIn("call BDOS", body)
        self.assertNotIn("F_CONOUT", text)

    def test_flush_sends_the_buffer_with_function_111(self):
        text = self.text()
        self.assertIn("F_WRITEBLK  equ 111", text)
        body = text[text.index("\nflush:"):text.index("; puts - output")]
        self.assertIn("ld c, F_WRITEBLK", body)
        self.assertIn("call BDOS", body)

    def test_the_buffer_is_flushed_before_waiting_and_quitting(self):
        text = self.text()
        wait = text[text.index("wait_key:"):text.index("; read_width")]
        self.assertLess(wait.index("call flush"), wait.index("F_CONIO"))
        quit_ = text[text.index("quit:"):text.index("; wait_key")]
        self.assertLess(quit_.index("call flush"), quit_.index("rst 0"))

    def test_the_buffer_flushes_itself_when_full(self):
        text = self.text()
        body = text[text.index("\nputc:"):text.index("; flush - send")]
        self.assertIn("cp OBUF_END >> 8", body)
        self.assertIn("call flush", body)

    def test_draw_page_is_bracketed_by_the_bench_markers(self):
        text = self.text()
        body = text[text.index("draw_page:"):text.index("dispatch_page:")]
        self.assertIn("MARKER      equ 0x3F00", text)
        self.assertLess(body.index("ld a, 1"), body.index("call clear_screen"))
        self.assertLess(body.index("call flush"), body.index("ld a, 2"))


if __name__ == "__main__":
    unittest.main()
