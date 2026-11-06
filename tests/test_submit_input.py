"""Submit-file program input: the '<' lines that follow a command.

CP/M Plus passes them to the running program as console input - the feature
CP/M 2.2 needed XSUB.COM for, and how Amstrad's PROFILE.SUB feeds PIP.  The
CCP collects them while it still owns $$$.SUB, queues the text through BDOS
F124 (a private helper) and con_in/con_status serve the queue while the
program runs.  tools/zx84_smoke.py proves it end to end with INPTEST.
"""

from __future__ import annotations

import unittest

from .layout import source


class ConsoleRedirect(unittest.TestCase):
    def test_console_serves_the_queue_first(self):
        text = source("src/bios/bios.zpa")
        body = text[text.index("con_status:"):text.index("con_out:")]
        self.assertIn("subin_active", body)
        self.assertIn("subin_reset", body)
        self.assertIn("kbd_status", body)      # falls back to the keyboard
        self.assertIn("kbd_getchar", body)

    def test_buffer_sits_below_the_staged_ccp(self):
        text = source("src/bios/bios.zpa")
        self.assertIn("SUBIN_BUF       equ 0xADA4", text)
        self.assertIn("SUBIN_SIZE      equ 0x200", text)

    def test_paging_never_eats_program_input(self):
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bdos_con_out:"):text.index("bdos_page_pause:")]
        self.assertIn("(subin_active)", body)


class AppendHelper(unittest.TestCase):
    def test_f124_is_dispatched(self):
        text = source("src/bdos/bdos.zpa")
        self.assertIn("jp z, bf_f124", text)
        self.assertIn("bf_f124:", text)

    def test_f124_appends_text_and_cr(self):
        text = source("src/bdos/bdos.zpa")
        start = text.index("bf_f124:")
        body = text[start:text.index("; F49: Get/Set System Control Block",
                                     start)]
        self.assertIn("copy_from_user", body)
        self.assertIn("ld (hl), 0x0D", body)    # the line's CR
        self.assertIn("subin_active", body)
        self.assertIn("subin_reset", body)      # DE = 0 clears the queue


class CcpCollects(unittest.TestCase):
    def test_collects_only_marker_lines(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn("F_SUBIN equ 124", text)
        start = text.index(".collect:")
        body = text[start:text.index(".collect_next:", start)]
        self.assertIn("cp '<'", body)
        self.assertIn("ld c, F_SUBIN", body)

    def test_prompt_drops_unread_input(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".prompt:"):text.index("call try_sub", 1)]
        self.assertIn("ld c, F_SUBIN", body)


if __name__ == "__main__":
    unittest.main()
