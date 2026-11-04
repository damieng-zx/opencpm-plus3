"""Local-only third-party application tests.

DISCKIT is Copyright 1988 Locomotive Software Ltd and must not be
redistributed.  These checks guard the local harness and the ignore rule.
"""

from __future__ import annotations

import unittest

from .layout import source


class LocalDiscKit(unittest.TestCase):
    def test_references_are_gitignored(self):
        self.assertIn("references/", source(".gitignore"))

    def test_tool_only_uses_a_local_copy(self):
        tool = source("tools/zx84_diskit.py")
        self.assertIn("Locomotive Software", tool)
        self.assertIn("not included", tool)
        self.assertIn("skipped (no local copy)", tool)
        self.assertIn("disckit-test.dsk", tool)
        self.assertIn('shutil.copyfile(base, scratch)', tool)
        # The only file it writes is the scratch image under build/.
        self.assertNotIn('references") / "binaries" / "DISCKIT.COMx").write',
                         tool)

    def test_docs_state_the_copyright(self):
        doc = source("docs/third-party-tests.md")
        self.assertIn("Locomotive Software", doc)
        self.assertIn("git-ignored", doc)
        self.assertIn("build/disckit-test.dsk", doc)


if __name__ == "__main__":
    unittest.main()
