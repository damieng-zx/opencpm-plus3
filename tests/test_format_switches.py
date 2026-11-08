"""FORMAT.COM's command-line switches.

`/Q` skips the read-back, which is the expensive half of a format.  These
are structural checks on the wiring; the behaviour is exercised at run time
by tools/zx84_smoke.py, which formats a disc with /Q and requires the
progress line to have no VERIFY phase.
"""

from __future__ import annotations

import unittest

from .layout import source


class FormatQuietSwitch(unittest.TestCase):
    def setUp(self):
        self.text = source("src/tools/format.asm")

    def _parser(self) -> str:
        return self.text[self.text.index("parse_quiet:"):
                         self.text.index("; USERF trampoline")]

    def test_parser_recognises_q(self):
        parser = self._parser()
        self.assertIn("cp 'Q'", parser)
        self.assertIn("ld (quiet), a", parser)

    def test_parser_rejects_anything_else(self):
        """A junk switch must reach `usage`, not start a format.

        The old tail_end_ok returned Z for a zero byte, so `or a` on the
        junk path would have accepted e.g. "A:/" as a valid tail.
        """
        parser = self._parser()
        junk = parser[parser.index(".q_junk:"):]
        self.assertIn("dec a", junk,
                      "the junk exit must clear Z, not set it")
        self.assertNotIn("xor a\n    ret", junk)

    def test_quiet_skips_verify_track(self):
        loop = self.text[self.text.index("track_loop:"):
                         self.text.index("; ---- Give the blank disc a disc spec")]
        self.assertIn("ld a, (quiet)", loop)
        self.assertIn("jr nz, .track_done", loop)
        skip = loop[loop.index("ld a, (quiet)"):loop.index(".track_done:")]
        self.assertIn("verify_track", skip)

    def test_summary_says_when_it_was_not_verified(self):
        self.assertIn("msg_unverified:", self.text)
        summary = self.text[self.text.index("ld de, msg_done"):
                            self.text.index("; ==============", 
                                            self.text.index("ld de, msg_done"))]
        self.assertIn("ld a, (quiet)", summary)
        self.assertIn("ld de, msg_unverified", summary)
        self.assertIn("ld de, msg_verified", summary)

    def test_usage_documents_the_switch(self):
        self.assertIn('db "FORMAT A: /Q"', self.text)
        self.assertIn("/Q formats without verifying", self.text)

    def test_drive_letter_is_still_required(self):
        """The switch must not be accepted in place of a drive."""
        start = self.text[self.text.index("start:"):self.text.index(".tail_end:")]
        self.assertIn("cp 'A'", start)
        self.assertIn("jp c, usage", start)


class FormatBootableIsSysgensJob(unittest.TestCase):
    """FORMAT has no /S: SYSGEN already installs the system.

    Duplicating it here would cost ~2K in the TPA-side tool, and chaining to
    SYSGEN.COM would depend on a file that need not be on the disc.
    """

    def test_no_sysgen_copy_in_format(self):
        """No boot-track code: that is SYSGEN's job, not a FORMAT switch."""
        text = source("src/tools/format.asm")
        for needle in ("DD_READ_SECTOR", "CPM3.SYS", "CPM3C.SYS"):
            self.assertNotIn(needle, text)

    def test_readme_points_at_sysgen(self):
        readme = source("README.md")
        self.assertIn("Making the result bootable is `SYSGEN B:`", readme)


if __name__ == "__main__":
    unittest.main()
