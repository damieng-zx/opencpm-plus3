# CP/M 3.1 API Reference — OpenCPM+3

This document covers the BDOS, BIOS, terminal, and program conventions for writing
.COM utilities on this system. All information is specific to this implementation.

---

## Table of Contents

1. [Program Startup & Memory Map](#1-program-startup--memory-map)
2. [BDOS Calling Convention](#2-bdos-calling-convention)
3. [BDOS Functions](#3-bdos-functions)
4. [FCB Structure](#4-fcb-structure)
5. [BIOS Functions](#5-bios-functions)
6. [Terminal (Screen & Keyboard)](#6-terminal-screen--keyboard)
7. [Disk Parameter Block (DPB)](#7-disk-parameter-block-dpb)
8. [Useful Recipes](#8-useful-recipes)

---

## 1. Program Startup & Memory Map

### TPA Memory Map (mode 0)

```
0000h  JP warm_boot          ; WBOOT vector
0001h  dw bios_base          ; BIOS jump table address - 3
0003h  db IOBYTE             ; F8/f8-compatible I/O byte
0004h  db user_drive         ; high nibble = user, low nibble = drive
0005h  JP bdos               ; BDOS entry point
0006h  dw bdos_vector        ; BDOS jump target AND the TPA memory
                            ; ceiling (equals F600h / TPA_TOP).  CP/M 3
                            ; programs read this to size the TPA.
0038h  JP isr_handler        ; IM 1 vector: common tick/motor ISR
005Ch  FCB1 (36 bytes)       ; first filename argument
006Ch  FCB2 (36 bytes)       ; second filename argument (overlaps FCB1 AL)
0080h  db cmd_tail_len       ; command tail length
0081h  ds 127                ; command tail text (default DMA buffer)
0100h  ...program code...    ; entry point
       ...
F600h  common memory starts  ; SCB/BIOS stubs, not usable by programs
```

### Entry Conditions

When a .COM program starts executing at 0100h:

- **SP** = 0xF600 (`TPA_TOP` = first byte of common memory). The stack grows
  down into the TPA, so memory at and above 0xF600 is off limits.
- **C** = current default drive (0=A)
- **Z80 interrupts**: Enabled, IM 1
- **Page zero**: WBOOT at 0000h, IOBYTE at 0003h, user/drive at 0004h,
  BDOS at 0005h. The word at 0006h is the BDOS entry (`bdos_vector`) and
  also the memory ceiling: it equals 0xF600, like a real CP/M 3 where
  `(0006h)` is `BDOS_base + 6`. Programs that compute their top of memory
  from it (WordStar, MBASIC, Turbo Pascal, ...) stay below the common area.
- **DMA address**: 0080h (default)
- **FCB1** (005Ch): parsed first filename argument from command line
- **FCB2** (006Ch): parsed second filename argument
- **Command tail**: length byte at 0080h, ASCII text at 0081h (no trailing CR)
- Both FCBs are cleared (drive=0, name=spaces) if no argument was given

### Exit Convention

Return to the CCP by jumping to 0000h (warm boot). This reloads the CCP and
redisplays the prompt. You can also call BDOS function 0 (system reset).

Programs should close any open files before exiting (BDOS F16).

### TPA Size

~61K available (0100h to F5FFh). The top of the TPA is fixed at 0xF600
(the first byte of common memory); the word at 0006h is the BDOS entry.

---

## 2. BDOS Calling Convention

### Registers

| Register | Direction | Purpose |
|----------|-----------|---------|
| C | In | Function number |
| DE | In | Parameter (address, value, etc.) |
| E | In | Low-byte parameter for some functions |
| A | Out | Return value (low byte) |
| HL | Out | Return value (16-bit) |

### Calling Pattern (Z80)

```asm
        ld      c, func_num
        ld      de, parameter
        call    5
        ; A and HL contain return values
```

### Return Values

- Most functions return a status in A (0=success, 0xFF=error).
- HL usually matches A (L = A, H = 0) for 8-bit returns.
- 16-bit returns use HL directly.
- Other registers (BC, DE, IX, IY) are NOT preserved across BDOS calls unless
  the function docs say so.

---

## 3. BDOS Functions

### Console I/O

#### F0 — System Reset
- **In**: C=0
- **Effect**: Warm boot; does not return. Reloads CCP.

#### F1 — Console Input
- **In**: C=1
- **Out**: A=character (with echo)
- **Note**: Waits for keypress. Echoes the character.

#### F2 — Console Output
- **In**: C=2, E=character
- **Out**: A=E
- **Note**: Outputs one character to the screen.

#### F3 — Auxiliary Input
- **Out**: A=0x1A (EOF)
- **Note**: Stub — no auxiliary device.

#### F4 — Auxiliary Output
- **In**: E=character
- **Note**: Stub — discarded.

#### F5 — List Output
- **In**: E=character
- **Note**: Stub — discarded (no printer).

#### F6 — Direct Console I/O
- **In**: C=6, E=command
- **Out**: varies
- E=0xFF: Read a character (non-blocking). Returns 0 if none ready.
- E=0xFE: Status check. Returns 0xFF if char ready, 0x00 if not.
- E=other: Output character E directly. Bypasses BDOS paging and echo processing.

#### F7 — Get IOBYTE
- **Out**: A=IOBYTE value

#### F8 — Set IOBYTE
- **In**: E=value

#### F9 — Print String
- **In**: C=9, DE=address of '$'-terminated string
- **Out**: A=0x24 ('$')
- **Note**: Outputs characters until '$' is found. The '$' is NOT printed.

#### F10 — Read Console Buffer
- **In**: C=10, DE=buffer address
- **Out**: A=0x0D
- **Buffer format**:
  ```
  +0: max chars  (set by caller, e.g. 126)
  +1: actual len (filled by BDOS)
  +2: data bytes (characters, no CR)
  ```
- **Line editing**: BS (0x08) / DEL (0x7F) = destructive backspace.
  Ctrl-C = abort + warm boot. CR = submit.
- **Note**: No cursor movement, insert mode, or history.

#### F11 — Get Console Status
- **Out**: A=0xFF (char ready) or 0x00 (not ready)

#### F12 — Return Version Number
- **Out**: HL=0x0031 (CP/M 3.1)

### Disk Operations

#### F13 — Reset Disk System
- **Effect**: Resets to drive A, clears login/RO vectors, sets DMA=0080h.

#### F14 — Select Disk
- **In**: E=drive (0=A, 1=B, ...)
- **Note**: Sets default drive for subsequent file operations.

#### F24 — Return Login Vector
- **Out**: HL=16-bit bitmap (bit N = drive N logged in)

#### F25 — Return Current Disk
- **Out**: A=drive number (0=A)

#### F26 — Set DMA Address
- **In**: DE=DMA address
- **Note**: Sets the 128-byte buffer address for disk reads/writes. Default 0080h.

#### F27 — Get Allocation Vector Address
- **Out**: HL=address of allocation bitvector for current drive

#### F28 — Write Protect Disk
- **Effect**: Marks current drive as read-only in software.

#### F29 — Get Read-Only Vector
- **Out**: HL=16-bit bitmap (bit N = drive N is read-only)

#### F31 — Get DPB Address
- **Out**: HL=address of Disk Parameter Block for current drive

#### F37 — Reset Drive
- **In**: DE=16-bit drive bitmap
- **Effect**: Clears login for specified drives.

#### F48 — Flush Buffers
- **Out**: A=0
- **Note**: Writes any dirty deblock buffer to disk.

### File Operations

#### F15 — Open File
- **In**: DE=FCB address
- **Out**: A=0 (found) or 0xFF (not found)
- **Note**: Sets CR=0. FCB must have drive and filename filled in.

#### F16 — Close File
- **In**: DE=FCB address
- **Out**: A=0 or 0xFF
- **Note**: Flushes directory entry. Required to save written data!

#### F17 — Search First
- **In**: DE=FCB address (supports '?' wildcards in name/type)
- **Out**: A=entry index (0-3) or 0xFF (not found)
- **Note**: Copies matching 128-byte directory sector to DMA.
  Return value 0-3 = offset into DMA (entry = DMA + index*32).

#### F18 — Search Next
- **Out**: A=entry index (0-3) or 0xFF (no more matches)
- **Note**: Continues from previous F17. Same FCB must remain at 005Ch.

#### F19 — Delete File
- **In**: DE=FCB address (supports wildcards)
- **Out**: A=0 (deleted) or 0xFF (none found)

#### F20 — Read Sequential
- **In**: DE=FCB address
- **Out**: A=0 (OK), 1 (EOF), 0xFF (error)
- **Note**: Reads 128 bytes to DMA. Advances CR. Auto-extends to next extent.

#### F21 — Write Sequential
- **In**: DE=FCB address
- **Out**: A=0 (OK), 1 (directory full), 2 (disk full or write-protected), 0xFF (write error)
- **Note**: Writes 128 bytes from DMA. Advances CR. Allocates blocks as needed.

#### F22 — Make File
- **In**: DE=FCB address
- **Out**: A=0 (created) or 0xFF (directory full)
- **Note**: Creates new directory entry. FCB must have drive and filename.
  Should be followed by writes then close.

#### F23 — Rename File
- **In**: DE=FCB address
- **Note**: Bytes 1-11 = old name, bytes 17-27 = new name. Supports '?' in old.

#### F30 — Set File Attributes
- **In**: DE=FCB address
- **Note**: Copies attribute bits (bit 7 of name/type bytes) to directory.

#### F33 — Read Random
- **In**: DE=FCB address (R0/R1/R2 = record number)
- **Out**: A=0 (OK), 1 (unwritten), 4 (no extent), 6 (random record overflow)
- **Note**: Reads 128 bytes from arbitrary record position to DMA.

#### F34 — Write Random
- **In**: DE=FCB address (R0/R1/R2 = record number)
- **Out**: A=0 (OK), 1 (directory full), 2 (disk full or write-protected), 6 (random record overflow)
- **Note**: Writes 128 bytes from DMA to arbitrary record position.

#### F35 — Compute File Size
- **In**: DE=FCB address
- **Out**: FCB[33-35] = random record count (virtual file size)
- **Note**: Scans all extents. Returns highest record + 1.

#### F36 — Set Random Record
- **In**: DE=FCB address
- **Out**: A=0, HL=0
- **Note**: FCB[33-35] = current sequential position as random record.

#### F40 — Write Random with Zero Fill
- **In**: DE=FCB (R0/R1/R2 set)
- **Out**: A=0 (OK), 5 (no directory space), 6 (random record overflow)
- **Note**: Same as F34 in this implementation, except that a missing
  directory slot returns 5 as defined for F40.

### CP/M 3 Extended Functions

#### F44 — Set Multi-Sector Count
- **In**: E=count (1..127)
- **Out**: A=0 (accepted) or 0xFF (invalid)
- **Note**: The count is stored in the SCB (`scb_multi`, offset 0x4A) and
  is reset to 1 by warm boot, but this BDOS transfers **one record per
  call** and reports it in `H`. CP/M 3 permits a partial transfer, so
  programs that honour `H` (PIP does) call again for the rest, while
  programs that ignore `H` keep the single-record behaviour.

#### F45 — Set BDOS Error Mode
- **In**: E=mode
- **Note**: Stored in the SCB (`scb_errmode`, offset 0x4B) as well.

#### F46 — Get Free Disk Space
- **In**: E=drive (0=A:, 1=B:, ...)
- **Out**: A=0 on success, three bytes at the DMA address hold the number
  of free 128-byte records (low, high, 0). A=0xFF if the drive is
  invalid. The DMA address itself is not changed.
- **Note**: Computed from the drive's allocation vector, so it reflects
  blocks that are allocated in the directory.

#### F47 — Chain to Program
- **In**: E=0xFF to adopt the current drive/user as the CCP's
- **Note**: Sets a chain flag in the SCB (`scb_chain`, offset 0x07) and
  warm boots. The CCP sees the flag and executes the command tail
  already at [0080h] instead of prompting, without clearing the program
  return code (F108). Does not return on success.

#### F49 — Get/Set System Control Block
- **In**: DE=PB (parameter block address)
- **PB format**: `[offset, operation, value_lo, value_hi]`
  - operation 0x00: get word → returns SCB word at offset
  - operation 0xFE: set byte
  - operation 0xFF: set word
- **Out**: A=0xFF, HL=0 for an invalid offset (0x63+) or unknown
  operation; otherwise the value read/written.
- **Note**: The SCB is 100 bytes (0x00-0x63). Offset 0x63 is the high
  byte of `scb_tpa`, so it is rejected to keep word accesses from running
  into the visible BIOS table.

#### F50 — Direct BIOS Call
- **In**: DE=PB (parameter block address)
- **PB format**: `[func, A, C, B, E, D, L, H]` (8 bytes)
- **Out**: A, HL = BIOS return values
- **Note**: Calls BIOS function number `func` with specified registers.
- **Note**: F50 follows the public BIOS numbering. Function 30 (`USERF`) is not supported through F50 because `USERF` requires an inline `DW` after `CALL`, which the 8-byte F50 parameter block cannot express.

#### F59 — Load Overlay
- **In**: DE=FCB of an already-open file; FCB+21h holds the load address.
  DE=0 means "nothing to load" and returns 0.
- **Out**: A=0 (loaded to end of file) or 0xFE (load error)
- **Note**: Reads 128-byte records sequentially to the address in the
  FCB and restores the DMA address afterwards.

#### F98 — Clean Up Disc (CCP helper)
- **Out**: A=0
- **Note**: Our buffers are per-call, so there is nothing to purge.

#### F99 — Truncate File
- **In**: DE=FCB; R0/R1/R2 = required file length in 128-byte records
- **Out**: A=0 on success, 0xFF if the file is not found, the target would
  extend the file, the drive is invalid, the file is read-only, or R2 is
  non-zero (this filesystem never exceeds 65535 records).
- **Effect**: Extents past the new length are removed from the directory
  and their blocks returned to the allocation vector. The extent holding
  the cut keeps only the blocks that hold records below the target and
  gets `RC = target - extent_base`. Truncating to zero keeps a single
  empty extent, so the file still exists with size 0. The FCB is
  re-synchronised to extent 0 (as F15 would leave it), with `CR = 0`.
- **Note**: No XFCB is involved — this filesystem has no passwords or
  date stamps, so the password hook in the CP/M 3 definition is a no-op
  here.

#### F104 — Set Date/Time
- **In**: DE=address of 4-byte date/time: `[days_lo, days_hi, hour_BCD, min_BCD]`

#### F105 — Get Date/Time
- **Out**: DMA gets 5 bytes: `[days_lo, days_hi, hour, min, sec]`
- **Out**: A=seconds, HL=day counter

#### F107 — Get Serial Number
- **In**: DE=buffer in the TPA
- **Out**: A=0; six ASCII bytes written at DE (`OPNCP3`)

#### F108 — Get/Set Program Return Code
- **In**: DE=0xFFFF to read, otherwise the new 16-bit code
- **Out**: HL=current code
- **Note**: Stored in the SCB (`scb_rc`, offset 0x08). The CCP clears it
  when it reads a new command from the console, and keeps it across F47.

#### F109 — Get/Set Console Mode
- **In**: DE=0xFFFF → get; DE=value → set

#### F110 - Get/Set Output Delimiter
- **In**: DE=0xFFFF (get) or E=delimiter (set)
- **Out**: A=current delimiter, HL=current delimiter
- **Note**: F9 terminates on this delimiter. The default is `$`.

#### F111 — Print Block to Console
- **In**: DE=character control block in the TPA: `[addr_lo, addr_hi, len_lo, len_hi]`
- **Out**: A=0
- **Note**: Output goes through the console path (paging/^S respected).

#### F112 — Print Block to Printer
- **In**: DE=character control block (same layout as F111)
- **Out**: A=0
- **Note**: No printer is fitted, so the block is discarded.

---

## 4. FCB Structure

### Layout (36 bytes)

```
Offset  Size  Field     Description
------  ----  -------   -----------
 0       1    DR        Drive: 0=default, 1=A, 2=B
 1-8     8    F1-F8     Filename (space-padded, ASCII uppercase)
 9-11    3    T1-T3     Filetype (space-padded, ASCII uppercase)
                       T1 bit 7 = Read-Only attribute
                       T2 bit 7 = System attribute
                       T3 bit 7 = Archive attribute
 12      1    EX        Extent number (low)
 13      1    S1        Reserved
 14      1    S2        Extent number (high)
 15      1    RC        Record count in this extent (0-128)
 16-31  16    AL0-ALF   Allocation block numbers (disk block list)
 32      1    CR        Current record (sequential access, 0-127)
 33      1    R0        Random record number (low byte)
 34      1    R1        Random record number (mid byte)
 35      1    R2        Random record number (high byte)
```

### Record Counting

- Each extent holds up to 128 records (16K of data on 1K-block disks).
- `CR` is the sequential record pointer within the current extent (0-127).
- `RC` is the number of records written in this extent (set by BDOS).
- For random access, the 24-bit record number in R0/R1/R2 addresses any
  128-byte record in the file.

### Wildcards

- '?' (0x3F) in any name/type position matches any character.
- Used with F17 (Search First) and F19 (Delete File).

### Typical Usage Pattern

```asm
; Open a file
fcb:    db  0              ; default drive
        db  'HELLO   '    ; filename (8 chars, space padded)
        db  'TXT'         ; extension (3 chars, space padded)
        ds  24            ; rest zeroed

        ld  de, fcb
        ld  c, 15         ; open file
        call 5
        cp  0xFF
        jr  z, not_found

        ; Read a record
        ld  de, fcb
        ld  c, 20         ; read sequential
        call 5
        ; data is now at DMA address (default 0080h)
```

---

## 5. BIOS Functions

### How to Call BIOS Functions

Use BDOS F50 (Direct BIOS Call) with an 8-byte parameter block:

```asm
bios_pb:
        db  func_num      ; BIOS function number
        db  0             ; A
        db  0             ; C
        db  0             ; B
        db  char          ; E
        dw  0             ; D, L (or DE as word)
        dw  0             ; H (or HL as word)

        ld  de, bios_pb
        ld  c, 50
        call 5
```

Alternatively, get the BIOS base address from 0001h and call through the
jump table directly:

```asm
        ld  a, (1)        ; low byte of bios base (normally 0x??00)
        ; BIOS function N is at bios_base + N*3
```

### Function Table

| Fn | Name | In | Out | Description |
|----|------|----|-----|-------------|
| 0 | BOOT | — | — | Cold boot. Never called by programs. |
| 1 | WBOOT | — | — | Warm boot. Use JP 0000h instead. |
| 2 | CONST | — | A=0xFF/0x00 | Console input status. |
| 3 | CONIN | — | A=char | Console input (blocking). |
| 4 | CONOUT | C=char | — | Console output. |
| 5 | LIST | C=char | — | Printer output (stub). |
| 6 | AUXOUT | C=char | — | Aux output (stub). |
| 7 | AUXIN | — | A=0x1A | Aux input (stub, returns EOF). |
| 8 | HOME | — | — | Home disk to track 0. |
| 9 | SELDSK | C=drive, E=login | HL=DPH or 0 | Select disk drive (0=A, 1=B). |
| 10 | SETTRK | BC=track | — | Set track for next I/O. |
| 11 | SETSEC | BC=sector | — | Set sector for next I/O. |
| 12 | SETDMA | BC=address | — | Set DMA address for next I/O. |
| 13 | READ | — | A=0/1 | Read 128 bytes to DMA. |
| 14 | WRITE | C=type | A=0/1/2 | Write 128 bytes from DMA. |
| 15 | LISTST | — | A=0 | List device status (stub). |
| 16 | SECTRN | BC=sector, DE=table | HL=physical | Sector translate (no-op). |
| 17 | CONOST | — | A=0xFF | Console output status (always ready). |
| 18 | AUXIST | — | A=0 | Aux input status (stub). |
| 19 | AUXOST | — | A=0 | Aux output status (stub). |
| 20 | DEVTBL | — | HL=table | Character device table. |
| 21 | DEVINIT | — | — | Device init (stub). |
| 22 | DRVTBL | — | HL=table | Drive table (16 pointers). |
| 23 | MULTIO | A=count | — | Set multi-sector count. |
| 24 | FLUSH | — | A=0 | Flush disk buffers (stub). |
| 25 | MOVE | HL=dst,DE=src,BC=len | — | Block move (LDIR). |
| 26 | TIME | C=0/0xFF | — | Get/set time (stub). |
| 27 | BNKSEL | A=bank | — | Select bank (0=TPA, else system). |
| 28 | SETBNK | A=bank | — | Set DMA bank for next I/O. |
| 29 | XMOVE | B=dst,C=src | — | Set up cross-bank move. |
| 30 | USERF | inline DW | varies | XBIOS dispatch (Amstrad extensions).  See [XBIOS/TE Interface](cpm-plus-xbios.md). |
| 31 | — | — | — | Reserved (JP 0). |
| 32 | SCRMODE | A=32 or 51 | — | Set screen column count (clears screen). |

---

## 6. Terminal (Screen & Keyboard)

### Screen Dimensions

| Mode | Columns | Rows | Char Width | Font |
|------|---------|------|------------|------|
| 51-col | 51 | 24 | 5px | 5px non-byte-aligned |
| 32-col | 32 | 24 | 8px | 8px byte-aligned |

Switch modes: `SCREEN 51` or `SCREEN 32` from the CCP, or BIOS fn 32.

Default: 51 columns.

The current column count minus 1 is stored in the SCB at offset 0x1A
(`conwidth`).

### Control Codes

| Code | Name | Effect |
|------|------|--------|
| 0x07 | BEL | Ignored (no beep) |
| 0x08 | BS | Move cursor left, erase character. Wraps to previous line. |
| 0x09 | TAB | Advance to the next 8-column tab stop, padding with spaces. |
| 0x0A | LF | Cursor down one row. Scrolls if at bottom. |
| 0x0D | CR | Cursor to column 0. |
| 0x1B | ESC | Start escape sequence. |

### Escape Sequences (VT52-compatible subset, plus ADM-3A/Kaypro codes)

Send these via BDOS F2 (one character at a time).

#### Cursor Movement

| Sequence | Name | Effect |
|----------|------|--------|
| `ESC A` | CUU | Cursor up (stop at row 0) |
| `ESC B` | CUD | Cursor down (stop at row 23) |
| `ESC C` | CUF | Cursor right (stop at last column) |
| `ESC D` | CUB | Cursor left (stop at column 0) |
| `ESC H` | HOME | Cursor to (0, 0) |
| `ESC Y r c` | CUP | Absolute position. r = row+32, c = col+32. Row 0-23, col 0 to cols-1. |
| `ESC = r c` | CUP | ADM-3A/Kaypro absolute position; same encoding as `ESC Y`. |
| `ESC +` | HOME | ADM-3A/Kaypro home (same as `ESC H`) |
| `ESC j` | SCP | Save cursor position |
| `ESC k` | RCP | Restore cursor position |

#### Erase

| Sequence | Name | Effect |
|----------|------|--------|
| `ESC E` | CEL | Clear entire screen (cursor stays) |
| `ESC *` | — | ADM-3A/Kaypro clear screen and home |
| `ESC J` | ED0 | Erase from cursor to end of screen |
| `ESC K` | EL0 | Erase from cursor to end of line |
| `ESC T` | — | ADM-3A/Kaypro erase to end of line (same as `ESC K`) |
| `ESC d` | ED1 | Erase from top of screen to cursor |
| `ESC l` | EL1 | Erase entire current line |
| `ESC o` | EL0d | Erase from start of line to cursor |

#### Scroll / Line Operations

| Sequence | Name | Effect |
|----------|------|--------|
| `ESC I` | RI | Reverse index: cursor up; scroll down if at row 0 |
| `ESC L` | IL | Insert blank line at cursor row |
| `ESC M` | DL | Delete cursor row (pull up) |
| `ESC N` | DCH | Delete character at cursor (shift left) |

#### Ignored Sequences

These are consumed without error but have no effect:

`ESC 0` `ESC 1` (status line), `ESC e` `ESC f` (cursor on/off),
`ESC p` `ESC q` (reverse), `ESC r` (underline), `ESC v` `ESC w` (wrap),
`ESC x` `ESC y` (80-col mode).

Sequences with a consumed parameter: `ESC 2 p` `ESC 3 p` `ESC 4 p` `ESC 5 p`
`ESC b col` `ESC c col` `ESC X tr lc h w`.

### Keyboard

#### Key Map (unshifted)

```
Row 0:  [CS]   z   x   c   v
Row 1:   a     s   d   f   g
Row 2:   q     w   e   r   t
Row 3:   1     2   3   4   5
Row 4:   0     9   8   7   6
Row 5:   p     o   i   u   y
Row 6:  [Enter] l   k   j   h
Row 7:  [Space] [SS] m   n   b
```

#### Modifier Combinations

The Caps Shift row follows the function-key table in the Spectrum +3
CP/M Plus manual (Appendix II.2.2):

| Mode | Keys | Characters |
|------|------|------------|
| Unshifted | — | lowercase letters, digits, space, enter |
| Caps Shift | Caps Shift | UPPERCASE letters |
| Caps+0 | Caps Shift + 0 | DEL (0x08) |
| Caps+1 | Caps Shift + 1 | Control-W (0x17) |
| Caps+2 | Caps Shift + 2 | Caps Lock (no character) |
| Caps+3 | Caps Shift + 3 | Control-S (0x13) |
| Caps+4 | Caps Shift + 4 | Control-I / TAB (0x09) |
| Caps+5 | Caps Shift + 5 | Control-A (0x01) |
| Caps+6 | Caps Shift + 6 | Control-^ (0x1E) |
| Caps+7 | Caps Shift + 7 | Control-_ (0x1F) |
| Caps+8 | Caps Shift + 8 | Control-F (0x06) |
| Caps+9 | Caps Shift + 9 | Control-G (0x07) |
| **BREAK** | **Caps Shift + Space** | **Control-[ / ESC (0x1B)** |
| Symbol Shift | Symbol Shift | punctuation: `! @ # $ % & * ( ) - = + etc.`; Space stays a space |
| Control | Caps+Symbol (Extend Mode) | Ctrl-A through Ctrl-Z (0x01-0x1A) |
| Ctrl-C | Caps+Sym+C | 0x03 |

#### Auto-repeat

- Initial delay: ~500ms
- Repeat rate: ~17 chars/sec

### Console I/O Patterns

```asm
; Print a string
print_msg:
        ld  de, msg
        ld  c, 9
        call 5
        ret
msg:    db 'Hello, world!', 13, 10, '$'

; Print a single character
        ld  e, 'A'
        ld  c, 2
        call 5

; Print a newline
print_crlf:
        ld  e, 13     ; CR
        ld  c, 2
        call 5
        ld  e, 10     ; LF
        ld  c, 2
        call 5
        ret

; Read a line of input
input_buf:
        db  80         ; max 80 characters
        ds  81         ; len byte + 80 data bytes

        ld  de, input_buf
        ld  c, 10
        call 5
        ; input_buf+1 = number of chars typed
        ; input_buf+2 = start of character data

; Check for keypress (non-blocking)
        ld  c, 11
        call 5
        cp  0xFF
        jr  z, key_available

; Direct console I/O — read without echo
        ld  e, 0xFF
        ld  c, 6
        call 5
        ; A=character or 0 if none ready
```

---

## 7. Disk Parameter Block (DPB)

### Standard +3 Disk Format

```
SPT=36  BSH=3  BLM=7  EXM=0  DSM=174  DRM=63
AL0=C0h  AL1=00h  CKS=16  OFF=1  PSH=2  PHM=3
```

### DPB Structure (17 bytes at the address returned by F31)

| Offset | Size | Field | Value | Meaning |
|--------|------|-------|-------|---------|
| 0 | 2 | SPT | 36 | Sectors per track (physical, 512-byte) |
| 2 | 1 | BSH | 3 | Block shift (log2 of block size - 7) |
| 3 | 1 | BLM | 7 | Block mask (2^BSH - 1) |
| 4 | 1 | EXM | 0 | Extent mask |
| 5 | 2 | DSM | 174 | Maximum block number (total blocks - 1) |
| 7 | 2 | DRM | 63 | Maximum directory entry number |
| 9 | 1 | AL0 | 0xC0 | Allocation vector byte 0 (first 2 blocks = directory) |
| 10 | 1 | AL1 | 0x00 | Allocation vector byte 1 |
| 11 | 2 | CKS | 16 | Directory checksum bytes |
| 13 | 2 | OFF | 1 | Reserved tracks (track 0 = boot) |
| 15 | 1 | PSH | 2 | Physical sector shift (log2 of phys/128) |
| 16 | 1 | PHM | 3 | Physical sector mask (2^PSH - 1) |

### Key Calculations

- **Block size**: 128 << BSH = 128 << 3 = 1024 bytes (1K)
- **Records per block**: BLM + 1 = 8
- **Disk capacity**: (DSM + 1) × block_size = 175 × 1K = 175K
- **Directory entries**: DRM + 1 = 64
- **Directory blocks**: 2 (from AL0=C0h = bits 7,6 set = blocks 0,1)
- **Physical sector size**: 128 << PSH = 128 << 2 = 512 bytes
- **Records per physical sector**: PHM + 1 = 4

---

## 8. Useful Recipes

### Parse the Command Tail

The CCP puts everything after the command name into the buffer at 0080h:

```asm
; Get command tail
        ld  a, (0x80)      ; length byte
        or  a
        jr  z, no_args     ; no arguments
        ld  hl, 0x81       ; start of text
        ; process HL[0..length-1]
```

### Copy Filename from FCB to Buffer

```asm
; FCB at 005Ch has the parsed filename
; Copy "NAME.EXT" to a display buffer
print_fcb_name:
        ld  hl, 0x5C + 1   ; point to filename field
        ld  b, 8
        call copy_spaces    ; copy 8 chars of name
        ld  e, '.'
        ld  c, 2
        call 5              ; print dot
        ld  hl, 0x5C + 9   ; point to extension field
        ld  b, 3
        call copy_spaces    ; copy 3 chars of ext
        ret

copy_spaces:
        ld  e, (hl)
        ld  c, 2
        call 5
        inc hl
        djnz copy_spaces
        ret
```

### Directory Listing Pattern

```asm
; List files matching pattern
search_fcb:
        db  0                ; default drive
        db  '????????'      ; wildcard name
        db  '???'           ; wildcard extension (or 'COM' for .COM files)
        ds  24              ; zeroed

        ld  de, search_fcb
        ld  c, 17           ; search first
        call 5
        cp  0xFF
        jr  z, no_files

show_entry:
        ; Directory data is at DMA (0080h)
        ; Entry at DMA + A*32
        ; Bytes 1-11 are the filename
        ; Print it...

        ld  de, search_fcb
        ld  c, 18           ; search next
        call 5
        cp  0xFF
        jr  nz, show_entry
```

### Clear Screen (VT52)

```asm
clear_screen:
        ld  e, 0x1B         ; ESC
        ld  c, 2
        call 5
        ld  e, 'E'          ; ESC E = clear screen
        ld  c, 2
        call 5
        ret
```

### Position Cursor

```asm
; Move cursor to row 5, column 10
cursor_xy:
        ld  e, 0x1B         ; ESC
        ld  c, 2
        call 5
        ld  e, 'Y'          ; ESC Y = cursor position
        ld  c, 2
        call 5
        ld  e, 5 + 32       ; row + 32 = 37
        ld  c, 2
        call 5
        ld  e, 10 + 32      ; col + 32 = 42
        ld  c, 2
        call 5
        ret
```

### Get Free Disk Space (Human-Readable)

```asm
check_free:
        ld  e, 0            ; default drive
        ld  c, 46           ; get free space
        call 5
        ; DMA[0..2] = 24-bit LE free record count
        ; Each record = 128 bytes, 8 records per 1K block
        ld  hl, (0x80)      ; low 16 bits
        ld  a, (0x82)       ; high byte
        ; Divide HL by 8 to get free K (for 1K blocks)
        srl a
        rr h
        srl a
        rr h
        srl a
        rr h
        ; HL = free K
        ; Print HL as decimal...
```

### Set Screen Mode via BIOS

```asm
set_51col:
        ld  de, bios_pb
        ld  c, 50
        call 5
        ret
bios_pb:
        db  32              ; BIOS fn 32 = SCRMODE
        db  51              ; A = 51 columns
        ds  6               ; remaining params zeroed
```

### Exit with Return Code

```asm
        ; Set return code to 1
        ld  de, 1
        ld  c, 108
        call 5

        ; Exit to CCP
        jp  0               ; warm boot
```

### Convert HL to Decimal String

```asm
; Convert HL to decimal ASCII at DE, return length in B
; Destroys AF, BC, HL
hl_to_dec:
        ld  b, 0
        ld  c, 10
.divide:
        call div_hl_c       ; HL = HL/10, A = HL%10
        add '0'
        push af
        inc b
        ld  a, h
        or  l
        jr  nz, .divide
.store:
        pop af
        ld  (de), a
        inc de
        djnz .store
        ret

; Divide HL by C, quotient in HL, remainder in A
div_hl_c:
        ld  a, 0
        ld  b, 16
.shift:
        sla l
        rl h
        rla
        cp  c
        jr  c, .skip
        sub c
        inc l
.skip:
        djnz .shift
        ret
```

---

## Quick Reference Card

```
BDOS Entry:     CALL 5 (C=function, DE=param, returns A/HL)
Warm Boot:      JP 0
BDOS Address:   word at 0006h (BDOS jump target); TPA top = 0xF600

Console:
  F1  = read char (echo)     F2  = write char
  F6  = direct I/O           F9  = print $-string
  F10 = read line            F11 = key status

Files:
  F15 = open    F16 = close   F17 = search first
  F18 = search next           F19 = delete
  F20 = read seq  F21 = write seq
  F22 = make     F23 = rename
  F33 = read rand  F34 = write rand
  F35 = file size  F36 = set random

Disk:
  F13 = reset    F14 = select drive  F25 = current drive
  F26 = set DMA  F31 = get DPB       F46 = free space

Screen:
  51x24 or 32x24 (BIOS fn 32 to switch)
  ESC E = clear     ESC H = home
  ESC Y r c = position (+32 offset to both)
  ESC J = erase to end of screen
  ESC K = erase to end of line

FCB at 005Ch (36 bytes):
  [DR, F1-F8, T1-T3, EX, S1, S2, RC, AL0-ALF, CR, R0-R2]

Command tail: length at 0080h, text at 0081h
```
