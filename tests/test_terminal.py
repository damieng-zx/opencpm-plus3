"""Terminal escape sequences added from the +3 CP/M Plus manual (App. III).

These are structural checks: they guard the wiring of ESC 3 (screen size),
ESC 4 (page mode), ESC b/c (colours) and ESC v/w (wrap control).  The
behaviour is exercised at run time by tools/zx84_smoke.py.
"""

from __future__ import annotations

import re
import unittest

from .layout import source, screen_source


class AnsiCsi(unittest.TestCase):
    """The VT-100 subset: ESC [ parameter collection and CUP/HVP."""

    def test_csi_introducer_and_state(self):
        text = screen_source()
        self.assertIn("ESC_CSI        equ 9", text)
        self.assertIn("db '['", text)
        self.assertIn(".csi_start:", text)
        self.assertIn(".csi_byte:", text)

    def test_cup_clamps_to_the_viewport_and_logical_width(self):
        text = screen_source()
        body = text[text.index(".csi_cup:"):text.index(
            "; ------- one-parameter sequences")]
        self.assertIn("vp_height", body)
        self.assertIn("_lg_width", body)
        self.assertIn("csi_params + 1", body)
        self.assertIn("_lg_autoflip", body)

    def test_movement_handlers_clamp(self):
        text = screen_source()
        for name in (".csi_cuu:", ".csi_cud:", ".csi_cuf:", ".csi_cub:",
                     ".csi_row_up:", ".csi_row_down:"):
            self.assertIn(name, text)
        body = text[text.index(".csi_row_down:"):text.index(
            "; ------- one-parameter sequences")]
        self.assertIn("vp_height", body)
        cuf = text[text.index(".csi_cuf:"):text.index(".csi_cub:")]
        self.assertIn("_lg_width", cuf)

    def test_erase_and_cursor_save_reuse_the_vt52_handlers(self):
        text = screen_source()
        self.assertIn("jp z, .csi_ed", text)
        self.assertIn("jp z, .csi_el", text)
        self.assertIn("jp z, .esc_j", text)
        self.assertIn("jp z, .esc_k", text)
        for target in (".esc_J", ".esc_d", ".esc_E",
                       ".esc_K", ".esc_o", ".esc_l"):
            self.assertIn(target, text)

    def test_harness_covers_cup_and_hvp(self):
        tool = source("tools/zx84_ansi.py")
        for seq in ("[5;10H", "[7;20f", "[99;99H", "[H", "[0;0H",
                    "[2A", "[3B", "[4C", "[2D"):
            self.assertIn(seq, tool)


class AnsiSgr(unittest.TestCase):
    """SGR (ESC [ ... m) and the private autowrap mode (ESC [ ? 7 h/l)."""

    def test_sgr_is_dispatched(self):
        text = screen_source()
        self.assertIn("cp 'm'", text)
        self.assertIn("jp z, .csi_sgr", text)
        self.assertIn(".csi_sgr:", text)

    def test_sgr_walks_every_parameter(self):
        text = screen_source()
        body = text[text.index(".csi_sgr:"):text.index(".sgr_param:")]
        self.assertIn("csi_params", body)
        self.assertIn("djnz .sgr_loop", body)
        self.assertIn("call .sgr_param", body)
        self.assertIn("call .sgr_reset", body)     # an empty list means 0

    def test_sgr_extended_colour_is_dropped(self):
        text = screen_source()
        body = text[text.index(".csi_sgr:"):text.index(".sgr_param:")]
        # 38/48 must stop the sequence: 38;5;9 would otherwise read 5 as
        # blink.
        self.assertIn("cp 38", body)
        self.assertIn("cp 48", body)
        self.assertIn(".sgr_extended:", body)

    def test_sgr_codes_have_handlers(self):
        text = screen_source()
        body = text[text.index(".sgr_param:"):text.index(".csi_setmode:")]
        for code, target in ((1, ".sgr_bold"), (5, ".sgr_blink"),
                             (7, ".sgr_rev"), (22, ".sgr_nobold"),
                             (25, ".sgr_noblink"), (27, ".sgr_norev"),
                             (39, ".sgr_fgdef"), (49, ".sgr_bgdef")):
            self.assertRegex(body, rf"cp {code}\s*\n\s*j[pr] z, {re.escape(target)}")
        for target in (".sgr_fg", ".sgr_bg", ".sgr_fgbr", ".sgr_bgbr",
                       ".sgr_map"):
            self.assertIn(target + ":", text)

    def test_ansi_colours_map_to_grb(self):
        text = screen_source()
        body = text[text.index(".sgr_map:"):text.index(".csi_setmode:")]
        # ANSI order is black, red, green, yellow, blue, magenta, cyan,
        # white; the Spectrum index is bit0 blue, bit1 red, bit2 green.
        self.assertIn("db 0, 2, 4, 6, 1, 3, 5, 7", body)

    def test_reverse_video_swaps_around_the_recompute(self):
        text = screen_source()
        body = text[text.index("_apply_attr:"):text.index(".aa_swap:")]
        self.assertIn("scr_rev", body)
        self.assertEqual(body.count("call .aa_swap"), 1)
        self.assertIn("call _set_attr", body)
        self.assertIn("jr .aa_swap", body)      # ...and swap back
        swap = text[text.index(".aa_swap:"):text.index("scr_putchar:")]
        for pair in ("scr_ink", "scr_ink_br", "scr_ink_fl"):
            self.assertIn(f"({pair})", swap)
        self.assertIn("(scr_paper)", swap)

    def test_colour_commands_honour_reverse_video(self):
        text = screen_source()
        for name in (".esc_pb:", ".esc_pc:"):
            body = text[text.index(name):text.index("\n\n", text.index(name))]
            self.assertIn("call _apply_attr", body)

    def test_private_modes_drive_the_wrap_flag(self):
        text = screen_source()
        self.assertIn("cp 'h'", text)
        self.assertIn("jp z, .csi_setmode", text)
        self.assertIn("cp 'l'", text)
        self.assertIn("jp z, .csi_resetmode", text)
        body = text[text.index(".csi_mode:"):text.index(".csi_erase:")]
        self.assertIn("csi_priv", body)          # only ESC [ ? ... counts
        self.assertIn("ld (scr_wrap), a", body)
        start = text.index(".csi_start:")
        self.assertIn("ld (csi_priv), a", text[start:start + 200])

    def test_harness_covers_sgr_and_private_modes(self):
        tool = source("tools/zx84_ansi.py")
        for seq in ("[0m", "[31m", "[42m", "[1m", "[0;37;44m", "[7m",
                    "[27m", "[5m", "[25m", "[90m", "[38;5;9m", "[m",
                    "[?7h", "[?7l", "[?3h", "[?8h"):
            self.assertIn(seq, tool)
        self.assertIn("def phase_sgr", tool)
        self.assertIn("def phase_mode", tool)


class EscapeTableWiring(unittest.TestCase):
    """One-parameter commands dispatch by esc_cmd; v/w have their own slots."""

    def test_one_param_dispatch(self):
        text = screen_source()
        body = text[text.index("ESC_WAIT_1P — consume the parameter"):
                    text.index(".esc_normal:")]
        for cmd, target in (("'3'", ".esc_p3"), ("'4'", ".esc_p4"),
                            ("'b'", ".esc_pb"), ("'c'", ".esc_pc")):
            self.assertIn(f"cp {cmd}", body)
            self.assertIn(f"jp z, {target}", body)

    def test_wrap_commands_have_handlers(self):
        text = screen_source()
        table = text[text.index(".esc_table:"):text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db 'v'\s*\n\s*dw \.esc_v")
        self.assertRegex(table, r"db 'w'\s*\n\s*dw \.esc_w")

    def test_handlers_exist(self):
        text = screen_source()
        for label in (".esc_p3:", ".esc_p4:", ".esc_pb:", ".esc_pc:",
                      ".esc_v:", ".esc_w:"):
            self.assertIn(label, text)


class ScreenSize(unittest.TestCase):
    def test_esc3_maps_32_and_51(self):
        text = screen_source()
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
        text = screen_source()
        body = text[text.index("scr_init:"):text.index(".rbt_loop:")]
        self.assertIn("ld (esc_state), a", body)


class PageMode(unittest.TestCase):
    def test_esc4_toggles_con_mode_bit0(self):
        text = screen_source()
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

        screen = screen_source()
        start = screen.index("\n_render_char:\n")
        render = screen[start:start + 400]
        self.assertIn("call _put_attr", render)

    def test_default_is_white_on_blue(self):
        text = screen_source()
        self.assertIn("DEFAULT_ATTR equ 0x0F", text)
        self.assertIn("scr_ink:      db 7", text)
        self.assertIn("scr_paper:    db 1", text)


class WrapControl(unittest.TestCase):
    def test_wrap_flag_and_advance(self):
        text = screen_source()
        self.assertIn("scr_wrap:     db 1", text)
        adv = text[text.index("_adv_col:"):text.index("_put_attr:")]
        self.assertIn("ld a, (scr_wrap)", adv)
        self.assertRegex(adv, r"j[pr] _do_lf")
        self.assertIn(".ac_clamp:", adv)

    def test_backspace_honours_wrap(self):
        text = screen_source()
        body = text[text.index("_do_bs:"):text.index("scr_status:")]
        self.assertIn("ld a, (scr_wrap)", body)


class StatusLine(unittest.TestCase):
    """ESC 0/1 and TE_STL share one flag; scrolling is height-driven."""

    def test_escape_table_has_status_line(self):
        text = screen_source()
        table = text[text.index(".esc_table:"):
                     text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db '0'\s*\n\s*dw \.esc_stl_off")
        self.assertRegex(table, r"db '1'\s*\n\s*dw \.esc_stl_on")

    def test_apply_reserves_the_bottom_row(self):
        text = screen_source()
        body = text[text.index("_stl_apply:"):text.index("_vp_fast_scroll:")]
        self.assertIn("ld (stl_on), a", body)
        self.assertIn("ld (vp_height), a", body)
        self.assertIn("ld (cursor_row), a", body)
        self.assertIn("jp _stl_draw", body)

    def test_fast_scroll_uses_the_viewport_height(self):
        text = screen_source()
        # The fast paths run from bank 5 (screen5.zpa).
        for start, end in (("_scroll_up_b5:", "_scroll_clear:"),
                           ("_scroll_down_b5:", "_clear_screen_b5:")):
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
        text = screen_source()
        table = text[text.index(".esc_table:"):
                     text.index("db 0                ; end of table")]
        self.assertRegex(table, r"db 'x'\s*\n\s*dw _enter80")
        self.assertRegex(table, r"db 'y'\s*\n\s*dw _exit80")
        self.assertIn(".p3_80:", text)
        self.assertIn("jp _enter80", text)

    def test_logical_buffer_is_bank5_free_ram(self):
        text = screen_source()
        self.assertRegex(text, r"LG_BUF\s+equ 0x5B00")
        self.assertLessEqual(0x5B00 + 80 * 24, 0x8000)
        # after the 6912-byte bitmap + attributes
        self.assertGreaterEqual(0x5B00, 0x4000 + 6912)

    def test_output_path_uses_put80(self):
        text = screen_source()
        self.assertIn("jp nz, _put80", text)
        for label in ("_put80:", "_lg_store_char:", "_lg_autoflip:", "_lg_flip:",
                      "_lg_scroll_up:", "_lg_scroll_down:", "_enter80:", "_exit80:"):
            self.assertIn(label, text)
        # page step is width-dependent (32/51/64 -> 24/29/16)
        self.assertIn("ld (lg_step), a", text)

    def test_width_change_in_24x80_refreshes_the_page_geometry(self):
        """SCREEN n while already in 24x80 must recompute lg_step.

        _lg_step_for_cols used to be called only from _enter80, so changing
        the width in 24x80 mode left the old step in place: at 32 columns
        flips jumped 0 -> 29 (not a page boundary) and at 64 columns 0 -> 0,
        leaving the rightmost 16 columns of the 80-column sheet unreachable.
        """
        text = screen_source()
        body = text[text.index("scr_set_cols:"):text.index(
            "; 24x80 mode", text.index("scr_set_cols:"))]
        self.assertIn("call _lg_step_for_cols", body)
        self.assertIn("ld (lg_off), a", body)

    def test_console_width_is_80_in_24x80(self):
        """F49 conwidth (SCB 0x1A) is 79 in 24x80, else the physical width.

        DIR and DUMP size their output from it, so in 24x80 they must see
        the 80-column logical screen, not the physical window.  Entering
        24x80 sets it, and every width change (ESC 3, ESC y, fn 32) goes
        through scr_set_cols, which must keep it at 79 while mode80 is on.
        """
        text = screen_source()
        body = text[text.index("_set_conwidth:"):]
        body = body[:body.index("\n; @proc", 1) if "\n; @proc" in body else None]
        self.assertIn("ld a, (mode80)", body)
        self.assertIn("ld a, 80", body)
        self.assertIn("ld a, (scr_cols)", body)
        self.assertIn("ld (scb_conwidth), a", body)
        enter = text[text.index("_enter80:"):text.index("_exit80:")]
        self.assertIn("call _set_conwidth", enter)
        set_cols = text[text.index("scr_set_cols:"):text.index(
            "; 24x80 mode", text.index("scr_set_cols:"))]
        self.assertIn("call _set_conwidth", set_cols)
        self.assertNotIn("ld (scb_conwidth)", set_cols)

    def test_auto_flip_is_off_at_cold_boot(self):
        """24x80 pages only on EXTEND+Enter unless a program sends ESC 5 0.

        Following the cursor flips the window whenever output crosses its
        edge, which flickers.  Cold init seeds lg_auto with the zero it
        already stored in mode80/lg_off, and TERMTEST, which turns it on,
        restores it on both of its exits.
        """
        bios = source("src/bios/bios.zpa")
        init = bios[bios.index("ld (mode80), a"):bios.index("call scr_init")]
        self.assertIn("ld (lg_auto), a", init)
        self.assertNotIn("ld a, 1", init)
        term = source("src/test/termtest.asm")
        restore = term[term.index("restore:"):term.index("warm:")]
        self.assertIn("ld a, '5'", restore)
        self.assertIn("ld b, '1'", restore)

    def test_dump_caps_its_line_at_the_buffer(self):
        """80 columns would give (80-8)/4 = 18 bytes; lnbuf holds 16."""
        dump = source("src/tools/dump.asm")
        self.assertIn("lnbuf:  ds 16", dump)
        width = dump[dump.index("ld c, F_GETSCB"):dump.index("ld (bpl), a")]
        self.assertIn("cp 17", width)
        self.assertIn("ld a, 16", width)

    def test_page_step_is_derived_from_the_width(self):
        """The step is 80-cols except at 32 columns, where it is 24."""
        text = screen_source()
        body = text[text.index("_lg_step_for_cols:"):text.index("_enter80:")]
        self.assertIn("sub (hl)", body)
        self.assertIn("ld (lg_step), a", body)
        # 80-32 is 48, but 32 columns need three pages: 0, 24, 48.
        self.assertIn("ld a, 24", body)

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
        text = screen_source()
        self.assertIn("_lg_set_page:", text)
        page = text[text.index("_lg_set_page:"):text.index("_flip_chord:")]
        self.assertIn("_lg_flip_left", page)
        self.assertIn("_lg_flip_right", page)
        self.assertIn("_lg_redraw", page)       # offset-viewport fallback
        # auto-flip uses the shared page-change helper
        auto = text[text.index("_lg_autoflip:"):text.index("_lg_flip:")]
        self.assertRegex(auto, r"j[pr] _lg_set_page")
        self.assertNotIn("call _lg_redraw", auto)
        # and the manual flip does too
        flip = text[text.index("_lg_flip:"):text.index("_lg_set_page:")]
        self.assertIn("call _lg_set_page", flip)

    def test_right_shift_uses_16_bit_addresses(self):
        """Regression: the dest/source ends must not assume a zero low byte."""
        text = screen_source()
        right = text[text.index("_lg_line_right:"):]
        body = right[:right.index("_lg_flip_shift:")]
        self.assertIn("add hl, de", body)
        self.assertIn("push hl", body)
        self.assertIn("pop hl", body)
        # the old, broken low-byte-only form
        self.assertNotIn("ld l, a                    ; HL = source end", body)

    def test_51_columns_clip_the_last_pixel(self):
        text = screen_source()
        self.assertIn("res 0, (hl)", text)

    def test_flip_only_shifts_the_surviving_columns(self):
        """The exposed edge is re-rendered, so the shift must not waste time
        clearing and rotating it (that was most of a 29-column flip)."""
        text = screen_source()
        left = text[text.index("_lg_line_left:"):text.index("_lg_line_right:")]
        right = text[text.index("_lg_line_right:"):text.index("_lg_flip_shift:")]
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

    def test_flip_hides_the_page_and_draws_only_non_blank_cells(self):
        """The page change blanks the attributes (ink = paper), clears the
        exposed strip after the shift and then draws only non-space cells."""
        text = screen_source()
        page = text[text.index("_lg_set_page:"):text.index("_flip_chord:")]
        self.assertIn("call _lg_attr_hide", page)
        self.assertIn("jr _lg_attr_fill", page)
        self.assertIn("_lg_attr_hide:", text)
        flip = text[text.index("_lg_flip_shift:"):text.index("_stl_mark_b5:")]
        self.assertIn("call _lg_clear_strip", flip)
        cells = flip[flip.index(".fs_cell:"):]
        self.assertLess(cells.index("cp ' '"),
                        cells.index("call _render_char_noattr"))
        # the full redraw clears its row up front for the same reason
        row = text[text.index("_lg_render_row_b5:"):text.index("_lg_store_char_b5:")]
        self.assertIn("call _clear_char_row", row)
        self.assertIn("cp ' '", row)
        self.assertIn("call _render_char_noattr", row)

    def test_51_column_flip_keeps_the_one_pixel_rotate(self):
        """145 pixels = 18 bytes + 1 bit.  Dropping the bit would leave the
        survivors a pixel off the 5-pixel cell grid (later edits would leave
        slivers), so the tight 51-column rows must rotate all 14 survivors."""
        text = screen_source()
        left = text[text.index("_lg_row_left51:"):text.index("_lg_row_right51:")]
        right = text[text.index("_lg_row_right51:"):text.index("_lg_flip_shift:")]
        self.assertEqual(left.count("rl (hl)"), 14)
        self.assertEqual(right.count("rr (hl)"), 14)
        # anything but the one 29-column step must use the generic loop
        flip = text[text.index("_lg_flip_shift:"):text.index("_stl_mark_b5:")]
        self.assertIn("cp 18", flip)
        self.assertIn(".fs_generic:", flip)

    def test_strip_clear_uses_the_unrolled_zero_run(self):
        """11 T-states a byte against LDIR's 21; the run covers the longest
        possible strip (a whole 32-byte scan line)."""
        text = screen_source()
        run = text[text.index("_lg_zero_run:"):text.index("_lg_row_left0:")]
        self.assertEqual(run.count("ld (de), a"), 32)
        self.assertEqual(run.count("inc e"), 32)
        self.assertIn("jp (hl)", run)
        self.assertIn("lint-exempt: stack", run)
        for name in ("_lg_clear_strip:", "_lg_row_left0:", "_lg_row_right0:"):
            body = text[text.index(name):]
            body = body[:body.index("\n\n")]
            self.assertIn("call _lg_zero_run", body)

    def test_flip_skips_the_per_cell_attribute_stamp(self):
        text = screen_source()
        flip = text[text.index("_lg_flip_shift:"):text.index("_stl_mark_b5:")]
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
        screen = screen_source()
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
