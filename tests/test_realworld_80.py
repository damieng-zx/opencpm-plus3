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
        for pid in ("wordstar30_80", "turbo3_80", "supercalc2_80",
                    "multiplan_80"):
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

    def test_sgr_is_asserted_at_run_time(self):
        """The docs claim SGR now takes effect for SuperCalc2.

        That claim used to be wrong in the other direction (the docs said
        SGR was ignored), so it is checked from both ends: the manifest
        asks for particular attribute values and the runner has the helper
        to verify them.
        """
        runner = source("tools/zx84_realworld.py")
        self.assertIn("def attribute_counts(", runner)
        self.assertIn("def expect_attrs(", runner)
        self.assertIn('step.get("expect_attrs")', runner)
        # 0x5800 is the Spectrum attribute file.
        self.assertIn("self.memory(5, 0x5800, 768)", runner)

        # The 51-column run is where both attribute values are on screen.
        sc2 = self.packages["supercalc2"]
        wanted = [s.get("expect_attrs") for s in sc2.get("steps", [])]
        wanted = [w for w in wanted if w]
        self.assertTrue(wanted, "supercalc2 must assert its SGR attributes")
        self.assertEqual(wanted[0].get("4F"), 64)   # bright column headers
        self.assertEqual(wanted[0].get("79"), 6)    # reversed cell marker

        # The 80-column variant can only see the bright ones.
        sc2_80 = self.packages["supercalc2_80"]
        wanted80 = [s.get("expect_attrs") for s in sc2_80.get("steps", [])]
        wanted80 = [w for w in wanted80 if w]
        self.assertTrue(wanted80, "supercalc2_80 must assert its SGR attributes")
        self.assertEqual(wanted80[0].get("4F"), 64)
        self.assertNotIn("79", wanted80[0])

    def test_docs_do_not_claim_sgr_is_ignored(self):
        for name in ("docs/compatibility.md", "docs/realworld-suite.md"):
            text = source(name)
            self.assertNotIn("SGR attribute switching is still ignored", text,
                             name)
            self.assertNotIn("SGR\n  attribute requests are still ignored",
                             text, name)
            self.assertNotIn("SGR, `ESC [ . m`) are still consumed", text, name)



class ScreenReaderModes(unittest.TestCase):
    """`RealWorld.screen()` must handle every width and the 24x80 window.

    The reader used to take the stride from `scr_cols` and read only
    `char_buffer`.  In 24x80 `scr_cols` is still the *physical* width, and
    `char_buffer` mirrors just the visible window, so columns past
    `lg_off + scr_cols` were invisible: SuperCalc2's right-hand columns
    could not be asserted on at all.
    """

    def setUp(self) -> None:
        # Import lazily: zx84_realworld pulls in the MCP client.
        import importlib
        self.rw = importlib.import_module("tools.zx84_realworld")

    def _reader(self):
        """A RealWorld with the emulator stubbed out by a memory dict."""

        rw = self.rw

        class Fake(rw.RealWorld):
            def __init__(self, cells, addr):
                self.cells = cells
                self.addr = addr
                self.cb = addr["char_buffer"]
                self.cb_bank = 6
                self.scr_cols = addr["scr_cols"]
                self.mode80 = addr["mode80"]
                self.lg_off = addr["lg_off"]
                self.lg_auto = addr["lg_auto"]
                self.lg_step = addr["lg_step"]
                self.lg_savecols = addr["lg_savecols"]
                self.stl_on = addr["stl_on"]
                self.vp_height = addr["vp_height"]
                self.vp_width = addr["vp_width"]
                self.lg_buf = addr["LG_BUF"]
                self.history = []

            def memory(self, bank, addr, length):
                cell = self.cells.get((bank, addr))
                if cell is None:
                    return b""
                return bytes(cell[:length])

        addr = dict(char_buffer=0xA000, scr_cols=0x0B7D, mode80=0xA8C1,
                    lg_off=0xA8C2, lg_auto=0xA8C3, lg_step=0xA8C4,
                    lg_savecols=0xA8C5, stl_on=0xA8C0, vp_height=0xA73C,
                    vp_width=0xA73D, LG_BUF=0x5B00)
        return Fake, addr

    @staticmethod
    def _bank(cells, bank, addr, data):
        cells[(bank, addr)] = bytearray(data)

    def test_narrow_modes_read_char_buffer(self):
        for cols in (32, 51, 64):
            Fake, addr = self._reader()
            cells = {}
            self._bank(cells, 4, addr["scr_cols"], [cols])
            self._bank(cells, 6, addr["mode80"], [0])
            self._bank(cells, 6, addr["stl_on"], [0])
            row = bytes(b"A>" + b"." * (cols - 2))
            self._bank(cells, 6, addr["char_buffer"], row * 24)
            r = Fake(cells, addr)
            line = r.screen()[0]
            self.assertTrue(line.startswith("A>"), cols)
            self.assertEqual(len(line), cols, "the full width must be read")

    def test_24x80_reads_the_logical_screen_not_the_window(self):
        Fake, addr = self._reader()
        cells = {}
        self._bank(cells, 4, addr["scr_cols"], [51])        # physical width
        self._bank(cells, 6, addr["mode80"], [1])
        self._bank(cells, 6, addr["lg_off"], [0])
        self._bank(cells, 6, addr["stl_on"], [0])
        # Logical line: 'L' for the left page, 'R' for the right page.
        logical = bytes(b"L" * 51 + b"R" * 29)
        self._bank(cells, 5, addr["LG_BUF"], logical * 24)
        # char_buffer only mirrors the left page.
        self._bank(cells, 6, addr["char_buffer"], b"L" * 51 * 24)
        r = Fake(cells, addr)

        line = r.screen()[0]
        self.assertEqual(len(line), 80)
        self.assertIn("R", line, "columns past the window must be visible")

    def test_window_slices_at_lg_off(self):
        Fake, addr = self._reader()
        cells = {}
        self._bank(cells, 4, addr["scr_cols"], [51])
        self._bank(cells, 6, addr["mode80"], [1])
        self._bank(cells, 6, addr["lg_off"], [29])
        self._bank(cells, 6, addr["stl_on"], [0])
        # Distinct character per column, so the slice is unambiguous even
        # though the 51-column window overlaps both pages.
        logical = bytes(0x41 + (c % 26) for c in range(80))
        self._bank(cells, 5, addr["LG_BUF"], logical * 24)
        self._bank(cells, 6, addr["char_buffer"], b"R" * 51 * 24)
        r = Fake(cells, addr)

        win = r.window()[0]
        self.assertEqual(len(win), 51)
        want = "".join(chr(0x41 + (c % 26)) for c in range(29, 80))
        self.assertEqual(win, want, "window must start at lg_off")

    def test_status_line_reduces_the_text_rows(self):
        Fake, addr = self._reader()
        cells = {}
        self._bank(cells, 4, addr["scr_cols"], [51])
        self._bank(cells, 6, addr["mode80"], [0])
        self._bank(cells, 6, addr["stl_on"], [1])       # status bar on
        self._bank(cells, 6, addr["char_buffer"], b"X" * 51 * 24)
        r = Fake(cells, addr)

        self.assertEqual(len(r.screen()), 23, "row 23 is the status bar")
        self.assertEqual(len(r.screen(24)), 24)
        self.assertIsNotNone(r.status_line())

    def test_status_line_reads_char_buffer_not_the_logical_screen(self):
        """The bar is drawn into char_buffer, so LG_BUF must be ignored."""
        Fake, addr = self._reader()
        cells = {}
        self._bank(cells, 4, addr["scr_cols"], [51])
        self._bank(cells, 6, addr["mode80"], [1])
        self._bank(cells, 6, addr["stl_on"], [1])
        # Logical screen row 23 says one thing ...
        self._bank(cells, 5, addr["LG_BUF"], b"L" * 80 * 24)
        # ... but the rendered bar (with the '>' page marker) is in char_buffer.
        bar = b" " * 50 + b">"
        self._bank(cells, 6, addr["char_buffer"], b"." * 51 * 23 + bar)
        r = Fake(cells, addr)
        self.assertEqual(r.status_line(), " " * 50 + ">")

    def test_status_line_reports_none_when_off(self):
        Fake, addr = self._reader()
        cells = {}
        self._bank(cells, 4, addr["scr_cols"], [51])
        self._bank(cells, 6, addr["mode80"], [0])
        self._bank(cells, 6, addr["stl_on"], [0])
        self._bank(cells, 6, addr["char_buffer"], b"X" * 51 * 24)
        r = Fake(cells, addr)
        self.assertIsNone(r.status_line())
        self.assertEqual(len(r.screen()), 24)

    def test_bank_offset_masking(self):
        """The MCP takes an offset within a 16K bank, not an absolute address."""
        runner = source("tools/zx84_realworld.py")
        self.assertIn("addr & 0x3FFF", runner)


if __name__ == "__main__":
    unittest.main()
