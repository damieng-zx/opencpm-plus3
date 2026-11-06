"""PROFILE.SUB is submitted once, on the first (cold) start.

CP/M 3 runs PROFILE.SUB from the boot drive before the first prompt.  Our CCP
is reloaded from the bank-6 staging area on every warm boot, so the "cold"
state has to live outside it: the SCB has a byte (0x0A) that a cold boot
reinitialises and the CCP clears when it fires the profile.  These checks
guard the wiring; tools/zx84_smoke.py proves the behaviour on the emulator.
"""

from __future__ import annotations

import unittest

from .layout import source


class ColdBootFlag(unittest.TestCase):
    def test_scb_has_the_flag(self):
        text = source("src/bios/common.zpa")
        block = text[text.index("scb_base:"):text.index("assert $ - scb_base")]
        self.assertIn("scb_coldboot:", block)
        self.assertIn("db 1", block)
        # 0x0A, immediately after the F108 return code.
        self.assertIn("scb_coldboot == 0xF60A", text)

    def test_ccp_addresses_match(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("CCP_COLD_ADDR  equ 0xF60A", text)


class ProfileSubmit(unittest.TestCase):
    def test_ccp_checks_the_flag_at_start(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index("ccp_start:"):text.index("print_prompt:")]
        self.assertIn("(CCP_COLD_ADDR)", body)
        self.assertIn("call profile_cmd", body)
        self.assertIn("jp c, .got_line", body)
        # Cleared so a warm boot does not run it again.
        self.assertIn("ld (CCP_COLD_ADDR), a", body)

    def test_profile_cmd_submits_the_file(self):
        text = source("src/ccp/miniccp.zpa")
        start = text.index("profile_cmd:")
        end = text.index("; =========================================================================",
                         start)
        body = text[start:end]
        self.assertIn("F17", body)                 # Search First
        self.assertIn("PROFILE_CMD_LEN + 1", body)  # text plus NUL
        self.assertIn("db 'SUBMIT PROFILE.SUB'", text)
        self.assertIn("db 'PROFILE '", text)
        self.assertIn("db 'SUB'", text)

    def test_stock_profile_is_not_shipped(self):
        """It works, but would copy ~10K into C: at every cold boot."""
        self.assertIn('"PROFILE.SUB"', source("build.cmd"))
        self.assertIn("*/PROFILE.SUB", source("build.sh"))


if __name__ == "__main__":
    unittest.main()
