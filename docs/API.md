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

- **SP** = 0xF5FE (`TPA_TOP` - 2). The CCP pushes 0000h (the warm-boot
  vector) as the program's return address, exactly like the CP/M 3 CCP, so
  a transient can end with `RET`. The stack grows down into the TPA, so
  memory at and above 0xF600 is off limits.
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

### COM file header (RSX-enabled programs)

A .COM file whose first byte is `RET` (`0C9h`) carries a CP/M 3 COM header,
as produced by `GENCOM` for programs with attached RSX modules.  The CCP's
loader copies the file to 0100h; the header occupies 0100h-01FFh and the
actual module starts at 0200h.  The loader then moves `comsize` (the word
at 0101h) bytes from 0200h down to 0100h before starting the program, like
the CP/M 3 `LOADER`.  **Attached RSX modules are not installed**: this
system has no RSX chain, so SET.COM runs without its RSX.  The helper lives
in common memory (`ccp_run_prog`) because the loaded program overwrites the
CCP.

### Exit Convention

Return to the CCP by jumping to 0000h (warm boot). This reloads the CCP and
redisplays the prompt. You can also call BDOS function 0 (system reset).
Because the CCP pushes 0000h before entry, a plain `RET` warm-boots too
(that is how DRI's `SETKEYS` exits).

Programs should close any open files before exiting (BDOS F16).

### TPA Size

~61K available (0100h to F5FFh). The top of the TPA is fixed at 0xF600
(the first byte of common memory); the word at 0006h is the BDOS entry.

### Cold start and PROFILE.SUB

After a cold boot the CCP looks for `PROFILE.SUB` on the default drive and,
if it exists, submits it (through `SUBMIT.COM`) before the first prompt, so
start-up commands run exactly like typed ones. A warm boot does not run it
again: the SCB byte at offset 0x0A (`scb_coldboot`) is re-initialised to 1
by a cold boot and the CCP clears it when it fires the profile. Because the
CCP itself is reloaded from the bank-6 staging copy on every warm boot, that
SCB byte is the only place the distinction can live.

### Submit-file program input

A submit line that begins with `<` is console input for the program the
previous line started, the facility CP/M 2.2 needed `XSUB.COM` for and
Amstrad's `PROFILE.SUB` uses to feed `PIP`. The CCP collects those lines
while it still owns the file, strips the marker and queues the text (with
its CR) through BDOS function 124 — a private helper, not part of CP/M 3 —
into a 512-byte buffer in bank 6. While that buffer holds data, `con_in` and
`con_status` serve it instead of the keyboard, so an ordinary `F1`/`F6`/`F10`
read sees the line; when it empties, the keyboard takes over again. A bare
`<` line queues an empty line, which is how `PIP` is told its input is done.

The queue is emptied at every prompt, so input a program leaves unread is
discarded rather than being executed as commands.

BDOS function 124 (private, used by the CCP only):

- **In**: DE = text in the TPA, B = length; DE = 0 clears the queue
- **Out**: A = 0, or 0xFF when the buffer is full (512 bytes)

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

#### F6 - Direct Console I/O
- **In**: C=6, E=command
- **Out**: varies
- E=0xFF: Read a character (non-blocking). Returns 0 if none ready.
- E=0xFE: Status check. Returns 0xFF if char ready, 0x00 if not.
- E=0xFD: Wait for a character and return it without echoing (CP/M 3).
  Programs use this for "press any key" prompts; returning immediately
  would look like a keypress and the program would carry on.
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
- **Note**: Also forgets the detected format of A: and B:, so the next
  login probes the disc again (the media may have been swapped, and a
  formatted disc may have a different geometry).

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
- **Effect**: Clears login for the specified drives and makes the next
  login probe their format again.

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

#### F19 - Delete File
- **In**: DE=FCB address (supports wildcards)
- **Out**: A=0 (deleted) or 0xFF (none found)
- **Note**: A file with the R/O attribute (bit 7 of the filetype byte,
  entry offset 9) is never deleted.  With F45's error mode bit set the call
  returns 0xFF; otherwise it prints `Bdos Err: R/O` and warm boots, like
  CP/M.

#### F20 — Read Sequential
- **In**: DE=FCB address
- **Out**: A=0 (OK), 1 (EOF), 0xFF (error)
- **Note**: Reads up to F44's count records (default 1) to consecutive
  128-byte DMA buffers. Advances CR and the DMA address, and auto-extends to
  the next extent. `H` reports the records actually read; at EOF the return
  is 1 with a possibly short count (see F44).

#### F21 — Write Sequential
- **In**: DE=FCB address
- **Out**: A=0 (OK), 1 (directory full), 2 (disk full or write-protected), 0xFF (write error)
- **Note**: Writes up to F44's count records (default 1) from consecutive
  128-byte DMA buffers. Advances CR and the DMA address, and allocates
  blocks as needed. `H` reports the records actually written; a disk-full or
  directory-full error can leave a short count.

#### F22 — Make File
- **In**: DE=FCB address
- **Out**: A=0 (created) or 0xFF (directory full)
- **Note**: Creates new directory entry. FCB must have drive and filename.
  Should be followed by writes then close.

#### F23 - Rename File
- **In**: DE=FCB address
- **Note**: Bytes 1-11 = old name, bytes 17-27 = new name. Supports '?' in old.
  A read-only file (bit 7 of the filetype byte) is refused the same way as
  F19: A=0xFF in error mode, otherwise `Bdos Err: R/O` and a warm boot.

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
- **Note**: Same as F34, except that a newly allocated data block is
  filled with zeros before the record is written (CP/M 3 semantics, so an
  all-zero record identifies an unwritten random record). The fill writes
  every record of the block from a zero buffer in common memory and never
  touches the user's DMA area. A missing directory slot returns 5.

### CP/M 3 Extended Functions

#### F44 — Set Multi-Sector Count
- **In**: E=count (1..127)
- **Out**: A=0 (accepted) or 0xFF (invalid)
- **Note**: The count is stored in the SCB (`scb_multi`, offset 0x4A) and
  is reset to 1 by warm boot.  The next F20/F21 transfers up to that many
  128-byte records, advancing the DMA by 128 per record, and sets `H` to the
  number actually moved; a count of 1 keeps the CP/M 2.2 fixed-buffer
  behaviour.  A read stops early at EOF (A=1) with the short count in `H`.
  The count applies only to sequential I/O; the random functions always move
  one record.  The valid range is 1..127.  An invalid count resets it to 1
  rather than leaving a stale larger value: PIP asks for 128, is rejected,
  falls back to one record and later uses smaller valid counts; Z80ASM asks
  for 8 and gets its whole source block in one read.

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
| 30 | USERF | inline DW | varies | XBIOS dispatch (Amstrad extensions).  Implements the TE calls plus the disc calls (`DD_INIT`, `DD_SETUP`, `DD_LOGIN`, `DD_SEL_FORMAT`, `DD_READ_ID`, `DD_READ_SECTOR`, `DD_WRITE`, `DD_CHECK_SECTOR`, `DD_FORMAT`, `DD_L_DPB`, `DD_L_XDPB`, `DD_L_READ`, `DD_L_WRITE`, motor on/off/timeout, `DD_L_SEEK`, `KM_SET_SPEED`, `KM_SET_KEY`, `KM_SET_EXPAND`, `KM_KT_PUT` and `KM_KT_GET`).  See [XBIOS/TE Interface](cpm-plus-xbios.md). |
| 31 | — | — | — | Reserved (JP 0). |
| 32 | SCRMODE | A=32, 51 or 64 | — | Set screen column count (clears screen). |

---

## 6. Terminal (Screen & Keyboard)

### Screen Dimensions

| Mode | Columns | Rows | Char Width | Font |
|------|---------|------|------------|------|
| 51-col | 51 | 24 | 5px | 5px non-byte-aligned |
| 32-col | 32 | 24 | 8px | 8px byte-aligned |
| 64-col | 64 | 24 | 4px | 4px, two characters per attribute cell |

Switch modes with `SCREEN.COM` (`SCREEN 51`, `SCREEN 32` or `SCREEN 64`), or
BIOS fn 32 directly.  64 columns is an extension: the +3 manual's `ESC 3` only
defines 32, 51 and 80; `ESC 3 2` (80) selects the 24×80 mode described
below.

Default: 51 columns.

64 columns is the widest mode with a full 4-pixel pitch (64 x 4 = 256
pixels).  Its font is the "Compression" ZX Origins typeface; because a
4-pixel glyph fits in one nibble, each 8-pixel attribute cell holds
exactly two characters, so colour and inverse-video boundaries align
with the text.  Characters outside ASCII are blank in this mode; 51 and
32 columns keep the full Amstrad graphics set.

The current column count minus 1 is stored in the SCB at offset 0x1A
(`conwidth`, read with BDOS F49).  In 24×80 mode it is 79 whatever the
physical width, so programs that size their output from it lay out for
the 80-column logical screen; see 24×80 below.

### Control Codes

| Code | Name | Effect |
|------|------|--------|
| 0x07 | BEL | Ignored (no beep) |
| 0x08 | BS | Move cursor left (non-destructive: the character stays). Wraps to previous line. |
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
| `ESC E` | CEL | Clear the viewport (cursor stays) |
| `ESC *` | — | ADM-3A/Kaypro clear screen and home |
| `ESC J` | ED0 | Erase from cursor to the bottom of the viewport |
| `ESC K` | EL0 | Erase from cursor to the right edge of the viewport |
| `ESC T` | — | ADM-3A/Kaypro erase to end of line (same as `ESC K`) |
| `ESC d` | ED1 | Erase from the top of the viewport to the cursor |
| `ESC l` | EL1 | Erase the cursor row inside the viewport |
| `ESC o` | EL0d | Erase from the viewport's left edge to the cursor |

The erase, scroll and line operations all act inside the current viewport
(see `ESC X` below).

#### Scroll / Line Operations

| Sequence | Name | Effect |
|----------|------|--------|
| `ESC I` | RI | Reverse index: cursor up; scroll down if at row 0 |
| `ESC L` | IL | Insert blank line at cursor row (rows below move down) |
| `ESC M` | DL | Delete cursor row (rows below pull up) |
| `ESC N` | DCH | Delete character at cursor (shift the viewport row left) |

`ESC L`/`ESC M`/`ESC N` stay inside the viewport: the line moves use the
viewport rows and the character move uses the viewport columns.  When the
cursor is on the last row of a scrolled viewport, a line feed scrolls only
the viewport and leaves the rest of the screen alone.

#### Screen, Wrap and Colour (CP/M Plus Appendix III)

| Sequence | Effect |
|----------|--------|
| `ESC 0` | Status line off: the bottom row returns to the text viewport (24 rows). |
| `ESC 1` | Status line on: reserves the bottom row for BIOS messages; the text viewport becomes 23 rows and the row is cleared. |
| `ESC 3 n` | Screen size: n = `0` → 24×32, `1` → 24×51, `2` → 24×80 (enters the virtual 80-column mode). Also clears the screen, resets the viewport and **cancels page mode**. Typed at the prompt as `ESC 3 0`/`ESC 3 1`. Any other parameter is consumed and ignored (old WordStar Z19 drivers use `ESC 3`/`ESC 4` with a space parameter as attribute controls). |
| `ESC 4 n` | Page mode: `0` disables, `1` enables (the `con_mode` bit used by `F109`). Other parameters are ignored. |
| `ESC 5 n` | Auto-flip in 24x80 mode: `0` enables, `1` disables, as the +3 manual specifies.  Disabled by default: pages change on EXTEND+Enter only. |
| `ESC x` | Enter 24x80 mode; clears the screen. |
| `ESC y` | Leave 24x80 mode; clears the screen and restores the physical width. |
| `ESC v` | Enable wrapping at the right edge (default). |
| `ESC w` | Disable wrapping; the last column is overwritten. |
| `ESC b c` | Foreground colour. `c` is the +3 palette number + 32 (32 black … 95 bright white). |
| `ESC c c` | Background colour; the border follows the background. |

Colour values follow the manual: blue = 34, red = 40, magenta = 42,
green = 64, cyan = 66, yellow = 72, white = 74, with bright variants
35/44/47/80/83/92/95.  The Spectrum BRIGHT attribute is set only when
both ink and paper are bright.  New characters take the current
attribute; existing text keeps the colours it was drawn with.

#### Ignored Sequences

These are consumed without error but have no effect:

`ESC e` `ESC f` (cursor on/off),
`ESC p` `ESC q` (reverse), `ESC r` `ESC u` (underline).

Sequences with a consumed parameter: `ESC 2 p` (national charset).

#### Viewport — `ESC X tr lc h w`

`ESC X` sets a rectangular text viewport.  All four parameters are the
documented CP/M Plus values plus 32: `tr`/`lc` are the absolute top row
and left column, `h`/`w` are height/width minus one.  Out-of-range values
are clamped (height to 24, width to the current columns, and the origin so
the rectangle stays on screen).  The cursor moves into the rectangle if it
was outside, and stays at the same relative position otherwise.

Cursor addressing (`ESC Y`), cursor motion, wrapping, scrolling, erase,
insert/delete line and delete character are all relative to the viewport;
`TE_ASK` reports its origin and size.  `ESC 3 n` and `TE_RESET` restore the
whole-screen viewport (23 rows while the status line is enabled).  The
viewport state lives in bank 6, so it costs no `CPM3.SYS` image space.

#### Status line — `ESC 0` / `ESC 1`

The status line is the BIOS message channel on the bottom screen row, not
the CCP prompt.  Enabling it reserves row 23, leaves a 23-row text
viewport and clears the row; disabling gives the row back to the text
viewport.  The state is independent of the viewport set by `ESC X` and of
the screen width, and it survives `ESC 3 n`/`TE_RESET`.

`TE_STL_ASK` reports `A = 00h` (disabled, Zero set) or `A = FFh` (enabled,
Zero clear); `TE_STL_ON_OFF` takes the enable/disable value in `A` and
returns the new state the same way.  The status line is **off** at cold
boot; `ESC 1` enables it from the prompt.

The status row is outside the viewport, so scrolling, erase and the fast
scroll path leave it alone.  It is drawn blank for now: BIOS messages and
the 80-column `<`/`>` markers land there once the FDC message and 24×80
paths exist.  The flag lives in bank 6 (`A8C0h`), outside the image.

#### 24×80 mode — `ESC x`, `ESC y`, `ESC 3 2`, `ESC 5 n`

`ESC x` enters a virtual 80-column screen and `ESC y` leaves it (both
clear the screen).  `ESC 3 2` also enters it at the current physical
width; `ESC 3 0`/`ESC 3 1` leave 24×80 and set 32/51 columns, as the
manual requires.  The physical width at entry is remembered, so leaving
restores it — 51 normally, or 64 when 24×80 was entered from our
64-column mode.

The 80×24 character grid lives in bank 5 at `5B00h-62BFh`, outside the
image and the visible `char_buffer`.  The physical screen shows a window
of the current width, and the window is paged in `lg_step`-column steps:

| physical width | pages | window starts |
|---|---|---|
| 32 | 3 | 0, 24, 48 |
| 51 | 2 | 0, 29 |
| 64 | 2 | 0, 16 |

So 51 columns need one flip to reach every column, while 64 columns need
only a 16-column scroll — less paging than the original +3.  32 columns
need three pages to cover all 80.

`ESC 5 n` controls automatic paging: `0` enables it, `1` disables it.
This is the +3 manual's polarity (Appendix III), and Locomotive's CP/M
Plus follows it: `0` turns auto-flip on, `1` off.  With it on, output,
cursor motion and line feeds keep the window on the cursor's page.  With
it off, the half is changed only with **EXTEND+Enter** (or CAPS
SHIFT+SYMBOL SHIFT+Enter, which is the same EXTEND state).

Unlike the +3, auto-flip is **off** from cold boot.  Following the
cursor flips the window every time output crosses the edge, so a DIR
listing or a full-screen redraw flickers between the pages.  The window
stays where the user put it until EXTEND+Enter; a program that wants the
cursor followed asks for it with `ESC 5 0`.  The `<`/`>` markers on the status line show whether
columns are hidden to the left/right; they are not drawn when the status
line is off.

A page change does not redraw the whole screen.  The two pages show the
same text shifted horizontally, so the BIOS shifts each 32-byte scan line
by `delta × font pitch` bits, stamps the row's attribute plane, and
re-renders only the newly exposed columns from `LG_BUF`.  Both the manual
chord and auto-flip use this path.  Only the columns that stay visible are
shifted and rotated: the exposed edge is re-rendered anyway, so touching
it in the shift pass is wasted work (at 51 columns the step is 29
columns = 18 bytes, i.e. more than half of the line).  The per-cell
attribute write is skipped on this path too, because the whole attribute
row was stamped in one pass first.  If the viewport is not the full
window (`ESC X` moved it or narrowed it), it falls back to a full redraw.
At 51 columns the 256th screen pixel lies outside the 51×5 = 255-pixel
text area, so it is cleared after the shift.

In 24×80 mode the SCB console width (`conwidth`, offset 0x1A, BDOS F49)
is 79, so DIR lists five entries a line, DUMP shows sixteen bytes a line
and `SCREEN` reports 80 columns; leaving 24×80 restores the physical
width.  (Locomotive's utilities assume 51 columns throughout.)

In 24×80 mode `TE_ASK` reports width − 1 = 79, the cursor column is
logical (0-79), the line/erase sequences work on the 80-column line, and
`TE_STL_ASK` sets Zero (as if disabled) while the status-line flag itself
is unchanged.  The status line still shows on row 23 when enabled, so the
text area is 23 rows.

`SET24X80.COM` switches from the prompt:

```text
SET24X80          enter 24x80
SET24X80 ON       same
SET24X80 OFF      leave and restore the previous width
```

The visible window takes the current ink/paper attribute for every cell
it draws; in 24×80 mode the per-cell colours of the 51/64-column buffer
are not preserved across flips.

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

### XBIOS calls

BIOS function 30 (`USERF`) exposes the +3 extended jumpblock.  Place the
entry address immediately after the `CALL`:

```asm
        call userf_entry        ; BIOS entry 30
        dw   0x00BF             ; TE_ASK
```

Implemented TE entries: `TE_ASK` (`0x00BF`), `TE_RESET` (`0x00C2`),
`TE_STL_ASK` (`0x00C5`), `TE_STL_ON_OFF` (`0x00C8`), `TE_SET_INK`
(`0x00CB`), `TE_SET_BORDER` (`0x00CE`), `TE_SET_SPEED` (`0x00D1`) and
`SCR_RUN_ROUTINE` (`0x00E9`).  Disc entries: `DD_INIT` (`0x0080`),
`DD_SETUP` (`0x0083`), `DD_READ_SECTOR` (`0x0086`), `DD_WRITE`
(`0x0089`), `DD_CHECK_SECTOR` (`0x008C`), `DD_FORMAT` (`0x008F`),
`DD_LOGIN` (`0x0092`),
`DD_SEL_FORMAT` (`0x0095`), `DD_READ_ID` (`0x009B`), `DD_L_DPB`
(`0x009E`), `DD_L_XDPB` (`0x00A1`), `DD_L_READ` (`0x00AD`), `DD_L_WRITE`
(`0x00B0`), `DD_L_ON_MOTOR`
(`0x00A4`), `DD_L_T_OFF_MOTOR` (`0x00A7`), `DD_OFF_MOTOR` (`0x00AA`) and
`DD_L_SEEK` (`0x00B3`).  The sector/format calls accept only CP/M bank 1
(the TPA) and FDC units 0 and 1 (A: and B:; whether a second drive is
fitted is up to the hardware).  See [XBIOS/TE Interface](cpm-plus-xbios.md) for
the register contracts, colour encoding and the `SCR_RUN_ROUTINE`
common-memory limitation.  `KM_SET_SPEED` (`0x00E0`) sets the keyboard
repeat delays, `KM_SET_KEY` (`0x00D7`) rewrites key translations,
`KM_SET_EXPAND` (`0x00D4`) stores expansion strings (the source string may
live in the TPA: the handler copies it byte by byte through the common
stub), and `KM_KT_PUT` (`0x00DD`)/`KM_KT_GET` (`0x00DA`) queue and dequeue
key tokens.

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
  51x24, 32x24 or 64x24 (BIOS fn 32 to switch)
  ESC E = clear     ESC H = home
  ESC Y r c = position (+32 offset to both)
  ESC J = erase to end of screen
  ESC K = erase to end of line

FCB at 005Ch (36 bytes):
  [DR, F1-F8, T1-T3, EX, S1, S2, RC, AL0-ALF, CR, R0-R2]

Command tail: length at 0080h, text at 0081h
```
