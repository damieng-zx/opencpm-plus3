# AGENT instructions

This file provides guidance to OpenCode, Claude Code and other AI agents when working with code in this repository.

## Project

Clean-room CP/M 3.1 for the ZX Spectrum +3. All code is original Z80 assembly — no code from the `opensource/` reference folder is used. The BIOS, BDOS, CCP, drivers, and tools are written from scratch.

## Build

```bash
build.cmd                    # Build cpm3.dsk
build.cmd --add FILE ...     # Build with extra CP/M files on disk
```

Requires: `sjasmplus` (Z80 assembler at C:\Apps\sjasmplus.exe), `python3`.

Build chain: ZPA preprocessing → CCP → BIOS (BDOS, drivers, font loader) → loader → boot sector → DSK image. The BIOS is stored as `CPM3.SYS` on the CP/M filesystem, loaded by a small stage-2 loader in track 0. The CCP is a separate file, `CCP.COM`, read from the boot disk during cold boot (see Boot Chain).

`references/binaries/` is optional third-party software: `SUBMIT.COM` and
`RENAME.COM` are excluded from the image (we build SUBMIT, and the CCP has a
built-in REN); the smoke runner adds `RENAME.COM` to a scratch copy so a real
third-party F23 caller is still covered.

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

Every routine documents In/Out/Clobbers (see Conventions). In `.zpa` sources
the machine-readable form is the `@param`/`@out`/`@clobbers` block, which ZPA
carries into the generated assembly for the linter to verify.

**Never commit broken code.** Test in the emulator first.

## Testing

The zx84 MCP emulator (F:\src\zx84) provides debugging tools. Key workflow:
- `model +3` → `load build/cpm3.dsk` → `disk_boot` → `run 1000`
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
2. Loader (~935B) → finds CPM3.SYS in directory, loads to C000h
3. Init code at C000h → copies system to bank 4, common stub to F600h
4. Cold boot in bank 4 → init screen/kbd/FDC, load fonts + `CCP.COM` + FID from disk
5. `warm_boot` → copy the staged CCP (bank 6, B000h) to 0100h
6. start_tpa (common) → switch to TPA mode, set page zero, JP 0100h

The CCP is **not** part of CPM3.SYS: `CCP.COM` (the MiniCCP PRL) is read from
the boot disk into bank 6 at B000h on cold boot (`load_ccp`) and copied to
0100h on every warm boot, so a normal exit never touches the disk. A cold
boot without `CCP.COM` prints a diagnostic and halts.

### Memory Layout (Banked)
**TPA mode (mode 0: banks 0,1,2,3)**:
- **0000-00FF**: Page zero — JP warm_boot_stub, JP bdos_stub, JP isr_handler
- **0100-F5FF**: TPA (~61K)
- **F600-FFFF**: Common memory stub (bank 3, always visible)

**System mode (mode 3: banks 4,7,6,3)**:
- **0000-3FFF**: Bank 4 — BIOS, BDOS, screen/kbd/FDC drivers
- **4000-7FFF**: Bank 7 — C: RAM disk (16K, owned by `RAMDISK.FID`)
- **8000-BFFF**: Bank 6 — FONT51 at 8000h, FONT32 at 8800h, optional RAMDISK.FID at 9000h, FONT64 at 9400h, FDC deblock buffer at 9C00h, runtime screen/scroll buffers at A000h-A8FFh, staged `CCP.COM` at B000h-BFFFh
- **F600-FFFF**: Common memory stub (bank 3, always visible)

**Screen access (mode 2: banks 4,5,6,3)**:
- **4000-7FFF**: Bank 5 — Screen RAM (paged in temporarily by `_page_in`/`_page_out`)

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
- `src/boot/loader.asm` — Stage 2: finds and loads CPM3.SYS from disk
- `src/bios/bios.asm` — Init + BIOS (PHASE 0000 for bank 4) + common stub (PHASE F600)
- `src/bios/common.asm` — Common memory stub: BDOS dispatch, bank switching, inter-bank copy
- `src/bios/screen.asm` — 32/51/64-column text display (8px, 5px and 4px fonts)
- `src/bios/keyboard.asm` — 8×5 matrix scan, ASCII mapping, debounce/repeat
- `src/bios/fdc765.asm` — uPD765A driver with sector deblocking (512→128 byte)
- `src/bios/font51.bin` — 256×8 byte font (incbin, not generated asm)
- `src/bios/font64.bin` — 4-pixel font for 64-column mode, generated from `src/bios/compression.ch8` by `tools/mkfont64.py`
- `src/bdos/bdos.asm` — Z80-native BDOS (console + file I/O)
- `src/ccp/miniccp.asm` — CCP with DIR, TYPE, ERA, REN, USER and HELP built in, plus `.COM` loading; built as `CCP.COM`
- `src/tools/screen.asm` — `SCREEN.COM`, the screen-width utility (BIOS fn 32)
- `src/tools/b16test.asm` — `B16TEST.COM`, the 16-bit block-number file test
  (create/write/size/free-space/truncate/delete on B:)
- `tools/mkdsk.py` — DSK image builder (`--format 180k` or `720k`); the
  720K layout uses 2K blocks, 128 directory entries and 16-bit block
  numbers, and the build writes it as `build/cpm3_720.dsk`
- `tools/zpa.py` — ZPA preprocessor (see **ZPA Preprocessing**)
- `tools/patchsum.py` — Boot sector checksum patcher (sum=3)
- `tools/check_ccp.py` — Fails the build if `CCP.COM` does not fit the bank-6 staging window
- `tools/mkfont64.py` — Builds `font64.bin` from the Compression `.ch8` (`--check` verifies the committed binary)
- `tools/z80lint.py` — Parser-based Z80 linter (see **Linting**)

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

The init code must copy `system_image` to bank 4 before copying `common_image` to F600h. `COMMON_BASE=F600` overlaps the physical source range of the loaded `system_image` in bank 3; copying common first corrupts bytes that still need to be relocated into bank 4. `tools/check_layout.py` verifies this order from `build/bios.lst`. The common copy itself still needs the correct LDIR/LDDR direction if its source/destination ranges overlap.

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
