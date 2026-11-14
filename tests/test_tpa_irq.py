"""BDOS user-memory accesses page the TPA in with interrupts off."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def common() -> str:
    return (ROOT / "src/bios/common.zpa").read_text(encoding="utf-8")


def body(text: str, start: str, end: str) -> str:
    return text[text.index(start):text.index(end, text.index(start))]


class TpaInterrupts(unittest.TestCase):
    def test_helpers_use_tpa_in_and_out(self):
        text = common()
        for name, end in (("read_user_byte:", "; write_user_byte"),
                          ("write_user_byte:", "; copy_from_user"),
                          ("copy_xfer:", "_cfu_src:")):
            b = body(text, name, end)
            self.assertIn("call tpa_in", b, name)
            self.assertIn("jp tpa_out", b, name)
            self.assertNotIn("BANK0_1FFD", b, name)

    def test_tpa_in_disables_and_remembers(self):
        b = body(common(), "tpa_in:", "tpa_out:")
        self.assertRegex(b, r"ld a, i\s+(;[^\n]*\s+)?di")
        self.assertIn("ld (tpa_ie), a", b)

    def test_tpa_out_restores(self):
        b = body(common(), "tpa_out:", "tpa_ie:")
        self.assertIn("ld a, (tpa_ie)", b)
        self.assertIn("ei", b)

    def test_pinned_record_copiers_kept(self):
        text = common()
        self.assertIn("ds 0xF97A - $, 0", text)
        self.assertIn("assert copy_record_to_tpa == 0xF97A", text)


if __name__ == "__main__":
    unittest.main()
