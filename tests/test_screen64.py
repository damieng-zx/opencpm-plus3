"""64-column mode: 4-pixel font, two characters per 8x8 attribute cell.

64 x 4 = 256 pixels, the Spectrum's full line width, so this is the widest
mode that can use a full 4-pixel pitch.  The typeface is "Compression" from
the ZX Origins collection; `tools/mkfont64.py` turns the .ch8 source into the
2048-byte font the loader expects.
"""

from __future__ import annotations

import sys
import unittest

from .layout import ROOT, source

TOOLS = str(ROOT / "tools")
if TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import mkfont64  # noqa: E402


class ScreenDriver(unittest.TestCase):
    def test_buffer_holds_the_widest_mode(self):
        text = source("src/bios/screen.zpa")
        self.assertIn("SCR_COLS_MAX equ 64", text)

    def test_set_cols_accepts_64_and_selects_its_font(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("scr_set_cols:"):text.index("; Font data is NOT embedded")]
        self.assertIn("cp 64", body)
        self.assertIn("ld hl, 0x9400", body)
        self.assertIn("ld (scb_conwidth), a", body)
        # Without FONT64.BIN on the boot disk the mode is refused rather
        # than drawing from uninitialised bank-6 RAM.
        self.assertIn("ld a, (_lf_found)", body)
        self.assertIn("and 0x10", body)

    def test_renderer_has_two_phases_and_no_spill(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index(".render64:"):text.index("; --- Shift-specialised")]
        # byte_col = col >> 1, phase = col & 1
        self.assertIn("srl a", body)
        self.assertIn("ld b, a", body)
        self.assertIn("and 1", body)
        self.assertIn("jr nz, .r64_hi", body)
        # even column: high nibble; odd column: glyph >> 4 into the low nibble
        self.assertIn("and 0x0F", body)
        self.assertIn("and 0xF0", body)
        self.assertEqual(body.count("srl d"), 4)
        # Never writes a second byte per glyph row.
        self.assertNotIn("inc l", body)

    def test_attributes_map_two_characters_per_cell(self):
        text = source("src/bios/screen.zpa")
        body = text[text.index("_put_attr:"):text.index("_do_cr:")]
        self.assertIn(".pa_64:", body)
        self.assertIn("srl a", body[body.index(".pa_64:"):])

    def test_fdc_buffer_moved_clear_of_the_wider_text_buffer(self):
        text = source("src/bios/fdc765.zpa")
        self.assertIn("deblock_buf equ 0x9C00", text)
        # 0xA500 would sit inside 64x24 = 1536 bytes of char_buffer at A000.
        self.assertIn("char_buffer equ 0xA000", source("src/bios/screen.zpa"))


class Loader(unittest.TestCase):
    def test_font64_is_loaded_from_the_boot_disk(self):
        text = source("src/bios/bios.zpa")
        self.assertIn('_lf_name64:   db "FONT64  BIN"', text)
        body = text[text.index(".lf_try64:"):text.index(".lf_try_ccp:")]
        self.assertIn("ld (_font64_blk0), a", body)
        self.assertIn("or 0x10", body)
        self.assertIn("ld de, 0x9400", text)
        self.assertIn("cp 31", text)          # all five scanned files found


class Command(unittest.TestCase):
    def test_screen_command_accepts_64(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".try_64:"):text.index(".screen_set:")]
        self.assertIn("cp '6'", body)
        self.assertIn("cp '4'", body)
        self.assertIn("ld a, 64", body)
        self.assertIn("SCREEN 32|51|64", text)


class Font(unittest.TestCase):
    def test_font_is_generated_from_the_ch8(self):
        self.assertEqual((ROOT / "src" / "bios" / "font64.bin").read_bytes(),
                         mkfont64.build())

    def test_font_is_4_pixels_wide(self):
        data = (ROOT / "src" / "bios" / "font64.bin").read_bytes()
        self.assertEqual(len(data), 256 * 8)
        bad = [i for i, value in enumerate(data) if value & 0x0F]
        self.assertEqual(bad, [], "glyph rows with pixels below bit 4")

    def test_high_ascii_is_blank(self):
        data = (ROOT / "src" / "bios" / "font64.bin").read_bytes()
        for code in range(0x80, 0x100):
            self.assertEqual(data[code * 8:(code + 1) * 8], bytes(8),
                             f"0x{code:02x} should be blank")

    def test_ascii_is_present(self):
        data = (ROOT / "src" / "bios" / "font64.bin").read_bytes()
        for code in range(0x21, 0x7F):
            self.assertNotEqual(data[code * 8:(code + 1) * 8], bytes(8),
                                f"0x{code:02x} is blank")


if __name__ == "__main__":
    unittest.main()
