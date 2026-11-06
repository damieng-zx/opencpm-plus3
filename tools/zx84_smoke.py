#!/usr/bin/env python3
"""Automated zx84 smoke test for the built CP/M +3 image.

Boots build/cpm3-test.dsk through the zx84 MCP server, runs the on-disk test
programs and a few CCP flows, and asserts the 51x24 character buffer.  This
is the automated counterpart of docs/mcp-smoke-test.md.

Usage:
    python3 tools/zx84_smoke.py
    python3 tools/zx84_smoke.py --zx84 F:/src/zx/zx84 --dsk build/cpm3-test.dsk
    ZX84_DIR=F:/src/zx/zx84 python3 tools/zx84_smoke.py

Exit codes: 0 = all checks passed, 1 = assertion/run failure, 2 = setup error.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COLS = 51
ROWS = 24


class SmokeError(RuntimeError):
    pass


def label_address(name: str) -> int:
    listing = ROOT / "build" / "bios.lst"
    if not listing.exists():
        raise SmokeError("build/bios.lst is missing; run build.cmd first")
    lines = listing.read_text(encoding="utf-8", errors="replace").splitlines()
    # An equate definition wins over the address the assembler happened to
    # be at: `foo: equ 0xA649` is listed with the current PC in the address
    # column, which is not the value of foo.
    for line in lines:
        m = re.match(
            rf"^\s*\d+\+*\s+[0-9A-F]{{4}}\s+[^;]*\b{re.escape(name)}\s*:\s*equ\s+0x([0-9A-Fa-f]+)",
            line, re.I)
        if m:
            return int(m.group(1), 16)
    # Prefer an exact-case label definition.  The equate pass below is
    # case-insensitive (so callers can ask for an `equ` constant), and
    # without this pass `scr_attr` would match `SCR_ATTR equ 0x5800`
    # instead of the variable at 0x0261.  `[^;]*` keeps comments such as
    # "; Scroll char_buffer: ..." from being mistaken for labels.
    # Lines from an included file carry a trailing `+` after the listing
    # number; lines from the top-level file do not, so accept both.
    for line in lines:
        m = re.match(
            rf"^\s*\d+\+*\s+([0-9A-F]{{4}})\s+[^;]*\b{re.escape(name)}:", line)
        if m:
            return int(m.group(1), 16)
    for line in lines:
        m = re.match(
            rf"^\s*\d+\+*\s+[0-9A-F]{{4}}\s+[^;]*\b{re.escape(name)}\s+equ\s+0x([0-9A-Fa-f]+)",
            line, re.I)
        if m:
            return int(m.group(1), 16)
    raise SmokeError(f"{name} label not found in build/bios.lst")


def bank_for_address(addr: int) -> int:
    """Bank that maps a buffer address in system/screen mode."""
    if 0x8000 <= addr < 0xC000:
        return 6
    return 4


def char_buffer_address() -> int:
    return label_address("char_buffer")


class MCP:
    """Minimal newline-delimited JSON-RPC client for the zx84 MCP server."""

    def __init__(self, zx84: Path, model: str):
        server = zx84 / "mcp" / "server.ts"
        if not server.exists():
            raise SmokeError(f"zx84 MCP server not found: {server}")
        npx = shutil.which("npx")
        if not npx:
            raise SmokeError("npx is not on PATH (install Node.js)")
        cmd = [npx, "--no-install", "tsx", "mcp/server.ts", "--model", model]
        if sys.platform == "win32":
            cmd = ["cmd", "/c"] + cmd
        self.proc = subprocess.Popen(
            cmd,
            cwd=str(zx84),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
        self.next_id = 1
        self.notifications: list[dict] = []
        self._stderr: list[str] = []
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self.initialize()

    def _drain_stderr(self) -> None:
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self._stderr.append(line.rstrip())
            if len(self._stderr) > 200:
                del self._stderr[:100]

    def stderr_tail(self) -> str:
        return "\n".join(self._stderr[-40:])

    def _send(self, obj: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(obj) + "\n")
        self.proc.stdin.flush()

    def _read_response(self, want_id: int, timeout: float) -> dict:
        assert self.proc.stdout is not None
        deadline = time.time() + timeout
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if line == "":
                raise SmokeError(f"zx84 MCP server exited\n{self.stderr_tail()}")
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except json.JSONDecodeError:
                continue
            if msg.get("id") == want_id:
                return msg
            if "method" in msg and "id" not in msg:
                self.notifications.append(msg)
        raise SmokeError(f"no response for MCP request {want_id}")

    def request(self, method: str, params: dict | None = None,
                timeout: float = 180.0) -> dict:
        rid = self.next_id
        self.next_id += 1
        msg = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            msg["params"] = params
        self._send(msg)
        resp = self._read_response(rid, timeout)
        if "error" in resp:
            raise SmokeError(f"{method}: {resp['error']}")
        return resp.get("result", {})

    def initialize(self) -> None:
        self.request("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "opencpm-smoke", "version": "1.0"},
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def call(self, name: str, args: dict | None = None,
             timeout: float = 180.0) -> str:
        res = self.request("tools/call",
                           {"name": name, "arguments": args or {}},
                           timeout)
        parts = [item.get("text", "") for item in res.get("content", [])
                 if item.get("type") == "text"]
        text = "\n".join(parts)
        if res.get("isError"):
            raise SmokeError(f"tool {name} failed: {text}")
        return text

    def close(self) -> None:
        try:
            if self.proc.stdin is not None:
                self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.terminate()
            self.proc.wait(timeout=5)
        except Exception:
            try:
                self.proc.kill()
            except Exception:
                pass


class Smoke:
    def __init__(self, mcp: MCP, dsk: Path, verbose: bool = False):
        self.mcp = mcp
        self.dsk = dsk
        self.verbose = verbose
        self.cb = char_buffer_address()
        self.cb_bank = bank_for_address(self.cb)
        self.scr_cols = label_address("scr_cols")
        self.scr_wrap = label_address("scr_wrap")
        self.scr_attr = label_address("scr_attr")
        self.cursor_col = label_address("cursor_col")
        self.cursor_row = label_address("cursor_row")
        self.con_mode = label_address("con_mode")
        self.esc_state = label_address("esc_state")
        self.ccp_stage = label_address("CCP_STAGE")
        self.font_ptr = label_address("font_ptr")
        self.scb_conwidth = label_address("scb_conwidth")
        self.history: list[str] = []

    def log(self, msg: str) -> None:
        print(f"[smoke] {msg}")

    def memory(self, bank: int, addr: int, length: int) -> bytes:
        txt = self.mcp.call("read_memory", {
            "address": hex(addr), "length": length, "bank": bank})
        out = bytearray()
        for line in txt.splitlines():
            m = re.match(r"^([0-9A-F]{4})\s+((?:[0-9A-F]{2} )+)", line)
            if m:
                out.extend(bytes.fromhex(m.group(2)))
        return bytes(out[:length])

    def screen(self) -> list[str]:
        cols = self.memory(4, self.scr_cols, 1)[0]
        if cols not in (32, 51, 64):
            cols = COLS
        data = self.memory(self.cb_bank, self.cb, cols * ROWS)
        if len(data) < cols * ROWS:
            raise SmokeError(f"short char_buffer read: {len(data)} bytes")
        return ["".join(chr(b) if 32 <= b < 127 else "."
                        for b in data[r * cols:(r + 1) * cols]).rstrip()
                for r in range(ROWS)]

    def text(self) -> str:
        return "\n".join(self.screen())

    def record(self) -> None:
        self.history.extend(self.screen())
        if len(self.history) > 400:
            self.history = self.history[-400:]

    def wait_for(self, needles: list[str], frames: int = 500,
                 attempts: int = 8) -> str:
        for _ in range(attempts):
            self.mcp.call("run", {"frames": frames})
            self.record()
            screen = self.text()
            if all(n in screen for n in needles):
                return screen
        raise SmokeError(
            "expected " + ", ".join(repr(n) for n in needles) +
            " -- screen:\n" + self.text())

    def command(self, cmd: str, frames: int = 500) -> None:
        self.log(cmd)
        self.mcp.call("type", {"text": cmd})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": frames})
        self.record()

    def expect(self, label: str, *needles: str, screen: str | None = None) -> None:
        screen = screen if screen is not None else self.text()
        missing = [n for n in needles if n not in screen]
        if missing:
            raise SmokeError(
                f"{label}: missing {missing!r} -- screen:\n{screen}")

    # ---- terminal escape helpers -------------------------------------

    def key(self, name: str, frames: int = 150) -> None:
        self.mcp.call("key", {"name": name})
        self.mcp.call("run", {"frames": frames})

    def esc(self, text: str, frames: int = 500) -> None:
        """Send BREAK (ESC) followed by a sequence, as at the A> prompt."""
        self.log(f"ESC {text}")
        self.key("shift+space")
        self.mcp.call("type", {"text": text})
        self.mcp.call("run", {"frames": frames})
        self.record()
        self.log(
            "  cols=%d wrap=%d attr=%02X mode=%04X state=%d" % (
                self.memory(4, self.scr_cols, 1)[0],
                self.memory(4, self.scr_wrap, 1)[0],
                self.memory(4, self.scr_attr, 1)[0],
                int.from_bytes(self.memory(4, self.con_mode, 2), "little"),
                self.memory(6, self.esc_state, 1)[0],
            ))

    def finish_prompt(self, frames: int = 900) -> None:
        """Run the junk command left in the line buffer and get a prompt."""
        self.key("enter")
        self.wait_for(["A>"], frames=frames)

    def run_terminal_escapes(self) -> None:
        """ESC 3/4/b/c/v/w typed at the A> prompt (CP/M Plus App. III)."""
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("expected 51 columns before the ESC tests")

        # ESC 4 n: page mode bit of the BDOS console mode word.
        self.esc("41")
        if not (self.memory(4, self.con_mode, 2)[0] & 1):
            raise SmokeError("ESC 4 1 did not set page mode")
        self.finish_prompt()
        self.esc("40")
        if self.memory(4, self.con_mode, 2)[0] & 1:
            raise SmokeError("ESC 4 0 did not clear page mode")
        self.finish_prompt()

        # ESC 3 n: 0 = 24x32, 1 = 24x51; it also cancels page mode, so
        # turn page mode back on first and watch ESC 3 clear it.
        self.esc("41")
        self.finish_prompt()
        self.esc("30")
        if self.memory(4, self.scr_cols, 1)[0] != 32:
            raise SmokeError("ESC 3 0 did not select 32 columns")
        if self.memory(4, self.con_mode, 2)[0] & 1:
            raise SmokeError("ESC 3 did not cancel page mode")
        self.finish_prompt()

        self.esc("31")
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("ESC 3 1 did not restore 51 columns")
        self.finish_prompt()

        # ESC v/w: wrapping at the right edge.  Use 32 columns so a short
        # line fills a row.
        self.esc("30")
        self.finish_prompt()
        self.esc("w")
        if self.memory(4, self.scr_wrap, 1)[0] != 0:
            raise SmokeError("ESC w did not clear the wrap flag")
        self.esc("H")
        self.mcp.call("type", {"text": "X" * 40})
        self.mcp.call("run", {"frames": 1200})
        row = self.memory(6, self.cursor_row, 1)[0]
        col = self.memory(6, self.cursor_col, 1)[0]
        if (row, col) != (0, 31):
            raise SmokeError(f"ESC w: cursor {row}/{col}, expected 0/31")
        self.finish_prompt()

        self.esc("v")
        if self.memory(4, self.scr_wrap, 1)[0] != 1:
            raise SmokeError("ESC v did not set the wrap flag")
        self.esc("H")
        self.mcp.call("type", {"text": "X" * 40})
        self.mcp.call("run", {"frames": 1200})
        if self.memory(6, self.cursor_row, 1)[0] == 0:
            raise SmokeError("ESC v: a 40-character line did not wrap")
        self.finish_prompt()

        # ESC b/c: the parameter is the +3 palette value + 32.
        self.esc("31")
        self.finish_prompt()
        self.esc("b(")          # 40 = normal red ink
        self.esc('c"')          # 34 = normal blue paper
        attr = self.memory(4, self.scr_attr, 1)[0]
        if attr != 0x0A:
            raise SmokeError(
                f"ESC b/c red on blue: attribute {attr:02X}, expected 0A")
        self.esc("b_")          # 95 = bright white ink
        self.esc("c#")          # 35 = bright blue paper
        attr = self.memory(4, self.scr_attr, 1)[0]
        if attr != 0x4F:
            raise SmokeError(
                f"ESC b/c bright: attribute {attr:02X}, expected 4F")
        # A character drawn now must carry the new attribute.
        self.esc("H")
        self.mcp.call("type", {"text": "Q"})
        self.mcp.call("run", {"frames": 800})
        cell = self.memory(5, 0x5800, 2)
        if cell[0] != 0x4F:
            raise SmokeError(
                f"new character attribute {cell[0]:02X}, expected 4F")
        self.finish_prompt()

        # Restore the defaults: bright white on blue (the +3 mixes that
        # down to normal), 51 columns, page mode and wrapping on.
        self.esc("b_")
        self.esc('c"')
        attr = self.memory(4, self.scr_attr, 1)[0]
        if attr != 0x0F:
            raise SmokeError(
                f"default colours restored as {attr:02X}, expected 0F")
        self.esc("31")
        self.finish_prompt()
        self.esc("41")
        self.esc("v")
        self.finish_prompt()
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("ESC tests left the screen at the wrong width")

    def boot(self) -> None:
        self.log(f"booting {self.dsk}")
        self.mcp.call("model", {"target": "zx128kplus3"})
        self.mcp.call("load", {"file": str(self.dsk)})
        self.mcp.call("disk_boot", {})
        self.mcp.call("run", {"frames": 1000})
        self.record()
        self.wait_for(["A>"], frames=500, attempts=8)
        self.expect("boot signon", "Open CP/M +3", "A>")

    def run_loader_stage(self) -> None:
        """The stage-2 loader stages fonts, FID and CCP in bank 6."""
        self.log("loader staging")
        for name, addr, path in (
                ("FONT51", 0x8000, ROOT / "src" / "bios" / "font51.bin"),
                ("FONT32", 0x8800, ROOT / "src" / "bios" / "font32.bin"),
                ("FONT64", 0x9400, ROOT / "src" / "bios" / "font64.bin")):
            data = path.read_bytes()
            got = self.memory(6, addr, len(data))
            if got != data:
                raise SmokeError(
                    f"{name} not staged at {addr:04X} in bank 6")
        fid = (ROOT / "build" / "RAMDISK.FID").read_bytes()
        if self.memory(6, 0x9000, len(fid)) != fid:
            raise SmokeError("RAMDISK.FID not staged at 9000 in bank 6")

        flags = self.memory(6, label_address("LF_FLAGS"), 1)[0]
        if flags != 0x1F:
            raise SmokeError(
                f"loader LF_FLAGS {flags:02X}, expected 1F (all staged)")
        clen = int.from_bytes(
            self.memory(6, label_address("LF_CCP_LEN"), 2), "little")
        if clen != 4 * 1024:
            raise SmokeError(
                f"loader LF_CCP_LEN {clen}, expected {4 * 1024}")

    # Free bank-6 gaps.  Nothing should touch these once the loader has
    # handed over, so a sentinel across the app tests catches accidental
    # overlaps (the fcb_buf/alv_c type of bug).
    # A880-A881 is f111_addr (BDOS F111 text pointer), so the gap is split
    # around it.
    # A880-A881 is f111_addr, A890-A8BF is the loader-staged row table and
    # A8C0 is the status-line flag, so the old A870-A8FF gap is split.
    BANK6_GAPS = ((0xA6FC, 4), (0xA83D, 3), (0xA870, 0x10),
                  (0xA882, 0x0E), (0xA8D9, 0x27), (0xADA4, 0x25C))

    def run_bank6_sentinels(self) -> None:
        self.sentinels: list[tuple[int, bytes]] = []
        for addr, length in self.BANK6_GAPS:
            pattern = bytes(0xA5 ^ (i & 0xFF) for i in range(length))
            self.mcp.call("write_memory", {
                "address": hex(addr), "hex_bytes": pattern.hex(), "bank": 6})
            self.sentinels.append((addr, pattern))
        self.log("bank-6 sentinels")

    def check_bank6_sentinels(self) -> None:
        for addr, pattern in self.sentinels:
            got = self.memory(6, addr, len(pattern))
            if got != pattern:
                for i, (a, b) in enumerate(zip(got, pattern)):
                    if a != b:
                        raise SmokeError(
                            f"bank-6 gap {addr + i:04X} was {a:02X}, "
                            f"expected {b:02X}")
                raise SmokeError(f"bank-6 gap {addr:04X} is short")

    def run_systest(self) -> None:
        self.command("SYSTEST", 2500)
        screen = self.text()
        self.expect("SYSTEST", "STACK OK", "MOVE OK", "CLOCK OK",
                    "P0 PASS", "TAB:", "A       B", "DELIM PASS",
                    screen=screen)
        if "STACK BAD" in screen or "MOVE BAD" in screen or \
                "CLOCK BAD" in screen or "P0 BAD" in screen or \
                "DELIM BAD" in screen:
            raise SmokeError("SYSTEST reported a failure:\n" + screen)

    def run_xtetest(self) -> None:
        """Exercise the XBIOS TE calls and their register contracts."""
        self.log("XTETEST")
        start = len(self.history)
        self.mcp.call("type", {"text": "XTETEST"})
        self.mcp.call("key", {"name": "enter"})
        # Test 19 remaps Z to Q and blocks for a key press.
        self.wait_for(["19.KTAB.."], frames=100, attempts=40)
        # Check the SCR_RUN_ROUTINE marker now, while test 7 is still on
        # screen: with tests 20-30 to follow it would scroll out later.
        attrs = self.memory(5, 0x5800, 768)
        if 0x5A not in attrs:
            raise SmokeError("SCR_RUN_ROUTINE screen marker 5A not found")
        flag = self.memory(3, 0xD100, 1)[0]
        if flag != 1:
            raise SmokeError(
                f"SCR_RUN_ROUTINE input flag {flag:02X}, expected 01")
        self.key("z")
        # Test 19 then remaps X in the CAPS table and blocks again: press
        # CAPS+X (the emulator's "shift+") and expect the remapped letter.
        self.wait_for(["19.CAPS.."], frames=100, attempts=40)
        self.key("shift+x", frames=5)
        # Poll in short bursts: once the key arrives the test races on to 20+
        # and would scroll this line away inside a single 100-frame step.
        self.wait_for(["19.CAPS..OK"], frames=15, attempts=200)
        # Test 31 holds a key at fast and slow repeat speeds.
        self.wait_for(["31.KREPEAT.."], frames=100, attempts=40)
        self.key("a", frames=60)
        self.wait_for(["31.SLOWX.."], frames=100, attempts=40)
        self.key("b", frames=60)
        self.wait_for(["DONE"], frames=100, attempts=40)
        screen = self.text()
        # The full run scrolls off the 24-line screen, so check every frame
        # recorded since the test started.
        seen = "\n".join(self.history[start:])
        if "FAIL" in seen:
            raise SmokeError("XTETEST reported a failure:\n" + seen)
        for needle in ("7.RUN..OK", "8.DISK..OK", "9.RW..OK",
                       "11.SETUP..OK", "12.DPB..OK", "13.XDPB..OK",
                       "14.LREAD..OK", "15.LWRITE..OK", "16.KMSPD..OK",
                       "17.KTPUT..OK", "18.KTGET..OK", "19.CAPS..OK",
                       "20.EXP..OK", "21.CDVER..OK", "22.CDINFO..OK", "23.DRIVESTAT..OK", "24.KTWRAP..OK", "25.SETKEY..OK", "26.EXPMAX..OK", "27.KMZERO..OK", "28.LREADX..OK", "29.BADSPEC..OK", "30.SETUPX..OK", "31.KREPEAT..OK", "32.FMTBAD..OK", "33.VIEWPORT..OK", "DONE"):
            if needle not in seen:
                raise SmokeError(
                    f"XTETEST missing {needle!r}:\n" + seen)
        # Test 30 leaves the edge block in place: no motor-off timeout,
        # step rate clamped to 16 ms with HUT 15, and 0x7F head-load/ND.
        for name, expected in (("motor_off_ticks", 0x00),
                               ("fdc_spec1", 0x0F),
                               ("fdc_spec2", 0xFD)):
            value = self.memory(4, label_address(name), 1)[0]
            if value != expected:
                raise SmokeError(
                    f"DD_SETUP edge {name} {value:02X}, expected {expected:02X}")
        # Restore the test-11 defaults for the rest of the run.
        for name, value in (("motor_off_ticks", 0xFA),
                            ("fdc_spec1", 0x4F),
                            ("fdc_spec2", 0x05)):
            self.mcp.call("write_memory", {
                "address": hex(label_address(name)),
                "hex_bytes": f"{value:02X}", "bank": 4})
        for name, expected in (("motor_off_ticks", 250),
                               ("fdc_spec1", 0x4F),
                               ("fdc_spec2", 0x05)):
            value = self.memory(4, label_address(name), 1)[0]
            if value != expected:
                raise SmokeError(
                    f"DD_SETUP defaults {name} {value:02X}, "
                    f"expected {expected:02X}")
        # Keyboard state lives in bank 6 (A63F+).  Test 27 leaves 0/0,
        # which the handler must store as 256 scans.
        for name in ("kbd_repeat_delay", "kbd_repeat_rate"):
            value = int.from_bytes(
                self.memory(6, label_address(name), 2), "little")
            if value != 256:
                raise SmokeError(
                    f"KM_SET_SPEED {name} {value}, expected 256")
        # Tests 17/18 queue and drain two tokens, then test 24 fills the
        # queue to 16 and runs 20 put/get cycles: head/tail end at 6.
        count = self.memory(6, label_address("kbd_token_count"), 1)[0]
        if count != 0:
            raise SmokeError(f"KM_KT_GET token count {count}, expected 0")
        for name, expected in (("kbd_token_head", 6), ("kbd_token_tail", 6)):
            value = self.memory(6, label_address(name), 1)[0]
            if value != expected:
                raise SmokeError(
                    f"KM_KT queue {name} {value}, expected {expected}")
        # Test 19 restored the built-in translation for Z after checking it.
        kmtab = self.memory(6, 0xA900, 8)
        if kmtab[4] != 0xFF:
            raise SmokeError(
                f"KM_SET_KEY table[4] {kmtab[4]:02X}, expected FF after reset")
        # Test 25 entries: key*4 + shift (normal, CAPS, SYMB, EXTEND).
        # It only touches the non-normal tables, so normal typing still works.
        for index, expected in ((2 * 4 + 1, ord("A")),
                                (3 * 4 + 2, ord("B")),
                                (4 * 4 + 3, ord("C")),
                                (5 * 4 + 1, ord("F")),
                                (5 * 4 + 2, ord("F")),
                                (5 * 4 + 3, ord("F")),
                                (5 * 4 + 0, 0xFF),
                                (6 * 4 + 1, ord("G")),
                                (6 * 4 + 0, 0xFF),
                                (39 * 4 + 1, ord("J"))):
            value = self.memory(6, 0xA900 + index, 1)[0]
            if value != expected:
                raise SmokeError(
                    f"KM_SET_KEY table[{index}] {value:02X}, "
                    f"expected {expected:02X}")
        # The emulator types upper-case letters with CAPS SHIFT, so restore
        # the test overrides before the remaining commands are typed.
        for index in (2 * 4 + 1, 3 * 4 + 2, 4 * 4 + 3,
                      5 * 4 + 1, 5 * 4 + 2, 5 * 4 + 3,
                      6 * 4 + 1, 39 * 4 + 1):
            self.mcp.call("write_memory", {
                "address": hex(0xA900 + index), "hex_bytes": "FF", "bank": 6})
        # KM_SET_EXPAND slot for token 85h: length 5 + "HELLO".
        slot = self.memory(6, 0xA9A0 + 5 * 32, 6)
        if slot != bytes((5, ord("H"), ord("E"), ord("L"),
                          ord("L"), ord("O"))):
            raise SmokeError(f"KM_SET_EXPAND slot {slot!r}, expected HELLO")
        # Test 26: token 80h stays empty after the over-long write; token
        # 9Eh holds the maximum 31-byte string.
        empty = self.memory(6, 0xA9A0, 1)[0]
        if empty != 0:
            raise SmokeError(
                f"KM_SET_EXPAND 80h length {empty}, expected 0")
        maxslot = self.memory(6, 0xA9A0 + 30 * 32, 32)
        expect31 = bytes((31,)) + b"0123456789ABCDEFGHIJKLMNOPQRSTU"
        if maxslot != expect31:
            raise SmokeError(
                f"KM_SET_EXPAND 9Eh slot {maxslot.hex()}, expected {expect31.hex()}")
        # DONE can appear a few frames before the CCP redraws its prompt.
        self.wait_for(["A>"], frames=50, attempts=40)

    def run_xtetest_format(self) -> None:
        """Run the destructive DD_FORMAT test on a scratch disk copy."""
        scratch = ROOT / "build" / "format-test.dsk"
        shutil.copyfile(self.dsk, scratch)
        self.log("XTETEST format test on a scratch image")
        old_dsk = self.dsk
        self.dsk = scratch
        try:
            self.boot()
            self.mcp.call("write_memory",
                          {"address": "DC00", "hex_bytes": "A5"})
            self.mcp.call("type", {"text": "XTETEST"})
            self.mcp.call("key", {"name": "enter"})
            self.wait_for(["10.FMT..OK"], frames=500, attempts=10)
            dump = self.mcp.call("sector_read", {
                "track": 39, "sector": 1, "side": 0, "length": 32})
            if "E5 E5 E5" not in dump:
                raise SmokeError(
                    "DD_FORMAT did not fill track 39 with 0xE5:\n" + dump)
            # Let the run finish: tests 19 and 19b wait for keys, then 31
            # holds two more for the repeat-cadence check.
            self.key("z")
            self.wait_for(["19.CAPS.."], frames=100, attempts=40)
            self.key("shift+x", frames=5)
            self.wait_for(["31.KREPEAT.."], frames=100, attempts=40)
            self.key("a", frames=60)
            self.wait_for(["31.SLOWX.."], frames=100, attempts=40)
            self.key("b", frames=60)
            self.wait_for(["DONE"], frames=500, attempts=10)
        finally:
            self.dsk = old_dsk
            try:
                scratch.unlink()
            except OSError:
                pass

    def run_format(self) -> None:
        """FORMAT.COM: 180K on A: via a disc swap, then B: layouts.

        A: is formatted on a scratch copy of the test image with the target
        hot-swapped in at the "put the disc in" prompt (the system disc must
        come out first, exactly as the command says).  B: then gets a 720K
        DS image and the two CPC layouts, all on a mounted B: image.  The
        emulator keeps disc writes in memory (it does not persist them back
        to the .dsk file), so sectors are read back through the FDC.
        """
        if not (ROOT / "build" / "cpm3_720.dsk").exists():
            raise SmokeError(
                "build/cpm3_720.dsk is missing; run build.cmd first")
        scratch = ROOT / "build" / "format-smoke.dsk"
        blank180 = ROOT / "build" / "format-blank180.dsk"
        blank720 = ROOT / "build" / "format-blank720.dsk"
        shutil.copyfile(self.dsk, scratch)
        shutil.copyfile(self.dsk, blank180)
        shutil.copyfile(ROOT / "build" / "cpm3_720.dsk", blank720)
        old_dsk = self.dsk
        self.dsk = scratch
        try:
            self.boot()
            # Argument handling and the ESC escape hatch, before anything
            # destructive happens.
            self.command("FORMAT", 300)
            self.expect("FORMAT usage", "Format the disc in the given drive.")
            self.command("FORMAT C:", 300)
            self.expect("FORMAT C: refused", "cannot be formatted",
                        "Only drives A: and B: are supported")
            self.command("FORMAT A:", 300)
            self.wait_for(["Take the disc out"], frames=50, attempts=4)
            self.key("escape", 300)
            self.expect("FORMAT cancelled", "Cancelled.")

            self.log("FORMAT A: 180K SS/40 track")
            self.format_disc("A", blank180, "1", "Done - 180K SS/40 track",
                             "Side 0")
            self.expect("180K format", "Done - 180K SS/40 track.",
                        "40 tracks, 9 sectors.",
                        "Every track formatted and verified.")
            self.check_sector(0, 0, 1, "00 00 28 09 02 01 03 02", drive=0)
            self.check_e5(39, 0, 1, drive=0)
            self.check_e5(1, 0, 1, drive=0)

            # The system disc was formatted in place; put the system image
            # back so FORMAT.COM can be loaded again, and mount a scratch
            # copy of the 720K image on B: for the remaining runs.
            self.mcp.call("eject", {"target": "disk", "drive": "A"})
            self.mcp.call("load", {"file": str(scratch), "drive": "A"})
            self.wait_for(["A>"], frames=200, attempts=4)
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.mcp.call("load", {"file": str(blank720), "drive": "B"})

            self.log("FORMAT B: 720K DS/80 track")
            self.format_disc("B", None, "2", "Done - 720K DS/80 track",
                             "Side 1")
            self.expect("720K format", "Done - 720K DS/80 track.",
                        "160 tracks, 9 sectors.",
                        "Every track formatted and verified.")
            self.check_sector(0, 0, 1, "03 01 50 09 02 01 04 02", drive=1)
            self.check_e5(79, 1, 9, drive=1)
            self.check_e5(40, 1, 4, drive=1)

            self.log("FORMAT B: CPC System 40 track")
            self.format_disc("B", None, "3", "Done - CPC System 40 track",
                             "Side 0")
            self.expect("CPC System format", "Done - CPC System 40 track.",
                        "40 tracks, 9 sectors.")
            self.check_sector(0, 0, 0x41, "01 00 28 09 02 02 03 02",
                              drive=1)
            self.check_e5(39, 0, 0x49, drive=1)
            self.command("DIR B:", 1500)
            self.expect("CPC System DIR", "No files")
            self.command("SHOWXDPB", 1500)
            self.expect("CPC System XDPB", "First=41h", "OFF=2",
                        "DSM=170")

            self.log("FORMAT B: CPC Data 40 track")
            self.format_disc("B", None, "4", "Done - CPC Data 40 track",
                             "Side 0")
            self.expect("CPC Data format", "Done - CPC Data 40 track.",
                        "40 tracks, 9 sectors.")
            # A data layout has no boot sector: track 0 is the directory.
            self.check_e5(0, 0, 0xC1, drive=1)
            self.check_e5(39, 0, 0xC9, drive=1)
            self.command("DIR B:", 1500)
            self.expect("CPC Data DIR", "No files")
            self.command("SHOWXDPB", 1500)
            self.expect("CPC Data XDPB", "First=C1h", "OFF=0",
                        "DSM=179")

            # --- 10-sector 3" layouts ---
            # HiForm 203: 42 tracks, interleave 3, so track 0's IDs are
            # physically 1,8,5,2,9,6,3,10,7,4.
            self.log("FORMAT B: HiForm 203 42 track")
            self.format_disc("B", None, "5", "Done - HiForm 203 42 track",
                             "Side 0")
            self.expect("HiForm format", "Done - HiForm 203 42 track.",
                        "42 tracks, 10 sectors.")
            self.check_sector(0, 0, 1, "00 00 2A 0A 02 01 03 02", drive=1)
            self.check_e5(41, 0, 10, drive=1)
            self.check_track_ids(0, [1, 8, 5, 2, 9, 6, 3, 10, 7, 4], drive=1)
            self.command("SHOWXDPB", 1500)
            self.expect("HiForm XDPB", "10x512", "DSM=204", "OFF=1",
                        "Gap2=16h")

            # SuperMat 192: 40 tracks, 10 sectors, 3 directory blocks.
            self.log("FORMAT B: SuperMat 192 40 track")
            self.format_disc("B", None, "6", "Done - SuperMat 192 40 track",
                             "Side 0")
            self.expect("SuperMat format", "Done - SuperMat 192 40 track.",
                        "40 tracks, 10 sectors.")
            self.check_sector(0, 0, 1, "00 00 28 0A 02 01 03 03", drive=1)
            self.check_e5(39, 0, 10, drive=1)
            self.check_track_ids(0, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10], drive=1)
            self.command("SHOWXDPB", 1500)
            self.expect("SuperMat XDPB", "10x512", "DSM=194", "DRM=95",
                        "Gap2=17h")

            # CPC IBM: 8 sectors of 512, interleave 2.
            self.log("FORMAT B: CPC IBM 40 track")
            self.format_disc("B", None, "7", "Done - CPC IBM 40 track",
                             "Side 0")
            self.expect("CPC IBM format", "Done - CPC IBM 40 track.",
                        "40 tracks, 8 sectors.")
            self.check_sector(0, 0, 1, "00 00 28 08 02 01 03 02", drive=1)
            self.check_e5(39, 0, 8, drive=1)
            self.check_track_ids(0, [1, 5, 2, 6, 3, 7, 4, 8], drive=1)
            self.command("SHOWXDPB", 1500)
            self.expect("CPC IBM XDPB", "8x512", "DSM=155", "Gap2=50h")

            # A drive with no disc must fail cleanly, not hang.
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.command("FORMAT B:", 400)
            self.wait_for(["Take the disc out of drive B:"], frames=50,
                          attempts=4)
            self.key("enter", 200)
            self.wait_for(["Put the disc to be formatted in drive B:"],
                          frames=50, attempts=4)
            self.key("enter", 200)
            self.wait_for(["Format type"], frames=300, attempts=4)
            self.mcp.call("type", {"text": "1"})
            self.mcp.call("run", {"frames": 200})
            self.wait_for(["FAILED"], frames=400, attempts=15)
            self.expect("FORMAT without a disc", "error (", "A>")
        finally:
            self.dsk = old_dsk
            try:
                self.mcp.call("eject", {"target": "disk", "drive": "B"})
            except SmokeError:
                pass
            for path in (scratch, blank180, blank720):
                try:
                    path.unlink()
                except OSError:
                    pass

    def format_disc(self, letter: str, target: Path | None, choice: str,
                    done_needle: str, side_needle: str) -> None:
        """Drive FORMAT.COM's prompts; swap `target` in for drive A:.

        Waits for this run's own summary line: the screen still holds the
        previous run's progress, so a generic "verified" match would return
        before the disc is done.
        """
        self.command(f"FORMAT {letter}:", 400)
        self.wait_for([f"FORMAT {letter}: - ALL DATA"], frames=400,
                      attempts=4)
        self.wait_for([f"Take the disc out of drive {letter}:"], frames=50,
                      attempts=4)
        self.key("enter", 200)
        if target is not None:
            self.mcp.call("eject", {"target": "disk", "drive": letter})
            self.mcp.call("load", {"file": str(target), "drive": letter})
        self.wait_for([f"Put the disc to be formatted in drive {letter}:"],
                      frames=50, attempts=4)
        self.key("enter", 200)
        self.wait_for(["Format type", "180K", "720K", "CPC System"],
                      frames=300, attempts=4)
        self.mcp.call("type", {"text": choice})
        self.mcp.call("run", {"frames": 200})

        # The progress line is rewritten in place: percentage first, then
        # the cylinder, the head and the format/verify phase.
        saw_side = saw_verify = saw_percent = False
        for _ in range(240):
            self.mcp.call("run", {"frames": 500})
            screen = self.text()
            self.record()
            saw_side = saw_side or side_needle in screen
            saw_verify = saw_verify or "VERIFY" in screen
            saw_percent = saw_percent or "%" in screen
            if done_needle in screen:
                if not (saw_side and saw_verify and saw_percent):
                    raise SmokeError(
                        "FORMAT progress line missing "
                        f"(track/side={saw_side} verify={saw_verify} "
                        f"percent={saw_percent}):\n" + screen)
                return
            if "FAILED" in screen:
                raise SmokeError("FORMAT reported a failure:\n" + screen)
        raise SmokeError("FORMAT did not finish:\n" + self.text())

    def check_sector(self, track: int, side: int, sector: int,
                     needle: str, drive: int = 0) -> None:
        dump = self.mcp.call("sector_read", {
            "track": track, "sector": sector, "side": side, "drive": drive,
            "length": 16})
        if needle.replace(" ", "") not in dump.replace(" ", ""):
            raise SmokeError(
                f"track {track} side {side} sector {sector} does not "
                f"start {needle}:\n{dump}")

    def check_e5(self, track: int, side: int, sector: int,
                 drive: int = 0) -> None:
        self.check_sector(track, side, sector,
                          "E5 E5 E5 E5 E5 E5 E5 E5", drive)

    def track_ids(self, track: int, side: int = 0,
                  drive: int = 0) -> list[int]:
        """The sector IDs of a track, in physical order."""
        text = self.mcp.call("track_geometry", {
            "track": track, "side": side, "drive": drive})
        ids = []
        for line in text.splitlines():
            parts = line.split()
            if len(parts) >= 4 and parts[0].isdigit():
                ids.append(int(parts[3], 16))
        return ids

    def track_info(self, track: int, side: int = 0,
                   drive: int = 0) -> str:
        """The header line of track_geometry: sector count, gap, filler."""
        text = self.mcp.call("track_geometry", {
            "track": track, "side": side, "drive": drive})
        return text.splitlines()[0]

    def check_track_ids(self, track: int, expected: list[int],
                        side: int = 0, drive: int = 0) -> None:
        """Check the IDs in physical order (interleave/skew layout)."""
        ids = self.track_ids(track, side, drive)
        if ids != expected:
            raise SmokeError(
                f"track {track} side {side} IDs {ids}, expected {expected}")

    def run_stat(self) -> None:
        """STAT: drive free space, file sizes/attributes, attribute changes."""
        self.log("STAT")
        self.command("STAT", 600)
        self.expect("STAT drives", "A: ", "K free of", "C: ")
        self.command("STAT *.TXT", 900)
        self.expect("STAT *.TXT", "SMOKE.TXT", "PAGE.TXT", "2 file(s)")
        self.command("STAT FORMAT.COM", 600)
        self.expect("STAT file", "FORMAT.COM", "1 file(s)")

        self.command("STAT FORMAT.COM $R/O", 600)
        self.expect("STAT set R/O", "FORMAT.COM set to R/O")
        self.command("STAT FORMAT.COM", 600)
        self.expect("STAT shows R/O", "FORMAT.COM", "R/O")
        self.command("STAT FORMAT.COM $R/W", 600)
        self.expect("STAT clear R/O", "FORMAT.COM set to R/W")
        self.command("STAT FORMAT.COM", 600)
        self.expect("STAT after R/W", "1 file(s)")
        line = [l for l in self.text().splitlines() if "FORMAT.COM" in l][-1]
        if "R/O" in line:
            raise SmokeError("STAT still shows R/O after $R/W: " + line)

        self.command("STAT *.COM $R/O", 600)
        self.expect("STAT wildcard", "specific file name")
        self.command("STAT FORMAT.COM $BOGUS", 600)
        self.expect("STAT usage", "free space per drive")

    def run_diskcopy(self) -> None:
        """DISKCOPY: A:->B:, a same-drive A:->A:, and a 10-sector layout copy.

        The A:->B: target is a 720K image (a different layout), so the copy
        has to format each target track as it goes; a sample of sectors must
        match the source byte for byte.  The same-drive run uses the 48K
        track buffer, so it takes four passes: the first pass is checked
        against the source, and the remaining passes only have to complete
        (the emulator drops a disc image's in-memory writes when it is
        ejected, so the target cannot keep tracks across passes here).
        Finally a HiForm disc (42 tracks, 10 sectors, interleave 3) is
        copied B:->A: and the target's track 0 must have the same sector
        cycle and gap, proving the layout was captured and re-applied
        rather than re-chosen.
        """
        src = ROOT / "build" / "diskcopy-src.dsk"
        dst = ROOT / "build" / "diskcopy-dst.dsk"
        foreign = ROOT / "build" / "diskcopy-720.dsk"
        shutil.copyfile(self.dsk, src)
        shutil.copyfile(ROOT / "build" / "cpm3.dsk", dst)
        shutil.copyfile(ROOT / "build" / "cpm3_720.dsk", foreign)
        old_dsk = self.dsk
        self.dsk = src
        try:
            self.boot()
            # Argument handling.
            self.command("DISKCOPY", 300)
            self.expect("DISKCOPY usage", "DISKCOPY source: target:")
            self.command("DISKCOPY C: B:", 300)
            self.expect("DISKCOPY C: rejected", "DISKCOPY source: target:")
            self.command("DISKCOPY A:", 300)
            self.expect("DISKCOPY one arg", "DISKCOPY source: target:")

            self.log("DISKCOPY A: B: (720K target)")
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.mcp.call("load", {"file": str(foreign), "drive": "B"})
            self.command("DISKCOPY A: B:", 400)
            self.wait_for(["Put the SOURCE disc in A:,", "the TARGET disc in B:,"],
                          frames=50, attempts=4)
            self.key("enter", 300)
            self.wait_for(["Copied 40 tracks."], frames=600, attempts=40)
            self.expect("DISKCOPY A->B",
                        "Source: SS, 40 tracks, 9 sectors of 512 bytes.",
                        "Every track verified.")
            for track, sector in ((0, 1), (0, 5), (1, 1), (3, 4), (9, 9),
                                  (17, 2), (25, 7), (39, 9)):
                a = self.mcp.call("sector_read", {
                    "track": track, "sector": sector, "side": 0, "drive": 0,
                    "length": 128}).split("\n", 1)[1]
                b = self.mcp.call("sector_read", {
                    "track": track, "sector": sector, "side": 0, "drive": 1,
                    "length": 128}).split("\n", 1)[1]
                if a != b:
                    raise SmokeError(
                        f"DISKCOPY left track {track} sector {sector} "
                        "different")
            # The target track must have been reformatted to the source's
            # 180K layout (9 sectors, gap 52h).
            if "Sectors: 9" not in self.track_info(0, drive=1):
                raise SmokeError("DISKCOPY did not reformat the target track")

            # Same drive: read a chunk, swap, write, swap back, ...
            self.log("DISKCOPY A: A:")
            source_sectors = {}
            for track, sector in ((0, 1), (1, 1), (5, 5), (9, 9)):
                source_sectors[(track, sector)] = self.mcp.call(
                    "sector_read", {"track": track, "sector": sector,
                                    "side": 0, "drive": 0,
                                    "length": 128}).split("\n", 1)[1]

            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.mcp.call("load", {"file": str(src), "drive": "A"})
            self.command("DISKCOPY A: A:", 400)
            self.wait_for(["Put the SOURCE disc in A:"], frames=50,
                          attempts=4)
            self.key("enter", 300)

            passes = 4               # 40 tracks, 10 per 48K pass
            for i in range(passes):
                self.wait_for(["put the TARGET disc in A:"], frames=500,
                              attempts=40)
                self.mcp.call("eject", {"target": "disk", "drive": "A"})
                self.mcp.call("load", {"file": str(dst), "drive": "A"})
                self.key("enter", 300)
                if i == passes - 1:
                    break
                self.wait_for(["Put the SOURCE disc back in A:"],
                              frames=500, attempts=40)
                if i == 0:
                    # The target is mounted: its first pass must match.
                    for (track, sector), data in source_sectors.items():
                        now = self.mcp.call(
                            "sector_read", {"track": track, "sector": sector,
                                            "side": 0, "drive": 0,
                                            "length": 128}).split("\n", 1)[1]
                        if now != data:
                            raise SmokeError(
                                "DISKCOPY same-drive pass 1 mismatch at "
                                f"track {track} sector {sector}")
                self.mcp.call("eject", {"target": "disk", "drive": "A"})
                self.mcp.call("load", {"file": str(src), "drive": "A"})
                self.key("enter", 300)
            self.wait_for(["Copied 40 tracks."], frames=600, attempts=40)
            self.expect("DISKCOPY A: A:", "Every track verified.")

            # --- Layout capture: copy a 10-sector HiForm disc ---
            self.log("FORMAT B: HiForm 203 (copy source)")
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.mcp.call("load", {"file": str(foreign), "drive": "B"})
            self.format_disc("B", None, "5", "Done - HiForm 203 42 track",
                             "Side 0")
            self.expect("HiForm source", "42 tracks, 10 sectors.")
            source_ids = self.track_ids(0, drive=1)
            if len(source_ids) != 10:
                raise SmokeError(f"HiForm source IDs {source_ids}")

            self.log("DISKCOPY B: A: (auto-formats A: as HiForm)")
            self.command("DISKCOPY B: A:", 400)
            self.wait_for(["Put the SOURCE disc in B:,", "the TARGET disc in A:,"],
                          frames=50, attempts=4)
            self.key("enter", 300)
            self.wait_for(["Copied 42 tracks."], frames=600, attempts=60)
            self.expect("DISKCOPY B: A:", "Every track verified.")
            info = self.track_info(0, drive=0)
            if "Sectors: 10" not in info or "Gap3: 16" not in info:
                raise SmokeError(
                    "DISKCOPY did not reformat A: with the HiForm layout: "
                    + info)
            target_ids = self.track_ids(0, drive=0)
            # The absolute rotational phase is not observable through READ
            # ID, so accept any rotation of the source's cycle.
            if (len(target_ids) != len(source_ids)
                    or sorted(target_ids) != sorted(source_ids)
                    or not any(source_ids[i:] + source_ids[:i] == target_ids
                               for i in range(len(source_ids)))):
                raise SmokeError(
                    f"HiForm layout not preserved: source {source_ids}, "
                    f"target {target_ids}")
            for track, sector in ((0, 10), (20, 10), (41, 10)):
                a = self.mcp.call("sector_read", {
                    "track": track, "sector": sector, "side": 0,
                    "drive": 0, "length": 64}).split("\n", 1)[1]
                b = self.mcp.call("sector_read", {
                    "track": track, "sector": sector, "side": 0,
                    "drive": 1, "length": 64}).split("\n", 1)[1]
                if a != b:
                    raise SmokeError(
                        f"HiForm copy differs at track {track} sector {sector}")
        finally:
            self.dsk = old_dsk
            for path in (src, dst, foreign):
                try:
                    path.unlink()
                except OSError:
                    pass

    def check_boot_track(self, expected: dict[int, str],
                         drive: int = 0) -> None:
        """Every sector of logical track 0 must match the source's."""
        for sector, dump in expected.items():
            now = self.mcp.call(
                "sector_read", {"track": 0, "sector": sector, "side": 0,
                                "drive": drive, "length": 512}
            ).split("\n", 1)[1]
            if now != dump:
                raise SmokeError(
                    f"boot track sector {sector} on drive {drive} does not "
                    "match the system disc")

    def run_sysgen(self) -> None:
        """SYSGEN: a B: target and the same-drive A: swap.

        Both targets must end up with the source's boot track (compared
        sector by sector through the emulator) and all three system files,
        which SYSGEN itself reads back from the target disc and compares
        with the copy it still holds in memory ("Checking X... ok").  The
        B: target is the distribution image, so the other files must still
        be there afterwards.
        """
        src = ROOT / "build" / "sysgen-src.dsk"
        dst = ROOT / "build" / "sysgen-dst.dsk"
        shutil.copyfile(self.dsk, src)
        shutil.copyfile(ROOT / "build" / "cpm3.dsk", dst)
        old_dsk = self.dsk
        self.dsk = src
        try:
            self.boot()

            self.command("SYSGEN", 300)
            self.expect("SYSGEN usage", "SYSGEN target:")
            self.command("SYSGEN C:", 300)
            self.expect("SYSGEN C: rejected", "SYSGEN target:")

            # The source's boot track, for comparing the targets against.
            boot = {}
            for sector in range(1, 10):
                boot[sector] = self.mcp.call(
                    "sector_read", {"track": 0, "sector": sector, "side": 0,
                                    "drive": 0, "length": 512}
                ).split("\n", 1)[1]

            # --- B: target: the distribution image, files must survive ---
            self.log("SYSGEN B:")
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.mcp.call("load", {"file": str(dst), "drive": "B"})
            self.command("SYSGEN B:", 400)
            self.wait_for(["The disc must be formatted"], frames=50,
                          attempts=4)
            self.key("enter", 300)
            self.wait_for(["Done - the target disc is bootable."], frames=600,
                          attempts=60)
            self.expect("SYSGEN B:",
                        "Source: SS, 40 tracks, 9 sectors.",
                        "Writing the boot track...",
                        "Writing CPM3.SYS... ok",
                        "Checking CCP.COM... ok",
                        "Done - the target disc is bootable.")
            self.check_boot_track(boot, drive=1)
            # Let the CCP take over again before typing the next command.
            self.mcp.call("run", {"frames": 2000})
            self.command("STAT B:CPM3.SYS", 800)
            self.expect("SYSGEN CPM3.SYS", "CPM3.SYS", "16K", "1 file(s)")
            self.command("STAT B:CCP.COM", 600)
            self.expect("SYSGEN CCP.COM", "CCP.COM", "4K", "1 file(s)")
            # The target was the distribution image: its own files survive.
            self.command("STAT B:FORMAT.COM", 600)
            self.expect("SYSGEN kept the other files",
                        "FORMAT.COM", "1 file(s)")

            # --- Same drive: the system is buffered, then the discs swap ---
            self.log("SYSGEN A:")
            self.mcp.call("eject", {"target": "disk", "drive": "B"})
            self.command("SYSGEN A:", 400)
            self.wait_for(["The disc must be formatted"], frames=50,
                          attempts=4)
            self.key("enter", 300)
            self.wait_for(["TARGET disc in A:"], frames=400, attempts=20)
            self.mcp.call("eject", {"target": "disk", "drive": "A"})
            self.mcp.call("load", {"file": str(dst), "drive": "A"})
            self.key("enter", 300)
            self.wait_for(["Done - the target disc is bootable."], frames=600,
                          attempts=60)
            self.expect("SYSGEN A:",
                        "Checking CPM3.SYS... ok",
                        "Checking CCP.COM... ok",
                        "Done - the target disc is bootable.")
            self.check_boot_track(boot, drive=0)
            self.mcp.call("run", {"frames": 2000})
            self.command("STAT CPM3.SYS", 600)
            self.expect("SYSGEN A: CPM3.SYS", "CPM3.SYS", "16K")
        finally:
            self.dsk = old_dsk
            for path in (src, dst):
                try:
                    path.unlink()
                except OSError:
                    pass

    def run_bbcbasic(self) -> None:
        """BBC BASIC must start from the distribution image when it is on it.

        BBC BASIC (Z80) is an optional local reference binary; a fresh
        checkout (and CI) has no copy, so this check skips quietly then.
        """
        dist = ROOT / "build" / "cpm3.dsk"
        if not dist.exists():
            self.log("BBC BASIC: no distribution image; skipped")
            return
        tools = str(ROOT / "tools")
        if tools not in sys.path:
            sys.path.insert(0, tools)
        import mkdsk  # noqa: E402

        image = mkdsk.DSKImage().load(dist)
        names = {image._read_dir_entry(i)[1:12]
                 for i in range(mkdsk.DIR_ENTRIES)
                 if image._read_dir_entry(i)[0] != 0xE5}
        if b"BBCBASICCOM" not in names:
            self.log("BBC BASIC not on the distribution image; skipped")
            return

        scratch = ROOT / "build" / "bbcbasic-test.dsk"
        shutil.copyfile(dist, scratch)
        self.log("BBC BASIC on the distribution image")
        old_dsk = self.dsk
        self.dsk = scratch
        try:
            self.boot()
            self.command("BBCBASIC", 2500)
            self.wait_for(["BBC BASIC (Z80)", ">"], frames=500, attempts=12)
        finally:
            self.dsk = old_dsk
            try:
                scratch.unlink()
            except OSError:
                pass

    def run_stltest(self) -> None:
        """Status line: TE_STL contract and the 23-row fast scroll."""
        self.log("STLTEST")
        self.command("STLTEST", 1500)
        self.wait_for(["STL..OK"], frames=300, attempts=10)
        if "FAIL" in self.text():
            raise SmokeError("STLTEST reported a failure")

    def run_m80test(self) -> None:
        """24x80: TE_ASK width, auto-flip cursor, and returning to 51."""
        self.log("M80TEST")
        self.command("M80TEST", 2000)
        self.wait_for(["M80..OK"], frames=300, attempts=10)
        if "FAIL" in self.text():
            raise SmokeError("M80TEST reported a failure")

    @staticmethod
    def _m80_row_ref(buf: bytes, off: int, row: int, scan: int,
                     cols: int) -> bytes:
        """Render one 51-column text row the way the BIOS should."""
        font = (ROOT / "src" / "bios" / "font51.bin").read_bytes()
        line = bytearray(32)
        for c in range(cols):
            glyph = font[buf[row * 80 + off + c] * 8 + scan]
            x = c * 5
            for k in range(5):
                if (glyph >> (7 - k)) & 1:
                    p = x + k
                    line[p >> 3] |= 0x80 >> (p & 7)
        return bytes(line)

    def run_m80bit(self) -> None:
        """24x80: the fast page flip leaves the right bitmap.

        M80BIT puts 'W' at logical column 29, moves to column 51 (which flips
        to page 29) and writes 'Q' there.  The visible bitmap is compared with
        a reference render of the logical buffer, so a wrong shift direction
        or a bad re-render source is caught.
        """
        self.log("M80BIT")
        self.command("M80BIT", 2000)
        self.wait_for(["M80BIT..OK"], frames=300, attempts=10)
        cols = self.memory(4, label_address("scr_cols"), 1)[0]
        off = self.memory(6, 0xA8C2, 1)[0]
        if (cols, off) != (51, 29):
            raise SmokeError(f"M80BIT: cols={cols}, off={off}, expected 51/29")
        buf = self.memory(5, 0x5B00, 80 * 24)
        for row in range(3):
            for scan in range(8):
                y = row * 8 + scan
                addr = 0x4000 + ((y & 0xC0) << 5) + ((y & 7) << 8) + \
                       ((y & 0x38) << 2)
                got = self.memory(5, addr, 32)
                want = self._m80_row_ref(buf, off, row, scan, cols)
                if got != want:
                    raise SmokeError(
                        f"M80BIT: bitmap mismatch at row {row} scan {scan}: "
                        f"{got.hex()} != {want.hex()}")
        # The program waits for a key, then leaves 24x80 itself.
        self.key("z")
        for _ in range(10):
            if self.memory(6, 0xA8C1, 1)[0] == 0:
                break
            self.mcp.call("run", {"frames": 100})
        if self.memory(6, 0xA8C1, 1)[0] != 0:
            raise SmokeError("M80BIT: 24x80 mode was not left")

    def run_set24x80(self) -> None:
        """SET24X80.COM enters/leaves 24x80 from the prompt."""
        self.log("SET24X80")
        for args, want, label in (("", 1, "SET24X80"),
                                  (" OFF", 0, "SET24X80 OFF"),
                                  (" ON", 1, "SET24X80 ON"),
                                  (" OFF", 0, "SET24X80 OFF (2)")):
            self.command("SET24X80" + args, 900)
            got = self.memory(6, 0xA8C1, 1)[0]
            if got != want:
                raise SmokeError(f"{label}: mode80={got}, expected {want}")
            self.expect(label + " prompt", "A>")
        self.command("SET24X80 JUNK", 700)
        self.expect("SET24X80 usage", "SET24X80 [ON|OFF]")

    def run_disktest(self) -> None:
        self.log("DISKTEST")
        self.mcp.call("type", {"text": "DISKTEST"})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": 200})
        self.record()
        for _ in range(8):
            self.record()
            screen = self.text()
            if "Press RETURN" in screen:
                self.mcp.call("key", {"name": "enter"})
                self.mcp.call("run", {"frames": 1500})
                continue
            if "A>" in screen and any("T29 " in line for line in self.history):
                break
            self.mcp.call("run", {"frames": 1200})
        else:
            self.record()
            screen = self.text()
            if not ("A>" in screen and
                    any("T29 " in line for line in self.history)):
                raise SmokeError("DISKTEST did not finish:\n" + screen)

        history = "\n".join(self.history)
        missing = [n for n in range(1, 30)
                   if not any(f"T{n} " in line and "PASS" in line
                              for line in self.history)]
        if missing:
            raise SmokeError(f"DISKTEST missing PASS for T{missing}")
        # T30 is the 16-bit block test; without a 16-bit B: it must skip,
        # not fail.  The late 720K run below exercises the real thing.
        if not any("T30 " in line and "SKIP" in line for line in self.history):
            raise SmokeError("DISKTEST T30 did not skip without a 16-bit B:")
        if any(" FAIL" in line for line in self.history):
            raise SmokeError("DISKTEST reported a failure:\n" + history)
        self.expect("DISKTEST prompt", "A>")

    def run_bdostest(self) -> None:
        self.log("BDOSTEST")
        self.mcp.call("type", {"text": "BDOSTEST"})
        self.mcp.call("key", {"name": "enter"})
        self.mcp.call("run", {"frames": 3500})
        for _ in range(12):
            self.record()
            screen = self.text()
            if "Press RETURN" in screen:
                self.mcp.call("key", {"name": "enter"})
                self.mcp.call("run", {"frames": 1500})
                continue
            if "Done." in screen:
                break
            self.mcp.call("run", {"frames": 1200})
        else:
            raise SmokeError("BDOSTEST did not finish:\n" + self.text())
        lines = [l for l in self.history if re.match(r"^F\d", l.strip())]
        failures = [l for l in lines if "FAIL" in l]
        if failures:
            raise SmokeError("BDOSTEST failures:\n" + "\n".join(failures))
        if not any("F59 LOADOVL" in l for l in self.history):
            raise SmokeError("BDOSTEST did not reach F59")
        if not any("F111 PRTBLK" in l and "F111OK" in l
                   for l in self.history):
            raise SmokeError("BDOSTEST F111 did not print its block")
        if not any("F104 SETDATE" in l for l in self.history):
            raise SmokeError("BDOSTEST did not reach F104")

    def run_ccp(self) -> None:
        self.command("DIR", 500)
        listing = self.text()
        self.expect("DIR", "CPM3     SYS", "SYSTEST  COM", "DISKTEST COM",
                    "SMOKE    TXT", screen=listing)

        # SMOKE.TXT is built from src/test/smoke.txt, so TYPE works even on a
        # checkout without the untracked references/ directory.
        self.command("TYPE SMOKE.TXT", 400)
        self.expect("TYPE", "SMOKE OK")

        self.command("HELP", 500)
        self.expect("HELP", "Built-in commands:", "DIR", "ERA", "REN", "USER")
        if "SCREEN -" in self.text():
            raise SmokeError("HELP still advertises a SCREEN built-in")

        # SCREEN is SCREEN.COM, not a built-in: the command loads from disk.
        self.command("SCREEN", 500)
        self.expect("SCREEN query", "Mode: 51 columns")

        self.command("SCREEN 32", 700)
        if self.memory(4, self.scr_cols, 1)[0] != 32:
            raise SmokeError("SCREEN 32 did not set scr_cols=32")
        self.expect("SCREEN 32 prompt", "A>")
        self.command("SCREEN 51", 700)
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("SCREEN 51 did not restore scr_cols=51")
        self.expect("SCREEN 51 prompt", "A>")

        # DATE.COM is built from source, so it is present on every image.
        self.command("DATE", 700)
        if not re.search(r"\d\d/\d\d/\d\d\d\d", self.text()):
            raise SmokeError("DATE did not print a date:\n" + self.text())

        # SUBMIT.COM and SMOKE.SUB are built from source, so they are on
        # every image.  Check both the explicit command and the implicit
        # "SMOKE" -> SUBMIT SMOKE.SUB chain.
        if "SUBMIT   COM" in listing and "SMOKE    SUB" in listing:
            self.command("SUBMIT SMOKE.SUB", 2000)
            # SMOKE.SUB runs HELP then DIR; check the last help line rather
            # than the header, which can scroll off above the listing.
            self.expect("SUBMIT file", "This help", "CPM3     SYS", "A>")
            self.command("SMOKE", 2000)
            self.expect("SUBMIT chain", "This help", "CPM3     SYS", "A>")
            self.command("SUBMIT NOPE.SUB", 900)
            self.expect("SUBMIT missing", "No 'SUB' File Found", "A>")
            if "PARAM    SUB" in listing:
                self.command("SUBMIT PARAM SMOKE.TXT *.TXT", 2500)
                self.expect("SUBMIT parameters", "SMOKE OK", "SMOKE    TXT", "A>")
                self.command("SUBMIT PARAM", 1200)
                self.expect("SUBMIT missing parameter",
                            "SUBMIT parameter missing", "A>")
        else:
            self.log("SUBMIT.COM/SMOKE.SUB not on the disk; skipping SUBMIT checks")

        # RENAME.COM and PIP.COM come from the untracked references/binaries
        # directory; skip them on a source-only image.
        if "RENAME   COM" in listing:
            # CP/M RENAME takes NEW then OLD.
            self.command("RENAME TEST.TXT SMOKE.TXT", 600)
            self.command("DIR A:*.TXT", 500)
            self.expect("RENAME", "TEST     TXT")
            self.command("RENAME SMOKE.TXT TEST.TXT", 600)
            self.command("DIR A:*.TXT", 500)
            self.expect("RENAME restore", "SMOKE    TXT")
        else:
            self.log("RENAME.COM not on the disk; skipping RENAME checks")

        self.command("DIR D:", 400)
        self.expect("invalid drive", "No files")

        self.command("DIR C:", 400)
        self.expect("C: empty", "No files")

        self.command("C:", 300)
        self.expect("C: prompt", "C>")
        self.command("A:", 300)
        self.expect("A: prompt", "A>")

        if "PIP      COM" in listing:
            self.command("PIP C:=A:DATE.COM", 1200)
            self.command("DIR C:", 500)
            self.expect("C: after PIP", "DATE     COM")

            self.command("C:", 300)
            self.expect("C: prompt", "C>")
            self.command("DATE", 700)
            if not re.search(r"\d\d/\d\d/\d\d\d\d", self.text()):
                raise SmokeError("DATE did not print a date:\n" + self.text())
            self.command("A:", 300)
            self.expect("A: prompt", "A>")
        else:
            self.log("PIP.COM not on the disk; skipping the C: copy check")

    def run_era(self) -> None:
        """ERA: usage, missing file, the *.* guard and a real delete."""
        self.command("ERA", 500)
        self.expect("ERA usage", "ERA filespec")

        self.command("ERA NOSUCH.TXT", 600)
        self.expect("ERA missing", "No file")

        # An all-wildcard delete must ask first; N leaves the disk alone.
        self.command("ERA *.*", 600)
        self.expect("ERA *.* prompt", "ALL (Y/N)?")
        self.key("n", 100)
        self.mcp.call("run", {"frames": 500})
        self.expect("ERA *.* aborted", "A>")
        self.command("DIR CPM3.SYS", 500)
        self.expect("ERA *.* deleted nothing", "CPM3     SYS")

        # Real deletion, using PIP to make a copy when it is on the disk.
        self.command("DIR PIP.COM", 500)
        if "PIP      COM" not in self.text():
            self.log("PIP.COM not on the disk; skipping the ERA delete check")
            return
        self.command("PIP ERA1.TXT=SMOKE.TXT", 800)
        self.command("DIR ERA1.TXT", 500)
        self.expect("ERA copy exists", "ERA1     TXT")
        self.command("ERA ERA1.TXT", 500)
        self.command("DIR ERA1.TXT", 500)
        self.expect("ERA deleted the file", "No files")

    def run_ren(self) -> None:
        """REN NEW=OLD: usage, missing old, a real rename and wildcards."""
        self.command("REN", 500)
        self.expect("REN usage", "REN new=old")

        self.command("REN NEW.TXT=NOSUCH.TXT", 600)
        self.expect("REN missing", "No file")

        # PIP is optional; without it there is nothing safe to rename.
        self.command("DIR PIP.COM", 500)
        if "PIP      COM" not in self.text():
            self.log("PIP.COM not on the disk; skipping the REN rename check")
            return
        self.command("PIP REN1.TXT=SMOKE.TXT", 800)
        self.command("REN REN2.TXT=REN1.TXT", 600)
        self.command("DIR REN2.TXT", 500)
        self.expect("REN new name", "REN2     TXT")
        self.command("DIR REN1.TXT", 500)
        self.expect("REN old name gone", "No files")

        # Wildcards are refused and leave the file alone.
        self.command("REN BAD.TXT=*.TXT", 600)
        self.expect("REN wildcard", "No wildcards")
        self.command("DIR REN2.TXT", 500)
        self.expect("REN wildcard changed nothing", "REN2     TXT")

        # RENAME.COM argument order, without the '='.
        self.command("PIP REN3.TXT=SMOKE.TXT", 800)
        self.command("REN REN4.TXT REN3.TXT", 600)
        self.command("DIR REN4.TXT", 500)
        self.expect("REN space form", "REN4     TXT")
        self.command("DIR REN3.TXT", 500)
        self.expect("REN space form old gone", "No files")

        self.command("ERA REN2.TXT", 500)
        self.command("ERA REN4.TXT", 500)
        self.command("DIR REN?.TXT", 500)
        self.expect("REN cleanup", "No files")

    def run_user(self) -> None:
        """USER: query, switch user areas, reject out-of-range values."""
        self.command("USER", 500)
        self.expect("USER query", "User 0")

        self.command("USER 3", 500)
        self.command("USER", 500)
        self.expect("USER set", "User 3")
        self.command("DIR", 600)
        self.expect("USER 3 has no files", "No files")

        self.command("USER 10", 500)
        self.command("USER", 500)
        self.expect("USER two digits", "User 10")

        self.command("USER 16", 500)
        self.expect("USER range", "USER n (0-15)")
        self.command("USER X", 500)
        self.expect("USER junk", "USER n (0-15)")

        self.command("USER 0", 500)
        self.command("DIR CPM3.SYS", 500)
        self.expect("USER 0 restored", "CPM3     SYS")
        self.command("USER", 500)
        self.expect("USER back to zero", "User 0")

    def run_screen64(self) -> None:
        """SCREEN 64: 4-pixel font, two characters per attribute cell."""
        self.command("SCREEN 64", 800)
        if self.memory(4, self.scr_cols, 1)[0] != 64:
            raise SmokeError("SCREEN 64 did not set scr_cols=64")
        font = self.memory(4, self.font_ptr, 2)
        if int.from_bytes(font, "little") != 0x9400:
            raise SmokeError(
                f"SCREEN 64 selected font {font.hex()}, expected 9400")
        if self.memory(3, self.scb_conwidth, 1)[0] != 63:
            raise SmokeError("SCREEN 64 did not update SCB conwidth to 63")
        self.expect("SCREEN 64 prompt", "A>")

        # The prompt sits on the first populated row: two 4-pixel glyphs
        # packed into one byte.  Bank 5 is not mapped while the CPU idles in
        # the BDOS, but the last _page_out flushed it, so the cold copy is
        # current and needs no paging tricks.
        ccp = (ROOT / "src" / "bios" / "font64.bin").read_bytes()
        rows = self.screen()
        row = next(i for i, line in enumerate(rows) if line.startswith("A>"))
        expect = bytes((ccp[ord("A") * 8 + r] & 0xF0) | (ccp[ord(">") * 8 + r] >> 4)
                       for r in range(8))
        base = 0x4000 + (row >> 3) * 0x800 + (row & 7) * 0x20
        got = bytes(self.memory(5, base + r * 0x100, 1)[0] for r in range(8))
        if got != expect:
            raise SmokeError(
                f"64-col glyphs at row {row}: screen {got.hex()} != font {expect.hex()}")

        # DIR formats from the SCB width: 64 columns means four entries a line.
        self.command("DIR", 900)
        listing = self.text()
        line = next((l for l in listing.splitlines() if "FONT32" in l), "")
        if line.count(" : ") < 3:
            raise SmokeError(
                f"DIR did not use four columns at 64 -- line: {line!r}\n{listing}")
        self.log(f"DIR at 64: {line.strip()}")

        # Scrolling at 64: repeated listings must scroll cleanly, not smear.
        # Every populated row must still be a directory line, a command echo
        # or the prompt - garbled rows mean the row table/width went wrong.
        for _ in range(3):
            self.command("DIR", 900)
        rows = self.screen()
        populated = sum(1 for r in rows if r.strip())
        if populated < 15:
            raise SmokeError(
                f"64-col scroll left only {populated} populated rows")
        bad = [r for r in rows if r.strip()
               and not (r.startswith("A:") or r.startswith("A>"))]
        if bad:
            raise SmokeError(f"64-col scroll garbled rows: {bad[:3]}")

        self.command("SCREEN 51", 800)
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("SCREEN 51 did not restore 51 columns")
        self.expect("SCREEN 51 prompt", "A>")

    def run_pagination(self) -> None:
        """PAGE console mode: stop at the page height and resume on RETURN."""
        if self.memory(4, self.scr_cols, 1)[0] != 51:
            raise SmokeError("expected 51 columns before the pagination test")

        # Make the result independent of the ESC 4/ESC 3 tests above.
        self.command("SETDEF [PAGE]", 700)
        self.expect("SETDEF [PAGE]", "A>")

        # The fixture has 30 lines; a page holds conpage+1 = 24 rows, so the
        # first page must stop at LINE 24 and withhold 25..30.
        self.command("TYPE PAGE.TXT", 900)
        for _ in range(8):
            if "Press RETURN" in self.text():
                break
            self.mcp.call("run", {"frames": 400})
            self.record()
        else:
            raise SmokeError("no page pause after 30 lines:\n" + self.text())

        screen = self.text()
        for required in ("LINE 20", "LINE 24"):
            if required not in screen:
                raise SmokeError(
                    f"page pause fired too early ({required} missing):\n"
                    + screen)
        for withheld in ("LINE 25", "LINE 30"):
            if withheld in screen:
                raise SmokeError(
                    f"page pause did not withhold {withheld}:\n{screen}")

        # RETURN resumes; the pager prompt must be erased, not left behind.
        self.mcp.call("key", {"name": "enter"})
        for _ in range(8):
            self.mcp.call("run", {"frames": 400})
            self.record()
            screen = self.text()
            if "LINE 30" in screen and "Press RETURN" not in screen:
                break
        else:
            raise SmokeError("paging did not resume:\n" + self.text())

        # NOPAGE: the same file prints to the end with no prompt and no key.
        self.command("SETDEF [NOPAGE]", 700)
        self.command("TYPE PAGE.TXT", 1500)
        screen = self.text()
        if "Press RETURN" in screen:
            raise SmokeError("[NOPAGE] still paused:\n" + screen)
        if "LINE 30" not in screen:
            raise SmokeError("[NOPAGE] lost the end of the file:\n" + screen)

        self.command("SETDEF [PAGE]", 700)

    def run_block16(self) -> None:
        """B: 720K PCW image: 2K blocks and 16-bit block numbers."""
        image = ROOT / "build" / "cpm3_720.dsk"
        if not image.exists():
            raise SmokeError(
                "build/cpm3_720.dsk is missing; run build.cmd first")
        self.log("mount 720K image on B:")
        self.mcp.call("load", {"file": str(image), "drive": "B"})

        self.command("DIR B:", 1200)
        self.expect("720K DIR", "HELLO16  TXT")
        self.command("TYPE B:HELLO16.TXT", 1200)
        self.expect("720K TYPE", "720K block test", "Line three.")

        # T30 in DISKTEST creates/writes/sizes/truncates/deletes a file on
        # B: and checks the free-space deltas, which only add up with
        # 16-bit block numbers and 2K blocks.
        self.command("DISKTEST 30", 3500)
        for _ in range(12):
            if "T30 " in self.text():
                break
            self.mcp.call("run", {"frames": 600})
            self.record()
        self.expect("16-bit block test", "T30 B16 16-bit blocks PASS")

    def run_ccp_external(self) -> None:
        """CCP.COM lives on the disk and is staged at CCP_STAGE on cold boot."""
        ccp = (ROOT / "build" / "CCP.COM").read_bytes()
        if not ccp:
            raise SmokeError("build/CCP.COM is empty")

        staged = self.memory(6, self.ccp_stage, len(ccp))
        if staged != ccp:
            raise SmokeError(
                "CCP.COM is not staged at %04X in bank 6 "
                "(read %s...)" % (self.ccp_stage, staged[:8].hex()))

        image = (ROOT / "build" / "CPM3.SYS").read_bytes()
        if image.find(ccp) >= 0:
            raise SmokeError("CPM3.SYS still embeds the CCP image")

        self.command("DIR CCP.COM", 500)
        self.expect("CCP.COM on disk", "A: CCP")

        # Every command above already warm-booted from the staged copy; prove
        # the CCP is a real file by looking at its size.
        self.log(f"CCP.COM {len(ccp)} bytes, CPM3.SYS {len(image)} bytes")

    def check_fdc(self) -> None:
        log = self.mcp.call("fdc_log", {})
        bad = [l for l in log.splitlines()
               if "retry" in l.lower() or "rejected" in l.lower()]
        if bad:
            raise SmokeError("FDC retry/error lines:\n" + "\n".join(bad[:20]))

    def run(self, quick: bool = False) -> None:
        self.boot()
        self.run_loader_stage()
        self.run_bank6_sentinels()
        self.run_systest()
        self.run_xtetest()
        self.run_stltest()
        self.run_m80test()
        self.run_m80bit()
        self.run_set24x80()
        # SYSTEST deliberately changes and restores the delimiter; DIR must
        # still be clean afterwards.
        self.command("DIR", 500)
        self.expect("DIR after SYSTEST", "CPM3     SYS", "A>")
        self.run_disktest()
        self.run_bdostest()
        self.run_ccp()
        self.run_era()
        self.run_ren()
        self.run_user()
        self.run_screen64()
        self.run_terminal_escapes()
        self.run_pagination()
        self.run_block16()
        self.run_ccp_external()
        self.run_stat()
        # Check before the scratch-image format test reboots the machine.
        self.check_bank6_sentinels()
        if quick:
            self.log("quick mode: skipping the destructive format test")
        else:
            self.run_xtetest_format()
            self.run_format()
            self.run_diskcopy()
            self.run_sysgen()
        # The distribution image is a different file; this reboots into it.
        self.run_bbcbasic()
        self.check_fdc()
        self.log("all checks passed")


def prepare_test_image(dsk: Path) -> Path:
    """Add optional third-party test binaries to a scratch copy of the image.

    RENAME.COM is deliberately not bundled into the distribution image - the
    CCP's built-in REN covers renaming - but the smoke keeps exercising a real
    third-party F23 caller when references/binaries/ is present.

    DISKTEST writes a 17K multi-extent file, and a developer image that
    build.cmd populated from references/binaries/ can be too full for that.
    Any large optional utilities the suite never runs (BBCBASIC.COM,
    NULU11.COM) are therefore dropped from the scratch copy if present; the
    scratch copy is disposable anyway.
    """
    rename = ROOT / "references" / "binaries" / "RENAME.COM"
    if not rename.exists():
        return dsk
    tools = str(ROOT / "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    import mkdsk  # noqa: E402

    image = mkdsk.DSKImage().load(dsk)
    for i in range(mkdsk.DIR_ENTRIES):
        if image._read_dir_entry(i)[1:12] == b"RENAME  COM":
            return dsk

    out = ROOT / "build" / "smoke.dsk"
    shutil.copyfile(dsk, out)
    image = mkdsk.DSKImage().load(out)
    for name in ("BBCBASIC.COM", "NULU11.COM"):
        if image.delete_cpm_file(name):
            print(f"[smoke] {name} dropped from {out.name} "
                  "(optional, keeps room for DISKTEST)")
    if image.add_cpm_file("RENAME.COM", rename.read_bytes()) is False:
        return dsk
    image.save(out)
    print(f"[smoke] RENAME.COM added to {out.name} for the test run")
    return out


def find_zx84(arg: str | None) -> Path:
    candidates = []
    if arg:
        candidates.append(Path(arg))
    env = os.environ.get("ZX84_DIR")
    if env:
        candidates.append(Path(env))
    candidates.append(ROOT.parent / "zx84")
    candidates.append(Path(r"F:\src\zx\zx84"))
    for c in candidates:
        if (c / "mcp" / "server.ts").exists():
            return c
    raise SmokeError(
        "zx84 not found; pass --zx84 PATH or set ZX84_DIR "
        "(expected an mcp/server.ts)")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3-test.dsk"),
                    help="DSK image to boot (the test image carries the "
                         "on-disk test programs)")
    ap.add_argument("--model", default="zx128kplus3")
    ap.add_argument("--quick", action="store_true",
                    help="skip the destructive DD_FORMAT test on a scratch image")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    dsk = Path(args.dsk)
    if not dsk.is_absolute():
        dsk = ROOT / dsk
    if not dsk.exists():
        print(f"error: {dsk} does not exist; run build.cmd first",
              file=sys.stderr)
        return 2
    dsk = prepare_test_image(dsk)

    try:
        zx84 = find_zx84(args.zx84)
        mcp = MCP(zx84, args.model)
        try:
            smoke = Smoke(mcp, dsk, args.verbose)
            smoke.run(quick=args.quick)
        finally:
            mcp.close()
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
