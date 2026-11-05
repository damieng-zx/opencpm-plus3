# OpenCP/M +3

Clean-room CP/M 3.1 (CP/M Plus) for the ZX Spectrum +3. Every part of the
system — BIOS, BDOS, CCP, drivers and tools — is original Z80 assembly written
for this project.

## Features

- **Three text modes**: 32x24 (8px font), 51x24 (5px, the +3's native width)
  and 64x24 (4px "Compression" font, two characters per attribute cell).
  `SCREEN 32|51|64` (the `SCREEN` utility), or BIOS function 32.
- **24x80 virtual screen**: an 80x24 buffer in bank 5, shown through a
  window of the current width.  `SET24X80` / `ESC x` enters it, `ESC y`
  leaves, `ESC 3 2` enters at the current width and `ESC 5 n` selects
  automatic or manual paging.  Automatic paging follows the cursor;
  otherwise EXTEND+Enter (or CAPS SHIFT+SYMBOL SHIFT+Enter) flips.  The
  window steps by 24, 29 or 16 columns at 32/51/64 columns, so our
  64-column mode needs only a 16-column shift — less paging than the
  original +3.  A flip shifts the bitmap and re-renders only the exposed
  columns; `<`/`>` on the status line mark hidden text.
- **Status line**: `ESC 0`/`ESC 1` toggle the bottom row for BIOS messages
  (23 text rows while it is on).  In 24x80 it carries the `<`/`>`
  hidden-column markers; `TE_STL_ASK` reports it as disabled in 24x80,
  as the +3 manual specifies.
- **Terminal**: VT52/ADM-3A cursor and erase sequences, colour and BRIGHT via
  `ESC b`/`ESC c`, wrap control (`ESC v`/`ESC w`), a settable viewport
  (`ESC X`), and the `ESC 3`/`ESC 4` screen-size and page-mode controls from
  the +3 CP/M manual.
- **XBIOS/TE**: the +3 extended BIOS terminal calls `TE_ASK`, `TE_RESET`,
  `TE_SET_INK`, `TE_SET_BORDER`, `TE_SET_SPEED` and `SCR_RUN_ROUTINE`, plus
  the disc calls (`DD_INIT`, `DD_SETUP`, `DD_LOGIN`, `DD_SEL_FORMAT`,
  `DD_READ_ID`, `DD_READ_SECTOR`, `DD_WRITE`, `DD_CHECK_SECTOR`,
  `DD_FORMAT`, `DD_L_DPB`, `DD_L_XDPB`, `DD_L_READ`, `DD_L_WRITE`, motor
  on/off/timeout and `DD_L_SEEK`), plus the keyboard calls (`KM_SET_SPEED`,
  `KM_SET_KEY`, `KM_SET_EXPAND`, `KM_KT_PUT`/`KM_KT_GET`), through BIOS
  function 30 (`USERF`); see [XBIOS/TE Interface](docs/cpm-plus-xbios.md).
- **Keyboard**: the +3 CP/M matrix — BREAK (`Caps Shift`+`Space`) sends ESC,
  `Caps Shift`+`Symbol` sends control codes, EXTEND+Enter flips the 24x80
  halves, plus the function-key mappings.
- **BDOS**: console and file I/O plus the CP/M 3 extensions real software
  uses — F44/F45/F46/F47/F48/F49/F50, F59, F99, F104/F105, F107-F112 and
  F120-F123 (SETDEF order/path). F46 computes free space from the allocation
  vector; F47 chains to a program without a prompt.
- **uPD765A FDC driver** with 512→128 byte sector deblocking.  Reads and
  writes the formats described by the XDPB, including 8-bit and 16-bit block
  numbers (DSM > 255), probing the geometry from the boot sector.
- **Banked memory**: 61K TPA, a separate system bank, and a common-memory stub
  that bridges TPA calls into the BIOS/BDOS.
- **MiniCCP**: `CCP.COM`, loaded from the boot disk at cold boot like real
  CP/M 3, with DIR, TYPE, ERA, REN, USER and HELP built in, `.COM` loading
  (including GENCOM COM files with a 256-byte header), the CP/M 3 warm-boot
  return address on the program stack, SUBMIT chaining and F47 program
  chaining.
- **C: RAM disk**: optional 16K `RAMDISK.FID` in bank 7.
- **Clock**: tick-driven date/time (F104/F105), maintained by an ISR in common
  memory so it keeps running while a TPA program executes.
- **Tooling**: a DSK image builder, font generator and emulator-driven test
  runners.

### Screen modes

| Mode | Size | Font | Notes |
|---|---|---|---|
| 32x24 | 32x24 | 8px | `SCREEN 32` |
| 51x24 | 51x24 | 5px | native +3 width, `SCREEN 51` |
| 64x24 | 64x24 | 4px | Compression font, `SCREEN 64` |
| 24x80 | 80x24 | current | virtual, paged, `SET24X80` |

The 24x80 buffer lives in bank 5 at `5B00-62BF`, outside the image and the
visible character buffer, so it costs no TPA or bank-6 space.

## CCP commands

Everything not built in is loaded from `?.COM` on the current drive or the
SETDEF search path.

| Command | Action |
|---|---|
| `DIR [filespec]` | directory listing (wildcards; the column count follows the screen width) |
| `TYPE filespec` | display a text file |
| `ERA filespec` | delete files (wildcards; `*.*` asks `ALL (Y/N)?` first) |
| `REN new=old` | rename a file (`REN new old` also works; wildcards are refused) |
| `USER [n]` | show or set the user area (0-15) |
| `HELP` | list the built-ins |

`A:`, `B:` and `C:` prefixes are accepted wherever a filespec is expected.

## Compatibility

The system boots from a standard 40-track +3 DSK and runs real CP/M software.
Every package below is downloaded, booted and exercised by
[the real-world suite](docs/realworld-suite.md); results are from the zx84 MCP
emulator.

| Package | Result | Notes |
|---|---|---|
| Zork I / II / III | Pass | large `.DAT` files, random reads, save files |
| dBASE II 2.43 | Pass | overlays, FCB random I/O, dot prompt |
| SuperCalc 1.05 / SuperCalc2 1.00 | Pass | overlays, cell entry, quit; SuperCalc2's VT-100 output is still literal |
| Microsoft Multiplan 1.05 | Pass | overlays, 80-column grid; the 24x80 variant fits it |
| VEDIT Plus 2.33 | Pass | CRT installer (VT-52), generated `VPLUS.COM`, opens a file |
| Microsoft COBOL-80 4.01 | Pass (compile) | `=HELLO` produces `HELLO.REL`; link/runtime needs the missing CRT driver |
| Spectrum +3 clock (3CLCK) | Partial | Extractor and CLOCKCLR pass; the clock FID needs the boot FID loader |
| BDS C 1.60 | Partial | Compiler part I/II banners; the compiler exits with a hang, so CLINK/run are untested |
| WordStar 3.0 | Pass | starts and draws its no-file menu; use `SET24X80` for its 80-column menus |
| WordMaster 1.07A | Pass | full edit/save cycle, BREAK = ESC |
| Microsoft BASIC-80 5.21 | Pass | interpreter, console and file I/O |
| Turbo Pascal 3.0 | Pass | IDE starts; `SCREEN 64` after a TINST 64-column install, or the 24x80 variant |
| Microsoft M80 + L80 3.44 | Pass | assemble → link → run |
| Microsoft FORTRAN-80 3.44 | Pass | compile → link → run |
| Microsoft BASIC Compiler 5.3 | Pass | compile → link → stand-alone `.COM` |
| Aztec C 1.06D | Pass | cc → asm → object → link → run |
| InterSystems Pascal/Z 4.0 | Pass | compile → assemble → link → run |
| muLISP-80 | Pass | LISP read-eval-print loop |
| APL/Z 1.1 | Pass | APL expressions in a 30 KB workspace |
| Microsoft ZSID 1.4 | Pass | debugger: load, dump, `G0` |
| SLR Z80ASM 1.32 | Pass | direct-to-`.COM` assembler; exercises F44 multi-sector reads |

All 24 packages are automated (some rows above group several packages);
the partial entries note what is still blocked. The suite is run on demand
rather than in CI because it downloads third-party software. The 24x80 variants (`wordstar30_80`, `turbo3_80`, `supercalc2_80`,
`multiplan_80`) are additional runs of four of those packages.

The default screen is 51 columns, the +3's native width.  For 80-column
software, enter the virtual 80-column screen with `SET24X80` (or `ESC x`);
it pans automatically or on EXTEND+Enter.  The real-world suite has 24x80
variants (`wordstar30_80`, `turbo3_80`, `supercalc2_80`) that run the same
packages under `SET24X80` and flip with EXTEND+Enter.

- **WordStar**'s menus wrap at 51 in the default mode; 24x80 gives them the
  full 80 columns and the right half.  Visual 200 escape codes still leave
  artifacts at the line starts.
- **Turbo Pascal**'s IDE wraps with its default install; TINST can install
  the editor for a 64-column terminal, which `SCREEN 64` fits, or use 24x80.
  Kaypro terminal escapes still leave stray `1` characters.
- **SuperCalc2** fits its banner in 24x80, but its VT-100 escapes are still
  printed literally; a VT-100 parser is the remaining blocker.
- **Multiplan** fits its command bar and grid in 24x80; terminal escapes
  still leave artifacts.

Also supported:

- A: and B: are selectable (a stock +3 has one single-sided drive; B:
  reads as empty rather than hanging, so software that probes it keeps
  working).  In an emulator a PCW DS/DD 720K image can be mounted on B:
  and used normally; the 720K format needs a double-sided drive, which
  real +3 hardware does not have.
- +3 and CPC 8-bit-block formats, plus the CP/M 3 16-bit block format
  (DSM > 255: eight 16-bit block numbers per extent, high byte first).
  `SHOWXDPB` displays the detected geometry; PCW DS/DD 720K disks (2K
  blocks, DSM=351) support full file I/O.
- Optional third-party CP/M utilities (BBC BASIC, PIP, ED, SET, ...) are
  picked up from `references/binaries/` when present; a source-only checkout
  ships the project's own tools and the CCP's DIR/TYPE/ERA/REN built-ins, so
  it can list, display, delete and rename files. `RENAME.COM` is deliberately
  not bundled (REN covers it); the smoke runner adds it to a scratch copy so
  a real third-party F23 caller is still exercised.

## Tools

- `SCREEN` — show or set the screen width (32, 51 or 64 columns).
- `SET24X80` — enter (`ON` or no argument) or leave (`OFF`) the virtual
  80-column screen.
- `DATE` — set/show the clock (4-digit year, tick-driven).
- `DUMP` — hex dump that adapts to the current screen width.
- `SETDEF` — show/set the search order and search path (F120-F123).
- `SHOWXDPB` — show the extended disk parameter blocks and detected geometry.
- `SUBMIT` — build the `$$$.SUB` file the CCP drains (supports `$1`..`$9`;
  nested submits are rejected).

## Test programs

- `BDOSTEST` — BDOS function tests (F1-F35, F104/F105).
- `STLTEST` — status line (`TE_STL`), 23-row viewport and scroll.
- `M80TEST` — 24x80 mode: TE_ASK width, auto-flip and leaving.
- `M80BIT` — 24x80 fast page flip, checked against a reference
  render of the logical buffer.
- `DISKTEST` — file, directory, extent and SCB tests (T1-T30,
  including 16-bit block numbers on a 720K B: image).
- `REGTEST` — BDOS register preservation (BC/DE/IX/IY across calls).
- `SYSTEST` — stack/MOVE/clock, page-zero, TAB and delimiter checks.
- `TERMTEST` — terminal escape-sequence walkthrough.
- `XTETEST` — XBIOS self-test (`TE_ASK`, `TE_RESET`, ink, border, speed,
  `SCR_RUN_ROUTINE`, and the disc calls).

## Wishlist / TODO

- **FORMAT** command (and a disk copy/verify tool).
- **VT-100/CSI parser** — in addition to the VT-52/ADM-3A sequences.
- **3px 80-column font** — a true 80x24 display with no paging (optional;
  24x80 already provides the width).
- **Larger multi-sector counts** — F44 currently accepts 1..127; 128 (a full
  16K buffer) is rejected so PIP falls back to its compatible path. Larger
  counts may be possible once PIP's buffering is fully understood.
- **Richer command-line file specs** (wildcards for `TYPE`, and the like).

## Out of scope

- Serial I/O
- Printer/parallel I/O
- Disckit.com

## Technical

### Memory Layout

| Range | TPA mode | System mode |
|-------|----------|-------------|
| 0000–3FFF | Bank 0 — TPA | Bank 4 — BIOS, BDOS, drivers |
| 4000–7FFF | Bank 1 — TPA | Bank 7 — C: RAM disk (16K) |
| 8000–BFFF | Bank 2 — TPA | Bank 6 — fonts, FID, FDC/text buffers |
| C000–F5FF | Bank 3 — TPA | Bank 3 — `CPM3.SYS` head (unused after init) |
| F600–FFFF | Common stub (bank 3) | Common stub (bank 3) |

`CPM3.SYS` is loaded at `C000` and can run past `F600` during the load;
`init` copies it to bank 4, then copies the common stub from bank 6 to
`F600–FFFF`.

Banking is controlled via port `0x1FFD`. See [AGENTS.md](AGENTS.md) for the
full architecture and [docs/boot.md](docs/boot.md) for the boot sequence.

### Building

Requires [sjasmplus](https://github.com/z00m128/sjasmplus) and Python 3.

```bash
# Build the disk image
build.cmd

# or, on a Unix-like shell
./build.sh

# Build with additional files
build.cmd --add FILE ...
```

Output: `build/cpm3.dsk` — a standard +3 disk image ready for emulation —
and `build/cpm3_720.dsk`, the PCW DS/DD 720K image used for 16-bit block
tests.

The system files on the disk are `CPM3.SYS` (BIOS + BDOS head),
`CPM3C.SYS` (common stub), `CCP.COM` (the command processor),
`FONT32.BIN`/`FONT51.BIN`/`FONT64.BIN` (screen fonts) and, optionally,
`RAMDISK.FID` (C: RAM disk). A disk without `CCP.COM` boots to a
diagnostic instead of a prompt; a disk without `CPM3C.SYS` does not boot.

The third-party binaries under `references/binaries/` are untracked and
optional. When present they are added automatically; a fresh clone (and CI)
builds a source-only disk, and the smoke runner skips the checks that need
them.

### Testing

Use the [zx84](https://github.com/damieng-zx/zx84) MCP emulator:

```
model +3
load build/cpm3.dsk
disk_boot
run 1000
```

zx84 snapshots can also be saved and loaded through MCP. After reaching a clean
prompt, use `save build/prompt.szx`; later use `load build/prompt.szx` to resume
testing from that prompt without rebooting the disk image.

Automated runners:

```bash
python3 tools/zx84_smoke.py              # boot, system tests, CCP, terminal
python3 tools/zx84_negative.py           # corrupted images must not boot
python3 tools/zx84_dri.py                # DRI utilities (needs local copies)
python3 tools/zx84_realworld.py          # the packages in the table above
python3 -m unittest discover -s tests -t .
```

### Project Structure

```
src/
  boot/     Boot sector and stage-2 loader
  bios/     BIOS, screen/keyboard/FDC drivers, common memory stub, fonts
  bdos/     BDOS (console + file I/O)
  ccp/      MiniCCP command processor
  fid/      RAM disk FID module
  util/     CP/M utilities
  test/     Test programs
tools/      Build tools (DSK image builder, font generator) and test runners
docs/       API reference, filesystem and compatibility documentation
```

## Documentation

- [Boot, Paging and Common Memory](docs/boot.md)
- [CP/M 3.1 BDOS API Reference](docs/API.md)
- [Filesystem Layout](docs/filesystem.md)
- [XBIOS/TE Interface](docs/cpm-plus-xbios.md)
- [CP/M Software Compatibility](docs/compatibility.md)
- [Real-world CP/M Suite](docs/realworld-suite.md)
- [zx84 MCP Smoke Test](docs/mcp-smoke-test.md)
- [Third-party Application Tests](docs/third-party-tests.md)
- [CI with zx84](docs/ci.md)

## Credits

The 64-column font is **Compression** from the
[ZX Origins](https://damieng.com/typography/zx-origins/compression/) collection.

## License

This project is licensed under the [MIT License](LICENSE).
