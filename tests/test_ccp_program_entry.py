"""Transient-program entry conventions: COM header, FCB write-back width."""

from __future__ import annotations

import unittest

from .layout import ROOT, labels, source


class ComHeaderLoader(unittest.TestCase):
    def test_ccp_constant_matches_the_common_helper(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("CCP_RUN_PROG", text)
        # The CCP is assembled before the BIOS, so the address is a constant
        # that common.zpa asserts against.  Check the built label agrees.
        lbl = labels().get("ccp_run_prog")
        if lbl is not None:
            self.assertEqual(lbl.addr, 0xFD0F)
        self.assertIn('assert ccp_run_prog == 0xFD0F', source("src/bios/common.zpa"))

    def test_helper_moves_the_module_down(self):
        body = source("src/bios/common.zpa")
        body = body[body.index("ccp_run_prog:"):]
        self.assertIn("cp 0xC9", body)          # RET marks a GENCOM header
        self.assertIn("ld hl, (0x0101)", body)  # comsize
        self.assertIn("ld hl, 0x0200", body)    # module start
        self.assertIn("ld de, 0x0100", body)    # destination
        self.assertIn("ldir", body)

    def test_entry_stack_pushes_warm_boot(self):
        body = source("src/bios/common.zpa")
        body = body[body.index("ccp_run_prog:"):]
        self.assertIn("push hl", body)
        self.assertIn("jp 0x0100", body)

    def test_stub_cannot_reach_the_interrupt_vector(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("overruns the IM 1 vector", text)
        self.assertIn('jp CCP_RUN_PROG', text)


class FcbWriteback(unittest.TestCase):
    def test_sequential_writeback_stops_at_byte_32(self):
        common = source("src/bios/common.zpa")
        body = common[common.index("writeback_fcb:"):]
        body = body[:body.index("ret")]
        self.assertIn("ld bc, 33", body)

    def test_random_record_calls_write_all_36(self):
        bdos = source("src/bdos/bdos.zpa")
        # F35 (file size) and F36 (set random record) publish R0/R1/R2.
        self.assertIn("writeback_fcb_rrr:", bdos)
        self.assertGreaterEqual(bdos.count("call writeback_fcb_rrr()"), 2)

    def test_rrr_helper_targets_the_user_fcb(self):
        bdos = source("src/bdos/bdos.zpa")
        body = bdos[bdos.index("writeback_fcb_rrr:"):]
        self.assertIn("ld de, (fcb_user_addr)", body)
        self.assertIn("call write_user_byte", body)
        self.assertIn("fcb_buf + 33", body)

    def test_docs_record_the_convention(self):
        api = source("docs/API.md")
        self.assertIn("SP** = 0xF5FE", api)
        self.assertIn("COM file header", api)
        tests = source("docs/third-party-tests.md")
        self.assertIn("FCB+21h", tests)
        self.assertTrue((ROOT / "tools" / "zx84_dri.py").exists())


if __name__ == "__main__":
    unittest.main()
