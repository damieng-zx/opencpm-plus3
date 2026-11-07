#!/usr/bin/env python3
"""Fetch PMAUTOAE.COM into the local (git-ignored) references tree.

PMAUTOAE.COM is a self-extracting PMARC archive by Yoshihiko Mino
(PMsfx Version 2.00, 1990).  It is third-party software, so it is not
committed: this tool downloads it into ``references/binaries/``, which is
git-ignored, exactly like BBC BASIC and the DRI utilities.

The build script adds ``references/binaries/PMAUTOAE.COM`` to the 720K
test image when it is present; the smoke runner then extracts it once
inside CP/M and checks the PMARC/PMEXT round trip.

The known-good copy is 30,976 bytes with CRC-32 45eb98c6 (this is the
copy cd.textfiles.com carries; the pub/rknop/cpm one is truncated).

Usage:
    python3 tools/fetch_pmautoae.py
    python3 tools/fetch_pmautoae.py --dest references/binaries
    python3 tools/fetch_pmautoae.py --refresh
"""
from __future__ import annotations

import argparse
import sys
import urllib.request
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

URL = ("http://cd.textfiles.com/230/EMULATOR/DIVERSE/CPM/DOSTOOLS/"
       "PMAUTOAE/PMAUTOAE.COM")
NAME = "PMAUTOAE.COM"
SIZE = 30976
CRC32 = 0x45EB98C6
USER_AGENT = "opencpm-plus3-pmautoae/1.0"


def fetch(dest_dir: Path, refresh: bool) -> Path:
    dest = dest_dir / NAME
    if dest.exists() and not refresh:
        print(f"[pmautoae] {dest} already present")
        return dest
    dest_dir.mkdir(parents=True, exist_ok=True)
    print(f"[pmautoae] download {URL}")
    req = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=90) as resp:
            data = resp.read()
    except Exception as exc:  # noqa: BLE001 - report any network failure
        raise SystemExit(f"error: download failed: {URL}: {exc}")

    if len(data) != SIZE:
        raise SystemExit(
            f"error: {NAME} is {len(data)} bytes, expected {SIZE}")
    crc = zlib.crc32(data) & 0xFFFFFFFF
    if crc != CRC32:
        raise SystemExit(
            f"error: {NAME} CRC-32 {crc:08X}, expected {CRC32:08X}")

    dest.write_bytes(data)
    print(f"[pmautoae] wrote {dest} ({len(data)} bytes)")
    return dest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dest", default=str(ROOT / "references" / "binaries"),
                    help="destination directory (git-ignored)")
    ap.add_argument("--refresh", action="store_true",
                    help="re-download even when the file is already there")
    args = ap.parse_args(argv)
    fetch(Path(args.dest), args.refresh)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
