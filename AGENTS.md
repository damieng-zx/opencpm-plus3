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

Build chain: ZPA preprocessing → CCP → BIOS (includes CCP, BDOS, drivers, font) → loader → boot sector → DSK image. The BIOS is stored as `CPM3.SYS` on the CP/M filesystem, loaded by a small stage-2 loader in track 0.

### ZPA Preprocessing
Source files use `.zpa` extension (e.g. `src/bios/common.zpa`). The build runs `tools/zpa.py` to preprocess `.zpa` files into `build/zpa/*.asm`, which the assembler then uses directly. **Always edit the `.zpa` files** — the `build/zpa/` output is generated and not checked in.

Always run the linter before building:
```bash
python3 tools/z80lint.py
```

**Never commit broken code.** Test in the emulator first.

## Testing

The zx84 MCP emulator (F:\src\zx84) provides debugging tools. Key workflow:
- `model +3` → `load build/cpm3.dsk` → `disk_boot` → `run 1000`
- Snapshots are supported: `save build/prompt.szx` and later `load build/prompt.szx`
  to resume from a known-good prompt state without rebooting the DSK.
- Read screen via char_buffer at the address shown in bios.lst for `char_buffer:`
- `fdc_log` shows all FDC operations (retries = bug)
- `registers`, `memory`, `disassemble` for debugging
- `type "text"` + `key enter` to send commands (`.` requires sym+m fix in emulator)

OCR does not work with our custom 5px font.

## Architecture

### Boot Chain
1. Boot sector (512B at FE00h) → loads loader from track 0
2. Loader (917B) → finds CPM3.SYS in directory, loads to C000h
3. Init code at C000h → copies system to bank 4, common stub to F600h
4. Cold boot in bank 4 → init screen/kbd/FDC, inter-bank copy CCP to 0100h
5. start_tpa (common) → switch to TPA mode, set page zero, JP 0100h

### Memory Layout (Banked)
**TPA mode (mode 0: banks 0,1,2,3)**:
- **0000-00FF**: Page zero — JP warm_boot_stub, JP bdos_stub, JP isr_handler
- **0100-F5FF**: TPA (~61K)
- **F600-FFFF**: Common memory stub (bank 3, always visible)

**System mode (mode 3: banks 4,7,6,3)**:
- **0000-3FFF**: Bank 4 — BIOS, BDOS, screen/kbd/FDC drivers, font, buffers, CCP image
- **4000-7FFF**: Bank 7 — System data / growth
- **8000-BFFF**: Bank 6 — Reserved
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
- `src/bios/screen.asm` — 51×24 display, 5px non-byte-aligned font rendering
- `src/bios/keyboard.asm` — 8×5 matrix scan, ASCII mapping, debounce/repeat
- `src/bios/fdc765.asm` — uPD765A driver with sector deblocking (512→128 byte)
- `src/bios/font51.bin` — 256×8 byte font (incbin, not generated asm)
- `src/bdos/bdos.asm` — Z80-native BDOS (console + file I/O)
- `src/ccp/miniccp.asm` — CCP with DIR, TYPE, VER, HELP, DUMP, .COM loading
- `tools/mkdsk.py` — DSK image builder
- `tools/patchsum.py` — Boot sector checksum patcher (sum=3)
- `tools/z80lint.py` — Z80 linter: stack balance across all return paths + register clobbering after CALL

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
`Out` registers are return values, not clobbers. `; Stack: …` comments are free-form
documentation and do not affect the linter. To suppress the stack-balance check on a routine
that intentionally leaves SP non-zero (e.g. a jp-based shim), add `; lint-exempt: stack`.

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
