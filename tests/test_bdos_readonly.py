"""The R/O attribute is enforced on delete (F19) and rename (F23)."""

from __future__ import annotations

import unittest

from .layout import source


def body(text: str, start: str, end: str) -> str:
    return text[text.index(start):text.index(end)]


class ReadOnlyDelete(unittest.TestCase):
    def test_f19_checks_the_filetype_attribute_bit(self):
        f19 = body(source("src/bdos/bdos.zpa"), "bf_f19:", "bf_f20:")
        # Match, then entry[9] bit 7 (the R/O attribute) must bail out.
        self.assertIn("ld de, 9", f19)
        self.assertIn("bit 7, a", f19)
        self.assertIn("jp nz, .del_ro_err", f19)
        self.assertIn(".del_ro_err:", f19)
        # Error mode decides between a return and the classic message.
        self.assertIn("call ro_error", f19)
        self.assertIn("ld a, 0xFF", f19)

    def test_f23_checks_the_filetype_attribute_bit(self):
        f23 = body(source("src/bdos/bdos.zpa"), "bf_f23:", "Random access helpers")
        self.assertIn("ld de, 9", f23)
        self.assertIn("bit 7, a", f23)
        self.assertIn("jp nz, .ren_ro_err", f23)
        self.assertIn(".ren_ro_err:", f23)
        self.assertIn("call ro_error", f23)

    def test_the_error_path_goes_through_ro_error(self):
        text = source("src/bdos/bdos.zpa")
        ro = body(text, "ro_error:", "msg_ro:")
        self.assertIn("error_mode", ro)
        self.assertIn("call print_str", ro)
        self.assertIn("jp warm_boot", ro)

    def test_writes_refuse_the_file_attribute(self):
        # F21/F34/F40 share bf_f21_core; an FCB opened from a read-only
        # entry carries bit 7 in its filetype byte.
        core = body(source("src/bdos/bdos.zpa"), "bf_f21_core:", ".wseq_do:")
        self.assertIn("bit 7, (ix + 9)", core)
        self.assertIn("call ro_error", core)
        self.assertIn(".wseq_writable", core)

    def test_disktest_covers_ro_delete_and_rename(self):
        text = source("src/test/disktest.asm")
        t13 = body(text, "test13:", "test14:")
        self.assertIn("F19: Delete", t13)
        self.assertIn("F23: Rename", t13)
        self.assertIn("F30: Set File Attributes", t13)
        self.assertIn("cp 0xFF", t13)
        # F45 error mode must be restored on both paths.
        self.assertGreaterEqual(t13.count("ld c, 45"), 2)
        self.assertGreaterEqual(t13.count("ld e, 0"), 1)

    def test_dri_harness_exercises_the_refusal(self):
        tool = source("tools/zx84_dri.py")
        self.assertIn("ERA RO.TXT", tool)
        self.assertIn("REN NEW.TXT=RO.TXT", tool)
        self.assertIn("Bdos Err: R/O", tool)
        self.assertIn("SET RO.TXT [RW]", tool)

    def test_docs_describe_the_enforcement(self):
        api = source("docs/API.md")
        self.assertIn("R/O attribute", api)
        compat = source("docs/compatibility.md")
        self.assertIn("F19 (delete) and F23", compat)
        self.assertIn("write", compat.lower())


if __name__ == "__main__":
    unittest.main()
