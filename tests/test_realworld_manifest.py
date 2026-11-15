"""Static checks for the real-world suite manifest.

These do not download anything or require an emulator; they catch broken
manifest entries before someone runs the network-backed suite.
"""
from __future__ import annotations

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "tests" / "realworld" / "manifest.json"


class RealWorldManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(MANIFEST.read_text(encoding="utf-8"))

    def test_version(self) -> None:
        self.assertEqual(self.data["version"], 1)

    def test_base_files_are_defined(self) -> None:
        base = self.data["base"]
        self.assertTrue(base["boot"].startswith("build/"))
        self.assertTrue(base["system"].startswith("build/"))
        self.assertGreaterEqual(len(base["files"]), 1)
        self.assertIn("build/CPM3.SYS", base["files"])

    def test_package_ids_are_unique(self) -> None:
        ids = [p["id"] for p in self.data["packages"]]
        self.assertEqual(len(ids), len(set(ids)))

    def test_packages_are_well_formed(self) -> None:
        fixtures = ROOT / self.data.get(
            "fixtures", "tests/realworld/fixtures")
        for pkg in self.data["packages"]:
            with self.subTest(package=pkg["id"]):
                self.assertTrue(pkg["id"])
                self.assertTrue(pkg["title"])
                self.assertTrue(pkg["url"].startswith(("http://", "https://")))
                self.assertIn(pkg.get("archive", "zip"),
                              ("zip", "file", "dsk"))
                self.assertTrue(pkg["command"])
                archive = pkg.get("archive", "zip")
                if archive in ("zip", "dsk"):
                    self.assertTrue(pkg.get("members"))
                else:
                    self.assertTrue(pkg.get("save_as"))
                for step in pkg.get("steps", []):
                    self.assertTrue(
                        "key" in step or "text" in step or "shell" in step
                        or step.get("wait"))
                    # expect_attrs maps attribute hex -> minimum cell count.
                    for key, count in step.get("expect_attrs", {}).items():
                        self.assertRegex(key, r"^[0-9A-F]{2}$")
                        self.assertIsInstance(count, int)
                        self.assertGreater(count, 0)
                for name in pkg.get("fixtures", []):
                    # A fixture is a name, or {"SRC.NAME": "ON.DISK.NAME"}.
                    src = name if isinstance(name, str) else next(iter(name))
                    self.assertTrue((fixtures / src).exists(), src)

    def test_known_issues_have_text(self) -> None:
        for pkg in self.data["packages"]:
            if "known_issue" in pkg:
                with self.subTest(package=pkg["id"]):
                    self.assertIsInstance(pkg["known_issue"], str)
                    self.assertTrue(pkg["known_issue"].strip())


class SaveRestoreCoverage(unittest.TestCase):
    """The Infocom games must exercise save and restore on real files.

    Saving is the only third-party path that creates a file, writes it
    sequentially, closes it and then deletes it so a second save can reuse
    the name - i.e. the exact F19/F21/F22/F16 sequence the bug hunt changed.
    These checks are static: they guard the scripted steps, not the emulator.
    """

    GAMES = {
        "hitchhiker": "HITCHHIK.SAV",
        "planetfall": "PLANETFA.SAV",
        "starcross": "STARCROS.SAV",
    }

    @classmethod
    def setUpClass(cls) -> None:
        cls.data = json.loads(MANIFEST.read_text(encoding="utf-8"))
        cls.packages = {p["id"]: p for p in cls.data["packages"]}

    def _texts(self, pkg_id: str) -> list[str]:
        pkg = self.packages[pkg_id]
        out = []
        for step in pkg["steps"]:
            for key in ("text", "shell"):
                if key in step:
                    out.append(step[key])
        return out

    def test_each_game_saves_and_restores(self):
        for pkg_id, save_name in self.GAMES.items():
            with self.subTest(package=pkg_id):
                pkg = self.packages[pkg_id]
                texts = self._texts(pkg_id)
                self.assertIn("save", texts, "no save step")
                self.assertIn("restore", texts, "no restore step")
                # The name must appear in the script somewhere: either the
                # game's own prompt (Hitchhiker and Planetfall name the
                # default) or the DIR that lists the result.  Starcross only
                # says "Type <ENTER> for default." on a 51-column screen.
                self.assertTrue(
                    any(save_name in e
                        for step in pkg["steps"]
                        for e in list(step.get("expect", []))
                        + [step.get("shell", "")]),
                    f"{pkg_id} never mentions {save_name}")

    def test_each_game_saves_twice_over_the_same_name(self):
        """A second save must overwrite in place, not add an extent.

        CP/M 3 makes the program delete the old file before it creates the
        new one (F22 refuses an existing name), so the second save is the
        path that exercises F19's per-extent delete and F21's block reuse.
        """
        for pkg_id in self.GAMES:
            with self.subTest(package=pkg_id):
                texts = self._texts(pkg_id)
                self.assertEqual(
                    texts.count("save"), 2,
                    f"{pkg_id} must save twice to cover the overwrite path")

    def test_each_game_checks_the_resulting_directory_entry(self):
        """`DIR [SIZE]` proves one file, one entry, no leaked blocks."""
        for pkg_id, save_name in self.GAMES.items():
            with self.subTest(package=pkg_id):
                pkg = self.packages[pkg_id]
                size_steps = [s for s in pkg["steps"]
                              if save_name in s.get("shell", "")]
                self.assertTrue(size_steps, f"{pkg_id} never lists its save")
                expect = " ".join(size_steps[0].get("expect", []))
                self.assertIn("Total 1K Blocks", expect)
                self.assertIn("Used/Max Dir Entries", expect)

    def test_the_save_file_tool_is_staged(self):
        """`DIR [SIZE]` needs DIR.COM on the image."""
        for pkg_id in self.GAMES:
            with self.subTest(package=pkg_id):
                self.assertIn("build/DIR.COM",
                              self.packages[pkg_id].get("files", []))


if __name__ == "__main__":
    unittest.main()
