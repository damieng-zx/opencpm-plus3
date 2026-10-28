# The CP/M Filesystem — An In-Depth Guide

## Introduction

The CP/M filesystem is one of the most influential disk formats in microcomputer history. Designed by Gary Kildall at Digital Research in the mid-1970s, it served as the primary filesystem for CP/M 2.2 and CP/M 3 (CP/M Plus), and was adopted by hundreds of different machines — from the Amstrad PCW and CPC, to the Kaypro, Osborne, and ZX Spectrum +3. Its influence can be seen in the design of early MS-DOS (FAT12), which borrowed heavily from CP/M's concepts.

Despite the enormous variety of hardware that ran CP/M, the filesystem itself is remarkably simple. There is no tree of directories, no file metadata beyond a name and some flags, and no complex on-disk data structures. The entire filesystem is described by a small parameter block and a flat directory of fixed-size entries.

This article explains how the CP/M filesystem works at every level — from the physical disk layout, through the block allocation scheme, to the directory format, FCB structures, and the mechanisms for reading and writing files.

---

## 1. Physical Disk Layout

A CP/M disk is divided into **tracks** and **sectors**. The exact geometry depends on the hardware — a 3-inch disk in an Amstrad PCW has 40 tracks of 9 sectors at 512 bytes each, while an 8-inch floppy on an earlier system might have 77 tracks of 26 sectors at 128 bytes each.

CP/M does not concern itself directly with the physical geometry. Instead, it works in terms of two abstractions:

- **Records**: The fundamental I/O unit is the 128-byte **record**. All CP/M file I/O is performed in multiples of 128 bytes. On disks with larger physical sectors (e.g. 512 bytes), the BIOS performs **sector deblocking** — packing four 128-byte records into one 512-byte physical sector.

- **Blocks**: The allocation unit for disk space. A block is a power-of-two multiple of 128 bytes — typically 1 KB (8 records) or 2 KB (16 records), though 4 KB, 8 KB, and 16 KB blocks are possible. The block size is chosen to balance between wasted space (large blocks on small files) and the number of blocks that can be tracked per directory entry.

### Reserved Tracks

The first N tracks on the disk are **reserved** (also called "system tracks"). These are not part of the CP/M filesystem at all. On a bootable disk, the reserved tracks contain the boot sector and the loader. The BIOS and BDOS live in `CPM3.SYS` on the CP/M filesystem, which the loader reads at cold boot; the CCP (`CCP.COM`), the fonts and the optional RAM disk image are ordinary files on the same disk. On a data-only disk, there may be no reserved tracks.

The number of reserved tracks is specified by the **OFF** parameter in the Disk Parameter Block.

### Data Area

Everything after the reserved tracks is the **data area**. This is divided into consecutively numbered blocks, starting from block 0. The first few blocks are reserved for the **directory** (specified by the AL0/AL1 allocation map in the DPB). The remaining blocks hold file data.

```
┌─────────────────────┬──────────────┬────────────────────────────┐
│   Reserved Tracks   │  Directory   │        File Data           │
│   (boot, system)    │  (blocks     │     (blocks 2..DSM)        │
│                     │   0..1)      │                            │
└─────────────────────┴──────────────┴────────────────────────────┘
        OFF tracks          AL0/AL1           Remaining blocks
```

---

## 2. The Disk Parameter Block (DPB)

The DPB is the single most important data structure in the CP/M filesystem. It completely describes the logical geometry of a disk. The BIOS provides a DPB for each drive, and the BDOS uses it to calculate everything — sector addresses, block counts, directory sizes, and allocation map dimensions.

The DPB contains the following fields:

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 2 | SPT | Logical 128-byte records per track |
| 2 | 1 | BSH | Block shift factor: block size = 128 × 2^BSH |
| 3 | 1 | BLM | Block mask: 2^BSH − 1 |
| 4 | 1 | EXM | Extent mask (see §4) |
| 5 | 2 | DSM | Highest block number (total blocks − 1) |
| 7 | 2 | DRM | Highest directory entry number (total entries − 1) |
| 9 | 1 | AL0 | Directory allocation bitmap, high byte |
| 10 | 1 | AL1 | Directory allocation bitmap, low byte |
| 11 | 2 | CKS | Checksum vector size: (DRM + 1) / 4, or 0 for fixed media |
| 13 | 2 | OFF | Number of reserved tracks |
| 15 | 1 | PSH | Physical sector shift factor (CP/M 3 only) |
| 16 | 1 | PHM | Physical sector mask (CP/M 3 only) |

### Key Relationships

**Block size** = 128 × 2^BSH. Common configurations:

| BSH | BLM | Block Size |
|-----|-----|------------|
| 3 | 7 | 1 KB |
| 4 | 15 | 2 KB |
| 5 | 31 | 4 KB |
| 6 | 63 | 8 KB |
| 7 | 127 | 16 KB |

**Total disk capacity** = (DSM + 1) × block_size.

**Directory entries** = DRM + 1. Each entry is 32 bytes. The directory occupies the first N blocks of the data area, where N is determined by AL0 and AL1.

**AL0 and AL1** form a 16-bit allocation bitmap for the directory. Bit 7 of AL0 corresponds to block 0, bit 6 to block 1, and so on through to bit 0 of AL1 (block 15). A set bit means the block is reserved for directory use. For example, AL0=0xC0, AL1=0x00 means blocks 0 and 1 are directory blocks, giving 2 KB of directory space — room for 64 entries at 32 bytes each.

**CKS** is the size of the checksum vector used to detect disk changes on removable media. It is calculated as (DRM + 1) / 4. For fixed (non-removable) disks, CKS is set to 0 or 8000h to indicate that no checksum checking is needed.

### Example: Amstrad PCW / +3 Standard Format

```
SPT  = 36    (9 physical sectors × 512 bytes ÷ 128 = 36 records/track)
BSH  = 3     (1 KB blocks)
BLM  = 7
EXM  = 0
DSM  = 174   (175 blocks × 1 KB = 175 KB usable)
DRM  = 63    (64 directory entries)
AL0  = C0h   (blocks 0 and 1 = directory)
AL1  = 00h
CKS  = 16    (64 entries ÷ 4)
OFF  = 1     (1 reserved track for boot sector)
PSH  = 2     (512-byte physical sectors: 128 × 2^2)
PHM  = 3
```

---

## 3. The Directory

The CP/M directory is a flat array of 32-byte entries stored in the directory blocks at the start of the data area. There are no subdirectories — every file on the disk appears as one or more entries in this single directory. Unused entries are marked with the byte 0xE5 in the first position.

### Directory Entry Format (32 bytes)

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 1 | ST | Status / User number (0-15, or E5h = deleted) |
| 1 | 8 | F1-F8 | Filename (padded with spaces, uppercase) |
| 9 | 3 | T1-T3 | File type / extension (padded with spaces) |
| 12 | 1 | EX | Extent number (low byte) |
| 13 | 1 | S1 | Bytes in last record (CP/M 3); reserved in CP/M 2.2 (see §6) |
| 14 | 1 | S2 | Extent number (high byte, bits 0-5) |
| 15 | 1 | RC | Record count — number of 128-byte records used in this extent |
| 16 | 16 | AL | Allocation map — block numbers for this extent |

### The Status Byte (ST)

The first byte serves double duty:

- **0-15**: The **user number**. CP/M supports 16 user areas (0-15). Files are only visible when the current user number matches. This provides a primitive form of file organisation — not security, since any program can change the user number.
- **0xE5**: The entry is **deleted** or unused. When CP/M deletes a file, it simply overwrites the status byte with 0xE5; the rest of the entry (including the allocation map) remains intact until overwritten by a new file. This is why file recovery utilities can sometimes undelete files.
- **16-31**: Used in CP/M 3 for **disk labels** (status = 0x20) and **timestamps** (status = 0x21).

### The Filename (F1-F8, T1-T3)

The filename is stored as 8 bytes of name plus 3 bytes of type, all in uppercase ASCII, padded with spaces (0x20). There is no dot stored — the dot in "FILE.TXT" is a display convention only.

The **high bits** of each filename and type byte are used as attribute flags:

| Byte | Bit 7 Meaning |
|------|---------------|
| T1 (byte 9) | **Read-Only**: file cannot be written or deleted |
| T2 (byte 10) | **System**: file is hidden from normal DIR listings |
| T3 (byte 11) | **Archive**: set when file is modified (CP/M 3) |
| F1-F8 (bytes 1-8) | User-defined attributes (CP/M 3 uses F1 bits for interface attributes) |

When comparing filenames, the high bits must be masked off.

### Extents

A single directory entry can only track a limited number of blocks. With 16 bytes available for the allocation map:

- If DSM ≤ 255 (blocks fit in one byte): 16 block numbers per entry
- If DSM > 255 (blocks need two bytes): 8 block numbers per entry

For 1 KB blocks with single-byte block numbers, one extent covers 16 × 1 KB = 16 KB. For 2 KB blocks, one extent covers 16 × 2 KB = 32 KB (or 8 × 2 KB = 16 KB if two-byte block numbers are needed).

When a file exceeds the capacity of a single extent, additional directory entries are created. These share the same filename, type, and user number, but have incrementing extent numbers. The **logical extent number** is calculated as:

```
logical_extent = (S2 × 32) + EX
```

This means EX holds the low 5 bits (0-31) and S2 holds the upper bits. In practice, for most disk formats, S2 is zero and EX alone suffices.

### The Extent Mask (EXM)

The EXM field in the DPB controls how many logical extents are packed into a single physical directory entry. This is an optimisation — if the block size is large enough that one directory entry's 16 allocation bytes can track more data than the nominal 16 KB of an extent, EXM allows the entry to span multiple logical extents.

| Block Size | DSM ≤ 255 | DSM > 255 |
|------------|-----------|-----------|
| 1 KB | EXM = 0 | N/A (max 256 KB) |
| 2 KB | EXM = 1 | EXM = 0 |
| 4 KB | EXM = 3 | EXM = 1 |
| 8 KB | EXM = 7 | EXM = 3 |
| 16 KB | EXM = 15 | EXM = 7 |

When EXM > 0, the low bits of EX (masked by EXM) indicate how full the directory entry is, while the upper bits identify which group of extents the entry represents. Two directory entries for the same file are considered the same physical extent if `EX >> (log2(EXM+1))` and S2 are equal.

The **RC** (record count) field gives the number of 128-byte records used in the **last logical extent** covered by this directory entry. For a full extent, RC = 128 (0x80). For the final extent of a file, RC indicates how much of the last extent is actually used.

### Example Directory

A disk might contain these entries (shown in decoded form):

```
User  Filename     Ext  S2  RC  Blocks
  0   HELLO   .COM  0   0   45  [3, 4, 5, 6, 7, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  0   BIGFILE .DAT  0   0  128  [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24]
  0   BIGFILE .DAT  1   0   64  [25, 26, 27, 28, 29, 30, 31, 32, 0, 0, 0, 0, 0, 0, 0, 0]
 E5   (deleted)     ...
 E5   (deleted)     ...
```

Here, HELLO.COM occupies 6 blocks (6 KB) with 45 records in its single extent (45 × 128 = 5,760 bytes). BIGFILE.DAT spans two extents: the first is full (128 records = 16 KB across 16 blocks) and the second holds 64 records (8 KB across 8 blocks), for a total of 24 KB.

---

## 4. Block Allocation

CP/M uses a **bitmap** to track which blocks are in use. This bitmap is called the **Allocation Vector (ALV)** and is maintained in memory — it is never stored on disk. Every time a disk is logged in (selected for the first time, or re-selected after a disk change), the BDOS rebuilds the ALV by scanning the entire directory.

The ALV has one bit per block. Bit N being set means block N is in use. The size of the ALV is `(DSM / 8) + 1` bytes.

### Rebuilding the ALV

When a disk is logged in:

1. Clear the ALV to all zeros.
2. Mark the directory blocks as used (from AL0/AL1).
3. Scan every directory entry. For each non-deleted entry (status ≠ 0xE5), mark every non-zero block number in the entry's allocation map as used.

This process is why CP/M can be slow when first accessing a disk — it must read the entire directory. It is also why the directory checksum (CKS) exists: rather than rebuilding the ALV on every disk access, CP/M checksums the directory entries and only rebuilds if the checksum changes (indicating a disk swap).

### Allocating a New Block

When the BDOS needs a new block for a file:

1. Scan the ALV from the beginning, looking for a zero bit (free block).
2. Set the bit to mark it as used.
3. Return the block number.

Blocks are allocated in order from low to high. There is no attempt to optimise for locality or to reduce fragmentation — the first free block is always chosen. In practice, this works well because CP/M disks are small and fragmentation is rarely a performance issue on floppy-based systems.

### Freeing Blocks

When a file is deleted, the BDOS marks the directory entry's status byte as 0xE5 and clears the corresponding bits in the ALV. The data blocks are not zeroed — they simply become available for reuse.

---

## 5. The File Control Block (FCB)

The FCB is the primary data structure for file operations in CP/M. Programs pass an FCB to the BDOS for every file operation — open, close, read, write, delete, rename. The FCB is a 36-byte structure that mirrors the 32-byte directory entry format, with 4 additional bytes used for sequential I/O.

### FCB Layout (36 bytes)

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 1 | DR | Drive code: 0 = default, 1 = A:, 2 = B:, ... |
| 1 | 8 | F1-F8 | Filename (uppercase, space-padded) |
| 9 | 3 | T1-T3 | File type (uppercase, space-padded) |
| 12 | 1 | EX | Current extent number |
| 13 | 1 | S1 | Bytes in last record (CP/M 3); reserved in CP/M 2.2 |
| 14 | 1 | S2 | Extent high byte |
| 15 | 1 | RC | Record count for current extent |
| 16 | 16 | D0-Dn | Allocation map (filled by BDOS on open) |
| 32 | 1 | CR | Current record within extent (0-127) |
| 33 | 3 | R0-R2 | Random record number (3 bytes, little-endian) |

### How the FCB is Used

**Opening a file**: The program fills in DR, filename, and type, then calls BDOS function 15 (Open File). The BDOS searches the directory for a matching entry and copies the extent information (EX, S2, RC, allocation map) into the FCB. The program can now read or write the file.

**Sequential read**: BDOS function 20 reads the record at position CR within the current extent. It uses the allocation map to find the block number, calculates the physical sector, and reads 128 bytes into the DMA buffer. CR is then incremented. When CR reaches 128 (end of extent), the BDOS automatically opens the next extent (EX + 1) and resets CR to 0.

**Sequential write**: Similar to read, but allocates new blocks as needed. When the allocation map for the current extent is full, a new directory entry (extent) is created.

**Random access**: BDOS functions 33/34 use the R0-R2 field (a 24-bit record number) to calculate the extent and record within extent, then perform the read or write. The formula is:

```
extent_number = random_record / 128
record_in_extent = random_record % 128
```

**Closing a file**: BDOS function 16 writes the current FCB state back to the directory. This is essential after writing — if a file is not closed, the directory entry may not reflect the final extent and record count, and data will be lost.

---

## 6. File Size Calculation

CP/M does not store an explicit file size in bytes. The size is implicit from the directory entries:

1. Find all extents for the file (all directory entries with matching user, name, and type).
2. The highest extent number tells you how many full extents precede it.
3. The RC field of the highest extent tells you how many records are in the final extent.
4. **Total records** = (highest_extent × 128) + RC (adjusting for EXM if applicable).
5. **File size in bytes** = total_records × 128.

This means CP/M file sizes are always a multiple of 128 bytes. There is no concept of a partial record. For text files, the convention is to place a Ctrl-Z (0x1A, ASCII SUB) character at the logical end of the file. Programs reading text files stop at the first 0x1A. Binary files (like .COM executables) simply occupy whole records, with any unused bytes in the final record being meaningless padding.

This 128-byte granularity is a well-known limitation of the CP/M filesystem. A 1-byte file consumes a full 128-byte record and one entire allocation block (typically 1 KB or 2 KB).

### Byte-Level File Size in CP/M 3

CP/M 3 introduced an optional mechanism for byte-level file sizes using **byte 13 (S1)** of the directory entry, sometimes called the "bytes in last record" field. When non-zero, S1 gives the number of valid bytes in the final 128-byte record (1-128). The true file size can then be calculated as:

```
file_size = (total_records × 128)
if S1 > 0:
    file_size = file_size - 128 + S1
```

For example, a file with RC=10 and S1=50 has a true size of (10 × 128) − 128 + 50 = 1,202 bytes, rather than the CP/M 2.2 estimate of 1,280 bytes.

In CP/M 2.2, this byte is always zero. Not all CP/M 3 implementations use it, and many tools ignore it — the Ctrl-Z convention for text files and fixed-size headers for binary files remained the more common practice.

---

## 7. Disk Labels and Timestamps (CP/M 3)

CP/M 3 (CP/M Plus) extended the directory format with two special entry types:

### Disk Label (Status = 0x20)

A disk label entry stores the volume name and controls which timestamp fields are active. It occupies a single directory entry:

- Bytes 1-11: Volume label (space-padded)
- Byte 12: Label flags
  - Bit 0: Set = label exists
  - Bit 4: Set = timestamps on creation
  - Bit 5: Set = timestamps on modification
  - Bit 6: Set = timestamps on access
  - Bit 7: Set = password protection enabled
- Bytes 24-27: Creation/update timestamp
- Bytes 28-31: Password (optional)

### Timestamp Entries (Status = 0x21)

Timestamps are stored in special directory entries with status byte 0x21. Each timestamp entry corresponds to the three directory entries immediately preceding it. In other words, every fourth directory entry slot is a timestamp entry.

Each timestamp entry contains:

- Byte 0: 0x21 (marks this as a timestamp entry)
- Bytes 1-10: Timestamp for the first of the three preceding entries (create + modify)
- Bytes 11-20: Timestamp for the second
- Bytes 21-30: Timestamp for the third

Each timestamp is stored as:
- 2 bytes: Date (days since 1 January 1978, little-endian)
- 1 byte: Hour (BCD)
- 1 byte: Minute (BCD)

The use of timestamp entries reduces the effective directory capacity by 25% — out of every four slots, one is consumed by timestamps.

---

## 8. Checksums and Disk Changes

Floppy disks are removable media. The user might swap disks at any time, and CP/M needs to detect this to avoid catastrophic data corruption (writing to the wrong disk using a stale ALV).

The mechanism is the **directory checksum vector**. The BDOS maintains an array of CKS bytes, one per directory sector. Each byte is a simple rolling sum of all 128 bytes in that sector. Before any directory access, the BDOS recomputes the checksum for the relevant sector and compares it to the stored value. If there is a mismatch, it means the disk has been changed, and the BDOS re-logs the drive (rebuilds the ALV from scratch).

For fixed (non-removable) media, CKS is set to 0 or 8000h, and no checksumming is performed.

This mechanism is not foolproof. If the user swaps two disks that happen to have identical directory checksums, CP/M will not detect the change. In practice this is extremely unlikely, but it is a theoretical vulnerability.

---

## 9. Sector Translation

Different disk controllers and formats use different physical sector numbering. Some use sequential numbering (1, 2, 3, ...), while others use interleaved numbering (1, 5, 2, 6, 3, 7, ...) to improve performance on slow controllers.

CP/M handles this through the **Sector Translation Table (XLT)**, a pointer to which is stored in the Disk Parameter Header (DPH). The BIOS function SECTRAN takes a logical sector number and returns a physical sector number using this table. If XLT is null (zero), no translation is performed (logical = physical).

The DPH is a per-drive structure that links together the XLT, directory buffer, DPB, checksum vector, and allocation vector:

| Offset | Size | Name | Description |
|--------|------|------|-------------|
| 0 | 2 | XLT | Pointer to sector translation table (or 0) |
| 2 | 6 | — | Scratch area (used by BDOS) |
| 8 | 2 | DIRBUF | Pointer to 128-byte directory buffer |
| 10 | 2 | DPB | Pointer to Disk Parameter Block |
| 12 | 2 | CSV | Pointer to checksum vector |
| 14 | 2 | ALV | Pointer to allocation vector |

---

## 10. Putting It All Together: Reading a File

Here is the complete sequence of events when a CP/M program reads a file:

1. **The program sets up an FCB** with the drive, filename, and type, then calls BDOS function 15 (Open File).

2. **The BDOS searches the directory** by iterating through all directory entries (0 to DRM). For each non-deleted entry, it compares the user number, filename, and type. When a match with EX=0 is found, the BDOS copies the allocation map, RC, and extent info into the FCB. The file is now "open".

3. **The program calls BDOS function 20 (Read Sequential)** to read the first record.

4. **The BDOS calculates the block number** from the FCB's current record (CR) and allocation map:
   - `block_index = CR >> BSH` (which block within this extent's allocation map)
   - `block_number = allocation_map[block_index]`
   - `record_in_block = CR & BLM` (which record within the block)

5. **The BDOS calculates the absolute record number**:
   - `absolute_record = (block_number << BSH) + record_in_block`

6. **The BDOS calculates the track and sector**:
   - `track = OFF + (absolute_record / SPT)`
   - `sector = absolute_record % SPT`

7. **The BDOS calls BIOS functions** SETTRK, SETSEC (with SECTRAN if needed), SETDMA, and READ to perform the physical I/O. The 128-byte record is placed in the DMA buffer (default address: 0x0080).

8. **CR is incremented**. If CR reaches 128, the BDOS opens the next extent (EX + 1) by searching the directory again, updating the FCB's allocation map.

9. **The program processes the data** in the DMA buffer and calls Read Sequential again for the next record.

10. **When there are no more records** (CR exceeds RC in the last extent), the BDOS returns an error code indicating end-of-file.

---

## 11. Sector Deblocking

Many CP/M systems use physical sectors larger than 128 bytes — 512 bytes being the most common (as on the Amstrad PCW, CPC, and Spectrum +3). Since CP/M's record size is 128 bytes, the BIOS must perform **sector deblocking**: reading a full 512-byte physical sector into a buffer and then extracting the requested 128-byte record from it.

The PSH and PHM fields in the CP/M 3 DPB describe the physical sector size:

- **PSH** (Physical Sector Shift): physical sector size = 128 × 2^PSH
- **PHM** (Physical Sector Mask): 2^PSH − 1

For 512-byte sectors: PSH = 2, PHM = 3 (four 128-byte records per physical sector).

The deblocking algorithm:

1. Compute the physical sector: `phys_sector = logical_sector >> PSH`
2. Compute the offset within the sector: `offset = (logical_sector & PHM) × 128`
3. If the required physical sector is already in the deblocking buffer (cache hit), extract the 128-byte record directly.
4. If not (cache miss), read the physical sector into the buffer, then extract.

For writes, the BIOS must use **read-modify-write**: read the physical sector, overwrite the appropriate 128-byte portion, then write the full sector back. This is necessary because we cannot write only 128 bytes to a 512-byte sector.

CP/M 3's BIOS specification includes a notion of **write types** to optimise deblocking:

- **Write type 0** (normal): Read-modify-write.
- **Write type 1** (to directory): Same as 0, but the sector should be written immediately (not deferred).
- **Write type 2** (first write to a new block): The block has just been allocated and contains no valid data, so the read step can be skipped — just write.

---

## 12. Multi-Extent Files and Large Disks

### Small vs. Large Disks

The size of block numbers in the allocation map depends on DSM:

- **DSM ≤ 255**: Block numbers are 1 byte. 16 entries per extent.
- **DSM > 255**: Block numbers are 2 bytes (little-endian). 8 entries per extent.

This means a single extent can track:

| Block Size | DSM ≤ 255 | DSM > 255 |
|------------|-----------|-----------|
| 1 KB | 16 KB | 8 KB |
| 2 KB | 32 KB | 16 KB |
| 4 KB | 64 KB | 32 KB |
| 8 KB | 128 KB | 64 KB |
| 16 KB | 256 KB | 128 KB |

### Maximum File Size

The maximum file size in CP/M is determined by the 3-byte random record number (R0-R2), which allows addressing up to 2^24 = 16,777,216 records, or 2 GB. In practice, the limit is constrained by disk size (DSM) and the number of available directory entries.

### Maximum Disk Size

With 2-byte block numbers, the maximum DSM is 65,535. With 16 KB blocks, this gives a maximum disk size of 65,536 × 16 KB = 1 GB. CP/M 3 supports up to 512 MB per drive in practice.

---

## 13. Wildcard Matching

CP/M supports two wildcard characters in filenames:

- **?** matches any single character in that position.
- **\*** is expanded to fill the remaining positions with **?** characters.

For example:
- `*.COM` becomes `????????.COM` — matches all .COM files
- `A*.?` becomes `A???????.?  ` — matches files starting with A, any single-character extension
- `??X*.*` becomes `??X?????.???` — matches files with X in the third position

Wildcard matching is performed by the BDOS Search First / Search Next functions (17/18). When comparing a directory entry against a search FCB, a `?` in any position of the FCB matches any character in the corresponding position of the directory entry.

---

## 14. User Areas

CP/M's user area system provides a simple file namespace mechanism. The current user number (0-15) is a system-wide setting. When listing or searching for files, only entries matching the current user number are visible. Files can be "moved" between user areas by changing the status byte of their directory entries.

User 0 has a special privilege: files in user 0 that have the SYS attribute set (bit 7 of T2) are visible from all user areas. This is typically used for system utilities and shared tools.

---

## 15. Amstrad Extensions

The Amstrad machines (PCW, CPC, and ZX Spectrum +3) all used CP/M-compatible disk formats but added several extensions that are worth documenting, as they appear on any disk from these systems.

### Disk Specification Block (Track 0, Sector 0)

Amstrad-format disks store a **disk specification block** in the first sector of the reserved track. This 16-byte structure allows the system to auto-detect the disk format without hardcoding it in the BIOS:

| Byte | Description |
|------|-------------|
| 0 | Format type: 0 = PCW SS, 1 = CPC System, 2 = CPC Data, 3 = PCW DS |
| 1 | Sidedness: bits 0-1 (0=single, 1=double alternate, 2=double successive), bit 7 (0=single track, 1=double track) |
| 2 | Tracks per side |
| 3 | Sectors per track |
| 4 | Sector size code: sector size = 2^(value + 7). E.g. 2 → 512 bytes |
| 5 | Reserved tracks |
| 6 | Block shift (BSH) |
| 7 | Number of directory blocks |
| 8 | Read/write gap length |
| 9 | Format gap length |
| 10-14 | Reserved |
| 15 | Checksum (used to validate the spec block) |

This is not part of the CP/M standard — it is an Amstrad convention. The block size can be derived from the BSH value using the formula: `block_size = 2^(BSH + 7)` (equivalently, `128 × 2^BSH`).

### PLUS3DOS File Headers

The ZX Spectrum +3 prepends a 128-byte **PLUS3DOS header** to files that originate from the Spectrum's native environment (BASIC programs, code blocks, etc.). The header provides byte-level file size and type information that CP/M's directory cannot store:

| Offset | Size | Description |
|--------|------|-------------|
| 0-7 | 8 | Signature: "PLUS3DOS" (ASCII) |
| 8 | 1 | End-of-file marker (0x1A) |
| 9 | 1 | Issue number |
| 10 | 1 | Version number |
| 11-14 | 4 | File length (32-bit little-endian, includes the 128-byte header) |
| 15 | 1 | +3 BASIC file type (0=BASIC, 1=number array, 2=string array, 3=code) |
| 16-17 | 2 | File length (from BASIC header) |
| 18-19 | 2 | Load address or BASIC line number |
| 20-127 | — | Reserved / padding |
| 127 | 1 | Checksum: sum of bytes 0-126, modulo 256 |

The checksum allows tools to detect whether a file has a valid PLUS3DOS header or is a raw CP/M file.

### AMSDOS File Headers

The Amstrad CPC uses a similar 128-byte **AMSDOS header** (also used by the PCW for some file types):

| Offset | Size | Description |
|--------|------|-------------|
| 0 | 1 | User number |
| 1-8 | 8 | Filename |
| 9-11 | 3 | Extension |
| 18 | 1 | File type (0=BASIC, 2=binary, 4=screen, 6=ASCII) |
| 21-22 | 2 | Load address (little-endian) |
| 24-25 | 2 | File length (little-endian) |
| 26-27 | 2 | Execute address (little-endian) |
| 64-66 | 3 | Logical file length (24-bit little-endian) |
| 67-68 | 2 | Checksum: sum of bytes 0-66 (16-bit little-endian) |

The AMSDOS header has no fixed signature string — it is identified by validating the checksum at bytes 67-68 against the sum of bytes 0-66. If the checksum is invalid, the file is assumed to be a headerless ASCII file.

### Implications for CP/M File Handling

Both header formats are exactly 128 bytes — one CP/M record. This means:
- The header occupies the first record of the file.
- The actual file data begins at record 1 (byte offset 128).
- The header's file length field provides byte-accurate sizing, working around CP/M's 128-byte granularity.
- Tools that are not header-aware will see the header as part of the file data.

When calculating the true file size, a header-aware tool should:
1. Read the first 128 bytes of the file.
2. Check for a valid PLUS3DOS signature or AMSDOS checksum.
3. If a header is found, use its embedded file length and subtract 128 for the header itself.
4. If no header is found, fall back to the CP/M record-count method (RC × 128, adjusted by S1 if available).

---

## 16. Comparison with FAT and Other Filesystems

It is instructive to compare CP/M's filesystem with FAT (File Allocation Table), which evolved from similar roots:

| Feature | CP/M | FAT12/16 |
|---------|------|----------|
| Directory structure | Flat, single level | Hierarchical (subdirectories) |
| Allocation tracking | In-memory bitmap (ALV), rebuilt from directory | On-disk FAT table |
| Block/cluster chain | Stored in directory entry | Stored in FAT as linked list |
| File size | Implicit (record count × 128) | Explicit (4-byte field in directory) |
| Max filename | 8.3 | 8.3 (+ VFAT long names) |
| Deletion | Status byte = E5h | First byte of name = E5h |

The key insight is that CP/M stores the block list **directly in the directory entry**, while FAT stores it as a **linked list in a separate table**. CP/M's approach is simpler and means the directory entry alone contains everything needed to find a file's data. FAT's approach scales better to large disks with many small files.

The 0xE5 deletion marker in FAT directories is a direct inheritance from CP/M — one of many fingerprints of CP/M's influence on the IBM PC ecosystem.

---

## 17. Practical Implications

### Why Files Have No Byte-Level Size

The 128-byte record granularity is a direct consequence of CP/M's heritage. The original Intel 8080 systems used 8-inch floppy disks with 128-byte sectors, and the record size was simply the sector size. When larger sectors became common, deblocking was added, but the 128-byte record abstraction was preserved for backward compatibility.

### Why the Directory Is Scanned Linearly

There is no hash table, B-tree, or any other index structure. Every file operation that involves searching (open, delete, rename, search first/next) scans the directory from entry 0 to DRM. On a disk with 64 directory entries, this is fast. On a hard disk with thousands of entries, it becomes noticeably slow — one of the reasons CP/M was less suitable for hard disk systems without modifications.

### Why There Are No Subdirectories

Gary Kildall considered the flat directory sufficient for the small floppy disks of the era. User areas provided a minimal form of organisation. CP/M 3 added no subdirectory support, and the filesystem was eventually superseded by FAT and other hierarchical systems.

### Why Disk Changes Are Dangerous

Because the ALV exists only in memory, swapping a disk without informing CP/M can cause the BDOS to allocate blocks that are already in use on the new disk, destroying data. The checksum mechanism provides some protection, but it is not infallible. Users of CP/M systems quickly learned to reset the drive (Ctrl-C at the prompt) before changing disks.

---

## Appendix A: Directory Entry Quick Reference

```
Byte:  0    1--------8  9--11  12  13  14  15  16-----------31
       ST   Filename    Type   EX  S1  S2  RC  Allocation Map

ST:    User number (0-15), E5h = deleted, 20h = label, 21h = timestamp
F/T:   ASCII uppercase, space-padded. High bits = attributes.
EX:    Extent low byte. (EX & EXM) = sub-extent, (EX >> log2(EXM+1)) = extent group.
S1:    Bytes in last record (CP/M 3, 1-128, 0 = full record). Always 0 in CP/M 2.2.
S2:    Extent high byte (bits 0-5). Logical extent = S2 × 32 + EX.
RC:    Records used in last logical extent (0-128).
AL:    Block numbers. 1 byte each if DSM ≤ 255, 2 bytes (LE) if DSM > 255.
       Zero = no block allocated.
```

## Appendix B: Common DPB Configurations

| System | SPT | BSH | BLM | EXM | DSM | DRM | AL0 | AL1 | OFF |
|--------|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| 8" SSSD | 26 | 3 | 7 | 0 | 242 | 63 | C0 | 00 | 2 |
| Amstrad PCW/+3 | 36 | 3 | 7 | 0 | 174 | 63 | C0 | 00 | 1 |
| Kaypro II | 40 | 3 | 7 | 0 | 194 | 63 | C0 | 00 | 1 |
| Osborne 1 | 20 | 4 | 15 | 1 | 45 | 63 | 80 | 00 | 3 |
| Amstrad CPC System | 36 | 3 | 7 | 0 | 170 | 63 | C0 | 00 | 2 |
| Amstrad CPC Data | 36 | 3 | 7 | 0 | 179 | 63 | C0 | 00 | 0 |

## Appendix C: Key BDOS File Functions

| Function | Number | Input | Description |
|----------|--------|-------|-------------|
| Search First | 17 | DE = FCB | Find first matching directory entry |
| Search Next | 18 | — | Find next matching entry |
| Delete File | 19 | DE = FCB | Delete all extents of a file |
| Read Sequential | 20 | DE = FCB | Read 128 bytes at current position |
| Write Sequential | 21 | DE = FCB | Write 128 bytes at current position |
| Make File | 22 | DE = FCB | Create a new directory entry |
| Rename File | 23 | DE = FCB | Rename (new name at FCB+16) |
| Open File | 15 | DE = FCB | Open existing file |
| Close File | 16 | DE = FCB | Write FCB back to directory |
| Read Random | 33 | DE = FCB | Read record at R0-R2 position |
| Write Random | 34 | DE = FCB | Write record at R0-R2 position |
| Compute File Size | 35 | DE = FCB | Set R0-R2 to file size in records |
| Set Random Record | 36 | DE = FCB | Set R0-R2 from current sequential position |

---

*This document describes the CP/M filesystem as implemented in CP/M 2.2 and CP/M 3 (CP/M Plus) by Digital Research. The same format, with minor variations, was used on the Amstrad PCW, Amstrad CPC, ZX Spectrum +3, Kaypro, Osborne, and hundreds of other Z80 and 8080-based systems.*
