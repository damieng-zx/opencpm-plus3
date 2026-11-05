"""Archive extraction with duplicate basenames (BDS C has two DEFF.CRL)."""

from __future__ import annotations

import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

from .layout import ROOT

sys.path.insert(0, str(ROOT / "tools"))
import zx84_realworld  # noqa: E402


class PrefixedMembers(unittest.TestCase):
    def _archive(self, directory: Path) -> Path:
        path = directory / "dupes.zip"
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr("a/DEFF.CRL", b"from-a")
            archive.writestr("b/DEFF.CRL", b"from-b")
            archive.writestr("a/CC.COM", b"cc")
        return path

    def test_prefix_disambiguates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self._archive(root)
            out = root / "out"
            zx84_realworld._extract_zip(
                archive, ["a/DEFF.CRL", "CC.COM"], out)
            self.assertEqual((out / "DEFF.CRL").read_bytes(), b"from-a")
            self.assertEqual((out / "CC.COM").read_bytes(), b"cc")

    def test_bare_duplicate_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = self._archive(root)
            with self.assertRaises(zx84_realworld.SetupError):
                zx84_realworld._extract_zip(
                    archive, ["DEFF.CRL"], root / "out")


if __name__ == "__main__":
    unittest.main()
