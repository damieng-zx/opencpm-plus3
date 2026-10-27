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
    for line in listing.read_text(encoding="utf-8", errors="replace").splitlines():
        m = re.match(rf"^\s*\d+\+\s+([0-9A-F]{{4}})\b.*\b{re.escape(name)}:", line)
        if m:
            return int(m.group(1), 16)
    raise SmokeError(f"{name} label not found in build/bios.lst")


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
        self.scr_cols = label_address("scr_cols")
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
        if cols not in (32, 51):
            cols = COLS
        data = self.memory(4, self.cb, cols * ROWS)
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
            if "A>" in screen and any("T22 " in line for line in self.history):
                break
            self.mcp.call("run", {"frames": 1200})
        else:
            self.record()
            screen = self.text()
            if not ("A>" in screen and
                    any("T22 " in line for line in self.history)):
                raise SmokeError("DISKTEST did not finish:\n" + screen)

        history = "\n".join(self.history)
        missing = [n for n in range(1, 23)
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
        self.expect("HELP", "Built-in commands:", "DIR", "TYPE", "SCREEN")

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
            self.expect("SUBMIT file", "Built-in commands:", "CPM3     SYS", "A>")
            self.command("SMOKE", 2000)
            self.expect("SUBMIT chain", "Built-in commands:", "CPM3     SYS", "A>")
            self.command("SUBMIT NOPE.SUB", 900)
            self.expect("SUBMIT missing", "No 'SUB' File Found", "A>")
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

    def check_fdc(self) -> None:
        log = self.mcp.call("fdc_log", {})
        bad = [l for l in log.splitlines()
               if "retry" in l.lower() or "rejected" in l.lower()]
        if bad:
            raise SmokeError("FDC retry/error lines:\n" + "\n".join(bad[:20]))

    def run(self) -> None:
        self.boot()
        self.run_systest()
        # SYSTEST deliberately changes and restores the delimiter; DIR must
        # still be clean afterwards.
        self.command("DIR", 500)
        self.expect("DIR after SYSTEST", "CPM3     SYS", "A>")
        self.run_disktest()
        self.run_bdostest()
        self.run_ccp()
        self.check_fdc()
        self.log("all checks passed")


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
