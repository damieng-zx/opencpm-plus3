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

# The box-drawing characters DISCKIT uses, in the 51-column font's order.
BOX = {"tl": 0x96, "h": 0x9A, "tr": 0x9C, "v": 0x95, "bl": 0x93, "br": 0x99}


def _check_menu_boxes(smoke) -> None:
    """Assert every menu box has all four edges.

    Every box the menu draws is a rectangle: its top and bottom rows must be
    corners plus a horizontal run, and its two side columns must be vertical
    bars on every row between.  A destructive BS truncates the bottom and
    left edges, so this catches that regression directly.
    """
    rows = smoke.screen()
    cols = smoke.memory(4, smoke.scr_cols, 1)[0]
    # Read the raw codes: Smoke.screen() maps non-ASCII bytes to ".", which
    # would hide every box-drawing character.
    data = smoke.memory(smoke.cb_bank, smoke.cb, cols * 24)
    grid = [list(data[r * cols:(r + 1) * cols]) for r in range(24)]

    found = 0
    for r in range(len(grid) - 1):
        for c in range(len(grid[r]) - 1):
            if grid[r][c] != BOX["tl"]:
                continue
            # Measure the top edge.
            x = c + 1
            while x < cols and grid[r][x] == BOX["h"]:
                x += 1
            if x >= cols or grid[r][x] != BOX["tr"]:
                continue
            right = x
            # Walk down the right edge to the bottom-right corner.
            y = r + 1
            while y < len(grid) and grid[y][right] == BOX["v"]:
                y += 1
            if y >= len(grid) or grid[y][right] != BOX["br"]:
                raise SmokeError(
                    "menu box at row %d col %d has no bottom-right corner; "
                    "BS is erasing the box edges:\n%s"
                    % (r, c, "\n".join(rows)))
            base = y
            # Bottom edge must run all the way back to a bottom-left corner.
            if grid[base][c] != BOX["bl"]:
                raise SmokeError(
                    "menu box at row %d col %d has no bottom-left corner:\n%s"
                    % (r, c, "\n".join(rows)))
            for x in range(c + 1, right):
                if grid[base][x] != BOX["h"]:
                    raise SmokeError(
                        "menu box at row %d col %d: bottom edge broken at "
                        "column %d:\n%s" % (r, c, x, "\n".join(rows)))
            # Left edge must be vertical for every row in between.
            for y in range(r + 1, base):
                if grid[y][c] != BOX["v"]:
                    raise SmokeError(
                        "menu box at row %d col %d: left edge broken at "
                        "row %d:\n%s" % (r, c, y, "\n".join(rows)))
            found += 1

    if found < 4:
        raise SmokeError(
            "expected at least 4 complete menu boxes, found %d:\n%s"
            % (found, "\n".join(rows)))


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

        # The menu draws its boxes right-to-left as "corner, BS, BS, dash,
        # BS, BS, dash, ...".  That relies on BS being a pure cursor motion
        # (as on CP/M Plus): a destructive BS eats the glyphs it just wrote
        # and the menu loses every box's bottom and left edges.
        _check_menu_boxes(smoke)
        print("[disckit] menu boxes complete (BS is non-destructive)")
    except SmokeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1
    finally:
        mcp.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
