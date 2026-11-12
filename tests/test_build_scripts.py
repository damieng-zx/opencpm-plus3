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


def disk_block(text: str, image: str, end_image: str | None) -> str:
    """The mkdsk arguments between two image builds, lower-cased."""
    flat = _norm(text)
    start = flat.index(f"mkdsk.py create build/{image}")
    if end_image is None:
        # The last image in the script; stop where the build summary starts.
        ends = [flat.find(marker, start) for marker in
                ("if errorlevel 1 goto :fail", "for %%a in (build/loader",
                 'echo "  loader:')]
        ends = [e for e in ends if e != -1]
        end = min(ends) if ends else len(flat)
    else:
        end = flat.index(f"mkdsk.py create build/{end_image}", start)
    return flat[start:end]


def disk_files(text: str, image: str = "cpm3.dsk",
               end_image: str | None = "cpm3-test.dsk") -> set[str]:
    """The build/*.SYS, build/*.COM and src/* assets passed to mkdsk."""
    block = disk_block(text, image, end_image)
    return set(re.findall(
        r"(?:build|src)/[a-z0-9_./-]+\.(?:com|sys|fid|bin|txt|sub)", block))


TEST_PROGRAMS = {
    "build/bdostest.com", "build/xtetest.com", "build/disktest.com",
    "build/termtest.com", "build/systest.com", "build/regtest.com",
    "build/inptest.com", "build/biostest.com", "build/chaintst.com",
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
    "build/erase.com", "build/dir.com", "build/device.com",
}
# Built for the benchmark (it runs on Locomotive's disk too) but only shipped
# on the test image, like the other test programs.
BENCHMARK = {"build/screenbm.com"}


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
        # The two images carry the same CP/M files; the boot sector and
        # stage-2 loader differ because the test image is a 720K disk with
        # its own -DDS720 build of both.
        boot_chain = {"build/bootsect.bin", "build/loader.bin"}
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            dist = disk_files(text) - boot_chain
            test = disk_files(text, "cpm3-test.dsk", "cpm3_720.dsk")
            self.assertTrue(dist <= test, name)
            self.assertTrue(TEST_PROGRAMS <= test, name)
            self.assertTrue(TEST_FIXTURES <= test, name)

    def test_the_benchmark_ships_with_the_tests_only(self):
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            self.assertFalse(disk_files(text) & BENCHMARK, name)
            self.assertTrue(BENCHMARK <= disk_files(
                text, "cpm3-test.dsk", "cpm3_720.dsk"), name)
            self.assertIn("build/screenbm.com", assembled_programs(text), name)

    def test_the_720k_distribution_mirrors_the_180k_one(self):
        """A second distribution disc, 720K, with nothing extra on it yet."""
        boot_chain = {"build/bootsect.bin", "build/loader.bin",
                      "build/bootsect720.bin", "build/loader720.bin",
                      "build/bios.bin"}
        for name, text in (("build.cmd", self.cmd), ("build.sh", self.sh)):
            block = disk_block(text, "cpm3-dist720.dsk", None)
            files = set(re.findall(
                r"(?:build|src)/[a-z0-9_./-]+\.(?:com|sys|fid|bin|txt|sub)",
                block)) - boot_chain
            # Same CP/M files as the 180K distribution...
            self.assertEqual(files, disk_files(text) - boot_chain, name)
            # ...and none of the test-only content.
            self.assertFalse(files & TEST_PROGRAMS, name)
            self.assertFalse(files & TEST_FIXTURES, name)
            self.assertFalse(files & BENCHMARK, name)
            self.assertNotIn("pmautoae", block, name)
            # It is a 720K disc booted by the -DDS720 pair.
            self.assertIn("--format 720k", block, name)
            self.assertIn("bootsect720.bin", block, name)
            self.assertIn("loader720.bin", block, name)
            self.assertNotIn("bootsect.bin", block, name)
            self.assertNotIn("loader.bin", block, name)

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
