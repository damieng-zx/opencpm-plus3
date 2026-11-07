"""Terminal escape sequences added from the +3 CP/M Plus manual (App. III).

These are structural checks: they guard the wiring of ESC 3 (screen size),
ESC 4 (page mode), ESC b/c (colours) and ESC v/w (wrap control).  The
behaviour is exercised at run time by tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import source


class AnsiCsi(unittest.TestCase):
    """The VT-100 subset: ESC [ parameter collection and CUP/HVP."""

    def test_csi_introducer_and_state(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("ESC_CSI        equ 9", text)
        self.assertIn("db '['", text)
        self.assertIn(".csi_start:", text)
        self.assertIn(".csi_byte:", text)

    def test_cup_clamps_to_the_viewport_and_logical_width(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index(".csi_cup:"):text.index(
            "; ------- one-parameter sequences")]
        self.assertIn("vp_height", body)
        self.assertIn("_lg_width", body)
        self.assertIn("csi_params + 1", body)
        self.assertIn("_lg_autoflip", body)

    def test_harness_covers_cup_and_hvp(self):
        tool = source("tools/zx84_ansi.py")
        for seq in ("[5;10H", "[7;20f", "[99;99H", "[H", "[0;0H"):
            self.assertIn(seq, tool)


class EscapeTableWiring(unittest.TestCase):
    """One-parameter commands dispatch by esc_cmd; v/w have their own slots."""

    def test_one_param_dispatch(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("ESC_WAIT_1P — consume the parameter"):
                    text.index(".esc_normal:")]
        for cmd, target in (("'3'", ".esc_p3"), ("'4'", ".esc_p4"),
                            ("'b'", ".esc_pb"), ("'c'", ".esc_pc")):
            self.assertIn(f"cp {cmd}", body)
            self.assertIn(f"jp z, {target}", body)

    def test_wrap_commands_have_handlers(self):
        text = source("src/bios/screen.zpa")
        table = text[text.index(".esc_table:"):text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db 'v'\s*\n\s*dw \.esc_v")
        self.assertRegex(table, r"db 'w'\s*\n\s*dw \.esc_w")

    def test_handlers_exist(self):
        text = source("src/bios/screen.zpa")
        for label in (".esc_p3:", ".esc_p4:", ".esc_pb:", ".esc_pc:",
                      ".esc_v:", ".esc_w:"):
            self.assertIn(label, text)


class ScreenSize(unittest.TestCase):
    def test_esc3_maps_32_and_51(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index(".esc_p3:"):text.index(".esc_p4:")]
        # Only the documented digits '0'-'2' (or raw 0-2) change the size;
        # other parameters are consumed and ignored.
        self.assertIn("cp '0'", body)
        self.assertIn("cp '3'", body)
        self.assertIn("sub '0'", body)
        self.assertIn("ld a, 32", body)
        self.assertIn("ld a, 51", body)
        self.assertIn("call _cancel_paging", body)
        self.assertIn("jp scr_set_cols", body)
        self.assertIn(".p3_ignore:", body)

    def test_size_change_resets_escape_state(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("scr_init:"):text.index(".rbt_loop:")]
        self.assertIn("ld (esc_state), a", body)


class PageMode(unittest.TestCase):
    def test_esc4_toggles_con_mode_bit0(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index(".esc_p4:"):text.index(".esc_pb:")]
        self.assertIn("ld a, (con_mode)", body)
        self.assertIn("and 0xFE", body)
        self.assertIn("or 0x01", body)
        self.assertIn("ld (con_mode), a", body)


class Colours(unittest.TestCase):
    def test_decode_uses_palette_bits(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("_decode_colour:"):text.index("_set_attr:")]
        self.assertIn("sub 32", body)
        self.assertIn("and 0x3F", body)
        self.assertIn("and 0x03", body)     # blue pair
        self.assertIn("and 0x0C", body)     # red pair
        self.assertIn("and 0x30", body)     # green pair
        self.assertIn("xor d", body)        # high = both bits set
        self.assertIn("and 0x15", body)     # one low bit per gun

    def test_attribute_recomputed_and_stamped(self):
        text = source("src/bios/common.zpa")
        body = text[text.index("_set_attr:"):text.index("_mul80:")]
        self.assertIn("ld a, 0x40", body)   # BRIGHT
        self.assertIn("add a, a", body)     # paper << 3
        self.assertIn("ld (scr_attr), a", body)

        screen = source("src/bios/screen.zpa")
        start = screen.index("\n_render_char:\n")
        render = screen[start:start + 400]
        self.assertIn("call _put_attr", render)

    def test_default_is_white_on_blue(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("DEFAULT_ATTR equ 0x0F", text)
        self.assertIn("scr_ink:      db 7", text)
        self.assertIn("scr_paper:    db 1", text)


class WrapControl(unittest.TestCase):
    def test_wrap_flag_and_advance(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("scr_wrap:     db 1", text)
        adv = text[text.index("_adv_col:"):text.index("_put_attr:")]
        self.assertIn("ld a, (scr_wrap)", adv)
        self.assertIn("jp _do_lf", adv)
        self.assertIn(".ac_clamp:", adv)

    def test_backspace_honours_wrap(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_do_bs:"):text.index("scr_status:")]
        self.assertIn("ld a, (scr_wrap)", body)


class StatusLine(unittest.TestCase):
    """ESC 0/1 and TE_STL share one flag; scrolling is height-driven."""

    def test_escape_table_has_status_line(self):
        text = source("src/bios/screen.zpa")
        table = text[text.index(".esc_table:"):
                     text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db '0'\s*\n\s*dw \.esc_stl_off")
        self.assertRegex(table, r"db '1'\s*\n\s*dw \.esc_stl_on")

    def test_apply_reserves_the_bottom_row(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_stl_apply:"):text.index("_vp_fast_scroll:")]
        self.assertIn("ld (stl_on), a", body)
        self.assertIn("ld (vp_height), a", body)
        self.assertIn("ld (cursor_row), a", body)
        self.assertIn("jp _stl_draw", body)

    def test_fast_scroll_uses_the_viewport_height(self):
        text = source("src/bios/screen.zpa")
        for start, end in (("_scroll_up:", "_scroll_clear:"),
                           ("_scroll_down:", "_clear_screen:")):
            body = text[text.index(start):text.index(end)]
            self.assertIn("ld a, (vp_height)", body)
            self.assertIn("_scroll_last", body)
            self.assertNotIn("ld a, 23", body)

    def test_te_stl_contract(self):
        text = source("src/bios/bios.zpa")
        ask = text[text.index(".te_stl_ask:"):text.index(".te_stl_on_off:")]
        self.assertIn("ld a, (stl_on)", ask)
        self.assertIn("ld a, 0xFF", ask)
        onoff = text[text.index(".te_stl_on_off:"):text.index(".te_ask:")]
        self.assertIn("ld a, (xbios_arg_a)", onoff)
        self.assertIn("_stl_apply", onoff)


class Wide80(unittest.TestCase):
    """24x80 mode: buffer placement, paging and the flip chord."""

    def test_escape_table_enters_and_leaves(self):
        text = source("src/bios/screen.zpa")
        table = text[text.index(".esc_table:"):
                     text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db 'x'\s*\n\s*dw _enter80")
        self.assertRegex(table, r"db 'y'\s*\n\s*dw _exit80")
        self.assertIn(".p3_80:", text)
        self.assertIn("jp _enter80", text)

    def test_logical_buffer_is_bank5_free_ram(self):
        text = source("src/bios/screen.zpa")
        self.assertRegex(text, r"LG_BUF\s+equ 0x5B00")
        self.assertLessEqual(0x5B00 + 80 * 24, 0x8000)
        # after the 6912-byte bitmap + attributes
        self.assertGreaterEqual(0x5B00, 0x4000 + 6912)

    def test_output_path_uses_put80(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("jp nz, _put80", text)
        for label in ("_put80:", "_lg_store_char:", "_lg_autoflip:", "_lg_flip:",
                      "_lg_scroll_up:", "_lg_scroll_down:", "_enter80:", "_exit80:"):
            self.assertIn(label, text)
        # page step is width-dependent (32/51/64 -> 24/29/16)
        self.assertIn("ld (lg_step), a", text)

    def test_extend_enter_is_the_flip_chord(self):
        kb = source("src/bios/keyboard.zpa")
        body = kb[kb.index(".emit:"):kb.index(".emit_map:")]
        self.assertIn("cp 30", body)          # raw key 30 = Enter
        self.assertIn("cp 3", body)           # CAPS+SYMB = EXTEND
        self.assertIn("_flip_chord", body)

    def test_te_ask_reports_the_logical_width(self):
        te = source("src/bios/bios.zpa")
        self.assertIn("ld a, (mode80)", te)
        self.assertIn("ld a, 80", te)
        self.assertIn("ld a, (vp_width)", te)

    def test_set24x80_utility(self):
        text = source("src/tools/set24x80.asm")
        self.assertIn("SET24X80 [ON|OFF]", text)
        self.assertIn("ld a, 'x'", text)
        self.assertIn("ld a, 'y'", text)

    def test_page_change_shifts_the_bitmap(self):
        """Both flips go through the fast shift path, not a full redraw."""
        text = source("src/bios/screen.zpa")
        self.assertIn("_lg_set_page:", text)
        page = text[text.index("_lg_set_page:"):text.index("_flip_chord:")]
        self.assertIn("_lg_flip_left", page)
        self.assertIn("_lg_flip_right", page)
        self.assertIn("_lg_redraw", page)       # offset-viewport fallback
        # auto-flip uses the shared page-change helper
        auto = text[text.index("_lg_autoflip:"):text.index("_lg_flip:")]
        self.assertIn("jp _lg_set_page", auto)
        self.assertNotIn("call _lg_redraw", auto)
        # and the manual flip does too
        flip = text[text.index("_lg_flip:"):text.index("_lg_set_page:")]
        self.assertIn("call _lg_set_page", flip)

    def test_right_shift_uses_16_bit_addresses(self):
        """Regression: the dest/source ends must not assume a zero low byte."""
        text = source("src/bios/screen.zpa")
        right = text[text.index("_lg_line_right:"):]
        body = right[:right.index("_lg_flip_left:")]
        self.assertIn("add hl, de", body)
        self.assertIn("push hl", body)
        self.assertIn("pop hl", body)
        # the old, broken low-byte-only form
        self.assertNotIn("ld l, a                    ; HL = source end", body)

    def test_51_columns_clip_the_last_pixel(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("res 0, (hl)", text)

    def test_flip_only_shifts_the_surviving_columns(self):
        """The exposed edge is re-rendered, so the shift must not waste time
        clearing and rotating it (that was most of a 29-column flip)."""
        text = source("src/bios/screen.zpa")
        left = text[text.index("_lg_line_left:"):text.index("_lg_line_right:")]
        right = text[text.index("_lg_line_right:"):text.index("_lg_flip_left:")]
        for body in (left, right):
            # The bytes at the exposed edge are neither cleared...
            self.assertNotIn(".ll_zero", body)
            self.assertNotIn(".lr_zero", body)
            # ...nor rotated: both carry chains cover only 32 - bytes.
            self.assertIn("32 - bytes", body)
            self.assertIn("sub e", body)
        # The move must happen before the rotate: rotating the source and
        # then overwriting the destination with an unrotated copy loses the
        # bit shift (the 51-column right flip regressed exactly that way).
        self.assertLess(left.index("ldir"), left.index(".ll_roll:"))
        self.assertLess(right.index("lddr"), right.index(".lr_bits:"))

    def test_flip_skips_the_per_cell_attribute_stamp(self):
        text = source("src/bios/screen.zpa")
        flip = text[text.index("_lg_flip_shift:"):text.index("_stl_draw:")]
        self.assertIn("call _render_char_noattr", flip)
        # _render_char still stamps the cell for the normal output path...
        self.assertIn("call _put_attr", text[text.index("_render_char:"):
                                             text.index("_render_char_noattr:")])
        # ...but the flip path enters after that call.
        self.assertIn("_render_char_body:", text)


class TermTest(unittest.TestCase):
    """TERMTEST.COM is the single self-checking screen regression."""

    def test_uses_the_screen_checker_and_phase_markers(self):
        text = source("src/test/termtest.asm")
        self.assertIn("SCR_RUN_ROUTINE equ 0x00E9", text)
        self.assertIn("checker_start:", text)
        # The three runner-checked glyph phases.
        self.assertIn("VIS32", text)
        self.assertIn("VIS51", text)
        self.assertIn("TERMTEST..OK", text)
        self.assertIn("TERMTEST..FAIL", text)

    def test_checker_reads_match_the_screen_layout(self):
        """The counter routine hardcodes bank-6/bank-5 addresses."""
        screen = source("src/bios/screen.zpa")
        term = source("src/test/termtest.asm")
        for name, value in (("char_buffer", 0xA000), ("LG_BUF", 0x5B00),
                            ("mode80", 0xA8C1), ("lg_off", 0xA8C2)):
            self.assertRegex(screen, rf"{name}:?\s+equ\s+0x{value:04X}\b")
            self.assertIn(f"0x{value:04X}", term)


class PromptEscapeEcho(unittest.TestCase):
    """F10 must pass ESC to the screen: BREAK 3 0 works at the A> prompt."""

    def test_f10_echoes_escape(self):
        text = source("src/bdos/bdos.zpa")
        self.assertIn("cp 0x1B", text)
        body = text[text.index(".rd_esc:"):text.index(".rd_done:")]
        self.assertIn("ld c, 0x1B", body)
        self.assertIn("call con_out", body)


if __name__ == "__main__":
    unittest.main()
