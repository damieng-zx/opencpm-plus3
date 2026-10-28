#!/usr/bin/env python3
"""
mkdsk.py - Create Spectrum +3 / CPCEMU DSK disk images for CP/M 3.1

Produces standard CPCEMU .DSK files compatible with FUSE and other emulators.
Supports +3 CP/M disk geometry: 40 tracks, 1 side, 9 x 512-byte sectors.

Usage:
    python mkdsk.py create output.dsk [--boot boot.bin] [--system sys.bin] [--add FILE ...]
"""

import struct
import sys
import os
import argparse

# --- +3 CP/M Disk Geometry ---
TRACKS = 40
SIDES = 1
SECTORS_PER_TRACK = 9
SECTOR_SIZE = 512
SECTOR_SIZE_CODE = 2        # 0=128, 1=256, 2=512, 3=1024
FIRST_SECTOR_ID = 1         # +3 sectors numbered 1-9
GAP3_LENGTH = 0x4E
FILLER_BYTE = 0xE5

TRACK_HEADER_SIZE = 256
TRACK_DATA_SIZE = SECTORS_PER_TRACK * SECTOR_SIZE
TRACK_TOTAL_SIZE = TRACK_HEADER_SIZE + TRACK_DATA_SIZE

# --- CP/M Filesystem Parameters ---
BLOCK_SIZE = 1024           # CP/M allocation block = 2 sectors
DIR_ENTRIES = 64            # Max directory entries
RESERVED_TRACKS = 1         # Track 0 reserved for boot/system
DIR_BLOCKS = (DIR_ENTRIES * 32 + BLOCK_SIZE - 1) // BLOCK_SIZE  # = 2


class DSKImage:
    """Represents a +3 DSK disk image in memory."""

    def __init__(self):
        """Create a blank disk filled with 0xE5 (CP/M empty marker)."""
        self.tracks = []
        for _ in range(TRACKS):
            track = []
            for _ in range(SECTORS_PER_TRACK):
                track.append(bytearray([FILLER_BYTE] * SECTOR_SIZE))
            self.tracks.append(track)

    def set_boot_sector(self, data):
        """Write raw data to track 0, sector 0 (the first physical sector)."""
        if len(data) > SECTOR_SIZE:
            raise ValueError(
                f"Boot sector data too large: {len(data)} bytes (max {SECTOR_SIZE})")
        self.tracks[0][0][:len(data)] = data

    def load(self, path):
        """Load an existing CPCEMU DSK image into self.tracks.

        Used by tests (and `mkdsk.py add`) to modify a built image without
        rebuilding it from a file list.
        """
        with open(path, "rb") as f:
            data = f.read()
        if not data.startswith(b"MV - CPCEMU Disk-File"):
            raise ValueError(f"{path}: not a CPCEMU DSK image")
        count = data[0x30]
        self.tracks = []
        off = 0x100
        for _ in range(count):
            header = data[off:off + TRACK_HEADER_SIZE]
            off += TRACK_HEADER_SIZE
            sectors = header[0x15] or SECTORS_PER_TRACK
            if off + sectors * SECTOR_SIZE > len(data):
                raise ValueError(f"{path}: truncated DSK image")
            self.tracks.append([
                bytearray(data[off + s * SECTOR_SIZE:off + (s + 1) * SECTOR_SIZE])
                for s in range(sectors)
            ])
            off += sectors * SECTOR_SIZE
        return self

    def write_raw(self, track, sector, data):
        """Write raw data starting at a specific track and sector (0-based).
        Spans across sectors and tracks as needed."""
        offset = 0
        t, s = track, sector
        while offset < len(data) and t < TRACKS:
            chunk_len = min(SECTOR_SIZE, len(data) - offset)
            self.tracks[t][s][:chunk_len] = data[offset:offset + chunk_len]
            offset += SECTOR_SIZE
            s += 1
            if s >= SECTORS_PER_TRACK:
                s = 0
                t += 1

    def _block_to_track_sector(self, block_num):
        """Convert a CP/M block number to (track, sector) tuple.
        Blocks start at the first data track (after reserved tracks)."""
        sectors_per_block = BLOCK_SIZE // SECTOR_SIZE
        abs_sector = (RESERVED_TRACKS * SECTORS_PER_TRACK) + (block_num * sectors_per_block)
        track = abs_sector // SECTORS_PER_TRACK
        sector = abs_sector % SECTORS_PER_TRACK
        return track, sector

    def _get_used_blocks(self):
        """Scan CP/M directory to find all allocated blocks."""
        used = set()
        for i in range(DIR_ENTRIES):
            entry = self._read_dir_entry(i)
            if entry[0] != 0xE5:  # Entry in use
                for j in range(16, 32):
                    if entry[j] != 0:
                        used.add(entry[j])
        return used

    def _read_dir_entry(self, index):
        """Read a 32-byte CP/M directory entry by index."""
        byte_offset = index * 32
        abs_sector = (RESERVED_TRACKS * SECTORS_PER_TRACK) + (byte_offset // SECTOR_SIZE)
        t = abs_sector // SECTORS_PER_TRACK
        s = abs_sector % SECTORS_PER_TRACK
        entry_offset = byte_offset % SECTOR_SIZE
        return bytes(self.tracks[t][s][entry_offset:entry_offset + 32])

    def _write_dir_entry(self, index, entry):
        """Write a 32-byte CP/M directory entry by index."""
        byte_offset = index * 32
        abs_sector = (RESERVED_TRACKS * SECTORS_PER_TRACK) + (byte_offset // SECTOR_SIZE)
        t = abs_sector // SECTORS_PER_TRACK
        s = abs_sector % SECTORS_PER_TRACK
        entry_offset = byte_offset % SECTOR_SIZE
        self.tracks[t][s][entry_offset:entry_offset + 32] = entry

    def _find_free_dir_entry(self):
        """Return index of first free directory entry, or None."""
        for i in range(DIR_ENTRIES):
            entry = self._read_dir_entry(i)
            if entry[0] == 0xE5:
                return i
        return None

    def _parse_cpm_filename(self, filename):
        """Convert a filename to CP/M 8.3 uppercase format.
        Returns (name_bytes[8], ext_bytes[3])."""
        filename = filename.upper().strip()
        if '.' in filename:
            name_part, ext_part = filename.rsplit('.', 1)
        else:
            name_part, ext_part = filename, ''
        name = name_part[:8].ljust(8).encode('ascii')
        ext = ext_part[:3].ljust(3).encode('ascii')
        return name, ext

    def add_cpm_file(self, filename, data, user=0):
        """Add a file to the CP/M directory and allocate blocks for its data."""
        # Pad last record with 0x1A (Ctrl-Z EOF marker) to 128-byte boundary
        remainder = len(data) % 128
        if remainder != 0:
            data = data + b'\x1A' * (128 - remainder)

        name, ext = self._parse_cpm_filename(filename)

        # Calculate total blocks available
        data_sectors = (TRACKS - RESERVED_TRACKS) * SECTORS_PER_TRACK
        total_blocks = data_sectors * SECTOR_SIZE // BLOCK_SIZE
        blocks_needed = (len(data) + BLOCK_SIZE - 1) // BLOCK_SIZE

        # Find free blocks (skip directory blocks)
        used_blocks = self._get_used_blocks()
        allocated = []
        for blk in range(DIR_BLOCKS, total_blocks):
            if len(allocated) >= blocks_needed:
                break
            if blk not in used_blocks:
                allocated.append(blk)

        if len(allocated) < blocks_needed:
            free = total_blocks - len(used_blocks) - DIR_BLOCKS
            print(f"  WARNING: skipping {filename} (need {blocks_needed} blocks, only {free} free)")
            return False

        # Write file data into allocated blocks
        for i, block_num in enumerate(allocated):
            t, s = self._block_to_track_sector(block_num)
            file_offset = i * BLOCK_SIZE
            sectors_per_block = BLOCK_SIZE // SECTOR_SIZE
            for sec_idx in range(sectors_per_block):
                data_offset = file_offset + sec_idx * SECTOR_SIZE
                if data_offset < len(data):
                    chunk = data[data_offset:data_offset + SECTOR_SIZE]
                    cur_s = s + sec_idx
                    cur_t = t + cur_s // SECTORS_PER_TRACK
                    cur_s = cur_s % SECTORS_PER_TRACK
                    if cur_t < TRACKS:
                        self.tracks[cur_t][cur_s][:len(chunk)] = chunk

        # Create directory extent entries (max 16 block pointers per extent)
        BLOCKS_PER_EXTENT = 16
        block_idx = 0
        extent_num = 0

        while block_idx < len(allocated):
            dir_idx = self._find_free_dir_entry()
            if dir_idx is None:
                raise ValueError("Directory full")

            extent_blocks = allocated[block_idx:block_idx + BLOCKS_PER_EXTENT]

            # Calculate records (128-byte units) in this extent
            extent_data_start = block_idx * BLOCK_SIZE
            extent_data_end = min(len(data), extent_data_start + len(extent_blocks) * BLOCK_SIZE)
            extent_bytes = extent_data_end - extent_data_start
            records = (extent_bytes + 127) // 128

            entry = bytearray(32)
            entry[0] = user                     # User number
            entry[1:9] = name                   # Filename
            entry[9:12] = ext                   # Extension
            entry[12] = extent_num & 0x1F       # Extent low (EX)
            entry[13] = 0                       # S1 (byte count in last record)
            entry[14] = extent_num >> 5          # S2 (extent high)
            entry[15] = min(records, 128)       # RC (record count)

            for j, blk in enumerate(extent_blocks):
                entry[16 + j] = blk             # AL0..AL15 block pointers

            self._write_dir_entry(dir_idx, entry)
            block_idx += BLOCKS_PER_EXTENT
            extent_num += 1
        return True

    def save(self, path):
        """Write the disk image in standard CPCEMU DSK format."""
        with open(path, 'wb') as f:
            # --- Disk Information Block (256 bytes) ---
            header = bytearray(256)
            sig = b"MV - CPCEMU Disk-File\r\nDisk-Info\r\n"
            header[0:len(sig)] = sig
            creator = b"CPM31+3\x00\x00\x00\x00\x00\x00\x00"
            header[0x22:0x22 + 14] = creator
            header[0x30] = TRACKS
            header[0x31] = SIDES
            struct.pack_into('<H', header, 0x32, TRACK_TOTAL_SIZE)
            f.write(header)

            # --- Track data ---
            for t in range(TRACKS):
                # Track Information Block (256 bytes)
                thdr = bytearray(TRACK_HEADER_SIZE)
                tsig = b"Track-Info\r\n"
                thdr[0:len(tsig)] = tsig
                thdr[0x10] = t                  # Track number
                thdr[0x11] = 0                  # Side number
                thdr[0x14] = SECTOR_SIZE_CODE   # Sector size code
                thdr[0x15] = SECTORS_PER_TRACK  # Sectors per track
                thdr[0x16] = GAP3_LENGTH        # GAP#3 length
                thdr[0x17] = FILLER_BYTE        # Filler byte

                for s in range(SECTORS_PER_TRACK):
                    off = 0x18 + s * 8
                    thdr[off + 0] = t                       # C - track
                    thdr[off + 1] = 0                       # H - side
                    thdr[off + 2] = FIRST_SECTOR_ID + s     # R - sector ID
                    thdr[off + 3] = SECTOR_SIZE_CODE        # N - size code
                    thdr[off + 4] = 0                       # ST1
                    thdr[off + 5] = 0                       # ST2
                    struct.pack_into('<H', thdr, off + 6, SECTOR_SIZE)

                f.write(thdr)
                for s in range(SECTORS_PER_TRACK):
                    f.write(self.tracks[t][s])

    def info(self):
        """Print disk statistics."""
        used = self._get_used_blocks()
        data_sectors = (TRACKS - RESERVED_TRACKS) * SECTORS_PER_TRACK
        total_blocks = data_sectors * SECTOR_SIZE // BLOCK_SIZE
        free_blocks = total_blocks - len(used) - DIR_BLOCKS

        files = set()
        for i in range(DIR_ENTRIES):
            entry = self._read_dir_entry(i)
            if entry[0] != 0xE5:
                fname = entry[1:12].decode('ascii', errors='replace').strip()
                files.add(fname)

        print(f"Geometry:   {TRACKS} tracks, {SIDES} side, "
              f"{SECTORS_PER_TRACK} sectors/track, {SECTOR_SIZE} bytes/sector")
        total_kb = TRACKS * SECTORS_PER_TRACK * SECTOR_SIZE // 1024
        free_kb = free_blocks * BLOCK_SIZE // 1024
        print(f"Capacity:   {total_kb}K total, {free_kb}K free "
              f"({free_blocks}/{total_blocks - DIR_BLOCKS} blocks)")
        print(f"Reserved:   {RESERVED_TRACKS} track(s) (boot/system)")
        print(f"Directory:  {DIR_ENTRIES} entries, {len(files)} files")
        if files:
            for fname in sorted(files):
                try:
                    print(f"  {fname}")
                except UnicodeEncodeError:
                    print(f"  (unprintable)")


# --- CLI Commands ---

def cmd_create(args):
    """Create a new DSK image, optionally with boot sector and files."""
    dsk = DSKImage()

    if args.boot:
        with open(args.boot, 'rb') as f:
            boot_data = f.read()
        dsk.set_boot_sector(boot_data)
        print(f"Boot sector: {args.boot} ({len(boot_data)} bytes)")

    if args.system:
        with open(args.system, 'rb') as f:
            sys_data = f.read()
        # System image written to track 0 starting at sector 1 (after boot sector)
        dsk.write_raw(0, 1, sys_data)
        sectors_used = (len(sys_data) + SECTOR_SIZE - 1) // SECTOR_SIZE
        print(f"System:     {args.system} ({len(sys_data)} bytes, {sectors_used} sectors)")

    if args.add:
        for filepath in args.add:
            filename = os.path.basename(filepath)
            with open(filepath, 'rb') as f:
                data = f.read()
            if dsk.add_cpm_file(filename, data) is not False:
                print(f"Added file: {filename} ({len(data)} bytes)")

    dsk.save(args.output)
    print()
    dsk.info()
    print(f"\nWritten: {args.output}")


def cmd_add(args):
    """Add CP/M files to an existing DSK image."""
    dsk = DSKImage().load(args.image)
    for filepath in args.files:
        filename = os.path.basename(filepath)
        with open(filepath, 'rb') as f:
            data = f.read()
        if dsk.add_cpm_file(filename, data) is not False:
            print(f"Added file: {filename} ({len(data)} bytes)")
    dsk.save(args.image)
    print(f"Written: {args.image}")


def main():
    parser = argparse.ArgumentParser(
        description='Create Spectrum +3 CP/M 3.1 DSK disk images')
    sub = parser.add_subparsers(dest='command', help='Commands')

    cp = sub.add_parser('create', help='Create a new DSK image')
    cp.add_argument('output', help='Output .dsk filename')
    cp.add_argument('--boot', metavar='FILE', help='Boot sector binary (max 512 bytes)')
    cp.add_argument('--system', metavar='FILE', help='System binary (placed after boot sector)')
    cp.add_argument('--add', metavar='FILE', nargs='*', help='CP/M files to add to directory')

    ip = sub.add_parser('info', help='Show info about an existing DSK')
    ip.add_argument('input', help='Input .dsk filename')

    ap = sub.add_parser('add', help='Add CP/M files to an existing DSK')
    ap.add_argument('image', help='.dsk filename to modify in place')
    ap.add_argument('files', nargs='+', metavar='FILE', help='CP/M files to add')

    args = parser.parse_args()

    if args.command == 'create':
        cmd_create(args)
    elif args.command == 'add':
        cmd_add(args)
    elif args.command == 'info':
        DSKImage().load(args.input).info()
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == '__main__':
    main()
