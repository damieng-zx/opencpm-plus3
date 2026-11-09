"""The CCP's built-in ERASE (ERA) command.

ERASE parses a CP/M filespec (with wildcards and an optional drive prefix),
calls BDOS F19, and asks "ERASE spec (Y/N)?" before deleting when the spec
has a wildcard, as the CP/M 3 User's Guide describes.  An option list such
as [CONFIRM] needs the ERASE.COM transient.  The runtime behaviour is
exercised by tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_erase_and_era_are_builtins_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        table = text[text.index(".cmd_table:"):text.index(".opt_com:")]
        self.assertIn('db "ERASE", 0\n    dw .do_era', table)
        self.assertIn('db "ERA", 0\n    dw .do_era', table)
        body = text[text.index(".check_builtins:"):text.index(".cmd_table:")]
        self.assertIn("jp z, .do_load_com", body)   # table end -> a program


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_era:"):text.index(".do_ren:")]

    def test_parses_the_filespec_and_calls_f19(self):
        body = self.body()
        self.assertIn("call parse_filename", body)
        self.assertIn("ld de, type_fcb", body)
        self.assertIn("ld c, 19", body)          # F19 delete file

    def test_missing_argument_prompts_and_missing_file_is_reported(self):
        body = self.body()
        self.assertIn("call get_arg", body)
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "Enter filename:"', text)
        self.assertIn('db "No File"', text)
        self.assertIn(".no_file", body)

    def test_any_wildcard_asks_first(self):
        body = self.body()
        self.assertIn("call _fcb_wild", body)
        self.assertIn("call print_word", body)    # echoes the spec as typed
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("db \"ERASE \", '$'", text)
        self.assertIn("db \" (Y/N)?\", '$'", text)
        # Anything but Y returns without deleting.
        asked = body[body.index("and 0xDF"):body.index(".era_delete:")]
        self.assertIn("cp 'Y'", asked)
        self.assertIn("ret nz", asked)
        self.assertIn("ld c, F_CIN", body)

    def test_option_list_loads_the_transient(self):
        body = self.body()
        self.assertIn("call find_opt", body)
        self.assertIn("jp c, .opt_com", body)

    def test_wildcard_guard_covers_the_whole_name_and_extension(self):
        text = source("src/ccp/miniccp.zpa")
        guard = text[text.index("_fcb_wild:"):text.index("_fcb_wild:") + 160]
        self.assertIn("ld hl, type_fcb + 1", guard)
        self.assertIn("ld b, 11", guard)
        self.assertIn("cp '?'", guard)

    def test_help_lists_erase(self):
        self.assertIn("ERASE (ERA)", source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
