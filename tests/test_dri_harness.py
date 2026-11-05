"""The local-only DRI utility harness and its known-issue notes."""

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
        # No local copies -> notice + exit 0, so CI never needs them.
        self.assertIn("skipped (no local copies)", self.tool)
        self.assertIn("return 0", self.tool)

    def test_exercises_show_and_ed(self):
        self.assertIn('smoke.command("SHOW"', self.tool)
        self.assertIn("Q-(Y/N)?", self.tool)
        self.assertIn("SMOKE OK", self.tool)
        self.assertIn("shift+sym+z", self.tool)       # Ctrl-Z ends ED insert
        self.assertIn("NEW FILE", self.tool)

    def test_known_issues_are_documented(self):
        tool = source("docs/third-party-tests.md")
        self.assertIn("DRI CP/M 3 utilities", tool)
        self.assertIn("ED `E` (end/save)", tool)
        self.assertIn("SETKEYS", tool)
        compat = source("docs/compatibility.md")
        self.assertIn("ED `E` (save)", compat)
        self.assertIn("**SET**", compat)
        self.assertTrue((ROOT / "tools" / "zx84_dri.py").exists())


if __name__ == "__main__":
    unittest.main()
