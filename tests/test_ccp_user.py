"""The CCP's built-in USER command.

USER sets the CP/M user area through BDOS F32 and asks "Enter User# :" when
there is no number.  The BDOS keeps page-zero byte 0004h in sync, and
directory searches match the current user, so 'USER 3' really does show a
different set of files; the prompt then reads "3A>".
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_user_and_use_are_builtins_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        table = text[text.index(".cmd_table:"):text.index(".opt_com:")]
        self.assertIn('db "USER", 0\n    dw .do_user', table)
        self.assertIn('db "USE", 0\n    dw .do_user', table)


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_user:"):text.index(".do_load_com:")]

    def test_uses_f32_to_set(self):
        body = self.body()
        self.assertIn("ld c, 32", body)            # F32: set user
        self.assertIn("ld e, a", body)

    def test_parses_one_or_two_decimal_digits(self):
        body = self.body()
        self.assertIn("add a, a", body)            # x2
        self.assertIn("add a, b", body)            # x5
        self.assertIn("add a, c", body)            # + second digit
        self.assertIn("ld a, (hl)", body)          # delimiter check
        self.assertIn("cp 16", body)               # range 0..15

    def test_asks_when_there_is_no_number(self):
        body = self.body()
        self.assertIn("ld de, msg_enter_user", body)
        self.assertIn("call prompt_line", body)
        self.assertIn('db "Enter User# : "', source("src/ccp/miniccp.zpa"))

    def test_rejects_bad_numbers(self):
        self.assertIn('db "USER n (0-15)"', source("src/ccp/miniccp.zpa"))
        self.assertIn("jr c, .user_usage", self.body())

    def test_prompt_shows_a_non_zero_user(self):
        text = source("src/ccp/miniccp.zpa")
        prompt = text[text.index("print_prompt:"):text.index("; parse_cmd")]
        self.assertIn("ld c, 32", prompt)              # F32 get
        self.assertIn("call nz, print_decimal_a", prompt)

    def test_help_lists_user(self):
        self.assertIn("USER (USE)", source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
