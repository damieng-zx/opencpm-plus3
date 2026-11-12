# AGENT instructions

This file provides guidance to OpenCode, Claude Code and other AI agents when working with code in this repository.

## Project

Clean-room CP/M 3.1 for the ZX Spectrum +3. All code is original Z80 assembly — no code from the `opensource/` reference folder is used. The BIOS, BDOS, CCP, drivers, and tools are written from scratch.

## Build

```bash
build.cmd                    # Build all four images
build.cmd --add FILE ...     # Build with extra CP/M files on every +3 image
```

Three +3 images are produced from the same system files, plus a data image:

- `build/cpm3.dsk` — **distribution** (180K single-sided): system, the
  utilities we build
  (`SUBMIT`, `SCREEN`, `SET24X80`, `SETDEF`, `DATE`, `SHOWXDPB`, `DUMP`,
  `FORMAT`, `DISKCOPY`, `DIR`, `ERASE`, `DEVICE`) and
  the local `references/binaries/` utilities (BBC BASIC, ED, PIP, ...).  No
  test programs.
- `build/cpm3-dist720.dsk` — the same CP/M files on a **720K** PCW DS/DD
  disc, booted by the `-DDS720` boot sector and loader.  Nothing extra yet;
  it exists for the ~570K free it leaves a larger tool set.  No test
  programs and no `PMAUTOAE.COM`.
- `build/cpm3-test.dsk` — the distribution files **plus** the `*TEST.COM`
  programs, their fixtures and (when fetched) `PMAUTOAE.COM`, on the same
  720K layout; the smoke and the other on-disk test runners boot this one.

A 720K disc is not readable by an unmodified +3, so `cpm3.dsk` stays the
image for real hardware.

`build/cpm3_720.dsk` is a PCW 720K data image for the 16-bit block tests.

Requires: `sjasmplus` (Z80 assembler at C:\Apps\sjasmplus.exe), `python3`.

Build chain: ZPA preprocessing → CCP → BIOS (BDOS, drivers, font loader) → loader → boot sector → DSK images. The BIOS head is stored as `CPM3.SYS` and the bank-5 screen code plus the common stub as `CPM3C.SYS` on the CP/M filesystem, loaded by a small stage-2 loader in track 0. The CCP is a separate file, `CCP.COM`, staged by the stage-2 loader during cold boot (see Boot Chain).

`CPM3.SYS` must fit the 16K `C000-FFFF` window, the common stub the
`F600-FFFF` window and the bank-5 screen code `62C0-7FFF` (with the stub
behind it, `CPM3C.SYS` must fit the loader's 7K bank-5 staging budget); the
build prints the budgets and `build/memory.map` lists every region. Before adding a large feature, read `docs/boot.md`
§ *Image headroom and the growth plan*.

`references/binaries/` is optional third-party software added to all three +3
images (that is how BBC BASIC gets onto the distribution disks); `SUBMIT.COM`,
`RENAME.COM`, `NULU11.COM` (an LBR library manager) and `PROFILE.SUB`
(Amstrad's start-up script: it works, but auto-running it copies ~10K into
the 16K C: RAM disk at every cold boot) are excluded.  The
smoke runner adds `RENAME.COM` to a scratch copy so a real third-party F23
caller is still covered, and drops the big optional utilities it never runs
(`BBCBASIC.COM`, `NULU11.COM`) if they are present, to leave room for
DISKTEST's 17K file.

### ZPA Preprocessing

Source files use the `.zpa` extension (`src/bios/*.zpa`, `src/bdos/*.zpa`,
`src/ccp/*.zpa`, `src/util/*.zpa`). `tools/zpa.py` expands them into
`build/zpa/*.asm` and the assembler only ever sees that output. **Always edit
the `.zpa` files** — `build/zpa/` is generated and not checked in.

ZPA adds pinned-register annotations and call-site checking on top of plain
Z80:

```asm
; @proc read_user_byte
; @param %addr:u16  de           ; address in the TPA, pinned to DE
; @out   a                       ; byte read
; @clobbers bc
; @end
read_user_byte:
    ...
    ld a, (%addr)                  ; %addr is substituted with DE
```

- Declarations go in a structured comment block immediately before the label.
  Types are `u8`/`i8`/`flag` (8-bit) and `u16`/`i16` (16-bit).
- `%name` anywhere in an operand is replaced by the pinned register.
- `call proc(%a, %b)` expands to the argument moves plus `call`;
  `call proc(%a) -> %out` captures an output. Both forms are type-checked
  against the callee's `@param` list and cross-checked across all files.
- `call proc(%a) preserving %var, ...` emits push/pop for every pinned
  register the callee clobbers, and warns if an active `%var` is clobbered
  without being preserved.
- `@extern` declares a routine whose body is raw assembly in another file.
- `; zpa: ignore` on a call line suppresses clobber warnings for that call.

The generated `build/bios.lst` is the authoritative symbol map: the memory-map
checker, layout checker (`check_layout.py`), CCP size check and the smoke
runner all read labels and `equ` values from it.

### Linting

`tools/z80lint.py` is a parser-based linter (instruction table plus
control-flow analysis, not regex). The build runs it with
`--gate-annotations`, so any finding fails the build; run it directly while
editing:

```bash
python3 tools/z80lint.py                  # all checks
python3 tools/z80lint.py --suggest-anno   # print computed effects as paste-ready lines
```

Checks:

1. **Stack balance** — every `RET` must be reached with net push/pop depth 0
   along every path (CFG with a fixed-point solver). `ld sp, …` is a stack
   rebase; `inc sp`/`dec sp`/`jp (hl/ix/iy)` need `; lint-exempt: stack`.
   Labels named in a `dw` table inside the routine are entry points at
   depth 0 too, so handlers reached only through a jump table (the XBIOS
   dispatcher) are still checked.
2. **Register clobber after CALL** — reading a register a preceding call
   clobbered without restoring it.
3. **Dead stores** — writes between `push` and `pop` that the pop discards.
4. **Clobber annotations** — the declared `Clobbers:`/`Out:` set must cover
   what the routine (including its callees, by actual effect) leaves changed,
   and every `Out:` register must really be produced. `; lint: ignore` on the
   `Clobbers:` line skips a routine.
5. **DI/EI balance** — every `RET` leaves the interrupt-enable flag as it
   found it; primitives that deliberately change it carry
   `; lint-exempt: ie`.
6. **1FFD write discipline** — port `1FFD` may only be written through
   `write_1ffd` (which maintains the `last_1ffd` shadow the ISR motor timer
   needs); pre-shadow/ISR contexts carry `; lint-exempt: 1ffd`.
7. **Duplicate labels** — a non-local label defined twice in the same binary
   makes call resolution ambiguous.
8. **Tail calls** — `call X` followed directly by an unlabelled `ret` must be
   `jp X` (a byte and 17 T-states shorter).  The two differ only when `X`
   reads or drops its own return address, or pages out the memory holding
   the `ret`; mark such a call (or its `ret`, since ZPA drops comments on
   `call proc(args)` lines) `; keep call`.  The three in common memory below
   `ccp_run_prog` are kept because shrinking them would move pinned
   addresses.

`jp` that could be `jr` is checked after assembly by `tools/jp2jr.py`
(it needs real addresses), and also fails the build.

The bank-5 paging rules (see `src/bios/screen5.zpa`) are checked the same
way by `tools/check_bank5.py`, which also fails the build.

Every routine documents In/Out/Clobbers (see Conventions). In `.zpa` sources
the machine-readable form is the `@param`/`@out`/`@clobbers` block, which ZPA
carries into the generated assembly for the linter to verify.

**Never commit broken code.** Test in the emulator first.

## Testing

The zx84 MCP emulator (F:\src\zx84) provides debugging tools. Key workflow:
- `model +3` → `load build/cpm3-test.dsk` → `disk_boot` → `run 1000`
  (use `build/cpm3.dsk` for the distribution image; it has no test programs)
- Snapshots are supported: `save build/prompt.szx` and later `load build/prompt.szx`
  to resume from a known-good prompt state without rebooting the DSK.
- Read screen via `char_buffer` in bank 6 (its `equ` value in `build/bios.lst`;
  currently `0xA000`)
- `fdc_log` shows all FDC operations (retries = bug)
- `registers`, `memory`, `disassemble` for debugging
- `type "text"` + `key enter` to send commands (`.` requires sym+m fix in emulator)

OCR does not work with our custom 5px font.

## Architecture

### Boot Chain
1. Boot sector (512B at FE00h) → loads loader from track 0
2. Loader (~1.2K) → stages fonts + `CCP.COM` + FID in bank 6 and `CPM3C.SYS` in bank 5 at 62C0h, then loads CPM3.SYS to C000h
3. Init code at C000h → copies system to bank 4, common stub from behind the bank-5 screen code to F600h (the screen code stays where the loader put it)
4. Cold boot in bank 4 → init screen/kbd/FDC, validate the staged FID
5. `warm_boot` → copy the staged CCP (bank 6, B000h) to 0100h
6. start_tpa (common) → switch to TPA mode, set page zero, JP 0100h

The CCP's `.COM` loader stub is copied to `0008h` for each run.  The CCP
sets `SP = TPA_TOP` and enters the stub, which loads the file at 0100h.
`ccp_run_prog` (common memory) then pushes `0000h` so a program may exit
with `RET` (the real CP/M 3 CCP does the same), applies the CP/M 3 COM
header rule (if 0100h holds `RET`, the module at 0200h is moved down
`comsize` bytes from 0101h) and jumps to 0100h.  Attached RSX modules are
not installed.  The stub must stay below `0038h` (the IM 1 vector); an
assert enforces it.

The CCP is **not** part of CPM3.SYS: `CCP.COM` (the MiniCCP PRL) is read from
the boot disk into bank 6 at B000h by the stage-2 loader and copied to
0100h on every warm boot, so a normal exit never touches the disk. A cold
boot without `CCP.COM` prints a diagnostic and halts.  The common stub is
also split out (as `CPM3C.SYS`, behind the bank-5 screen code) so `CPM3.SYS`
can use the whole bank-3 window; a missing `CPM3C.SYS` stops the boot at the
loader.

### Memory Layout (Banked)
**TPA mode (mode 0: banks 0,1,2,3)**:
- **0000-00FF**: Page zero — JP warm_boot_stub, JP bdos_stub, JP isr_handler
- **0100-F5FF**: TPA (~61K)
- **F600-FFFF**: Common memory stub (bank 3, always visible)

**System mode (mode 3: banks 4,7,6,3)**:
- **0000-3FFF**: Bank 4 — BIOS, BDOS, screen/kbd/FDC drivers
- **4000-7FFF**: Bank 7 — C: RAM disk (16K, owned by `RAMDISK.FID`)
- **8000-BFFF**: Bank 6 — FONT51 at 8000h, FONT32 at 8800h, optional RAMDISK.FID at 9000h, FONT64 at 9400h, FDC deblock buffer at 9C00h, `DD_CHECK_SECTOR` compare buffer at 9E00h, runtime screen/scroll buffers at A000h-A5FFh, row-address table at A700h and CSV/ALV at A740h-A82Ch, BIOS/BDOS scratch at A600h-A6FFh and A82Dh-A83Ch, screen cursor/ESC scratch at A730h-A739h, viewport scratch at A73Ah-A73Fh, loader-staged screen row table at A890h-A8BFh, status-line flag at A8C0h, 24x80 state at A8C1h-A8DFh, `KM_SET_KEY` translation table at A900h-A99Fh, `KM_SET_EXPAND` slots at A9A0h-AD7Fh, FCB shadow at AD80h-ADA3h, submit-file input buffer at ADA4h-AFA3h, staged `CCP.COM` at B000h-BFFFh
- **F600-FFFF**: Common memory stub (bank 3, always visible)

**Screen access (mode 2: banks 4,5,6,3)**:
- **4000-7FFF**: Bank 5 — Screen RAM (paged in temporarily by `_page_in`/`_page_out`)
- **5B00-62BF**: Bank 5 — 80x24 logical screen for 24x80 mode (`LG_BUF`), outside the bitmap/attributes
- **62C0-7FFF**: Bank 5 — screen code that only runs paged in (`src/bios/screen5.zpa`, ~2.5K, staged in place by the loader); the stale boot copy of the common stub follows it

### Banking (port 1FFD)
- Mode 0 (`BANK0_1FFD=0x01`): banks 0,1,2,3 — TPA execution
- Mode 3 (`BANK1_1FFD=0x07`): banks 4,7,6,3 — system execution
- Mode 2 (`PAGING_SCREEN=0x05`): banks 4,5,6,3 — screen access (temporary)
- `MOTOR_BIT=0x08`: OR into 1FFD value for disk motor

### Common Memory Stub (F600-FFFF)
The common stub bridges TPA and system banks:
- `bdos_stub` — saves user SP, switches to system, calls bdos_entry, switches back
- `warm_boot_stub` — switches to system, jumps to warm_boot
- `isr_handler` — IM 1 interrupt handler (tick counter)
- `start_tpa` — sets up page zero, switches to TPA, starts CCP
- `bank_sel` — BIOS function 27 (must be in common since it switches banks)
- Inter-bank copy routines: `copy_record_to_tpa`, `copy_record_from_tpa`, `copy_block_to_tpa`
- User memory helpers: `read_user_byte`, `write_user_byte`, `copy_from_user`, `copy_to_user`
- FCB shadowing: `setup_fcb`, `writeback_fcb`, `fcb_buf` (36 bytes)
- Buffers: `dirbuf` (128B), `xfer_staging` (32B), `bdos_stack` (128B)

### BDOS Banking Model
Interrupts are disabled during system mode. The BDOS accesses user memory
(FCBs, strings, buffers) via common-memory helpers:
- **FCB access**: `setup_fcb` copies 36-byte FCB from TPA to `fcb_buf` (common memory).
  BDOS works with `fcb_buf` via IX. `writeback_fcb` copies back on success.
- **String/buffer access**: `read_user_byte`/`write_user_byte` switch banks per byte.
- **DMA transfers**: `copy_record_to_tpa`/`copy_record_from_tpa` in FDC driver.
- **Directory→DMA**: `copy_to_user` for search result delivery.

### Key Ports
- `0xFE`: ULA (border + keyboard matrix)
- `0x1FFD`: +3 paging + motor
- `0x2FFD`: FDC status (read)
- `0x3FFD`: FDC data (read/write)

## Source Structure

- `src/boot/bootsect.asm` — Boot sector (checksum must be 3 mod 256)
- `src/boot/loader.asm` — Stage 2: stages fonts/CCP/FID in bank 6 and `CPM3C.SYS` in bank 5, then loads the `CPM3.SYS` head
- `src/bios/bios.asm` — Init + BIOS (PHASE 0000 for bank 4) + bank-5 screen code (PHASE 62C0) + common stub (PHASE F600)
- `src/bios/common.asm` — Common memory stub: BDOS dispatch, bank switching, inter-bank copy
- `src/bios/screen.asm` — 32/51/64-column text display (8px, 5px and 4px fonts)
- `src/bios/screen5.zpa` — the screen routines that only run with the screen
  paged in (glyph rendering, scrolling, the 24x80 page flip, LG_BUF edits),
  assembled for and run from bank 5 at `62C0`.  Bank-4 code enters them
  through `call _page_in / jp X_b5` stubs or while already paged in; they
  leave with a final `jp _page_out` and never call anything that switches
  banks (`tools/check_bank5.py` fails the build otherwise)
- `src/bios/keyboard.asm` — 8×5 matrix scan, ASCII mapping, debounce/repeat
- `src/bios/fdc765.asm` — uPD765A driver with sector deblocking (512→128 byte);
  login detects the format from the sector-ID group and, for the 1-9 group,
  rebuilds the XDPB from the boot sector's 10-byte AMSDOS spec (so 10-sector
  42-track layouts work)
- `src/bios/font51.bin` — 256×8 byte font (incbin, not generated asm)
- `src/bios/font64.bin` — 4-pixel font for 64-column mode, generated from `src/bios/font64.ch8` (all 256 glyphs) by `tools/mkfont64.py`, which writes each row into both nibbles (`0xA0` -> `0xAA`) so the renderer merges a glyph into either half of a screen byte with one mask and no shift
- `src/bdos/bdos.asm` — Z80-native BDOS (console + file I/O).  The directory/FCB
  helpers (`find_free_block`, `read_dir_entry`, `write_dir_entry`,
  `dir_sector_to_bios`, `search_next_entry`, `match_fcb`, `bf_f15`-`bf_f18`,
  `close_dir_update`) live at the end of `common.asm` instead, in common
  memory, to leave room in the 16K bank-4 image; see `docs/boot.md`
- `src/ccp/miniccp.zpa` — CCP with the CP/M 3 built-ins DIR, DIRSYS, ERASE, RENAME, TYPE and USER (and their short forms DIRS, ERA, REN, TYP, USE) plus HELP, `cmd1!cmd2` chaining (the rest of the line is kept by private BDOS F125) and `.COM` loading; built as `CCP.COM`.  Its work buffers are `equ` addresses above the image, so they do not count against the 4K staging window.  On a cold start it submits `PROFILE.SUB` from the default drive — the SCB byte at `0x0A` (`scb_coldboot`) marks a cold boot and the CCP clears it, so a warm boot does not run the profile again.  Lines of a submit file that begin with `<` are queued for the running program (BDOS F124, a private CCP helper) and served by `con_in`/`con_status` as console input
- `src/tools/dir.asm` — `DIR.COM`, the option form of DIR that the CCP's
  built-in hands over (`FULL`, `SIZE`, `ATT`, `DIR`/`SYS`/`RO`/`RW`,
  `DRIVE=`, `USER=`, `EXCLUDE`, `NOSORT`, `LENGTH=`, `MESSAGE`, `NOPAGE`/`FF`,
  `DATE`).  Reads each drive's whole directory in one pass (`?` in the FCB's
  drive byte matches every user, so no user number is switched), applies the
  filespecs, user list and filters itself, merges extents by name and user,
  sorts through a pointer table and prints
- `src/tools/erase.asm` — `ERASE.COM`: `[CONFIRM]` for ERA/ERASE (collects
  every match first, because a delete disturbs the search state)
- `src/tools/device.asm` — `DEVICE.COM`: reads the BIOS character device table
  (BIOS fn 20 through F50) and assigns logical devices by writing the SCB
  redirection vectors (F49); the BIOS honours `LSTVEC`/`AUXOVEC` only
- `src/tools/screen.asm` — `SCREEN.COM`, the screen-width utility (BIOS fn 32)
- `src/tools/set24x80.asm` — `SET24X80.COM`, enter/leave the virtual 80x24 screen
- `src/tools/setkeys.asm` — `SETKEYS.COM`, apply a +3 key-definition file
  through XBIOS `KM_SET_KEY`/`KM_SET_EXPAND` (replaces Amstrad's Locomotive
  build, which is never shipped)
- `src/tools/sysgen.asm` — `SYSGEN.COM`: reads the system from A: (track 0
  via `DD_READ_SECTOR` and the three system files via the BDOS) into memory,
  checks the target's geometry with `DD_LOGIN`, then writes the boot track
  (`DD_WRITE`) and the files, reading every file back to verify it; the
  buffers live in the TPA so the target may be the same drive
- `src/tools/stat.asm` — `STAT.COM`: per-drive free space (F46) and capacity
  (F31/DPB), file sizes and attributes from directory searches (F17/F18),
  and `$R/O`/`$R/W`/`$SYS` attribute changes (F30)
- `src/tools/diskcopy.asm` — `DISKCOPY.COM`, raw sector copy between A:/B:
  (including the same drive twice): `DD_LOGIN` detects the source layout,
  `DD_READ_ID` captures each source track's ID order, then `DD_FORMAT` plus
  `DD_READ_SECTOR`/`DD_WRITE` copy track by track (formatting each target
  track just before its data, so the target needs no pre-format and the
  interleave/skew are preserved) and `DD_CHECK_SECTOR` reads every written
  track back; a 48K TPA buffer bridges the disc swaps for a single drive
- `src/tools/format.asm` — `FORMAT.COM`, the disc formatter (XBIOS `DD_L_XDPB`,
  `DD_FORMAT`, `DD_CHECK_SECTOR`, `DD_WRITE`): `FORMAT A:`/`FORMAT B:`;
  180K SS/40, 720K DS/80, CPC System, CPC Data, HiForm 203 (42T/10),
  SuperMat 192 (40T/10) and CPC IBM (8 sector).
  One track is formatted then verified, a live progress line shows
  percentage/track/side/phase, the CHRN table is built with interleave and
  skew, and the AMSDOS disc spec is written into the boot sector of the
  layouts that reserve one
- `tools/mkdsk.py` — DSK image builder (`--format 180k` or `720k`); the
  720K layout uses 2K blocks, 128 directory entries and 16-bit block
  numbers, and the build writes it as `build/cpm3_720.dsk`
- `tools/zpa.py` — ZPA preprocessor (see **ZPA Preprocessing**)
- `tools/patchsum.py` — Boot sector checksum patcher (sum=3)
- `tools/check_ccp.py` — Fails the build if `CCP.COM` does not fit the bank-6 staging window
- `tools/split_sys.py` — Splits the raw BIOS blob into `CPM3.SYS` (head) and `CPM3C.SYS` (bank-5 screen code + common stub)
- `tools/check_bank5.py` — Fails the build if bank-4/common code names a
  bank-5 label without `call _page_in` first in the same routine (`; paged`
  marks an exception), or if bank-5 code calls anything that reaches
  `write_1ffd`
- `tools/mkfont64.py` — Builds `font64.bin` from `font64.ch8` (`--check` verifies the committed binary)
- `tools/z80lint.py` — Parser-based Z80 linter (see **Linting**)
- `tools/jp2jr.py` — Lists every `jp` in `CPM3.SYS`/`CPM3C.SYS` whose target
  is within `jr` range (from `build/bios.lst`); `--fix` rewrites them in the
  `.zpa` sources.  The build runs it with `--check`, so any candidate fails
  the build; after `--fix`, rebuild and rerun until clean, since shrinking
  code brings more targets into range.  It skips the BIOS
  jump table, self-modified jumps, pinned common memory before
  `ccp_run_prog`, and lines marked `; keep jp`

## Conventions

### Register Documentation
Every routine MUST document In/Out/Clobbers:
```asm
; routine_name — Description
;   In:       A = param
;   Out:      HL = result
;   Clobbers: AF, BC, DE
```
`z80lint.py` validates both the clobber list and stack balance across all return paths.
It also verifies the annotations themselves: every register a routine (or its callees,
by actual effect) leaves changed must appear in `Clobbers:` or `Out:`, and every `Out:`
register must actually be produced. Annotation findings are informational by default
(pass `--gate-annotations` to enforce once the backlog is cleaned up).
`Out` registers are return values, not clobbers. `; Stack: …` comments are free-form
documentation and do not affect the linter. To suppress the stack-balance check on a routine
that intentionally leaves SP non-zero (e.g. a jp-based shim), add `; lint-exempt: stack`.
Add `; lint: ignore` to a `Clobbers:` line to skip annotation verification for that routine.

### Screen Paging
Screen writes require `_page_in` (switches to mode 2 for bank 5 access) then `_page_out` (restores mode 3). Both preserve the motor bit via `motor_flag` in common memory.

### BDOS Stack
The common stub (`bdos_stub`) switches to `bdos_stack` in common memory before entering the BDOS. The user's stack is in TPA (banks 0/1/2) which becomes inaccessible in system mode. `bdos_ret` resets SP to `bdos_stack - 2` and RETs to the stub.

### FDC Result Handling
`fdc_read_byte`/`fdc_recv` clobber BC. Save ST0/ST1 with `push af` BEFORE reading remaining result bytes. ST0=0x40 (abnormal termination) with ST1 bit 7 (EN) is normal for single-sector reads — only ST0 >= 0x80 is a real error.

### LDIR/LDDR Overlap
When copying memory blocks with LDIR (forward) or LDDR (backward), source and destination ranges must not overlap in the direction of copy:
- **LDIR** (forward, HL→HL+BC to DE→DE+BC): safe only if `DE >= HL + BC` or `HL >= DE + BC`
- **LDDR** (backward, HL down to HL-BC to DE down to DE-BC): safe even with overlap

The init code copies `system_image` to bank 4 first because that copy overwrites the loader; nothing may need the loader afterwards. The common stub no longer overlaps it: it comes from behind the bank-5 screen code in the staged `CPM3C.SYS` (`SYS2_STAGE + (common_image - screen5_image)`, bank 5) and is a plain LDIR to F600h, since bank 5 and bank 3 are different banks. `tools/check_layout.py` verifies the init copy source from `build/bios.lst` and the head/common size budgets.

## Standard +3 Disk Format (DPB)
```
SPT=36  BSH=3  BLM=7  EXM=0  DSM=174  DRM=63
AL0=C0h  AL1=00h  CKS=16  OFF=1  PSH=2  PHM=3
```
One reserved track. 9 sectors/track, 512 bytes/sector, 1K blocks.

## Debugging Approach
- Develop and enhance tools (MCP commands, Python scripts, linters) to ensure accurate and timely resolution of issues and improve project consistency.
- Do not go down long rabbit holes without a solid reason. Use breakpoints, watchpoints, traps, and other emulator tools to gather evidence before theorizing. Let the data lead.

## Build Number
Stored in `build/buildnum` (ignored by git) and incremented by the build
scripts. It is passed to the assembler as `BUILD_NUM` and displays on the
signon line for verification. Delete `build/buildnum` to restart at 1.
