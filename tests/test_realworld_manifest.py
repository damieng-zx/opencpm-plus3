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
                self.assertIn(pkg.get("archive", "zip"), ("zip", "file"))
                self.assertTrue(pkg["command"])
                if pkg.get("archive", "zip") == "zip":
                    self.assertTrue(pkg.get("members"))
                else:
                    self.assertTrue(pkg.get("save_as"))
                for step in pkg.get("steps", []):
                    self.assertTrue(
                        "key" in step or "text" in step or step.get("wait"))
                for name in pkg.get("fixtures", []):
                    self.assertTrue((fixtures / name).exists(), name)

    def test_known_issues_have_text(self) -> None:
        for pkg in self.data["packages"]:
            if "known_issue" in pkg:
                with self.subTest(package=pkg["id"]):
                    self.assertIsInstance(pkg["known_issue"], str)
                    self.assertTrue(pkg["known_issue"].strip())


if __name__ == "__main__":
    unittest.main()
