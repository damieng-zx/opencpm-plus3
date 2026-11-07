"""Helpers shared by the static regression tests."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def source(rel: str) -> str:
    """Return a source file as text (UTF-8, newlines normalised)."""
    return (ROOT / rel).read_text(encoding="utf-8")


def labels() -> dict:
    """Return {label_name: Label} from build/bios.lst, or {} if not built."""
    listing = ROOT / "build" / "bios.lst"
    if not listing.exists():
        return {}
    tools = str(ROOT / "tools")
    if tools not in sys.path:
        sys.path.insert(0, tools)
    from build_memory_map import parse_listing  # type: ignore

    out = {}
    for section in parse_listing(listing):
        for label in section.labels:
            out[label.name] = label
    return out


def dsk_sectors(path: Path | None = None) -> list[list[bytes]]:
    """Return a built DSK as [track][sector] (512-byte bytes objects).

    Tracks are logical (a double-sided image alternates sides within a
    cylinder), which is the order the DSK container and CP/M use.
    """
    import struct

    dsk = path or (ROOT / "build" / "cpm3.dsk")
    data = dsk.read_bytes()
    cylinders = data[0x30]
    sides = data[0x31] or 1
    sectors = 9  # +3 geometry is fixed here
    track_total = 0x100 + sectors * 512
    out = []
    off = 0x100
    for _ in range(cylinders * sides):
        track = []
        base = off + 0x100
        for s in range(sectors):
            track.append(data[base + s * 512: base + (s + 1) * 512])
        out.append(track)
        off += track_total
    return out


def dsk_directory(path: Path | None = None) -> list[bytes]:
    """Return the raw 32-byte directory entries from a built DSK.

    The directory starts on the first data track and is two blocks long:
    four sectors (64 entries) with 1K blocks, eight (128 entries) with 2K
    blocks.
    """
    import struct

    dsk = path or (ROOT / "build" / "cpm3.dsk")
    raw = dsk.read_bytes()
    tracks = dsk_sectors(dsk)
    block_size = 2048 if raw[0x31] == 2 else 1024
    dir_sectors = (2 * block_size) // 512
    blob = b"".join(tracks[1][s] for s in range(dir_sectors))
    count = (2 * block_size) // 32
    return [blob[i * 32:(i + 1) * 32] for i in range(count)]
