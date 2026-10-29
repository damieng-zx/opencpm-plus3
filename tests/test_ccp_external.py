"""The CCP is a file (CCP.COM), not part of CPM3.SYS.

The BIOS reads CCP.COM from the boot disk during cold boot and stages it in
the top of bank 6; warm boot copies the staged image into the TPA without
touching the disk.  These checks guard the wiring.  The staged bytes are
verified at run time by tools/zx84_smoke.py.
"""

from __future__ import annotations

import unittest

from .layout import ROOT, dsk_directory, source


class ImageSplit(unittest.TestCase):
    def test_bios_no_longer_embeds_the_ccp(self):
        text = source("src/bios/bios.zpa")
        self.assertNotIn('incbin "miniccp.bin"', text)
        self.assertNotIn("ccp_stored", text)
        self.assertIn("CCP_STAGE   equ 0xB000", text)
        self.assertIn("CCP_MAX_BLK equ 4", text)

    def test_staging_window_stays_inside_bank6(self):
        text = source("src/bios/bios.zpa")
        self.assertIn("assert CCP_STAGE + CCP_MAX_BLK * 1024 <= 0xC000", text)
        self.assertIn("assert CCP_STAGE >= 0xB000", text)

    def test_warm_boot_copies_the_staged_image(self):
        text = source("src/bios/bios.zpa")
        body = text[text.index("warm_boot:"):text.index("; Console I/O")]
        self.assertIn("ld hl, CCP_STAGE", body)
        self.assertIn("ld bc, (_ccp_len)", body)
        self.assertIn("call copy_block_to_tpa", body)

    def test_cold_boot_loads_the_ccp_and_reports_a_missing_one(self):
        text = source("src/bios/bios.zpa")
        body = text[text.index("cold_boot:"):text.index("warm_boot:")]
        self.assertIn("call load_ccp", body)
        self.assertIn("MSG_NO_CCP", body)
        self.assertIn('db "CCP.COM missing', text)

    def test_build_scripts_ship_ccp_com(self):
        cmd = source("build.cmd")
        self.assertIn("--raw=build\\CCP.COM", cmd)
        self.assertIn("build\\CCP.COM", cmd.split("mkdsk.py", 1)[1])
        sh = source("build.sh")
        self.assertIn("--raw=build/CCP.COM", sh)
        self.assertIn("build/CCP.COM", sh.split("mkdsk.py", 1)[1])


class DirectoryScan(unittest.TestCase):
    def test_scan_recognises_ccp_and_finishes(self):
        text = source("src/bios/bios.zpa")
        self.assertIn('_lf_name_ccp: db "CCP     COM"', text)
        self.assertIn("cp 31", text)      # font51, font32, font64, CCP and FID
        body = text[text.index(".lf_try_ccp:"):text.index(".lf_try_fid:")]
        self.assertIn("ld de, _ccp_al", body)
        self.assertIn("ld bc, 16", body)
        self.assertIn("ldir", body)

    def test_load_ccp_stages_blocks_and_records_length(self):
        text = source("src/bios/bios.zpa")
        body = text[text.index("load_ccp:"):text.index("_lf_load_block:")]
        self.assertIn("ld de, CCP_STAGE", body)
        self.assertIn("ld b, CCP_MAX_BLK", body)
        self.assertIn("call _lf_load_n", body)
        self.assertIn("ld (_ccp_len), hl", body)


class BuiltImage(unittest.TestCase):
    def test_ccp_fits_the_staging_window(self):
        ccp = ROOT / "build" / "CCP.COM"
        if not ccp.exists():
            self.skipTest("build/CCP.COM is missing (run build.cmd)")
        self.assertLessEqual(ccp.stat().st_size, 4 * 1024)

    def test_disk_carries_ccp_com(self):
        if not (ROOT / "build" / "cpm3.dsk").exists():
            self.skipTest("build/cpm3.dsk is missing (run build.cmd)")
        names = {entry[1:12] for entry in dsk_directory() if entry[0] != 0xE5}
        self.assertIn(b"CCP     COM", names)

    def test_cpm3_sys_leaves_the_ccp_out(self):
        bios = ROOT / "build" / "CPM3.SYS"
        ccp = ROOT / "build" / "CCP.COM"
        if not bios.exists() or not ccp.exists():
            self.skipTest("building the image is required")
        self.assertNotIn(ccp.read_bytes(), bios.read_bytes())
        # The CCP used to be almost 3K of the image.  The hard limit is the
        # 16K bank-4 window (check_layout.py enforces the system image);
        # embedding the CCP again would push the whole file past 16K.
        self.assertLess(bios.stat().st_size, 16 * 1024)


class CheckTool(unittest.TestCase):
    def test_check_ccp_reads_the_equates(self):
        tool = source("tools/check_ccp.py")
        self.assertIn('const(text, "CCP_STAGE")', tool)
        self.assertIn('const(text, "CCP_MAX_BLK")', tool)


if __name__ == "__main__":
    unittest.main()
