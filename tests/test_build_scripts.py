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


def disk_files(text: str) -> set[str]:
    """The build/*.SYS, build/*.COM and src/* assets passed to mkdsk."""
    flat = _norm(text)
    start = flat.index("mkdsk.py create build/cpm3.dsk")
    end = flat.index("mkdsk.py create build/cpm3_720.dsk", start)
    block = flat[start:end]
    return set(re.findall(
        r"(?:build|src)/[a-z0-9_./-]+\.(?:com|sys|fid|bin|txt|sub)", block))


class BuildScripts(unittest.TestCase):
    def setUp(self) -> None:
        self.cmd = source("build.cmd")
        self.sh = source("build.sh")

    def test_assemble_the_same_programs(self):
        self.assertEqual(assembled_programs(self.cmd),
                         assembled_programs(self.sh))

    def test_package_the_same_files(self):
        self.assertEqual(disk_files(self.cmd), disk_files(self.sh))

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
