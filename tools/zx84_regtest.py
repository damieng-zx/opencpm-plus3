#!/usr/bin/env python3
"""Boot the +3 image and run REGTEST.COM.

REGTEST plants magic values in BC/DE/IX/IY, makes BDOS calls (F12, F2,
F25, F13, F15) and prints one line per function showing which registers
survived.  By default this driver fails if any register was clobbered;
pass --report-only to just print the output (evidence gathering).

Usage:
    python3 tools/zx84_regtest.py
    python3 tools/zx84_regtest.py --report-only

Exit codes: 0 = all registers preserved, 1 = clobber detected or run
failure, 2 = setup error.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from zx84_smoke import MCP, ROOT, Smoke, SmokeError, find_zx84  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--zx84", help="path to the zx84 checkout")
    ap.add_argument("--dsk", default=str(ROOT / "build" / "cpm3.dsk"),
                    help="DSK image to boot")
    ap.add_argument("--model", default="zx128kplus3")
    ap.add_argument("--report-only", action="store_true",
                    help="print REGTEST output without asserting")
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
            smoke = Smoke(mcp, dsk)
            smoke.boot()
            smoke.command("REGTEST", 1500)
            for _ in range(10):
                if "REGTEST DONE" in smoke.text():
                    break
                smoke.record()
                smoke.mcp.call("run", {"frames": 1200})
                smoke.record()
            else:
                print(smoke.text())
                print("error: REGTEST did not finish", file=sys.stderr)
                return 1

            output = "\n".join(smoke.history)
            print(output)
            if args.report_only:
                return 0
            clobbered = [ln for ln in output.splitlines()
                         if re.search(r"[BDXY]-", ln)]
            if clobbered:
                print("error: BDOS clobbered registers:\n  " +
                      "\n  ".join(clobbered), file=sys.stderr)
                return 1
            print("REGTEST: all registers preserved")
            return 0
        finally:
            mcp.close()
    except SmokeError as e:
        print(f"error: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
