#!/usr/bin/env python3
"""Negative boot tests for the CP/M +3 image.

Creates corrupted copies of build/cpm3.dsk and checks that they do NOT
reach the CP/M prompt:

  missing    CPM3.SYS directory entry marked deleted
  truncated  CPM3.SYS allocation map starts with block 0
  badblock   CPM3.SYS points at a block past the end of the disk
  nosys2     CPM3C.SYS (common stub) directory entry marked deleted
  badsum     boot-sector checksum corrupted
  noccp      CCP.COM directory entry marked deleted (signon + diagnostic)
  emptyccp   CCP.COM allocation map empty (diagnostic, no prompt)
  shortccp   CCP.COM keeps only its first 1K block
  shortsys2  CPM3C.SYS keeps only its first 1K block
  badccpblock CCP.COM points at a block past the end of the disk
  badsys2block CPM3C.SYS points at a block past the end of the disk
  nofont32   FONT32.BIN deleted (boots, SCREEN 32 refused)
  nodisk     drive A ejected before disk_boot

The loader's expected failure mode is a red border/tight loop (or the ROM
refusing the boot sector).  The test only requires that no `A>`/signon
appears, so it stays valid if the failure message/colour changes.
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))

from zx84_smoke import (  # noqa: E402
    COLS, ROWS, MCP, SmokeError, bank_for_address, find_zx84, label_address)


SECTOR = 512
TRACK_TOTAL = 0x100 + 9 * SECTOR


def sector_offset(track: int, sector: int) -> int:
    return 0x100 + track * TRACK_TOTAL + 0x100 + sector * SECTOR


def entry_offset(entry: int) -> int:
    return sector_offset(1, entry // 16) + (entry % 16) * 32


def find_entry(data: bytearray, name: bytes) -> int:
    for i in range(64):
        off = entry_offset(i)
        if bytes(data[off + 1:off + 12]) == name:
            return off
    raise SmokeError(f"{name.decode()} directory entry not found")


def block_sector_offset(data: bytearray, block: int) -> int:
    """Disk byte offset of the first sector of a 1K CP/M block."""
    abs_sector = block * 2           # 1K block = 2 x 512-byte sectors
    track = abs_sector // 9 + 1      # OFF=1
    sector = abs_sector % 9
    return sector_offset(track, sector)


def make_images(src: Path, outdir: Path) -> dict[str, Path]:
    outdir.mkdir(parents=True, exist_ok=True)
    base = bytearray(src.read_bytes())

    def write(name: str, data: bytearray) -> Path:
        path = outdir / f"{name}.dsk"
        path.write_bytes(data)
        return path

    images: dict[str, Path] = {}

    missing = bytearray(base)
    missing[find_entry(missing, b"CPM3    SYS")] = 0xE5          # user byte -> deleted
    images["missing"] = write("missing", missing)

    truncated = bytearray(base)
    truncated[find_entry(truncated, b"CPM3    SYS") + 16] = 0     # first allocation block = 0
    images["truncated"] = write("truncated", truncated)

    badblock = bytearray(base)
    badblock[find_entry(badblock, b"CPM3    SYS") + 16] = 200     # > DSM 174
    images["badblock"] = write("badblock", badblock)

    # The common stub is a separate boot file; without it the loader must
    # stop rather than jump into an uninitialised common memory.
    nosys2 = bytearray(base)
    nosys2[find_entry(nosys2, b"CPM3C   SYS")] = 0xE5
    images["nosys2"] = write("nosys2", nosys2)

    badsum = bytearray(base)
    badsum[0x3FF] ^= 0xFF                    # boot-sector checksum byte
    images["badsum"] = write("badsum", badsum)

    # CCP.COM is loaded from the disk at cold boot; without it the system
    # must say so instead of jumping into a half-built TPA.
    noccp = bytearray(base)
    noccp[find_entry(noccp, b"CCP     COM")] = 0xE5   # mark deleted
    images["noccp"] = write("noccp", noccp)

    # Optional files: the loader must skip them and the system must still
    # boot.  FONT64 is gated on LF_FLAGS bit 4, so SCREEN 64 must be refused.
    nofont64 = bytearray(base)
    nofont64[find_entry(nofont64, b"FONT64  BIN")] = 0xE5
    images["nofont64"] = write("nofont64", nofont64)

    nofont51 = bytearray(base)
    nofont51[find_entry(nofont51, b"FONT51  BIN")] = 0xE5
    images["nofont51"] = write("nofont51", nofont51)

    nofid = bytearray(base)
    nofid[find_entry(nofid, b"RAMDISK FID")] = 0xE5
    images["nofid"] = write("nofid", nofid)

    # Corrupt the OCFID magic in the FID's first block: the loader stages
    # the bytes but load_fid must refuse to register C:.
    badfid = bytearray(base)
    off = find_entry(badfid, b"RAMDISK FID")
    badfid[block_sector_offset(badfid, badfid[off + 16])] ^= 0xFF
    images["badfid"] = write("badfid", badfid)

    # FONT32 is optional like FONT51/FONT64: without it the system boots but
    # SCREEN 32 must be refused.
    nofont32 = bytearray(base)
    nofont32[find_entry(nofont32, b"FONT32  BIN")] = 0xE5
    images["nofont32"] = write("nofont32", nofont32)

    # The stage-2 loader follows the allocation map, not RC.  Keeping only
    # the first 1K block of a staged file exercises a short read/write:
    # CCP.COM gets a partial image (LF_CCP_LEN = 1024) and CPM3C.SYS leaves
    # most of the common-stub staging area uninitialised.
    shortccp = bytearray(base)
    shortccp[find_entry(shortccp, b"CCP     COM") + 17] = 0
    images["shortccp"] = write("shortccp", shortccp)

    shortsys2 = bytearray(base)
    shortsys2[find_entry(shortsys2, b"CPM3C   SYS") + 17] = 0
    images["shortsys2"] = write("shortsys2", shortsys2)

    # A zero-length CCP.COM stages nothing; LF_CCP_LEN = 0 must trigger the
    # "CCP.COM missing" diagnostic rather than a jump into an empty TPA.
    emptyccp = bytearray(base)
    emptyccp[find_entry(emptyccp, b"CCP     COM") + 16] = 0
    images["emptyccp"] = write("emptyccp", emptyccp)

    # Directory entries that point past DSM must fail in the loader instead
    # of reading a sector from beyond the disk.
    badccp = bytearray(base)
    badccp[find_entry(badccp, b"CCP     COM") + 16] = 200
    images["badccpblock"] = write("badccpblock", badccp)

    badsys2 = bytearray(base)
    badsys2[find_entry(badsys2, b"CPM3C   SYS") + 16] = 200
    images["badsys2block"] = write("badsys2block", badsys2)

    return images


class Negative:
    def __init__(self, mcp: MCP):
        self.mcp = mcp
        self.cb = label_address("char_buffer")
        self.cb_bank = bank_for_address(self.cb)

    def memory(self, bank: int, addr: int, length: int) -> bytes:
        txt = self.mcp.call("read_memory", {
            "address": hex(addr), "length": length, "bank": bank})
        data = bytearray()
        for line in txt.splitlines():
            m = re.match(r"^([0-9A-F]{4})\s+((?:[0-9A-F]{2} )+)", line)
            if m:
                data.extend(bytes.fromhex(m.group(2)))
        return bytes(data[:length])

    def screen(self) -> str:
        txt = self.mcp.call("read_memory", {
            "address": hex(self.cb), "length": COLS * ROWS, "bank": self.cb_bank})
        data = bytearray()
        for line in txt.splitlines():
            m = re.match(r"^([0-9A-F]{4})\s+((?:[0-9A-F]{2} )+)", line)
            if m:
                data.extend(bytes.fromhex(m.group(2)))
        return "".join(chr(b) if 32 <= b < 127 else "."
                       for b in data[:COLS * ROWS])

    def reset(self) -> None:
        self.mcp.call("model", {"target": "zx128kplus3"})

    def no_boot(self, name: str, path: Path) -> None:
        self.reset()
        self.mcp.call("load", {"file": str(path)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1500})
        screen = self.screen()
        if "A>" in screen or "Open CP/M +3" in screen:
            raise SmokeError(f"{name}: unexpectedly booted:\n{screen}")
        print(f"[negative] {name}: no boot (ok)")

    def no_ccp(self, path: Path) -> None:
        """No CCP.COM: signon, a clear diagnostic, and no prompt."""
        self.reset()
        self.mcp.call("load", {"file": str(path)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1500})
        screen = self.screen()
        if "A>" in screen:
            raise SmokeError(f"noccp: reached a prompt without CCP.COM:\n{screen}")
        if "CCP.COM missing" not in screen:
            raise SmokeError(f"noccp: no diagnostic on screen:\n{screen}")
        print("[negative] noccp: reports missing CCP.COM, no prompt (ok)")

    def boots(self, name: str, path: Path) -> None:
        """An optional file is missing: boot must still reach the prompt."""
        self.reset()
        self.mcp.call("load", {"file": str(path)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1500})
        screen = self.screen()
        if "A>" not in screen or "Open CP/M +3" not in screen:
            raise SmokeError(f"{name}: did not boot cleanly:\n{screen}")
        print(f"[negative] {name}: boots (ok)")

    def c_absent(self, name: str, path: Path) -> None:
        """No usable FID: C: must not be registered."""
        self.boots(name, path)
        slot = label_address("drive_table_c_slot")
        raw = self.memory(3, slot, 2)
        if raw != b"\x00\x00":
            raise SmokeError(f"{name}: C: registered with a bad FID ({raw.hex()})")
        print(f"[negative] {name}: C: absent (ok)")

    def font64_missing(self, path: Path) -> None:
        """Without FONT64.BIN, SCREEN 64 must be refused."""
        self.boots("nofont64", path)
        self.mcp.call("type", {"text": "SCREEN 64"})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": 800})
        cols = self.memory(4, label_address("scr_cols"), 1)[0]
        if cols != 51:
            raise SmokeError(
                f"nofont64: SCREEN 64 changed width to {cols}, expected 51")
        print("[negative] nofont64: SCREEN 64 refused (ok)")

    def no_prompt(self, name: str, path: Path) -> None:
        """A partially staged boot file may print the signon, but no prompt."""
        self.reset()
        self.mcp.call("load", {"file": str(path)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 2500})
        screen = self.screen()
        if "A>" in screen:
            raise SmokeError(f"{name}: unexpectedly reached a prompt:\n{screen}")
        print(f"[negative] {name}: no prompt (ok)")

    def ccp_empty(self, path: Path) -> None:
        """Zero-length CCP.COM: the BIOS must report it and halt."""
        self.reset()
        self.mcp.call("load", {"file": str(path)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1500})
        screen = self.screen()
        if "A>" in screen:
            raise SmokeError(f"emptyccp: reached a prompt with no CCP image:\n{screen}")
        if "CCP.COM missing" not in screen:
            raise SmokeError(f"emptyccp: no diagnostic on screen:\n{screen}")
        print("[negative] emptyccp: reports missing CCP.COM, no prompt (ok)")

    def font32_missing(self, path: Path) -> None:
        """Without FONT32.BIN, SCREEN 32 must be refused."""
        self.boots("nofont32", path)
        self.mcp.call("type", {"text": "SCREEN 32"})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": 800})
        cols = self.memory(4, label_address("scr_cols"), 1)[0]
        if cols != 51:
            raise SmokeError(
                f"nofont32: SCREEN 32 changed width to {cols}, expected 51")
        print("[negative] nofont32: SCREEN 32 refused (ok)")

    def nodisk(self) -> None:
        self.reset()
        self.mcp.call("load", {"file": str(ROOT / "build" / "cpm3.dsk")})
        self.mcp.call("eject", {"target": "disk", "drive": "0"})
        msg = self.mcp.call("disk_boot", {})
        if "No disk" not in msg:
            raise SmokeError(f"nodisk: disk_boot did not report a missing disk: {msg}")
        screen = self.screen()
        if "A>" in screen or "Open CP/M +3" in screen:
            raise SmokeError(f"nodisk: unexpectedly booted:\n{screen}")
        print("[negative] nodisk: no boot (ok)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    ap.add_argument("--keep", action="store_true",
                    help="keep the generated build/negative images")
    args = ap.parse_args()

    src = Path(args.dsk)
    if not src.is_absolute():
        src = ROOT / src
    if not src.exists():
        print(f"error: {src} does not exist; run build.cmd first", file=sys.stderr)
        return 2

    outdir = ROOT / "build" / "negative"
    if outdir.exists() and not args.keep:
        shutil.rmtree(outdir)
    try:
        images = make_images(src, outdir)
        mcp = MCP(find_zx84(args.zx84), args.model)
        try:
            neg = Negative(mcp)
            for name, path in images.items():
                if name == "noccp":
                    neg.no_ccp(path)
                elif name == "emptyccp":
                    neg.ccp_empty(path)
                elif name == "nofont64":
                    neg.font64_missing(path)
                elif name == "nofont32":
                    neg.font32_missing(path)
                elif name == "nofont51":
                    neg.boots(name, path)
                elif name in ("nofid", "badfid"):
                    neg.c_absent(name, path)
                elif name in ("shortccp", "shortsys2",
                              "badccpblock", "badsys2block"):
                    neg.no_prompt(name, path)
                else:
                    neg.no_boot(name, path)
            neg.nodisk()
        finally:
            mcp.close()
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        if not args.keep and outdir.exists():
            shutil.rmtree(outdir, ignore_errors=True)
    print("[negative] all failure cases rejected")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
