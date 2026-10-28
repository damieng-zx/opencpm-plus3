# OpenCP/M +3

Clean-room CP/M 3.1 (CP/M Plus) for the ZX Spectrum +3. Every part of the
system — BIOS, BDOS, CCP, drivers and tools — is original Z80 assembly written
for this project.

## Features

- **Three text modes**: 32x24 (8px font), 51x24 (5px, the +3's native width)
  and 64x24 (4px "Compression" font, two characters per attribute cell).
  `SCREEN 32|51|64`, or BIOS function 32.
- **Terminal**: VT52/ADM-3A cursor and erase sequences, colour and BRIGHT via
  `ESC b`/`ESC c`, wrap control (`ESC v`/`ESC w`), and the `ESC 3`/`ESC 4`
  screen-size and page-mode controls from the +3 CP/M manual.
- **Keyboard**: the +3 CP/M matrix — BREAK (`Caps Shift`+`Space`) sends ESC,
  `Caps Shift`+`Symbol` sends control codes, plus the function-key mappings.
- **BDOS**: console and file I/O plus the CP/M 3 extensions real software
  uses — F44/F45/F46/F47/F48/F49/F50, F59, F99, F104/F105, F107-F112 and
  F120-F123 (SETDEF order/path). F46 computes free space from the allocation
  vector; F47 chains to a program without a prompt.
- **uPD765A FDC driver** with 512→128 byte sector deblocking. Reads and writes
  the formats described by the XDPB (8-bit blocks), probing the geometry from
  the boot sector.
- **Banked memory**: 61K TPA, a separate system bank, and a common-memory stub
  that bridges TPA calls into the BIOS/BDOS.
- **MiniCCP**: `CCP.COM`, loaded from the boot disk at cold boot like real
  CP/M 3, with DIR, TYPE, ERA, REN, USER, HELP and SCREEN built in, `.COM` loading, SUBMIT
  chaining and F47 program chaining.
- **C: RAM disk**: optional 16K `RAMDISK.FID` in bank 7.
- **Clock**: tick-driven date/time (F104/F105), maintained by an ISR in common
  memory so it keeps running while a TPA program executes.
- **Tooling**: a DSK image builder, font generator and emulator-driven test
  runners.

## CCP commands

Everything not built in is loaded from `?.COM` on the current drive or the
SETDEF search path.

| Command | Action |
|---|---|
| `DIR [filespec]` | directory listing (wildcards; the column count follows the screen width) |
| `TYPE filespec` | display a text file |
| `ERA filespec` | delete files (wildcards; `*.*` asks `ALL (Y/N)?` first) |
| `REN new=old` | rename a file (wildcards are refused) |
| `USER [n]` | show or set the user area (0-15) |
| `SCREEN [32\|51\|64]` | set or query the screen width |
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
| SuperCalc 1.05 / SuperCalc2 1.00 | Pass | overlays, cell entry, quit |
| WordStar 3.0 | Pass | starts and draws its no-file menu; 80-column menus wrap at 51 (see below) |
| WordMaster 1.07A | Pass | full edit/save cycle, BREAK = ESC |
| Microsoft BASIC-80 5.21 | Pass | interpreter, console and file I/O |
| Turbo Pascal 3.0 | Pass | IDE starts; fits `SCREEN 64` after a TINST 64-column install |
| Microsoft M80 + L80 3.44 | Pass | assemble → link → run |
| Microsoft FORTRAN-80 3.44 | Pass | compile → link → run |
| Microsoft BASIC Compiler 5.3 | Pass | compile → link → stand-alone `.COM` |
| Aztec C 1.06D | Pass | cc → asm → object → link → run |
| Microsoft ZSID 1.4 | Pass | debugger: load, dump, `G0` |
| SLR Z80ASM 1.32 | Known | needs full multi-sector F20; see the TODO list |

15 of the 16 packages pass (some rows above group several packages);
Z80ASM's limitation is documented in the suite. The suite is run on demand
rather than in CI because it downloads third-party software.

Two display caveats, both from the same root cause — the default screen is 51
columns:

- **WordStar** is an 80-column program; its menus wrap at 51 columns.
- **Turbo Pascal**'s 80-column IDE wraps with its default install; TINST can
  install the editor for a 64-column terminal, which `SCREEN 64` then fits.

Also supported:

- A: and B: are selectable (there is one physical drive; B: reads as empty
  rather than hanging, so software that probes it keeps working).
- +3 and CPC 8-bit-block formats via the extended DPB machinery; `SHOWXDPB`
  displays the detected geometry. PCW 720K disks are detected but their
  16-bit block file I/O is not implemented.
- Optional third-party CP/M utilities (BBC BASIC, PIP, ED, RENAME, SET, ...)
  are picked up from `references/binaries/` when present; a source-only
  checkout ships the project's own tools and the CCP's DIR/TYPE/ERA/REN
  built-ins, so it can list, display, delete and rename files. PIP and RENAME
  are also exercised by the smoke runner when those binaries are on the disk.

## Tools

- `DATE` — set/show the clock (4-digit year, tick-driven).
- `DUMP` — hex dump that adapts to the current screen width.
- `SETDEF` — show/set the search order and search path (F120-F123).
- `SHOWXDPB` — show the extended disk parameter blocks and detected geometry.
- `SUBMIT` — build the `$$$.SUB` file the CCP drains (supports `$1`..`$9`;
  nested submits are rejected).

## Test programs

- `BDOSTEST` — BDOS function tests (F1-F35, F104/F105).
- `DISKTEST` — file, directory, extent and SCB tests (T1-T22).
- `REGTEST` — BDOS register preservation (BC/DE/IX/IY across calls).
- `SYSTEST` — stack/MOVE/clock, page-zero, TAB and delimiter checks.
- `TERMTEST` — terminal escape-sequence walkthrough.
- `XTETEST` — XBIOS/TE probe.

## Wishlist / TODO

- **FORMAT** command (and a disk copy/verify tool).
- **80-column mode** — a 3px font, or an 80-column buffer with a panned
  viewport. This is the remaining gap for WordStar and other 80-column
  layouts.
- **Full multi-sector F20 transfers**, which would fix Z80ASM. A prototype
  broke PIP's copy, so the single-record behaviour stands until that is
  understood.
- **16-bit block formats** (PCW 720K file I/O).
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
| C000–F5FF | Bank 3 — TPA | Bank 3 — loaded image (unused after init) |
| F600–FFFF | Common stub (bank 3) | Common stub (bank 3) |

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

Output: `build/cpm3.dsk` — a standard +3 disk image ready for emulation.

The system files on the disk are `CPM3.SYS` (BIOS + BDOS), `CCP.COM` (the
command processor), `FONT32.BIN`/`FONT51.BIN`/`FONT64.BIN` (screen fonts) and,
optionally, `RAMDISK.FID` (C: RAM disk). A disk without `CCP.COM` boots to a
diagnostic instead of a prompt.

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
- [CI with zx84](docs/ci.md)

## Credits

The 64-column font is **Compression** from the
[ZX Origins](https://damieng.com/typography/zx-origins/compression/) collection.

## License

This project is licensed under the [MIT License](LICENSE).
