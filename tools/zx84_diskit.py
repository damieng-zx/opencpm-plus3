#!/usr/bin/env python3
"""Run a locally supplied DISCKIT against the built +3 image.

DISCKIT is Copyright 1988 Locomotive Software Ltd.  It is **not** part of
this repository and must not be redistributed.  This tool only reads your
own legal copy from ``references/binaries/DISCKIT.COMx`` (git-ignored) or
``--bin DIR``, adds it to a scratch copy in ``build/`` and boots that copy.
If the file is absent the tool exits 0 with a notice, so CI never needs the
binary.

Usage:
    python3 tools/zx84_diskit.py
    python3 tools/zx84_diskit.py --bin /path/to/your/cpm/tools --zx84 /path/to/zx84
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from zx84_smoke import MCP, ROOT, Smoke, SmokeError, find_zx84

NOTICE = """\
DISCKIT is Copyright 1988 Locomotive Software Ltd.
It is not included in, or redistributed with, this project.
Put your own legal copy at references/binaries/DISCKIT.COMx
(that directory is git-ignored) and re-run.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--bin", default=str(ROOT / "references" / "binaries"),
                    help="directory containing your DISCKIT.COMx")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    args = ap.parse_args()

    src = Path(args.bin) / "DISCKIT.COMx"
    if not src.exists():
        print(NOTICE)
        print("[disckit] skipped (no local copy)")
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

    scratch = ROOT / "build" / "disckit-test.dsk"
    shutil.copyfile(base, scratch)
    image = mkdsk.DSKImage().load(scratch)
    if image.add_cpm_file("DISCKIT.COM", src.read_bytes()) is False:
        print("error: could not add DISCKIT.COM to the scratch image",
              file=sys.stderr)
        return 2
    image.save(scratch)
    print(f"[disckit] local copy added to {scratch.name} (not redistributed)")

    mcp = MCP(find_zx84(args.zx84), args.model)
    try:
        smoke = Smoke(mcp, scratch)
        smoke.boot()
        smoke.mcp.call("type", {"text": "DISCKIT"})
        smoke.mcp.call("key", {"name": "enter"})
        smoke.mcp.call("run", {"frames": 800})
        screen = smoke.text()
        if "DISC KIT" not in screen or "Locomotive Software" not in screen:
            print("FAIL: DISCKIT banner not found:\n" + screen,
                  file=sys.stderr)
            return 1
        print("[disckit] banner ok")

        # DISCKIT then asks for the disc to be removed and polls
        # SENSE DRIVE STATUS until Ready clears, reading the key through
        # KM_KT_GET.  Both used to leave it on this prompt forever.
        smoke.wait_for(["Please remove the disc from the drive"],
                       frames=600, attempts=6)
        smoke.mcp.call("eject", {"target": "disk", "drive": "A"})
        smoke.key("enter", 300)
        smoke.wait_for(["Format", "Verify"], frames=900, attempts=20)
        print("[disckit] menu reached (disc removal + key input)")
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
