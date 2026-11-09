"""The CCP's built-in RENAME (REN) command.

REN takes NEW=OLD (the old name is the one that must exist); the FCB for
BDOS F23 carries it at bytes 1-11 with the new name at 17-27.  The wildcards
of the two names must correspond; every matching file is renamed on its own
with the '?' of the new name filled from the old name, because F23 copies the
new name verbatim.  An existing target asks "delete (Y/N)?".
"""

from __future__ import annotations

import unittest

from .layout import source


class Dispatch(unittest.TestCase):
    def test_rename_and_ren_are_builtins_before_com_loading(self):
        text = source("src/ccp/miniccp.zpa")
        table = text[text.index(".cmd_table:"):text.index(".opt_com:")]
        self.assertIn('db "RENAME", 0\n    dw .do_ren', table)
        self.assertIn('db "REN", 0\n    dw .do_ren', table)


class Handler(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_ren:"):text.index(".do_user:")]

    def test_splits_new_from_old_at_the_equals_sign(self):
        body = self.body()
        self.assertIn("cp '='", body)
        self.assertIn("ld (ren_new), hl", body)
        self.assertIn("ld (ren_old), hl", body)
        # The new name is parsed first, then the old one.
        self.assertLess(body.index("(ren_new)"), body.index("(ren_old)"))

    def test_accepts_a_space_separator(self):
        body = self.body()
        # '=' wins if present; otherwise the first space splits the names,
        # matching RENAME.COM's "REN NEW OLD" order.
        self.assertIn(".ren_find_sp:", body)
        self.assertIn("cp ' '", body)
        self.assertIn("ld hl, (ren_new)", body)

    def test_prompts_for_both_names_when_there_is_no_argument(self):
        body = self.body()
        self.assertIn("ld de, msg_ren_new", body)
        self.assertIn("ld de, msg_ren_old", body)
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "Enter New Name:"', text)
        self.assertIn('db "Enter Old Name:"', text)

    def test_builds_the_f23_fcb(self):
        body = self.body()
        self.assertIn("ld de, ren_fcb + 17", body)     # new name at 17..27
        self.assertIn("ld de, ren_fcb + 1", body)      # old name at 1..11
        self.assertIn("ld (ren_fcb), a", body)         # drive byte
        self.assertIn("ld c, 23", body)                # F23 rename

    def test_wildcards_must_correspond(self):
        body = self.body()
        self.assertIn(".ren_wcheck:", body)
        self.assertIn("jp nz, .ren_wild", body)
        self.assertIn('db "Wildcards do not correspond"',
                      source("src/ccp/miniccp.zpa"))

    def test_each_match_is_renamed_on_its_own(self):
        body = self.body()
        self.assertIn("ld c, 17", body)                # F17 over the old name
        self.assertIn("ld c, 18", body)                # F18 for the next
        self.assertIn("cp '?'", body)                  # '?' filled from old
        self.assertIn("ld a, (ix + 0)", body)

    def test_existing_target_asks_before_deleting(self):
        body = self.body()
        self.assertIn("ld de, msg_not_renamed", body)
        self.assertIn("ld c, 19", body)                # F19 deletes it on Y
        self.assertIn(".ren_restart:", body)           # searches start afresh
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "Not renamed "', text)
        self.assertIn('"delete (Y/N)?"', text)

    def test_missing_file_is_reported(self):
        self.assertIn('db "No File"', source("src/ccp/miniccp.zpa"))
        self.assertIn("jp .no_file", self.body())

    def test_help_lists_rename(self):
        self.assertIn("RENAME (REN)", source("src/ccp/miniccp.zpa"))


if __name__ == "__main__":
    unittest.main()
