"""The CCP's built-in ERA command.

ERA parses a CP/M filespec (with wildcards and an optional drive prefix),
calls BDOS F19, and asks for confirmation before an all-wildcard delete.
The runtime behaviour is exercised by tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_era_is_a_builtin_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('cmd_era:    db "ERA", 0', text)
        body = text[text.index(".check_builtins:"):text.index(".do_load_com:")]
        self.assertIn("ld de, cmd_era", body)
        self.assertIn("jp z, .do_era", body)
        self.assertLess(body.index("cmd_era"), body.index("jp .do_load_com"))


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_era:"):text.index(".do_load_com:")]

    def test_parses_the_filespec_and_calls_f19(self):
        body = self.body()
        self.assertIn("call parse_filename", body)
        self.assertIn("ld de, type_fcb", body)
        self.assertIn("ld c, 19", body)          # F19 delete file

    def test_reports_usage_and_missing_files(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "ERA filespec"', text)
        self.assertIn('db "No file"', text)
        self.assertIn("jp BDOS", self.body())

    def test_all_wildcard_delete_asks_first(self):
        body = self.body()
        self.assertIn("call _era_all", body)
        self.assertIn('db "ALL (Y/N)? $"', source("src/ccp/miniccp.zpa"))
        # A rejected answer returns without deleting.
        self.assertIn("jr z, .era_delete", body)
        rejected = body[body.index("cp 'y'"):body.index(".era_delete:")]
        self.assertIn("ret", rejected)
        self.assertIn("ld c, F_CIN", body)

    def test_guard_covers_the_whole_name_and_extension(self):
        text = source("src/ccp/miniccp.zpa")
        guard = text[text.index("_era_all:"):text.index("_era_all:") + 160]
        self.assertIn("ld hl, type_fcb + 1", guard)
        self.assertIn("ld b, 11", guard)
        self.assertIn("cp '?'", guard)

    def test_help_lists_era(self):
        self.assertIn("ERA    - Erase files", source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
