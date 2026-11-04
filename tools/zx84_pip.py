#!/usr/bin/env python3
"""Run a locally supplied PIP against the built +3 image.

PIP is Copyright Digital Research.  It is **not** part of this repository
and must not be redistributed.  This tool only reads your own copy from
``references/binaries/PIP.COM`` (git-ignored) or ``--bin DIR``, adds it to a
scratch copy in ``build/`` and boots that copy.  If the file is absent the
tool exits 0 with a notice, so CI never needs the binary.

The check runs a real copy, ``A:COPY.TXT=A:SMOKE.TXT``, then types the copy
back and looks for ``SMOKE OK``.  PIP is a genuine F44 multi-sector caller,
so this exercises the sequential read/write path end to end with a
third-party program.

Usage:
    python3 tools/zx84_pip.py
    python3 tools/zx84_pip.py --bin /path/to/your/cpm/tools --zx84 /path/to/zx84
"""
from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path

from zx84_smoke import MCP, ROOT, Smoke, SmokeError, find_zx84

NOTICE = """\
PIP is Copyright Digital Research.
It is not included in, or redistributed with, this project.
Put your own copy at references/binaries/PIP.COM
(that directory is git-ignored) and re-run.
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--bin", default=str(ROOT / "references" / "binaries"),
                    help="directory containing your PIP.COM")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"))
    ap.add_argument("--model", default="zx128kplus3")
    args = ap.parse_args()

    src = Path(args.bin) / "PIP.COM"
    if not src.exists():
        print(NOTICE)
        print("[pip] skipped (no local copy)")
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

    scratch = ROOT / "build" / "pip-test.dsk"
    shutil.copyfile(base, scratch)
    image = mkdsk.DSKImage().load(scratch)
    if image.add_cpm_file("PIP.COM", src.read_bytes()) is False:
        print("error: could not add PIP.COM to the scratch image",
              file=sys.stderr)
        return 2
    image.save(scratch)
    print(f"[pip] local copy added to {scratch.name} (not redistributed)")

    mcp = MCP(find_zx84(args.zx84), args.model)
    try:
        smoke = Smoke(mcp, scratch)
        smoke.boot()
        smoke.command("PIP", 600)
        smoke.expect("PIP prompt", "*")

        # Copy through PIP's own command line (destination=source).
        smoke.mcp.call("type", {"text": "A:COPY.TXT=A:SMOKE.TXT"})
        smoke.mcp.call("key", {"name": "enter"})
        smoke.mcp.call("run", {"frames": 2500})
        smoke.record()
        smoke.expect("PIP after copy", "*")

        # A blank line leaves PIP and returns to the CCP.
        smoke.mcp.call("key", {"name": "enter"})
        smoke.mcp.call("run", {"frames": 1200})
        smoke.record()
        smoke.expect("PIP exit", "A>")

        smoke.command("TYPE COPY.TXT", 900)
        smoke.expect("copied file", "SMOKE OK")
        print("[pip] copy ok")
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
