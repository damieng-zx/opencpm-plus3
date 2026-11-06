"""Keep the Windows and Unix build scripts in step.

CI builds with ``build.sh`` while local builds use ``build.cmd``.  When the
two drift, CI produces a different disk image (a missing program, or a
missing ``CPM3C.SYS`` split) and the emulator job fails even though the
working tree builds locally.
"""

from __future__ import annotations

import re
import unittest

from .layout import ROOT, source

ASSEMBLE = re.compile(r"--raw=(\S+)")


def _norm(path: str) -> str:
    return path.replace("\\", "/").lower()


def assembled_programs(text: str) -> dict[str, str]:
    """Map each --raw output to the source passed to sjasmplus."""
    out: dict[str, str] = {}
    for line in text.splitlines():
        match = ASSEMBLE.search(line)
        if not match:
            continue
        dst = _norm(match.group(1))
        src = _norm(line.split()[-1])
        if dst.startswith("build/") and src.startswith(("src/", "build/")):
            out[dst] = src
    return out


def disk_block(text: str, image: str, end_image: str) -> str:
    """The mkdsk arguments between two image builds, lower-cased."""
    flat = _norm(text)
    start = flat.index(f"mkdsk.py create build/{image}")
    end = flat.index(f"mkdsk.py create build/{end_image}", start)
    return flat[start:end]


def disk_files(text: str, image: str = "cpm3.dsk",
               end_image: str = "cpm3-test.dsk") -> set[str]:
    """The build/*.SYS, build/*.COM and src/* assets passed to mkdsk."""
    block = disk_block(text, image, end_image)
    return set(re.findall(
        r"(?:build|src)/[a-z0-9_./-]+\.(?:com|sys|fid|bin|txt|sub)", block))


TEST_PROGRAMS = {
    "build/bdostest.com", "build/xtetest.com", "build/stltest.com",
    "build/m80test.com", "build/m80bit.com", "build/disktest.com",
    "build/termtest.com", "build/systest.com", "build/regtest.com",
}
TEST_FIXTURES = {
    "src/test/smoke.txt", "src/test/page.txt",
    "src/test/smoke.sub", "src/test/param.sub",
}
UTILITIES = {
    "build/date.com", "build/showxdpb.com", "build/dump.com",
    "build/setdef.com", "build/submit.com", "build/screen.com",
    "build/set24x80.com", "build/format.com", "build/diskcopy.com",
    "build/stat.com", "build/sysgen.com",
}


class BuildScripts(unittest.TestCase):
    def setUp(self) -> None:
        self.cmd = source("build.cmd")
        self.sh = source("build.sh")

    def test_assemble_the_same_programs(self):
        self.assertEqual(assembled_programs(self.cmd),
                         assembled_programs(self.sh))

    def test_package_the_same_files(self):
        # Both images: the distribution and the test image must match between
        # build.cmd and build.sh.
        self.assertEqual(disk_files(self.cmd),
                         disk_files(self.sh))
        self.assertEqual(
            disk_files(self.cmd, "cpm3-test.dsk", "cpm3_720.dsk"),
            disk_files(self.sh, "cpm3-test.dsk", "cpm3_720.dsk"))

    def test_distribution_has_utilities_but_no_test_programs(self):
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            dist = disk_files(text)
            self.assertFalse(dist & TEST_PROGRAMS, name)
            self.assertFalse(dist & TEST_FIXTURES, name)
            self.assertTrue(UTILITIES <= dist, name)
            for shared in ("build/cpm3.sys", "build/cpm3c.sys",
                           "build/ccp.com", "build/ramdisk.fid"):
                self.assertIn(shared, dist, name)

    def test_test_image_adds_the_test_programs(self):
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            dist = disk_files(text)
            test = disk_files(text, "cpm3-test.dsk", "cpm3_720.dsk")
            self.assertTrue(dist <= test, name)
            self.assertTrue(TEST_PROGRAMS <= test, name)
            self.assertTrue(TEST_FIXTURES <= test, name)

    def test_both_split_the_system_image(self):
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            self.assertIn("split_sys.py", text, name)
            self.assertIn("cpm3c.sys", text.lower(), name)

    def test_the_standalone_b16test_is_gone(self):
        self.assertFalse((ROOT / "src" / "tools" / "b16test.asm").exists())
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            self.assertNotIn("b16test", text.lower(), name)
        disktest = source("src/test/disktest.asm")
        self.assertIn("test30:", disktest)
        self.assertIn('db "T30 B16 16-bit blocks$"', disktest)
        self.assertIn("DISKTEST 30", source("tools/zx84_smoke.py"))


if __name__ == "__main__":
    unittest.main()
