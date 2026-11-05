#!/usr/bin/env python3
"""Run locally supplied DRI CP/M 3 utilities against the built +3 image.

The DRI utilities are Copyright Digital Research.  They are **not** part of
this repository and must not be redistributed.  This tool only reads your own
copies from ``references/binaries/`` (git-ignored) or ``--bin DIR``, adds them
to a scratch copy in ``build/`` and boots that copy.  If the binaries are
absent the tool exits 0 with a notice, so CI never needs them.

Covered:

* ``SHOW``    - drive status, free space (SCB driven).
* ``ED``      - append/type a source line, insert text, save with ``E`` (END)
  and quit with ``Q``/``Y``.
* ``SET``     - the DRI attribute utility runs, prints its "no options"
  diagnostic and applies a bracketed attribute (``SET FILE [RO]``).
* ``SETKEYS`` - parses ``RESET.KEY`` and programs the +3 key table through
  XBIOS ``KM_SET_KEY`` / ``KM_SET_EXPAND``.

Usage:
    python3 tools/zx84_dri.py
    python3 tools/zx84_dri.py --bin /path/to/your/cpm/tools --zx84 /path/to/zx84
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from zx84_smoke import (MCP, ROOT, Smoke, SmokeError,
                        bank_for_address, find_zx84)

NOTICE = """\
The DRI CP/M 3 utilities are Copyright Digital Research.
They are not included in, or redistributed with, this project.
Put your own copies at references/binaries/ (git-ignored) and re-run.
"""

# BIOS keyboard override table (src/bios/keyboard.zpa: KMTAB equ 0xA900,
# 40 keys x 4 shift tables).  SETKEYS writes here through XBIOS KM_SET_KEY.
KMTAB = 0xA900
KMTAB_SIZE = 160


def key(smoke: Smoke, name: str, frames: int = 500, hold: int = 10) -> None:
    smoke.mcp.call("key", {"name": name, "frames": hold})
    smoke.mcp.call("run", {"frames": frames})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--bin", default=str(ROOT / "references" / "binaries"),
                    help="directory containing the DRI .COM files")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    args = ap.parse_args()

    bin_dir = Path(args.bin)
    wanted = ("SHOW.COM", "ED.COM", "SET.COM", "SETKEYS.COM", "RESET.KEY")
    missing = [n for n in wanted if not (bin_dir / n).exists()]
    if missing:
        print(NOTICE)
        print(f"[dri] skipped (missing {', '.join(missing)})")
        return 0

    base = Path(args.dsk)
    if not base.is_absolute():
        base = ROOT / base
    if not base.exists():
        print(f"error: {base} does not exist; run build.cmd first",
              file=sys.stderr)
        return 2

    sys.path.insert(0, str(ROOT / "tools"))

    # Build a clean scratch image from the boot/system files: the DRI tools
    # need room and the distribution image may already carry local utilities.
    base_files = ["build/CPM3.SYS", "build/CPM3C.SYS", "build/CCP.COM",
                  "src/bios/font51.bin", "src/bios/font32.bin",
                  "src/bios/font64.bin", "build/RAMDISK.FID"]
    missing = [p for p in base_files if not (ROOT / p).exists()]
    if missing:
        print(f"error: missing build output: {', '.join(missing)}; "
              "run build.cmd first", file=sys.stderr)
        return 2
    extra = [bin_dir / n for n in wanted]
    if (ROOT / "build" / "SET24X80.COM").exists():
        base_files.append("build/SET24X80.COM")
    # ED's read test types an existing line (the build's own smoke fixture).
    if (ROOT / "src" / "test" / "smoke.txt").exists():
        base_files.append("src/test/smoke.txt")

    scratch = ROOT / "build" / "dri-test.dsk"
    cmd = [sys.executable, str(ROOT / "tools" / "mkdsk.py"), "create",
           str(scratch),
           "--boot", str(ROOT / "build" / "bootsect.bin"),
           "--system", str(ROOT / "build" / "loader.bin"),
           "--add", *[str(ROOT / p) for p in base_files],
           *[str(p) for p in extra]]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or "WARNING" in (result.stdout or ""):
        print("error: could not build the scratch image\n"
              + (result.stdout or "") + (result.stderr or ""),
              file=sys.stderr)
        return 2
    print(f"[dri] local copies added to {scratch.name} (not redistributed)")

    mcp = MCP(find_zx84(args.zx84), args.model)
    try:
        smoke = Smoke(mcp, scratch)
        smoke.boot()

        # --- SHOW: drive status and free space -------------------------
        smoke.command("SHOW", 2500)
        smoke.expect("SHOW", "A: RW", "Space:")
        print("[dri] SHOW ok")

        # --- ED: append and type a line, then quit ---------------------
        smoke.mcp.call("type", {"text": "ED SMOKE.TXT"})
        key(smoke, "enter", 800)
        smoke.expect("ED prompt", ": *")
        smoke.mcp.call("type", {"text": "a"})
        key(smoke, "enter", 500)
        smoke.mcp.call("type", {"text": "t"})
        key(smoke, "enter", 800)
        smoke.expect("ED type", "SMOKE OK")
        smoke.mcp.call("type", {"text": "q"})
        key(smoke, "enter", 500)
        smoke.expect("ED quit prompt", "Q-(Y/N)?")
        smoke.mcp.call("type", {"text": "y"})
        key(smoke, "enter", 800)
        smoke.expect("ED exit", "A>")
        print("[dri] ED read + quit ok")

        # --- ED: insert text, save with E, and read it back ------------
        smoke.mcp.call("type", {"text": "ED NEW.TXT"})
        key(smoke, "enter", 800)
        smoke.expect("ED new", "NEW FILE")
        smoke.mcp.call("type", {"text": "i"})
        smoke.mcp.call("run", {"frames": 300})   # I enters insert directly
        smoke.mcp.call("type", {"text": "DRI ED OK"})
        key(smoke, "enter", 300)
        key(smoke, "shift+sym+z", 500)          # Ctrl-Z ends insert
        smoke.mcp.call("type", {"text": "e"})
        key(smoke, "enter", 2000)
        smoke.expect("ED save exit", "A>")
        smoke.command("TYPE NEW.TXT", 1500)
        smoke.expect("ED saved text", "DRI ED OK")
        print("[dri] ED insert + save + type ok")

        # --- SET: runs, and applies a bracketed attribute --------------
        smoke.command("SET", 2500)
        smoke.expect("SET no options", "ERROR: No options specified.")
        # A file to work on: ED can create one, but a one-liner is quicker.
        smoke.mcp.call("type", {"text": "ED RO.TXT"})
        key(smoke, "enter", 800)
        smoke.mcp.call("type", {"text": "i"})
        smoke.mcp.call("run", {"frames": 300})
        smoke.mcp.call("type", {"text": "RO TEST"})
        key(smoke, "enter", 300)
        key(smoke, "shift+sym+z", 500)
        smoke.mcp.call("type", {"text": "e"})
        key(smoke, "enter", 2000)
        smoke.command("SET RO.TXT [RO]", 2500)
        # The status wraps over the 51-column screen, so match the prefix.
        smoke.expect("SET RO", "Read Only")

        # The attribute is enforced: ERA and REN must refuse it and leave
        # the file in place.  (F19/F23 check the directory entry's R/O bit.)
        smoke.command("ERA RO.TXT", 1500)
        smoke.expect("ERA refuses R/O", "Bdos Err: R/O")
        smoke.command("DIR RO.TXT", 1200)
        smoke.expect("R/O file still present", "RO       TXT")
        smoke.command("REN NEW.TXT=RO.TXT", 1500)
        smoke.expect("REN refuses R/O", "Bdos Err: R/O")
        smoke.command("DIR RO.TXT", 1200)
        smoke.expect("still RO.TXT after REN", "RO       TXT")

        # Clearing R/O makes both operations work again.
        smoke.command("SET RO.TXT [RW]", 2500)
        smoke.expect("SET RW", "Read Write")
        smoke.command("ERA RO.TXT", 1500)
        smoke.command("DIR RO.TXT", 1200)
        smoke.expect("R/O file deleted after RW", "No files")
        print("[dri] SET ok (R/O enforced on ERA/REN)")

        # --- SETKEYS: parse RESET.KEY and program the key table --------
        before = smoke.memory(bank_for_address(KMTAB), KMTAB, KMTAB_SIZE)
        smoke.command("SETKEYS RESET.KEY", 2500)
        smoke.expect("SETKEYS exit", "A>")
        after = smoke.memory(bank_for_address(KMTAB), KMTAB, KMTAB_SIZE)
        if before == after:
            raise SmokeError("SETKEYS did not change the key override table")
        print("[dri] SETKEYS ok (key table updated)")

        print("[dri] all checks passed")
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
