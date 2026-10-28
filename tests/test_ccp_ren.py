"""The CCP's built-in REN command.

CP/M's REN takes NEW=OLD: the old name is the one that must exist, and the
FCB for BDOS F23 carries it at bytes 1-11 with the new name at 17-27.
Wildcards are refused because F23 renames every matching directory entry.
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_ren_is_a_builtin_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('cmd_ren:    db "REN", 0', text)
        body = text[text.index(".check_builtins:"):text.index(".do_load_com:")]
        self.assertIn("ld de, cmd_ren", body)
        self.assertIn("jp z, .do_ren", body)
        self.assertLess(body.index("cmd_ren"), body.index("jp .do_load_com"))


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_ren:"):text.index(".do_load_com:")]

    def test_splits_new_from_old_at_the_equals_sign(self):
        body = self.body()
        self.assertIn("cp '='", body)
        self.assertIn("ld (ren_new), hl", body)
        self.assertIn("ld (ren_old), hl", body)
        # The new name is parsed first, then the old one.
        self.assertLess(body.index("(ren_new)"), body.index("(ren_old)"))

    def test_builds_the_f23_fcb(self):
        body = self.body()
        self.assertIn("ld de, ren_fcb + 17", body)     # new name at 17..27
        self.assertIn("ld de, ren_fcb + 1", body)      # old name at 1..11
        self.assertIn("ld (ren_fcb), a", body)         # drive byte
        self.assertIn("ld c, 23", body)                # F23 rename

    def test_rejects_wildcards(self):
        body = self.body()
        self.assertIn("call _fcb_wild", body)
        self.assertIn("jr z, .ren_wild", body)
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "No wildcards"', text)
        guard = text[text.index("_fcb_wild:"):text.index("_fcb_wild:") + 160]
        self.assertIn("ld b, 11", guard)
        self.assertIn("cp '?'", guard)

    def test_usage_and_not_found_messages(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "REN new=old"', text)
        self.assertIn('db "No file"', text)

    def test_help_lists_ren(self):
        self.assertIn("REN    - Rename file (new=old)",
                      source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
