"""The local-only DRI utility harness and its documented coverage."""

from __future__ import annotations

import unittest

from .layout import ROOT, source


class DriHarness(unittest.TestCase):
    def setUp(self) -> None:
        self.tool = source("tools/zx84_dri.py")

    def test_reads_local_copies_and_skips_in_ci(self):
        self.assertIn("references", self.tool)
        self.assertIn("SHOW.COM", self.tool)
        self.assertIn("ED.COM", self.tool)
        self.assertIn("SET.COM", self.tool)
        self.assertIn("SETKEYS.COM", self.tool)
        # No local copies -> notice + exit 0, so CI never needs them.
        self.assertIn("skipped (missing", self.tool)
        self.assertIn("return 0", self.tool)
        # A clean scratch image keeps the packed build image out of the way.
        self.assertIn("mkdsk.py", self.tool)

    def test_exercises_show_ed_set_and_setkeys(self):
        self.assertIn('smoke.command("SHOW"', self.tool)
        self.assertIn("Q-(Y/N)?", self.tool)
        self.assertIn("SMOKE OK", self.tool)
        self.assertIn("shift+sym+z", self.tool)       # Ctrl-Z ends ED insert
        self.assertIn("NEW FILE", self.tool)
        # ED's END/save is verified by reading the file back.
        self.assertIn('smoke.command("TYPE NEW.TXT"', self.tool)
        self.assertIn("DRI ED OK", self.tool)
        # SET: runs, reports no options, and applies a bracketed attribute.
        self.assertIn("ERROR: No options specified.", self.tool)
        self.assertIn("SET RO.TXT [RO]", self.tool)
        self.assertIn("Read Only", self.tool)
        # SETKEYS: the key override table (KMTAB) must change.
        self.assertIn("KMTAB", self.tool)
        self.assertIn("did not change the key override table", self.tool)

    def test_coverage_is_documented(self):
        tool = source("docs/third-party-tests.md")
        self.assertIn("DRI CP/M 3 utilities", tool)
        self.assertIn("SETKEYS", tool)
        self.assertIn("ED", tool)
        compat = source("docs/compatibility.md")
        self.assertIn("**ED**", compat)
        self.assertIn("**SET**", compat)
        self.assertIn("**SETKEYS**", compat)
        self.assertTrue((ROOT / "tools" / "zx84_dri.py").exists())


if __name__ == "__main__":
    unittest.main()
