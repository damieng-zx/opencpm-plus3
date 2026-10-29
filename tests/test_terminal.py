"""Terminal escape sequences added from the +3 CP/M Plus manual (App. III).

These are structural checks: they guard the wiring of ESC 3 (screen size),
ESC 4 (page mode), ESC b/c (colours) and ESC v/w (wrap control).  The
behaviour is exercised at run time by tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import source


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
        text = source("src/bios/screen.zpa")
        body = text[text.index("_decode_colour:"):text.index("_set_attr:")]
        self.assertIn("sub 32", body)
        self.assertIn("and 0x3F", body)
        self.assertIn("and 0x03", body)     # blue pair
        self.assertIn("and 0x0C", body)     # red pair
        self.assertIn("and 0x30", body)     # green pair
        self.assertIn("xor d", body)        # high = both bits set
        self.assertIn("and 0x15", body)     # one low bit per gun

    def test_attribute_recomputed_and_stamped(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_set_attr:"):text.index("_cancel_paging:")]
        self.assertIn("ld a, 0x40", body)   # BRIGHT
        self.assertIn("add a, a", body)     # paper << 3
        self.assertIn("ld (scr_attr), a", body)

        start = text.index("\n_render_char:\n")
        render = text[start:start + 400]
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
