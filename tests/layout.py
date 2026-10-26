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


def dsk_sectors() -> list[list[bytes]]:
    """Return the built DSK as [track][sector] (512-byte bytes objects)."""
    import struct

    dsk = ROOT / "build" / "cpm3.dsk"
    data = dsk.read_bytes()
    tracks = data[0x30]
    sectors = 9  # +3 geometry is fixed here
    track_total = 0x100 + sectors * 512
    out = []
    off = 0x100
    for _ in range(tracks):
        track = []
        base = off + 0x100
        for s in range(sectors):
            track.append(data[base + s * 512: base + (s + 1) * 512])
        out.append(track)
        off += track_total
    return out


def dsk_directory() -> list[bytes]:
    """Return the 64 raw 32-byte directory entries from the built DSK."""
    tracks = dsk_sectors()
    blob = b"".join(tracks[1][s] for s in range(4))
    return [blob[i * 32:(i + 1) * 32] for i in range(64)]
