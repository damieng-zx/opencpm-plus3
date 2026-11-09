"""Coverage gates for the BDOS, the BIOS table and the shipped programs.

These do not run the emulator.  They scan the dispatch tables and the build
scripts, then require every implemented entry (or every built program) to be
mentioned by at least one on-disk or smoke test.  A new function or utility
therefore cannot quietly arrive without a test.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

from .layout import ROOT, source

# Entries that cannot be reached from a transient test.
BDOS_EXEMPT = {
    0: "system reset never returns to the caller",
    124: "private CCP submit-input helper, exercised by the SUBMIT/INPTEST smoke",
    125: "private CCP helper for the rest of a cmd1!cmd2 line, exercised by "
         "the '!' chain in the smoke",
}

# BIOS entries that cannot (or must not) be called by a TPA test program.
BIOS_EXEMPT = {
    0: "cold boot never returns",
    1: "warm boot never returns",
    3: "blocking console input",
    27: "BNKSEL would leave the TPA while the test is running",
    30: "USERF is the XBIOS entry, covered by XTETEST",
    31: "reserved (JP 0)",
    32: "SCRMODE is covered by SCREEN.COM and the ESC 3 tests",
}


def harnesses() -> list[Path]:
    """The scripts that drive the emulator (some are local/optional)."""
    names = ("zx84_smoke.py", "zx84_negative.py", "zx84_regtest.py",
             "zx84_dri.py", "zx84_pip.py", "zx84_diskit.py",
             "zx84_realworld.py", "screen_bench.py")
    return [ROOT / "tools" / name for name in names
            if (ROOT / "tools" / name).exists()]


def harness_corpus() -> str:
    """Harness text only: a program's own source must not count as a test."""
    return "\n".join(p.read_text(encoding="utf-8", errors="replace")
                     for p in harnesses())


def runtime_corpus() -> str:
    """Built on-disk tests plus the emulator harnesses (no static tests)."""
    built = [p for p in build_paths("build.cmd") if p.startswith("src/test/")]
    paths = [ROOT / p for p in built] + harnesses()
    return "\n".join(p.read_text(encoding="utf-8", errors="replace")
                     for p in paths)


def bdos_functions() -> list[int]:
    text = source("src/bdos/bdos.zpa")
    return sorted({int(n) for n in re.findall(r"\bbf_f(\d+)\b", text)})


def bios_entries() -> list[int]:
    text = source("src/bios/bios.zpa")
    block = text[text.index("bios_base:"):text.index("; System state")]
    return [int(n) for n in re.findall(
        r"^\s*(?:fn_\w+:\s*)?jp\s+[^;\r\n]+;\s*(\d+):", block, re.M)]


def build_paths(script: str) -> set[str]:
    text = source(script).replace("\\", "/").lower()
    return set(re.findall(r"src/(?:tools|util|test)/[a-z0-9_.-]+\.(?:asm|zpa)",
                          text))


class BdosCoverage(unittest.TestCase):
    def test_every_implemented_function_is_runtime_tested(self):
        corpus = runtime_corpus()
        missing = [n for n in bdos_functions()
                   if n not in BDOS_EXEMPT
                   and not re.search(rf"\bf0*{n}\b", corpus, re.I)]
        self.assertFalse(
            missing,
            "BDOS functions with no src/test or smoke reference: "
            + ", ".join(f"F{n}" for n in missing))

    def test_exemptions_still_exist(self):
        functions = set(bdos_functions())
        for fn in BDOS_EXEMPT:
            self.assertIn(fn, functions,
                          f"F{fn} exemption is stale; remove it")


class BiosCoverage(unittest.TestCase):
    def test_jump_table_has_every_entry(self):
        entries = bios_entries()
        self.assertEqual(entries, list(range(33)),
                         "BIOS jump table entries are missing or out of order")

    def test_every_callable_entry_has_a_biostest_case(self):
        biotest = source("src/test/biostest.asm")
        smoke = source("tools/zx84_smoke.py")
        missing = []
        for fn in bios_entries():
            if fn in BIOS_EXEMPT:
                continue
            if f"B{fn:02d}" not in biotest or f"({fn}, " not in smoke:
                missing.append(fn)
        self.assertFalse(
            missing,
            "BIOS entries without a BIOSTEST case and smoke marker: "
            + ", ".join(str(n) for n in missing))


class ProgramCoverage(unittest.TestCase):
    def test_every_built_tool_is_invoked(self):
        corpus = harness_corpus()
        missing = []
        for script in ("build.cmd", "build.sh"):
            for path in build_paths(script):
                if not path.startswith(("src/tools/", "src/util/")):
                    continue
                name = Path(path).stem.upper()
                # Path.stem keeps the dot: date.zpa -> DATE, dump.asm -> DUMP.
                name = name.split(".")[0]
                if name not in corpus:
                    missing.append(f"{path} ({name})")
        self.assertFalse(
            missing,
            "built utilities with no smoke/test reference: "
            + ", ".join(sorted(set(missing))))

    def test_every_built_test_program_is_run(self):
        corpus = harness_corpus()
        missing = []
        for script in ("build.cmd", "build.sh"):
            for path in build_paths(script):
                if not path.startswith("src/test/"):
                    continue
                name = Path(path).stem.upper()
                if name not in corpus:
                    missing.append(f"{path} ({name})")
        self.assertFalse(
            missing,
            "built test programs with no harness reference: "
            + ", ".join(sorted(set(missing))))

    def test_build_scripts_agree_on_what_they_build(self):
        self.assertEqual(build_paths("build.cmd"), build_paths("build.sh"))


if __name__ == "__main__":
    unittest.main()
