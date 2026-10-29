#!/usr/bin/env python3
"""Automated zx84 smoke test for the built CP/M +3 image.

Boots build/cpm3.dsk through the zx84 MCP server, runs the on-disk test
programs and a few CCP flows, and asserts the 51x24 character buffer.  This
is the automated counterpart of docs/mcp-smoke-test.md.

Usage:
    python3 tools/zx84_smoke.py
    python3 tools/zx84_smoke.py --zx84 F:/src/zx/zx84 --dsk build/cpm3.dsk
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
                self.memory(4, self.esc_state, 1)[0],
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
        row = self.memory(4, self.cursor_row, 1)[0]
        col = self.memory(4, self.cursor_col, 1)[0]
        if (row, col) != (0, 31):
            raise SmokeError(f"ESC w: cursor {row}/{col}, expected 0/31")
        self.finish_prompt()

        self.esc("v")
        if self.memory(4, self.scr_wrap, 1)[0] != 1:
            raise SmokeError("ESC v did not set the wrap flag")
        self.esc("H")
        self.mcp.call("type", {"text": "X" * 40})
        self.mcp.call("run", {"frames": 1200})
        if self.memory(4, self.cursor_row, 1)[0] == 0:
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
        self.wait_for(["19.KTAB.."], frames=500, attempts=8)
        self.key("z")
        self.wait_for(["DONE"], frames=500, attempts=8)
        screen = self.text()
        # The full run scrolls off the 24-line screen, so check every frame
        # recorded since the test started.
        seen = "\n".join(self.history[start:])
        if "FAIL" in seen:
            raise SmokeError("XTETEST reported a failure:\n" + seen)
        for needle in ("7.RUN..OK", "8.DISK..OK", "9.RW..OK",
                       "11.SETUP..OK", "12.DPB..OK", "13.XDPB..OK",
                       "14.LREAD..OK", "15.LWRITE..OK", "16.KMSPD..OK",
                       "17.KTPUT..OK", "18.KTGET..OK", "19.KTAB..OK",
                       "DONE"):
            if needle not in seen:
                raise SmokeError(
                    f"XTETEST missing {needle!r}:\n" + seen)
        # SCR_RUN_ROUTINE stages its routine at D000h, writes 5Ah to the
        # bottom-right attribute in bank 5 and 1 to the D100h flag.  Later
        # output scrolls the screen, so look for the marker anywhere in the
        # attribute plane rather than at a fixed cell.
        attrs = self.memory(5, 0x5800, 768)
        if 0x5A not in attrs:
            raise SmokeError("SCR_RUN_ROUTINE screen marker 5A not found")
        flag = self.memory(3, 0xD100, 1)[0]
        if flag != 1:
            raise SmokeError(
                f"SCR_RUN_ROUTINE input flag {flag:02X}, expected 01")
        for name, expected in (("motor_off_ticks", 250),
                               ("fdc_spec1", 0x4F),
                               ("fdc_spec2", 0x05)):
            value = self.memory(4, label_address(name), 1)[0]
            if value != expected:
                raise SmokeError(
                    f"DD_SETUP {name} {value:02X}, expected {expected:02X}")
        for name, expected in (("kbd_repeat_delay", 10),
                               ("kbd_repeat_rate", 5)):
            value = self.memory(4, label_address(name), 1)[0]
            if value != expected:
                raise SmokeError(
                    f"KM_SET_SPEED {name} {value}, expected {expected}")
        tokens = self.memory(4, label_address("kbd_token_buf"), 4)
        if tokens != bytes((0x08, 0x2B, 0x00, 0x1F)):
            raise SmokeError(
                f"KM_KT_PUT tokens {tokens!r}, expected [08, 2B, 00, 1F]")
        count = self.memory(4, label_address("kbd_token_count"), 1)[0]
        if count != 0:
            raise SmokeError(f"KM_KT_GET token count {count}, expected 0")
        head = self.memory(4, label_address("kbd_token_head"), 1)[0]
        if head != 2:
            raise SmokeError(f"KM_KT_GET head {head}, expected 2")
        # Test 19 restored the built-in translation for Z after checking it.
        kmtab = self.memory(6, 0xA900, 8)
        if kmtab[4] != 0xFF:
            raise SmokeError(
                f"KM_SET_KEY table[4] {kmtab[4]:02X}, expected FF after reset")
        self.expect("XTETEST prompt", "A>")

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
            # Let the run finish (test 19 waits for a key).
            self.key("z")
            self.wait_for(["DONE"], frames=500, attempts=10)
        finally:
            self.dsk = old_dsk
            try:
                scratch.unlink()
            except OSError:
                pass

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
        line = next((l for l in listing.splitlines() if "CPM3" in l), "")
        if "FONT32" not in line:
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

        # B16TEST creates/writes/sizes/truncates/deletes a file on B: and
        # checks the free-space deltas, which only add up with 16-bit
        # block numbers and 2K blocks.
        self.command("B16TEST", 4500)
        for _ in range(12):
            if "B16 " in self.text():
                break
            self.mcp.call("run", {"frames": 600})
            self.record()
        self.expect("16-bit block test", "B16 PASS")

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

    def run(self) -> None:
        self.boot()
        self.run_systest()
        self.run_xtetest()
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
        self.run_xtetest_format()
        self.check_fdc()
        self.log("all checks passed")


def prepare_test_image(dsk: Path) -> Path:
    """Add optional third-party test binaries to a scratch copy of the image.

    RENAME.COM is deliberately not bundled into the distribution image - the
    CCP's built-in REN covers renaming - but the smoke keeps exercising a real
    third-party F23 caller when references/binaries/ is present.
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
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"),
                    help="DSK image to boot")
    ap.add_argument("--model", default="zx128kplus3")
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
            smoke.run()
        finally:
            mcp.close()
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
