"""The real-world 24x80 variants and their package image base."""

from __future__ import annotations

import json
import unittest

from .layout import ROOT, source


class RealWorld24x80(unittest.TestCase):
    def setUp(self) -> None:
        self.manifest = json.loads(
            (ROOT / "tests" / "realworld" / "manifest.json").read_text(
                encoding="utf-8"))
        self.packages = {p["id"]: p for p in self.manifest["packages"]}

    def test_base_carries_the_split_and_set24x80(self):
        files = self.manifest["base"]["files"]
        self.assertIn("build/CPM3.SYS", files)
        self.assertIn("build/CPM3C.SYS", files)
        self.assertIn("build/SET24X80.COM", files)

    def test_24x80_variants_run_set24x80_and_flip(self):
        for pid in ("wordstar30_80", "turbo3_80", "supercalc2_80"):
            pkg = self.packages[pid]
            self.assertEqual(pkg["setup"], ["SET24X80"], pid)
            flips = [s for s in pkg.get("steps", [])
                     if s.get("key") == "shift+sym+enter"]
            self.assertTrue(flips, pid)
            self.assertTrue(any(s.get("expect") for s in flips), pid)

    def test_runner_supports_setup(self):
        runner = source("tools/zx84_realworld.py")
        self.assertIn('pkg.get("setup", [])', runner)
        self.assertIn('rw.wait_for(setup["expect"]', runner)


if __name__ == "__main__":
    unittest.main()
