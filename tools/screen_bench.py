#!/usr/bin/env python3
"""Measure screen-rendering throughput on CP/M 3 for the ZX Spectrum +3.

Runs ``SCREENBM.COM`` (``src/test/screenbm.asm``) on a disk image and times
each phase by watching the marker byte the program writes between phases, so
the numbers are Z80 T-states of real work -- nothing is measured inside the
guest and nothing depends on a guest clock.

The same binary runs unchanged on this system and on Locomotive's CP/M Plus,
which is the whole point: ``--dsk`` accepts either.  The program uses only
BDOS function 2 and the escape sequences both systems document (ESC E, ESC H,
ESC Y), after normalising the terminal with ESC 0 / ESC 3 1.

Usage:
    python3 tools/screen_bench.py                        # this build
    python3 tools/screen_bench.py --dsk build/cpm3.dsk
    python3 tools/screen_bench.py --compare /path/locomotive.dsk
    python3 tools/screen_bench.py --compare /path/locomotive.dsk --name Mine

Exit codes: 0 = measured, 1 = failure, 2 = setup error.
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

PHASES = [
    (1, "glyphs", "9384 glyphs (8 pages of 23x51)"),
    (2, "scroll", "640 line feeds (= 640 scrolls)"),
    (3, "clear", "40 x ESC E"),
    (4, "cursor", "2000 x ESC Y 20 5"),
    (5, "page", "4 full screens of 23x51 glyphs, wrapping"),
    (6, "call", "2000 x BDOS fn 2, ignored control code"),
    (7, "noflip", "25 x 51-char rows in 24x80, paging OFF"),
    (8, "flip", "25 x 51-char rows in 24x80, paging ON (one flip each)"),
    (9, "erase", "1000 x ESC K from column 0 (a full row)"),
]
PHASE_OPS = {"glyphs": 9384, "scroll": 640, "clear": 40, "cursor": 2000,
             "page": 4 * 23 * 51, "call": 2000, "noflip": 25, "flip": 25,
             "erase": 1000}


def tstates(mcp: MCP) -> int:
    txt = mcp.call("registers", {})
    m = re.search(r"T-states:\s*(\d+)", txt)
    if not m:
        raise SmokeError("no T-states in the register dump")
    return int(m.group(1))


def prepare(src: Path, bench: bytes, dest: Path) -> None:
    """Copy src to dest and add the benchmark, verifying the result.

    Locomotive's images use a 'MV - CPC format Disk Image (DU54)' header this
    project's writer does not emit; the track data after it is standard
    CPCEMU, so normalise the 34-byte header first.
    """
    sys.path.insert(0, str(ROOT / "tools"))
    import mkdsk  # noqa: E402

    if dest.exists():
        dest.unlink()
    data = bytearray(src.read_bytes())
    if data.startswith(b"MV - CPC ") and not data.startswith(b"MV - CPCEMU"):
        data[0:34] = b"MV - CPCEMU Disk-File\r\nDisk-Info\r\n"
        norm = dest.with_suffix(".normalised.dsk")
        norm.write_bytes(data)
        src = norm

    shutil.copyfile(src, dest)
    image = mkdsk.DSKImage().load(dest)
    before = len(image.list_files())
    had = any(n == "SCREENBM.COM" for n, _, _ in image.list_files())
    if had:
        # The test image already carries the benchmark: replace it.
        image.delete_cpm_file("SCREENBM.COM")
        before -= 1
    if image.add_cpm_file("SCREENBM.COM", bench) is False:
        raise SmokeError(f"no room for SCREENBM.COM on {src.name}")
    image.save(dest)

    # A reused scratch path, or a copy the emulator still holds open, would
    # silently keep the previous contents and stack a second SCREENBM on top.
    check = mkdsk.DSKImage().load(dest)
    names = [n for n, _, _ in check.list_files()]
    if len(names) != before + 1 or names.count("SCREENBM.COM") != 1:
        raise SmokeError(
            f"{dest.name}: expected {before + 1} files with one SCREENBM.COM, "
            f"found {len(names)} ({names.count('SCREENBM.COM')} SCREENBM)")


def measure(mcp: MCP, dsk: Path, verbose: bool = False) -> dict[str, dict]:
    """Boot dsk, run SCREENBM 0, and time every phase from its marker writes."""
    mcp.call("model", {"target": "zx128kplus3"})
    mcp.call("load", {"file": str(dsk)})
    mcp.call("disk_boot", {})
    mcp.call("run", {"frames": 1500})

    mcp.call("delete_memory_watchpoint", {})
    mcp.call("memory_watchpoint", {
        "address": f"{MARKER:04X}", "length": 1, "mode": "write"})
    mcp.call("type", {"text": "SCREENBM 0"})
    mcp.call("key", {"name": "enter"})

    marks: list[tuple[int, int]] = []   # (marker value, T-states at the write)
    for _ in range(40):
        hit = mcp.call("continue", {"max_frames": 20000})
        if "Memory watchpoint" not in hit:
            break
        m = re.search(r"=\s*([0-9A-F]{2})\s+PC=", hit)
        marks.append((int(m.group(1), 16) if m else -1, tstates(mcp)))
        if marks[-1][0] == 0:
            break
    mcp.call("delete_memory_watchpoint", {})

    values = [v for v, _ in marks]
    for num, name, desc in PHASES:
        if 0x10 + num not in values or 0x20 + num not in values:
            raise SmokeError(
                f"{name}: marker 0x{0x10 + num:02X}/0x{0x20 + num:02X} missing "
                f"(saw {[f'0x{v:02X}' for v in values]})")

    out: dict[str, dict] = {}
    for num, name, desc in PHASES:
        t0 = next(t for v, t in marks if v == 0x10 + num)
        t1 = next(t for v, t in marks if v == 0x20 + num)
        delta = t1 - t0
        out[name] = {"tstates": delta, "ops": PHASE_OPS[name],
                     "per_op": delta / PHASE_OPS[name], "desc": desc}
        if verbose:
            print(f"  {name:<7}{delta:>13,} T  "
                  f"{out[name]['per_op']:>9.1f} T/op")
    return out


def show(name: str, result: dict[str, dict]) -> None:
    print(f"\n{name}")
    print(f"  {'phase':<8}{'T-states':>13}{'T/op':>10}  workload")
    for _, key, desc in PHASES:
        r = result[key]
        print(f"  {key:<8}{r['tstates']:>13,}{r['per_op']:>10.1f}  {desc}")
    flips = result["flip"]["tstates"] - result["noflip"]["tstates"]
    glyph = result["glyphs"]["per_op"]
    per = (flips / 25) - glyph
    print(f"  {'(flip)':<8}{flips:>13,}{per:>10.1f}"
          f"  derived: phase 8 - phase 7 - one glyph")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3-test.dsk"),
                    help="disk image to measure (default: this build's test image)")
    ap.add_argument("--name", default="OpenCP/M +3",
                    help="label for --dsk in the output")
    ap.add_argument("--compare", metavar="DSK", action="append", default=[],
                    help="another image to measure and tabulate against --dsk "
                         "(e.g. Locomotive's); repeatable")
    ap.add_argument("--bin", default=str(ROOT / "build" / "screenbm.com"),
                    help="benchmark binary (default: build/screenbm.com)")
    ap.add_argument("--json", metavar="FILE", help="also write results as JSON")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    bench_path = Path(args.bin)
    if not bench_path.exists():
        print(f"error: {bench_path} is missing; run build.cmd first",
              file=sys.stderr)
        return 2

    images = [(args.name, Path(args.dsk))] + [
        (Path(p).stem, Path(p)) for p in args.compare]
    for _, dsk in images:
        if not dsk.exists():
            print(f"error: {dsk} does not exist", file=sys.stderr)
            return 2

    bench = bench_path.read_bytes()
    results: dict[str, dict[str, dict]] = {}
    mcp = MCP(find_zx84(args.zx84), "zx128kplus3")
    try:
        for idx, (name, dsk) in enumerate(images):
            scratch = ROOT / "build" / f"screenbm-work-{idx}.dsk"
            print(f"[bench] preparing {dsk.name} ...", flush=True)
            prepare(dsk, bench, scratch)
            print(f"[bench] measuring {name} ...", flush=True)
            results[name] = measure(mcp, scratch, args.verbose)
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()

    for name, _ in images:
        show(name, results[name])

    if len(images) > 1:
        print("\nratio (--dsk / other); > 1.0 means --dsk spends more T-states:")
        print(f"  {'phase':<8}" + "".join(f"{n:>18}" for n, _ in images[1:]))
        for _, key, _ in PHASES:
            base = results[images[0][0]][key]["tstates"]
            row = f"  {key:<8}"
            for name, _ in images[1:]:
                row += f"{base / results[name][key]['tstates']:>17.2f}x"
            print(row)
        base = (results[images[0][0]]["flip"]["tstates"]
                - results[images[0][0]]["noflip"]["tstates"])
        row = f"  {'(flip)':<8}"
        for name, _ in images[1:]:
            other = (results[name]["flip"]["tstates"]
                     - results[name]["noflip"]["tstates"])
            row += f"{base / other:>17.2f}x"
        print(row)

    if args.json:
        Path(args.json).write_text(json.dumps(results, indent=2))
        print(f"\nwrote {args.json}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
