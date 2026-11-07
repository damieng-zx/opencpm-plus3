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


class DskExtraction(unittest.TestCase):
    """A DSK archive pulls files out of an image's CP/M directory."""

    def _image(self, directory: Path) -> Path:
        sys.path.insert(0, str(ROOT / "tools"))
        from mkdsk import DSKImage

        dsk = DSKImage("180k")
        dsk.add_cpm_file("DEMO.COM", b"hello" * 40)
        dsk.add_cpm_file("DATA.DAT", bytes(range(256)) * 3)
        path = directory / "demo.dsk"
        dsk.save(path)
        return path

    def test_extracts_named_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = self._image(root)
            out = root / "out"
            zx84_realworld._extract_dsk(
                image, ["DEMO.COM", "DATA.DAT"], out)
            self.assertEqual((out / "DEMO.COM").read_bytes()[:200],
                             (b"hello" * 40))
            self.assertEqual((out / "DATA.DAT").read_bytes()[:768],
                             bytes(range(256)) * 3)

    def test_missing_member_reports_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = self._image(root)
            with self.assertRaises(zx84_realworld.SetupError) as ctx:
                zx84_realworld._extract_dsk(image, ["NOPE.COM"], root / "out")
            self.assertIn("DEMO.COM", str(ctx.exception))


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
