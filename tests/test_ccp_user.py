"""The CCP's built-in USER command.

USER shows or changes the CP/M user area through BDOS F32.  The BDOS keeps
page-zero byte 0004h in sync, and directory searches match the current user,
so 'USER 3' really does show a different set of files.
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_user_is_a_builtin_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('cmd_user:   db "USER", 0', text)
        body = text[text.index(".check_builtins:"):text.index(".do_load_com:")]
        self.assertIn("ld de, cmd_user", body)
        self.assertIn("jp z, .do_user", body)
        self.assertLess(body.index("cmd_user"), body.index("jp .do_load_com"))


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_user:"):text.index(".do_load_com:")]

    def test_uses_f32_for_get_and_set(self):
        body = self.body()
        self.assertIn("ld c, 32", body)            # F32: get/set user
        self.assertIn("ld e, 0xFF", body)          # E=0xFF queries
        self.assertIn("ld e, a", body)             # otherwise set

    def test_parses_one_or_two_decimal_digits(self):
        body = self.body()
        self.assertIn("add a, a", body)            # x2
        self.assertIn("add a, b", body)            # x5
        self.assertIn("add a, c", body)            # + second digit
        self.assertIn("ld a, (hl)", body)          # delimiter check
        self.assertIn("cp 16", body)               # range 0..15

    def test_reports_and_rejects(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "User $"', text)
        self.assertIn('db "USER n (0-15)"', text)
        self.assertIn("jp .user_usage", self.body())

    def test_help_lists_user(self):
        self.assertIn("USER   - Show/set the user area (0-15)",
                      source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
