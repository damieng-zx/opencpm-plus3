#!/usr/bin/env python3
"""
mkdsk.py - Create Spectrum +3 / CPCEMU DSK disk images for CP/M 3.1

Produces standard CPCEMU .DSK files.  Two CP/M formats are supported:

  180k  +3: 40 cylinders, 1 side, 9 x 512-byte sectors, 1K blocks,
        64 directory entries, 8-bit block numbers (DSM=174).
  720k  PCW DS/DD: 80 cylinders, 2 sides, 9 x 512-byte sectors,
        2K blocks, 128 directory entries, 16-bit block numbers
        (DSM=351, high byte first).

Usage:
    python mkdsk.py create output.dsk [--format 720k] [--boot boot.bin]
           [--system sys.bin] [--add FILE ...]
    python mkdsk.py add image.dsk FILE ...
    python mkdsk.py info image.dsk
"""

import struct
import sys
import os
import argparse

SECTOR_SIZE = 512
SECTOR_SIZE_CODE = 2        # 0=128, 1=256, 2=512, 3=1024
FIRST_SECTOR_ID = 1         # +3 sectors numbered 1-9
GAP3_LENGTH = 0x4E
FILLER_BYTE = 0xE5

TRACK_HEADER_SIZE = 256
DIR_ENTRY_SIZE = 32

# --- CP/M Formats -----------------------------------------------------------

FORMATS = {
    "180k": dict(
        label="+3 180K",
        cylinders=40, sides=1, sectors=9, sector_size=SECTOR_SIZE,
        block_size=1024, dir_blocks=2, reserved_tracks=1,
        dsm=174, disc_type=0),
    "720k": dict(
        label="PCW DS/DD 720K",
        cylinders=80, sides=2, sectors=9, sector_size=SECTOR_SIZE,
        block_size=2048, dir_blocks=2, reserved_tracks=1,
        dsm=351, disc_type=3),
}

# Back-compat constants for the default (+3 180K) format.
TRACKS = FORMATS["180k"]["cylinders"]
SIDES = FORMATS["180k"]["sides"]
SECTORS_PER_TRACK = FORMATS["180k"]["sectors"]
BLOCK_SIZE = FORMATS["180k"]["block_size"]
DIR_ENTRIES = (FORMATS["180k"]["dir_blocks"] * BLOCK_SIZE) // DIR_ENTRY_SIZE
RESERVED_TRACKS = FORMATS["180k"]["reserved_tracks"]


def format_for_geometry(cylinders, sides):
    for name, fmt in FORMATS.items():
        if fmt["cylinders"] == cylinders and fmt["sides"] == sides:
            return name
    return "180k"


class DSKImage:
    """A CPCEMU DSK image plus its CP/M filesystem layout.

    Sectors are stored by logical track: for a double-sided (alternating)
    disk logical track 2*c is cylinder c head 0 and 2*c+1 is cylinder c
    head 1, which is the order CPCEMU uses in the file.
    """

    def __init__(self, fmt="180k"):
        self.set_format(fmt)

    def set_format(self, fmt):
        if fmt not in FORMATS:
            raise ValueError(f"unknown format {fmt!r}")
        self.format_name = fmt
        self.fmt = FORMATS[fmt]
        self.cylinders = self.fmt["cylinders"]
        self.sides = self.fmt["sides"]
        self.sectors = self.fmt["sectors"]
        self.sector_size = self.fmt["sector_size"]
        self.block_size = self.fmt["block_size"]
        self.dir_blocks = self.fmt["dir_blocks"]
        self.reserved = self.fmt["reserved_tracks"]
        self.dsm = self.fmt["dsm"]
        self.disc_type = self.fmt["disc_type"]
        self.dir_entries = (self.dir_blocks * self.block_size) // DIR_ENTRY_SIZE
        self.records_per_track = self.sectors * (self.sector_size // 128)
        self.sectors_per_block = self.block_size // self.sector_size
        self.logical_tracks = self.cylinders * self.sides
        self.tracks = []
        for _ in range(self.logical_tracks):
            self.tracks.append([
                bytearray([FILLER_BYTE] * self.sector_size)
                for _ in range(self.sectors)
            ])

    def set_boot_sector(self, data):
        """Write raw data to logical track 0, sector 0 (the boot sector)."""
        if len(data) > self.sector_size:
            raise ValueError(
                f"Boot sector data too large: {len(data)} bytes "
                f"(max {self.sector_size})")
        self.tracks[0][0][:len(data)] = data

    def set_disc_spec(self):
        """Build the AMSDOS disc spec a data disk needs for format detection.

        Byte 0 is the disc type (3 = PCW DS/DD) and byte 7 is the number of
        directory blocks; fdc_login derives AL0/AL1/DRM/CKS from it.
        """
        spec = bytearray(self.sector_size)
        spec[0] = self.disc_type
        spec[7] = self.dir_blocks
        self.set_boot_sector(bytes(spec))

    def load(self, path):
        """Load an existing CPCEMU DSK image into self.tracks."""
        with open(path, "rb") as f:
            data = f.read()
        if not data.startswith(b"MV - CPCEMU Disk-File"):
            raise ValueError(f"{path}: not a CPCEMU DSK image")

        cylinders = data[0x30]
        sides = data[0x31] or 1
        self.set_format(format_for_geometry(cylinders, sides))

        logical = cylinders * sides
        off = 0x100
        for t in range(logical):
            header = data[off:off + TRACK_HEADER_SIZE]
            if not header.startswith(b"Track-Info"):
                raise ValueError(f"{path}: bad track header at track {t}")
            sectors = header[0x15] or self.sectors
            off += TRACK_HEADER_SIZE
            if off + sectors * self.sector_size > len(data):
                raise ValueError(f"{path}: truncated DSK image")
            track = []
            for s in range(sectors):
                start = off + s * self.sector_size
                track.append(bytearray(data[start:start + self.sector_size]))
            self.tracks[t] = track
            off += sectors * self.sector_size
        return self

    # --- Record/directory addressing ------------------------------------

    def _record_loc(self, record):
        """Map a data-area 128-byte record to (logical track, sector, offset).

        Record 0 is the first record after the reserved tracks."""
        rec = self.reserved * self.records_per_track + record
        track = rec // self.records_per_track
        pos = rec % self.records_per_track
        per_sector = self.sector_size // 128
        sector = pos // per_sector
        offset = (pos % per_sector) * 128
        return track, sector, offset

    def _read_record(self, record):
        track, sector, offset = self._record_loc(record)
        return bytes(self.tracks[track][sector][offset:offset + 128])

    def _write_record(self, record, data):
        track, sector, offset = self._record_loc(record)
        self.tracks[track][sector][offset:offset + 128] = data[:128]

    def write_raw(self, track, sector, data):
        """Write raw data starting at a specific logical track and sector
        (0-based), spanning sectors and tracks."""
        offset = 0
        t, s = track, sector
        while offset < len(data) and t < self.logical_tracks:
            chunk = min(self.sector_size, len(data) - offset)
            self.tracks[t][s][:chunk] = data[offset:offset + chunk]
            offset += self.sector_size
            s += 1
            if s >= self.sectors:
                s = 0
                t += 1

    # --- Directory ------------------------------------------------------

    @property
    def block_bits(self):
        return 16 if self.dsm > 255 else 8

    @property
    def blocks_per_extent(self):
        # One extent is 128 records; 16 slots when 8-bit, 8 when 16-bit.
        records_per_block = self.block_size // 128
        return min(128 // records_per_block, 16 if self.block_bits == 8 else 8)

    def _read_dir_entry(self, index):
        return self._read_record((index * DIR_ENTRY_SIZE) // 128)[
            (index * DIR_ENTRY_SIZE) % 128:
            (index * DIR_ENTRY_SIZE) % 128 + DIR_ENTRY_SIZE]

    def _write_dir_entry(self, index, entry):
        rec = (index * DIR_ENTRY_SIZE) // 128
        data = bytearray(self._read_record(rec))
        off = (index * DIR_ENTRY_SIZE) % 128
        data[off:off + DIR_ENTRY_SIZE] = entry
        self._write_record(rec, data)

    def _entry_blocks(self, entry):
        if self.block_bits == 8:
            return [b for b in entry[16:32] if b]
        return [(entry[16 + 2 * i] << 8) | entry[17 + 2 * i]
                for i in range(8)
                if entry[16 + 2 * i] or entry[17 + 2 * i]]

    def _set_entry_blocks(self, entry, blocks):
        if self.block_bits == 8:
            for i, blk in enumerate(blocks):
                entry[16 + i] = blk
            return
        for i, blk in enumerate(blocks):
            entry[16 + 2 * i] = (blk >> 8) & 0xFF
            entry[17 + 2 * i] = blk & 0xFF

    def _get_used_blocks(self):
        used = set()
        for i in range(self.dir_entries):
            entry = self._read_dir_entry(i)
            if entry[0] != 0xE5:
                used.update(self._entry_blocks(entry))
        return used

    def _find_free_dir_entry(self):
        for i in range(self.dir_entries):
            if self._read_dir_entry(i)[0] == 0xE5:
                return i
        return None

    def _parse_cpm_filename(self, filename):
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
        remainder = len(data) % 128
        if remainder != 0:
            data = data + b'\x1a' * (128 - remainder)

        name, ext = self._parse_cpm_filename(filename)
        total_blocks = self.dsm + 1
        blocks_needed = (len(data) + self.block_size - 1) // self.block_size

        used_blocks = self._get_used_blocks()
        allocated = []
        for blk in range(self.dir_blocks, total_blocks):
            if len(allocated) >= blocks_needed:
                break
            if blk not in used_blocks:
                allocated.append(blk)

        if len(allocated) < blocks_needed:
            free = total_blocks - len(used_blocks) - self.dir_blocks
            print(f"  WARNING: skipping {filename} (need {blocks_needed} "
                  f"blocks, only {free} free)")
            return False

        records_per_block = self.block_size // 128
        for i, block_num in enumerate(allocated):
            base = i * records_per_block
            for r in range(records_per_block):
                off = (base + r) * 128
                if off >= len(data):
                    break
                self._write_record(block_num * records_per_block + r,
                                   data[off:off + 128])

        # Create directory extent entries.
        block_idx = 0
        extent_num = 0
        per_extent = self.blocks_per_extent

        while block_idx < len(allocated):
            dir_idx = self._find_free_dir_entry()
            if dir_idx is None:
                raise ValueError("Directory full")

            extent_blocks = allocated[block_idx:block_idx + per_extent]
            extent_start = block_idx * self.block_size
            extent_end = min(len(data), extent_start + len(extent_blocks) *
                             self.block_size)
            records = (extent_end - extent_start + 127) // 128

            entry = bytearray(DIR_ENTRY_SIZE)
            entry[0] = user
            entry[1:9] = name
            entry[9:12] = ext
            entry[12] = extent_num & 0x1F       # EX
            entry[13] = 0                       # S1
            entry[14] = (extent_num >> 5) & 0x3F  # S2
            entry[15] = min(records, 128)       # RC
            self._set_entry_blocks(entry, extent_blocks)

            self._write_dir_entry(dir_idx, entry)
            block_idx += per_extent
            extent_num += 1
        return True

    # --- DSK container --------------------------------------------------

    def save(self, path):
        track_size = TRACK_HEADER_SIZE + self.sectors * self.sector_size
        with open(path, 'wb') as f:
            header = bytearray(256)
            sig = b"MV - CPCEMU Disk-File\r\nDisk-Info\r\n"
            header[0:len(sig)] = sig
            creator = b"CPM31+3\x00\x00\x00\x00\x00\x00\x00"
            header[0x22:0x22 + 14] = creator
            header[0x30] = self.cylinders
            header[0x31] = self.sides
            struct.pack_into('<H', header, 0x32, track_size)
            f.write(header)

            for lt in range(self.logical_tracks):
                thdr = bytearray(TRACK_HEADER_SIZE)
                thdr[0:12] = b"Track-Info\r\n"
                cyl = lt // self.sides
                head = lt % self.sides
                thdr[0x10] = cyl
                thdr[0x11] = head
                thdr[0x14] = SECTOR_SIZE_CODE
                thdr[0x15] = self.sectors
                thdr[0x16] = GAP3_LENGTH
                thdr[0x17] = FILLER_BYTE

                for s in range(self.sectors):
                    off = 0x18 + s * 8
                    thdr[off + 0] = cyl
                    thdr[off + 1] = head
                    thdr[off + 2] = FIRST_SECTOR_ID + s
                    thdr[off + 3] = SECTOR_SIZE_CODE
                    thdr[off + 4] = 0
                    thdr[off + 5] = 0
                    struct.pack_into('<H', thdr, off + 6, self.sector_size)

                f.write(thdr)
                for s in range(self.sectors):
                    f.write(self.tracks[lt][s])

    def info(self):
        used = self._get_used_blocks()
        total_blocks = self.dsm + 1
        free_blocks = total_blocks - len(used) - self.dir_blocks

        files = set()
        for i in range(self.dir_entries):
            entry = self._read_dir_entry(i)
            if entry[0] != 0xE5:
                fname = entry[1:12].decode('ascii', errors='replace').strip()
                files.add(fname)

        total_kb = (self.cylinders * self.sides * self.sectors *
                    self.sector_size) // 1024
        free_kb = free_blocks * self.block_size // 1024
        print(f"Format:     {self.fmt['label']} ({self.block_bits}-bit blocks)")
        print(f"Geometry:   {self.cylinders} cylinders, {self.sides} side(s), "
              f"{self.sectors} sectors/track, {self.sector_size} bytes/sector")
        print(f"Capacity:   {total_kb}K total, {free_kb}K free "
              f"({free_blocks}/{total_blocks - self.dir_blocks} blocks)")
        print(f"Reserved:   {self.reserved} logical track(s) (boot/system)")
        print(f"Directory:  {self.dir_entries} entries, {len(files)} files")
        if files:
            for fname in sorted(files):
                print(f"  {fname}")


# --- CLI Commands ---

def cmd_create(args):
    """Create a new DSK image, optionally with boot sector and files."""
    dsk = DSKImage(args.format)

    if args.boot:
        with open(args.boot, 'rb') as f:
            boot_data = f.read()
        dsk.set_boot_sector(boot_data)
        print(f"Boot sector: {args.boot} ({len(boot_data)} bytes)")
    elif args.format != "180k":
        # Data disk: give the FDC login a valid AMSDOS disc spec.
        dsk.set_disc_spec()
        print("Boot sector: generated AMSDOS disc spec")

    if args.system:
        with open(args.system, 'rb') as f:
            sys_data = f.read()
        dsk.write_raw(0, 1, sys_data)
        used = (len(sys_data) + SECTOR_SIZE - 1) // SECTOR_SIZE
        print(f"System:     {args.system} ({len(sys_data)} bytes, "
              f"{used} sectors)")

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
        description='Create Spectrum +3 / PCW CP/M 3.1 DSK disk images')
    sub = parser.add_subparsers(dest='command', help='Commands')

    cp = sub.add_parser('create', help='Create a new DSK image')
    cp.add_argument('output', help='Output .dsk filename')
    cp.add_argument('--format', default='180k', choices=sorted(FORMATS),
                    help='CP/M format (default 180k)')
    cp.add_argument('--boot', metavar='FILE',
                    help='Boot sector binary (max 512 bytes)')
    cp.add_argument('--system', metavar='FILE',
                    help='System binary (placed after boot sector)')
    cp.add_argument('--add', metavar='FILE', nargs='*',
                    help='CP/M files to add to directory')

    ip = sub.add_parser('info', help='Show info about an existing DSK')
    ip.add_argument('input', help='Input .dsk filename')

    ap = sub.add_parser('add', help='Add CP/M files to an existing DSK')
    ap.add_argument('image', help='.dsk filename to modify in place')
    ap.add_argument('files', nargs='+', metavar='FILE',
                    help='CP/M files to add')

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
