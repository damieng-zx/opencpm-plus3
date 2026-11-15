#!/usr/bin/env python3
"""Time the checksum algorithms in CKBENCH.COM at 3.5 MHz.

The guest does no timing.  CKBENCH.COM writes a phase marker to MARKER with a
memory watchpoint armed: marker 0x10+N opens phase N and 0x20+N closes it, so
the T-states at the two writes bracket exactly the work between them.  That is
the same technique tools/screen_bench.py uses, and it is exact - no polling
granularity, no guest clock.

Every phase hashes the same 16K, so the useful comparison is T-states per
byte, and from that the throughput at 3.5 MHz.

Usage:
    python3 tools/ckbench.py
    python3 tools/ckbench.py --zx84 F:/src/zx/zx84
    python3 tools/ckbench.py --json build/ckbench.json
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

from zx84_smoke import MCP, ROOT, SmokeError, find_zx84

MARKER = 0x3F00
BYTES_PER_PHASE = 16384
CLOCK_HZ = 3_500_000

PHASES = [
    (1, "sum8", "8-bit additive sum"),
    (2, "sum16", "16-bit additive sum"),
    (3, "xor8", "8-bit XOR"),
    (4, "fletcher16", "Fletcher-16 (mod 255)"),
    (5, "crc16_bit", "CRC-16-CCITT, bit at a time"),
    (6, "crc16_tab", "CRC-16-CCITT, byte table"),
    (7, "crc32_nib", "CRC-32, nibble table"),
    (8, "crc32_tab", "CRC-32, byte table"),
    (9, "crc32_tab2", "CRC-32, byte table (second form)"),
]


def tstates(mcp: MCP) -> int:
    txt = mcp.call("registers", {})
    m = re.search(r"T-states:\s*(\d+)", txt)
    if not m:
        raise SmokeError("no T-states in the register dump")
    return int(m.group(1))


def prepare(dest: Path, bench: bytes) -> Path:
    """Copy the distribution image and add CKBENCH.COM."""
    sys.path.insert(0, str(ROOT / "tools"))
    import mkdsk

    shutil.copyfile(ROOT / "build" / "cpm3.dsk", dest)
    image = mkdsk.DSKImage().load(dest)
    if any(n == "CKBENCH.COM" for n, _, _ in image.list_files()):
        image.delete_cpm_file("CKBENCH.COM")
    if image.add_cpm_file("CKBENCH.COM", bench) is False:
        raise SmokeError(f"no room for CKBENCH.COM on {dest.name}")
    image.save(dest)
    return dest


def measure(mcp: MCP, verbose: bool = False) -> list[dict]:
    mcp.call("delete_memory_watchpoint", {})
    mcp.call("memory_watchpoint", {
        "address": f"{MARKER:04X}", "length": 1, "mode": "write"})

    marks: list[tuple[int, int]] = []      # (marker value, T-states at write)
    # MD5 is far slower than everything else, so its phase needs more frames
    # between markers than the watchpoint call returns by default.  Raise the
    # allowance and keep going until the run really stops.
    for _ in range(200):
        hit = mcp.call("continue", {"max_frames": 200000})
        if "Memory watchpoint" not in hit:
            break
        m = re.search(r"=\s*([0-9A-F]{2})\s+PC=", hit)
        marks.append((int(m.group(1), 16) if m else -1, tstates(mcp)))
        if marks[-1][0] == 0xFF:
            break
    mcp.call("delete_memory_watchpoint", {})

    seen = {v for v, _ in marks}
    out = []
    for num, key, label in PHASES:
        opens, closes = 0x10 + num, 0x20 + num
        if opens not in seen or closes not in seen:
            raise SmokeError(
                f"{label}: markers 0x{opens:02X}/0x{closes:02X} missing "
                f"(saw {[f'0x{v:02X}' for v in sorted(seen)]})")
        t0 = next(t for v, t in marks if v == opens)
        t1 = next(t for v, t in marks if v == closes)
        cycles = t1 - t0
        # Phase 10 measures only MD5_STEPS steps, not the full sample.
        steps = 256 if num == 10 else BYTES_PER_PHASE
        per_byte = cycles / steps
        rec = {
            "key": key,
            "label": label,
            "cycles": cycles,
            "tstates_per_byte": per_byte,
            "kb_per_second": (1 / per_byte) * CLOCK_HZ / 1024,
        }
        out.append(rec)
        if verbose:
            print(f"  {label}: {cycles:,} T = "
                  f"{rec['tstates_per_byte']:.2f} T/byte", flush=True)
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--zx84")
    ap.add_argument("--model", default="zx128kplus3")
    ap.add_argument("--json", help="write the raw measurements here")
    ap.add_argument("--keep", action="store_true",
                    help="keep the scratch image")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args(argv)

    bench = ROOT / "build" / "ckbench.com"
    if not bench.exists():
        bench = ROOT / "build" / "CKBENCH.COM"
    if not bench.exists():
        print("error: build/ckbench.com is missing; run build.cmd first",
              file=sys.stderr)
        return 2

    scratch = ROOT / "build" / "ckbench-test.dsk"
    prepare(scratch, bench.read_bytes())

    mcp = MCP(find_zx84(args.zx84), args.model)
    try:
        mcp.call("model", {"target": args.model})
        mcp.call("load", {"file": str(scratch)})
        mcp.call("disk_boot", {})
        mcp.call("run", {"frames": 1000})
        mcp.call("type", {"text": "CKBENCH"})
        mcp.call("key", {"name": "enter"})
        results = measure(mcp, args.verbose)
    finally:
        mcp.close()
        if not args.keep:
            try:
                scratch.unlink()
            except OSError:
                pass

    print()
    print(f"{'algorithm':36} {'T/byte':>8} {'cycles':>12} {'KB/s':>7}")
    print("-" * 66)
    for r in results:
        print(f"{r['label']:36} {r['tstates_per_byte']:8.2f} "
              f"{r['cycles']:12,} {r['kb_per_second']:7.1f}")

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2) + "\n",
                                   encoding="utf-8")
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
