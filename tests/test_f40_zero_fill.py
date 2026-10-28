"""F40 (Write Random with Zero Fill) must zero a newly allocated block.

CP/M 3 Programmer's Guide, function 40: "a previously unallocated data
block is filled with zeros before the record is written", so an all-zero
record marks an unwritten random record.  F34 deliberately does not do
this, which is why the test checks both functions.
"""

from __future__ import annotations

import unittest

from .layout import source


class ZeroFillWiring(unittest.TestCase):
    def test_f40_requests_the_fill_before_the_shared_core(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f40:"):text.index("; @proc div_hl_bc")]
        self.assertIn("ld (f40_zfill), a", body)
        self.assertLess(body.index("ld (f40_zfill), a"),
                        body.index("jp bf_f21_core"))

    def test_shared_core_consumes_the_request_once(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bf_f21_core:"):text.index(".wseq_do:")]
        self.assertIn("ld a, (f40_zfill)", body)
        self.assertIn("ld (f40_pending), a", body)
        # The one-shot flag is cleared on entry, so a request left by a
        # failed F40 cannot leak into a later F21/F34 write.
        cleared = body[body.index("ld (f40_pending), a"):]
        self.assertIn("ld (f40_zfill), a", cleared)

    def test_allocation_fills_then_keeps_the_block_number(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index(".wseq_alloc:"):text.index(".wseq_full:")]
        self.assertIn("ld a, (f40_pending)", body)
        self.assertIn("call zero_fill_block", body)
        # bf_f21_core's continued path expects A = block number.
        tail = body[body.index("call zero_fill_block"):]
        self.assertIn(".wseq_alloc_nofill:", tail)
        self.assertIn("ld a, (hl)", tail)
        self.assertIn("jp .wseq_have_block", tail)
        self.assertLess(tail.index("ld a, (hl)"),
                        tail.index("jp .wseq_have_block"))

    def test_zero_fill_block_covers_the_whole_block(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("zero_fill_block:"):text.index("; F22: Make File")]
        self.assertIn("ld hl, f40_zero", body)      # zero source in common
        self.assertIn("ld b, 128", body)            # one full record
        self.assertIn("cached_blm", body)           # records per block
        self.assertIn("ld (f40_left), a", body)
        for call in ("set_trk", "set_sec", "set_dma", "disk_write"):
            self.assertIn(f"call {call}", body)
        self.assertIn("ret nz", body)               # BIOS error propagates

    def test_zero_buffer_lives_above_the_bdos_stack(self):
        text = source("src/bios/common.zpa")
        self.assertIn("f40_zero equ bdos_stack", text)
        self.assertIn("f40_zero + 128 <= 0x10000", text)
        # It must not be assembled over the stack area (a ds before the
        # equ would place it at bdos_stack_base and let the fill wipe the
        # live BDOS stack).
        self.assertNotIn("f40_zero:   ds 128", text)


class DisktestCoverage(unittest.TestCase):
    def test_t22_checks_the_gap_the_reuse_and_f34(self):
        text = source("src/test/disktest.asm")
        body = text[text.index("test22:"):text.index("t22_new:")]
        self.assertIn("ld c, 40", body)             # write random zero fill
        self.assertIn("call t22_all_zero", body)    # gap records read empty
        self.assertIn("ld c, 34", body)             # plain write random
        self.assertIn("cp 0xAA", body)              # F34 leaves stale data
        self.assertIn("0xAA", body)                 # stale pattern source


if __name__ == "__main__":
    unittest.main()
