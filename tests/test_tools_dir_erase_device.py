"""DIR.COM, ERASE.COM and DEVICE.COM: the CP/M 3 transients behind the CCP.

The CCP's built-in DIR, ERASE and RENAME load the related program when an
option list follows (User's Guide, Table 4-1); DEVICE is a transient on its
own.  These are source-level checks, the emulator runs are in the smoke test.
"""

from __future__ import annotations

import re
import unittest

from .layout import source


def opt_table() -> dict[str, int]:
    text = source("src/tools/dir.asm")
    body = text[text.index("opt_table:"):text.index("word:           ds")]
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r'db "([A-Z]+)", 0, (\d+)', body)}


class DirOptions(unittest.TestCase):
    # Table 5-5 of the User's Guide.
    MANUAL = {"ATT", "DATE", "DIR", "DRIVE", "DISK", "EXCLUDE", "FF", "FULL",
              "LENGTH", "MESSAGE", "NOPAGE", "NOSORT", "RO", "RW", "SIZE",
              "SYS", "USER"}

    def test_every_documented_option_is_in_the_table(self):
        self.assertEqual(set(opt_table()), self.MANUAL)

    def test_drive_and_disk_are_one_option(self):
        table = opt_table()
        self.assertEqual(table["DRIVE"], table["DISK"])
        self.assertEqual(len(set(table.values())), len(table) - 1)

    def test_flag_options_index_the_flag_bytes(self):
        """Ids 0-12 are the simple options; each owns one flag byte."""
        text = source("src/tools/dir.asm")
        flags = text[text.index("opt_flags:"):text.index("; Option names")]
        names = re.findall(r"^(o_[a-z]+):\s+db 0", flags, re.M)
        table = opt_table()
        simple = sorted((i, n) for n, i in table.items() if i < 13)
        self.assertEqual(len(names), len(simple))
        for (ident, name), flag in zip(simple, names):
            self.assertEqual(flag, "o_" + name.lower().replace("exclude", "excl")
                             .replace("message", "msg"), (ident, name))

    def test_valued_options_follow_the_flags(self):
        table = opt_table()
        self.assertEqual((table["DRIVE"], table["USER"], table["LENGTH"]),
                         (13, 14, 15))

    def test_attribute_bits_are_in_the_type_bytes(self):
        """R/O is bit 7 of the first type byte, SYS of the second."""
        text = source("src/tools/dir.asm")
        body = text[text.index("pass_attrs:"):text.index("; Sorting")]
        self.assertIn("ld de, 8", body)         # name offset 8 = type byte 1
        printed = text[text.index("print_attrs:"):text.index("; size_cells")]
        self.assertIn("ld de, 9", printed)       # SYS
        self.assertIn("ld de, 8", printed)       # R/O

    def test_records_use_the_extent_mask(self):
        """(EX & EXM) * 128 + RC: the records one directory entry holds."""
        text = source("src/tools/dir.asm")
        body = text[text.index("handle_entry:"):text.index("rec_addr:")]
        self.assertIn("EX & EXM", body)
        self.assertEqual(body.count("add hl, hl"), 7 + 0)   # * 128

    def test_block_numbers_are_sixteen_bit_above_dsm_255(self):
        text = source("src/tools/dir.asm")
        body = text[text.index("count_blocks:"):text.index("name_selected:")]
        self.assertIn("ld b, 16", body)
        self.assertIn("ld b, 8", body)

    def test_the_length_option_needs_five_or_more(self):
        text = source("src/tools/dir.asm")
        self.assertRegex(text, r"cp 5\s+jr c, \.bad")

    def test_the_stamp_message_is_the_manual_s(self):
        text = source("src/tools/dir.asm")
        self.assertIn("Date and Time Stamping Inactive", text)

    def test_the_directory_is_read_once_and_no_user_is_switched(self):
        """'?' in the drive byte lists every user; F32 is only ever a get."""
        text = source("src/tools/dir.asm")
        scan = text[text.index("scan_dir:"):text.index("; make_scan_fcb")]
        self.assertIn("ld (scanfcb), a", scan)
        self.assertIn("ld a, '?'", scan)
        self.assertEqual(text.count("ld c, F_USER"), 1)
        start = text[text.index("start:"):text.index("; restore")]
        self.assertIn("ld e, 0xFF", start)       # F32 with E=FF: get

    def test_a_single_option_list_is_enforced(self):
        text = source("src/tools/dir.asm")
        self.assertIn("opts_seen", text)

    def test_size_mode_prints_the_summary_even_with_no_matches(self):
        """A drive with nothing matching still reports its space usage.

        The listing formats print "No File" and nothing else, which is right
        for a listing.  With [SIZE] the user asked for the space report, so
        an empty selection must still reach print_group and its totals.
        """
        text = source("src/tools/dir.asm")
        drive = text[text.index("process_drive:"):text.index("; process_user")]
        # The empty-selection summary is emitted once per drive...
        self.assertIn("ld a, (o_size)", drive)
        self.assertIn("ld a, (grp_done)", drive)
        self.assertIn("jp print_group", drive)
        # ...so an empty per-user area must NOT print one of its own, or
        # USER=ALL would emit a block for each of the 16 user areas.
        user = text[text.index("process_user:"):
                    text.index("; scan_dir - every directory entry")]
        self.assertNotIn("jp print_group\n.have", user)
        self.assertEqual(user.count("jp print_group"), 1,
                         "process_user should reach print_group only when "
                         "there are files")

    def test_the_empty_summary_names_a_selected_user(self):
        """The report is attributed to a user area the selection covers."""
        text = source("src/tools/dir.asm")
        drive = text[text.index("process_drive:"):text.index("; process_user")]
        self.assertIn("user_mask", drive)
        self.assertIn("call test_bit", drive)
        self.assertIn("ld (nfiles), hl", drive)

    def test_one_summary_per_drive_with_user_all(self):
        """USER=ALL must not print a summary block per empty user area.

        There are 16 user areas.  Emitting the report from process_user
        would give 16 blocks of zeroes for an empty drive; the drive loop
        guards on grp_done so only the first is printed.
        """
        text = source("src/tools/dir.asm")
        drive = text[text.index("process_drive:"):text.index("; process_user")]
        # The guard must be consulted before printing.
        guard = drive.index("ld a, (grp_done)")
        print_at = drive.index("jp print_group")
        self.assertLess(guard, print_at)
        self.assertIn("ret nz", drive[guard:print_at])
        # And print_group records that it ran.
        group = text[text.index("print_group:"):text.index("; print_heading")]
        self.assertIn("ld (grp_done), a", group)
        # Reset per drive so drive B: can report too.
        self.assertIn("ld (grp_done), a", drive)

    def test_no_file_is_not_printed_over_a_size_summary(self):
        """One report, not two: the summary already said there were none."""
        text = source("src/tools/dir.asm")
        self.assertIn("grp_done", text)
        start = text[text.index("call run_groups"):text.index("; restore")]
        # A summary having been printed suppresses the "No File" line.
        self.assertIn("ld a, (grp_done)", start)
        self.assertIn("jr nz, .done", start)
        self.assertLess(start.index("grp_done"), start.index("msg_no_file"))
        # ...and it is cleared per drive so it cannot leak between them.
        drive = text[text.index("process_drive:"):text.index("; process_user")]
        self.assertIn("ld (grp_done), a", drive)

    def test_summary_columns_line_up(self):
        """Both '=' signs in the two summary lines share a column.

        The value fields are five wide, so the labels before them have to
        be padded to the same length on each line.
        """
        text = source("src/tools/dir.asm")

        def literal(name):
            start = text.index(name)
            line = text[start:text.index("\n", start)]
            return line[line.index('"') + 1:line.index('$')]

        first_label = literal("msg_tot1:")      # "Total Bytes = "
        records_label = literal("msg_tot2:")    # "K  Total Records   = "
        files_label = literal("msg_tot3:")      # "Files Found = "
        blocks_label = literal("msg_tot4:")     # "   Total 1K Blocks = "

        # Line 1: label + 5-column value + K + 2 + label, then a 5-wide value.
        line1_eq1 = first_label.index("=")
        line2_eq1 = files_label.index("=")
        self.assertEqual(line1_eq1, line2_eq1,
                         f"{first_label!r} vs {files_label!r}")

        # Render both lines exactly as print_totals does and compare the
        # column of each '='.  msg_tot2 starts with the "K" of the value
        # that precedes it, so it must not be counted twice.
        rendered1 = (first_label + f"{182:5d}" + records_label + f"{1131:5d}")
        rendered2 = (files_label + f"{33:5d}" + blocks_label + f"{161:5d}")

        self.assertEqual(rendered1.index("="), rendered2.index("="),
                         f"{rendered1!r} vs {rendered2!r}")
        self.assertEqual(rendered1.index("=", 20),
                         rendered2.index("=", 20),
                         f"{rendered1!r} vs {rendered2!r}")
        # Pin the actual columns so a change has to be deliberate.
        self.assertEqual(rendered1.index("="), 12)
        self.assertEqual(rendered1.index("=", 20), 38)

        # No padding is left between a label and its '='.
        for label in (first_label, files_label, blocks_label):
            self.assertTrue(label.endswith(" = "), repr(label))
        self.assertTrue(records_label.endswith(" = "), repr(records_label))


class Erase(unittest.TestCase):
    def test_confirm_is_the_only_option_and_c_abbreviates_it(self):
        text = source("src/tools/erase.asm")
        self.assertIn('str_confirm:    db "CONFIRM", 0', text)
        # A prefix of CONFIRM is accepted; a longer or different word is not.
        body = text[text.index("parse_options:"):text.index("; parse_spec")]
        self.assertIn("scf                        ; some other word", body)

    def test_matches_are_collected_before_the_first_delete(self):
        text = source("src/tools/erase.asm")
        self.assertIn("a delete disturbs", text)
        body = text[text.index("per_file:"):text.index("; Option list")]
        self.assertLess(body.index("call add_unique"),
                        body.index("ld c, F_DELETE"))

    def test_without_confirm_a_wildcard_asks_once(self):
        text = source("src/tools/erase.asm")
        self.assertIn('msg_erase:      db "ERASE $"', text)
        self.assertIn('msg_yn:         db " (Y/N)?$"', text)
        self.assertIn('msg_no_file:    db "No File"', text)


class CcpAliases(unittest.TestCase):
    """ERA and REN load ERASE.COM and RENAME.COM, not programs of their own name."""

    def test_era_with_options_loads_erase_com(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn(".opt_era:\n    ld hl, str_erase_com\n    jp .do_load_com",
                      text)
        self.assertIn('str_erase_com:\n    db "ERASE", 0', text)

    def test_ren_with_options_loads_rename_com(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn(".opt_ren:\n    ld hl, str_rename_com\n    jp .do_load_com",
                      text)
        self.assertIn('str_rename_com:\n    db "RENAME", 0', text)


class DirsysOptions(unittest.TestCase):
    """DIRSYS [options] runs DIR.COM with SYS put first in the option list."""

    def test_dirsys_with_options_loads_dir_com(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".do_dirsys:"):text.index(".dirsys_plain:")]
        self.assertIn("call insert_text", body)
        self.assertIn("ld hl, str_dir_com", body)
        self.assertIn("jp .do_load_com", body)
        self.assertIn('str_dir_com:\n    db "DIR", 0', text)

    def test_the_inserted_option_is_sys(self):
        text = source("src/ccp/miniccp.zpa")
        self.assertIn('str_sys_opt:\n    db "SYS "', text)
        body = text[text.index(".do_dirsys:"):text.index(".dirsys_plain:")]
        self.assertIn("ld c, 4", body)
        self.assertIn("ld de, str_sys_opt", body)

    def test_a_full_line_is_refused(self):
        text = source("src/ccp/miniccp.zpa")
        body = text[text.index(".do_dirsys:"):text.index(".dirsys_plain:")]
        self.assertIn("jp c, .com_unknown", body)


class Device(unittest.TestCase):
    def logical(self) -> dict[str, str]:
        text = source("src/tools/device.asm")
        body = text[text.index("log_table:"):text.index("baud_table:")]
        return {m.group(1): m.group(2).strip()
                for m in re.finditer(r'db "([A-Z]+)", 0, (.+)', body)}

    def test_every_logical_name_of_the_manual_is_known(self):
        names = set(self.logical())
        self.assertGreaterEqual(
            names, {"CONIN", "CONOUT", "AUXIN", "AUXOUT", "LST", "CON",
                    "CONSOLE", "KEYBOARD", "AUX", "AUXILIARY", "PRINTER"})

    def test_the_combined_names_cover_both_directions(self):
        table = self.logical()
        self.assertEqual(table["CON"], "L_CONIN | L_CONOUT")
        self.assertEqual(table["CONSOLE"], "L_CONIN | L_CONOUT")
        self.assertEqual(table["AUX"], "L_AUXIN | L_AUXOUT")
        self.assertEqual(table["AUXILIARY"], "L_AUXIN | L_AUXOUT")
        self.assertEqual(table["KEYBOARD"], "L_CONIN")
        self.assertEqual(table["PRINTER"], "L_LST")

    def test_logical_bits_are_the_scb_vector_order(self):
        """CIVEC, COVEC, AIVEC, AOVEC, LOVEC are consecutive SCB words."""
        text = source("src/tools/device.asm")
        self.assertIn("SCB_CIVEC       equ 0x22", text)
        for name, bit in (("L_CONIN", "0x01"), ("L_CONOUT", "0x02"),
                          ("L_AUXIN", "0x04"), ("L_AUXOUT", "0x08"),
                          ("L_LST", "0x10")):
            self.assertRegex(text, rf"{name}\s+equ {bit}")
        bios = source("src/bios/common.zpa")
        order = [bios.index(f"scb_{v}:") for v in
                 ("civec", "covec", "aivec", "aovec", "lovec")]
        self.assertEqual(order, sorted(order))

    def test_the_device_table_modes_match_the_bios(self):
        """DEVICE reads the mode bits the BIOS table defines."""
        text = source("src/tools/device.asm")
        bios = source("src/bios/common.zpa")
        self.assertIn("MODE_IN         equ 0x01", text)
        self.assertIn("MODE_OUT        equ 0x02", text)
        self.assertIn("MODE_SERIAL     equ 0x08", text)
        self.assertIn("MODE_XON        equ 0x10", text)
        modes = bios[bios.index("; Mode bits:"):bios.index("char_dev_table:")]
        self.assertIn("0x01 input, 0x02 output", modes)
        self.assertIn("0x08 serial", modes)
        self.assertIn("0x10 XON/XOFF", modes)

    def test_vector_bit_15_is_entry_zero(self):
        text = source("src/tools/device.asm")
        self.assertIn("ld hl, 0x8000", text)

    def test_the_console_is_not_redirectable(self):
        """Only CON may feed CONIN:/CONOUT: because the BIOS ignores those."""
        text = source("src/tools/device.asm")
        self.assertIn("jp nz, err_console", text)
        self.assertIn("CONIN: and CONOUT: can only be assigned to CON", text)

    def test_baud_codes_are_the_manual_rates(self):
        text = source("src/tools/device.asm")
        rates = re.search(r"baud_table:\s+dw ([^\n]+)\n\s+dw ([^\n]+)", text)
        values = [int(v) for v in
                  (rates.group(1) + "," + rates.group(2)).split(",")]
        self.assertEqual(values, [0, 50, 75, 110, 134, 150, 300, 600, 1200,
                                  1800, 2400, 3600, 4800, 7200, 9600, 19200])

    def test_bios_function_numbers(self):
        text = source("src/tools/device.asm")
        self.assertIn("pb_devtbl:      db 20,", text)       # DEVTBL
        self.assertIn("pb_screen:      db 32,", text)       # SCRMODE


class Pager(unittest.TestCase):
    def test_unpaged_output_keeps_the_page_counter_at_zero(self):
        """Lines printed with paging off must not make the next line pause."""
        text = source("src/bdos/bdos.zpa")
        body = text[text.index("bdos_con_out:"):text.index("bdos_page_pause:")]
        self.assertIn("jr z, .unpaged", body)
        unpaged = body[body.index(".unpaged:"):body.index(".tick:")]
        self.assertIn("ld (bdos_page_row), a", unpaged)


if __name__ == "__main__":
    unittest.main()
