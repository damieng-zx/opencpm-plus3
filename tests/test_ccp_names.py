"""CP/M 3 built-in command names, DIR/DIRSYS and the unknown-command echo.

Table 4-1 of the CP/M 3 User's Guide lists DIR, DIRSYS, ERASE, RENAME, TYPE
and USER with the short forms DIRS, ERA, REN, TYP and USE.  DIR lists the
files without the SYS attribute and DIRSYS those with it.
"""

from __future__ import annotations

import unittest

from .layout import source

NAMES = ["DIR", "DIRSYS", "DIRS", "ERASE", "ERA", "RENAME", "REN",
         "TYPE", "TYP", "USER", "USE", "HELP"]


def table_text() -> str:
    text = source("src/ccp/miniccp.zpa")
    return text[text.index(".cmd_table:"):text.index(".opt_com:")]


class Table(unittest.TestCase):
    def test_every_documented_name_and_abbreviation_is_present(self):
        table = table_text()
        for name in NAMES:
            self.assertIn(f'db "{name}", 0', table, name)

    def test_table_ends_with_a_zero_byte(self):
        code = [ln.strip() for ln in table_text().splitlines()
                if ln.strip() and not ln.strip().startswith(";")]
        self.assertEqual(code[-1], "db 0")

    def test_a_word_that_is_not_in_the_table_loads_a_program(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".check_builtins:"):text.index(".cmd_table:")]
        self.assertIn("jp z, .do_load_com", body)

    def test_unknown_command_repeats_its_name_with_a_question_mark(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".com_unknown:"):text.index("; skip_arg")]
        self.assertIn("call print_word", body)
        self.assertIn("ld de, msg_unknown", body)


class Dir(unittest.TestCase):
    def body(self) -> str:
        text = source("src/ccp/miniccp.zpa")
        return text[text.index(".do_dirsys:"):text.index(".do_type:")]

    def test_dirsys_selects_the_sys_files(self):
        body = self.body()
        self.assertIn("ld a, 0x80", body)
        self.assertIn("ld (dir_mode), a", body)

    def test_the_sys_bit_decides_what_is_listed(self):
        body = self.body()
        self.assertIn("ld de, 10", body)              # second type byte
        self.assertIn("and 0x80", body)
        self.assertIn("xor e", body)
        self.assertIn("ld (dir_other), a", body)

    def test_messages_follow_the_manual(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('db "SYSTEM FILE(S) EXIST"', text)
        self.assertIn('db "NON-SYSTEM FILE(S) EXIST"', text)
        self.assertIn('db "No File"', text)

    def test_a_bare_name_is_not_widened_to_any_type(self):
        # DIR FOO matches FOO with a blank type only (User's Guide 5.1).
        self.assertNotIn("matches FOO.*", self.body())
        self.assertNotIn("dir_fcb + 9", self.body())

    def test_option_list_loads_the_transient(self):
        body = self.body()
        self.assertIn("call find_opt", body)
        self.assertIn("jp c, .opt_com", body)


class Chain(unittest.TestCase):
    """cmd1!cmd2: the CCP hands the rest of the line to BDOS F125."""

    def test_parse_cmd_cuts_the_line_at_the_bang(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index("parse_cmd:\n"):text.index(".check_builtins:")]
        self.assertIn("cp '!'", body)
        self.assertIn("ld c, F_PEND", body)
        self.assertIn("ld (cmd_buf + 1), a", body)   # the shorter length

    def test_the_prompt_runs_the_pending_text_first(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".prompt:"):text.index(".read_console:")]
        self.assertIn("ld c, F_PEND", body)
        self.assertLess(body.index("F_PEND"), body.index("call try_sub"))
        self.assertIn("call echo_sub_line", body)

    def test_bdos_keeps_the_text_across_the_warm_boot(self):
        bdos = source("src/bdos/bdos.zpa")
        self.assertIn("jp z, bf_f125", bdos)
        body = bdos[bdos.index("bf_f125:"):bdos.index("PEND_MAX equ")]
        self.assertIn("call copy_from_user", body)
        self.assertIn("call copy_to_user", body)
        self.assertIn("ld (pend_len), a", body)


class Type(unittest.TestCase):
    def test_type_asks_for_a_name_and_handles_no_page(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".do_type:"):text.index(".do_help:")]
        self.assertIn("call get_arg", body)
        self.assertIn("res 0, l", body)               # CON_MODE_PAGE off
        self.assertIn("cp 'N'", body)


if __name__ == "__main__":
    unittest.main()
