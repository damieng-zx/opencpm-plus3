#!/usr/bin/env python3
"""Run locally supplied DRI CP/M 3 utilities against the built +3 image.

The DRI utilities are Copyright Digital Research.  They are **not** part of
this repository and must not be redistributed.  This tool only reads your own
copies from ``references/binaries/`` (git-ignored) or ``--bin DIR``, adds them
to a scratch copy in ``build/`` and boots that copy.  If ``SHOW.COM`` or
``ED.COM`` is absent the tool exits 0 with a notice, so CI never needs the
binaries.

Covered today:

* ``SHOW`` - drive status, free space (F?/SCB driven).
* ``ED``   - append/type a source line, insert text, and quit with ``Q``/``Y``.

Known issues (documented in docs/third-party-tests.md; not run here):

* ``ED``'s ``E`` (end/save) hangs after the directory write.
* ``SET`` loops reading the disk; ``SETKEYS`` stops after opening its key file.

Usage:
    python3 tools/zx84_dri.py
    python3 tools/zx84_dri.py --bin /path/to/your/cpm/tools --zx84 /path/to/zx84
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from zx84_smoke import MCP, ROOT, Smoke, SmokeError, find_zx84

NOTICE = """\
The DRI CP/M 3 utilities are Copyright Digital Research.
They are not included in, or redistributed with, this project.
Put your own copies at references/binaries/ (git-ignored) and re-run.
"""


def key(smoke: Smoke, name: str, frames: int = 500, hold: int = 10) -> None:
    smoke.mcp.call("key", {"name": name, "frames": hold})
    smoke.mcp.call("run", {"frames": frames})


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--bin", default=str(ROOT / "references" / "binaries"),
                    help="directory containing SHOW.COM and ED.COM")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    args = ap.parse_args()

    bin_dir = Path(args.bin)
    show = bin_dir / "SHOW.COM"
    ed = bin_dir / "ED.COM"
    if not show.exists() or not ed.exists():
        print(NOTICE)
        print("[dri] skipped (no local copies)")
        return 0

    base = Path(args.dsk)
    if not base.is_absolute():
        base = ROOT / base
    if not base.exists():
        print(f"error: {base} does not exist; run build.cmd first",
              file=sys.stderr)
        return 2

    sys.path.insert(0, str(ROOT / "tools"))
    import mkdsk  # noqa: E402

    scratch = ROOT / "build" / "dri-test.dsk"
    shutil.copyfile(base, scratch)
    image = mkdsk.DSKImage().load(scratch)

    def on_image(name11: bytes) -> bool:
        for i in range(mkdsk.DIR_ENTRIES):
            entry = image._read_dir_entry(i)
            if entry[0] != 0xE5 and entry[1:12] == name11:
                return True
        return False

    for name, name11, src in (
            ("SHOW.COM", b"SHOW    COM", show),
            ("ED.COM", b"ED      COM", ed)):
        if on_image(name11):
            print(f"[dri] {name} already on the image")
            continue
        if not image.add_cpm_file(name, src.read_bytes()):
            print(f"error: could not add {name} to the scratch image",
                  file=sys.stderr)
            return 2
    image.save(scratch)
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

        # --- ED: insert text and discard with Q ------------------------
        smoke.mcp.call("type", {"text": "ED NEW.TXT"})
        key(smoke, "enter", 800)
        smoke.expect("ED new", "NEW FILE")
        smoke.mcp.call("type", {"text": "i"})
        smoke.mcp.call("run", {"frames": 300})   # I enters insert directly
        smoke.mcp.call("type", {"text": "DRI ED OK"})
        key(smoke, "enter", 300)
        key(smoke, "shift+sym+z", 500)          # Ctrl-Z ends insert
        smoke.mcp.call("type", {"text": "q"})
        key(smoke, "enter", 500)
        smoke.expect("ED discard prompt", "Q-(Y/N)?")
        smoke.mcp.call("type", {"text": "y"})
        key(smoke, "enter", 800)
        smoke.expect("ED discard exit", "A>")
        print("[dri] ED insert + discard ok")

        print("[dri] all checks passed (known ED save/SET issues are "
              "documented, not run)")
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
