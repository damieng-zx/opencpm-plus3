# OpenCP/M +3

A complete, from-scratch CP/M 3.1 (CP/M Plus) for the ZX Spectrum +3. The
BIOS, BDOS, CCP, screen, keyboard and uPD765A drivers, the utilities and the
build and test tooling are all original Z80 assembly written for this project.

**It is not Locomotive Software's CP/M Plus, and contains no part of it.** No
Locomotive ROM, binary or disassembly was used: everything here was written
against the published CP/M 3 documentation and the +3's documented hardware
behaviour.

## Compared with Locomotive CP/M +3

Both systems speak CP/M 3.1 and the +3's XBIOS, so the same applications run.
Beyond that, this system offers:

| | Locomotive CP/M Plus (+3) | OpenCP/M +3 |
|---|---|---|
| Origin | Locomotive Software, 1987 | clean-room, this project |
| Text widths | 32 and 51 columns | 32, 51 and **64** columns |
| Virtual 80-column screen (`SET24X80`) | rendered in 51 columns | rendered in **51 or 64** columns |
| Formatting a disk | `DISCKIT` | **`FORMAT.COM`** (7 layouts) |
| Copying a disk | `DISCKIT` | **`DISKCOPY.COM`** (track level, verified) |
| RAM disk | `RAMDISC.FID` | **`RAMDISK.FID`**, 16K C: |
| Serial (AUX) device | supported | **not implemented** |
| Parallel (printer) | supported | **not implemented** |
| BASIC | Mallard BASIC | **BBC BASIC** |

## Features

- **Display** — 32, 51 and 64 columns plus the paged 24x80 virtual screen; see
  [Screen modes](#screen-modes).
- **Status line**: `ESC 0`/`ESC 1` toggle the bottom row for BIOS messages
  (23 text rows while it is on).  In 24x80 it carries the `<`/`>`
  hidden-column markers; `TE_STL_ASK` reports it as disabled in 24x80,
  as the +3 manual specifies.
- **Terminal**: VT52/ADM-3A cursor and erase sequences, colour and BRIGHT via
  `ESC b`/`ESC c`, wrap control (`ESC v`/`ESC w`), a settable viewport
  (`ESC X`), and the `ESC 3`/`ESC 4` screen-size and page-mode controls from
  the +3 CP/M manual.
- **XBIOS/TE**: the +3 extended BIOS terminal, disk and keyboard calls through
  BIOS function 30 (`USERF`) — `TE_ASK`, `TE_RESET`, `TE_SET_INK`,
  `TE_SET_BORDER`, `TE_SET_SPEED`, `SCR_RUN_ROUTINE`, the `DD_*` disk calls and
  the `KM_*` keyboard calls; see
  [XBIOS/TE Interface](docs/cpm-plus-xbios.md).
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
  that bridges TPA calls into the BIOS/BDOS; see
  [Memory Layout](#memory-layout).
- **Clock**: tick-driven date/time (F104/F105), maintained by an ISR in common
  memory so it keeps running while a TPA program executes.
- **C: RAM disk**: optional 16K `RAMDISK.FID` in bank 7.

### Screen modes

| Mode | Font | Select with |
|---|---|---|
| 32x24 | 8px | `SCREEN 32` |
| 51x24 | 5px | `SCREEN 51` (default) |
| 64x24 | 4px | `SCREEN 64` |
| 80x24 | current | `SET24X80` (virtual, paged) |

All modes are 24 rows high.  The 80x24 buffer lives in bank 5 at
`5B00-62BF`, outside the image and the visible character buffer, so it costs no
TPA or bank-6 space.  `SET24X80` / `ESC x` enters it, `ESC y` leaves, `ESC 3 2`
enters at the current width.  The window changes page on EXTEND+Enter (or
CAPS SHIFT+SYMBOL SHIFT+Enter), not when output crosses its edge, which
would flicker; a program can ask for automatic paging with `ESC 5 0`.  The window steps by 24, 29 or 16 columns at
32/51/64 columns.  A flip shifts the bitmap and re-renders only the exposed
columns; `<`/`>` on the status line mark hidden text.

## CCP commands

`CCP.COM` is loaded from the boot disk at cold boot like real CP/M 3.  It
loads `.COM` files (including GENCOM files with a 256-byte header), pushes the
CP/M 3 warm-boot return address so a program may exit with `RET`, chains submit
files and supports F47 program chaining.

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

The system boots from a standard 40-track +3 DSK and runs real CP/M 3 software.
It has been exercised end to end with 34 third-party packages — interpreters,
compilers, assemblers, debuggers, screen editors, databases and games — plus
the DRI CP/M 3 utilities, all downloaded, booted and driven under the zx84 MCP
emulator.

- **Compilers and toolchains** — M80/L80, FORTRAN-80, BASIC Compiler, Aztec C,
  Pascal/Z and SLR Z80ASM assemble, link and run.
- **Applications** — Zork I-III, dBASE II, SuperCalc, Multiplan, WordStar,
  WordMaster, VEDIT Plus, Turbo Pascal and BASIC-80 work; the large data files,
  overlays and random FCB I/O they use are the interesting part.
- **Games** — Pac-Man 95, STAR, Hunt, Ladder, Othello and Colossal Cave run,
  which covers dense full-screen redraws and keyboard input at play speed.
- **Interactive fiction** — Hitchhiker's Guide, Planetfall and Starcross run
  from their Infocom CP/M disks, streaming large `.DAT` files as they play.
- **DRI utilities** — ED, SET, SETKEYS and SHOW, including GENCOM files with a
  COM header.
- **Disk formats** — +3/CPC 8-bit blocks, the CP/M 3 16-bit block format (DSM >
  255) and PCW 720K images, with `SHOWXDPB` reporting the probed geometry.  A
  720K disc can be the *boot* disc: the stage-2 loader and boot sector are
  built for both layouts, and the test image uses the 720K pair.

The known gaps are documented rather than hidden: 3CLCK's clock FID needs a
generic +3 FID loader and Sargon fails a copy-protection check on the boot
track.  WordStar, Turbo Pascal, SuperCalc2 and Multiplan need the
[24x80 screen](#screen-modes) or, for Turbo Pascal, `SCREEN 64` after a TINST
64-column install.

Per-package results, the exact checks run and why the failures fail are in the
[compatibility tables](docs/compatibility.md); the harness is described in the
[real-world suite](docs/realworld-suite.md).  See [Documentation](#documentation)
for the API references.

## Tools

- `SCREEN.COM` — show or set the screen width (32, 51 or 64 columns).
- `SET24X80.COM` — enter (`ON` or no argument) or leave (`OFF`) the virtual
  80-column screen.
- `DATE.COM` — set/show the clock (4-digit year, tick-driven).
- `DUMP.COM` — hex dump that adapts to the current screen width.
- `SETDEF.COM` — show/set the search order and search path (F120-F123).
- `SHOWXDPB.COM` — show the extended disk parameter blocks and detected
  geometry.
- `SUBMIT.COM` — build the `$$$.SUB` file the CCP drains (supports `$1`..`$9`;
  nested submits are rejected; a line beginning with `<` is passed to the
  running program as console input, so a script can drive `PIP`).
- `FORMAT.COM` — format a disk in A: or B: (`FORMAT A:` / `FORMAT B:`). Asks
  for the disk to be swapped, then for a layout:

  | # | Layout | Geometry |
  |---|---|---|
  | 1 | 180K SS/40 (PCW) | 9 sectors, 1 reserved track |
  | 2 | 720K DS/80 (PCW) | 9 sectors, 1 reserved track |
  | 3 | CPC System 40 | 9 sectors, 2 reserved, IDs 41h-49h |
  | 4 | CPC Data 40 | 9 sectors, no reserved, IDs C1h-C9h |
  | 5 | HiForm 203 42 | 10 sectors, 12/22 gaps, interleave 3 |
  | 6 | SuperMat 192 40 | 10 sectors, 3 dir blocks, interleave 1 |
  | 7 | CPC IBM 40 | 8 sectors, interleave 2 |

  Formats one track and verifies it sector by sector before moving on, with a
  live `percentage / track / side / FORMAT|VERIFY` line. It writes the AMSDOS
  disk spec into the boot sector of the layouts that reserve one, and the login
  probe rebuilds the geometry from that spec, so 10-sector and 42-track disks
  are detected as themselves. CPC Data is identified by its sector IDs
  instead. No no-verify option or bad-sector mapping yet.
- `STAT.COM` — `STAT` shows each drive's free space (`A: 59K free of 175K`);
  `STAT filespec` lists matching files with size and attributes (`R/O`,
  `SYS`); `STAT filespec $R/O` / `$R/W` / `$SYS` sets or clears an attribute.
  Free space comes from BDOS F46, capacity from the DPB, sizes by summing the
  directory extents, attributes from the entry and F30. Wildcards work for
  listing only (F30 matches exact names).
- `DISKCOPY.COM` — copy one disk to another: `DISKCOPY A: B:`,
  `DISKCOPY B: A:`, or the same drive twice (`A: A:` / `B: B:`).  It asks for
  the source (and target) disks, detects the source layout with the same login
  probe the BIOS uses, then copies track by track.  With two drives each track
  is read and written straight away; on one drive it reads as many tracks as
  fit in a 48K buffer (up to 10), asks for the target, writes them, and asks
  for the source back.  A live line shows the percentage, the logical track,
  the side and READ/FORMAT/WRITE.  The target does not have to be
  pre-formatted: as each track is written, the target track is formatted first,
  using the source track's own ID layout (captured with repeated READ ID, so
  the interleave and skew are copied rather than re-chosen).  The absolute
  rotational phase is not observable, so the target's ID order can be a
  rotation of the source's cycle.  Every written track is then read back and
  compared with the data still in the buffer (DD_CHECK_SECTOR), so a write that
  silently failed is caught on the spot.
- `SYSGEN.COM` — make a formatted disk bootable: `SYSGEN B:` or `SYSGEN A:`.
  The system is read from A: (track 0 — boot sector and stage-2 loader — plus
  `CPM3.SYS`, `CPM3C.SYS` and `CCP.COM`) and buffered in memory, so the target
  can be the same drive: SYSGEN then asks for the disks to be swapped. The
  target's geometry is checked against the source's first; only the boot track
  and the three system files are written, so other files on the target are
  kept. Every written file is read back and compared with the buffered copy
  (`Checking CPM3.SYS... ok`), and for the same drive the boot track is written
  after the swap.

## Wishlist / TODO

- **DISKCOPY: optional check of the source as well** (a full source-read pass
  before the copy).
- **FORMAT options** — no-verify, a bootable system layout and mapping bad
  sectors into a hidden file.
- **ANSI extras** — the CSI subset (see
  [docs/ansi-subset.md](docs/ansi-subset.md)) covers cursor motion, erase
  and save/restore; SGR (`ESC [ … m`) and the private autowrap modes
  (`ESC [ ? 7 h/l`) are still accepted and ignored.
- **Larger multi-sector counts** — F44 currently accepts 1..127; 128 (a full
  16K buffer) is rejected so PIP falls back to its compatible path. Larger
  counts may be possible once PIP's buffering is fully understood.
- **Richer command-line file specs** (wildcards for `TYPE`, and the like).

## Technical

### Memory Layout

| Range | TPA mode | System mode |
|-------|----------|-------------|
| 0000–3FFF | Bank 0 — TPA | Bank 4 — BIOS, BDOS, drivers |
| 4000–7FFF | Bank 1 — TPA | Bank 7 — C: RAM disk (16K) |
| 8000–BFFF | Bank 2 — TPA | Bank 6 — fonts, FID, FDC/text buffers |
| C000–F5FF | Bank 3 — TPA | Bank 3 — `CPM3.SYS` head (unused after init) |
| F600–FFFF | Common stub (bank 3) | Common stub (bank 3) |

`CPM3.SYS` is loaded at `C000` and can run past `F600` during the load; `init`
copies it to bank 4, then copies the common stub to `F600–FFFF` from
`CPM3C.SYS`, which the loader stages in bank 5 at `62C0` behind the screen
code that runs from there.

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

Output: three +3 images and one data image.

| Image | Contents |
|---|---|
| `build/cpm3.dsk` | **Distribution.** A 180K single-sided +3 disc: the system files, the utilities under [Tools](#tools), and — when `references/binaries/` is present — the local third-party utilities, including **BBC BASIC**. |
| `build/cpm3-dist720.dsk` | **720K distribution.** The same CP/M files as `cpm3.dsk`, on a 720K PCW DS/DD disc (80 cylinders, two alternating sides, 2K blocks) booted by the `-DDS720` pair. Nothing extra on it yet: it exists for the ~570K free it gives a larger tool set later. |
| `build/cpm3-test.dsk` | **Test image.** A 720K PCW DS/DD disc carrying everything on the distribution image plus the on-disk regression suite, its fixtures and, when fetched, `PMAUTOAE.COM`. The smoke runner boots this image. |
| `build/cpm3_720.dsk` | PCW DS/DD 720K data image used by the 16-bit block tests. |

A 720K disc is not readable by an unmodified +3 (its drive is single-sided
180K), so `cpm3.dsk` remains the image for real hardware; the 720K pair suits
emulators, PCW drives and the larger third-party toolkits.

A disk without `CCP.COM` boots to a diagnostic instead of a prompt; a disk
without `CPM3C.SYS` does not boot.

The third-party binaries under `references/binaries/` are untracked and
optional. When present they are added to **every** +3 image automatically, so
each distribution disk carries BBC BASIC and your other tools; a fresh clone
(and CI) builds a source-only disk, and the smoke runner skips the checks that
need them.  Those files are copyrighted: they are not part of the repository and
are never shipped with a release.  `RENAME.COM` is deliberately excluded (the
CCP's built-in `REN` covers it); the smoke runner adds it to a scratch copy so
a real third-party F23 caller is still covered.  `NULU11.COM` (an LBR library
manager) is left off the image, and so is `PROFILE.SUB`: it is Amstrad's
start-up script, and running it at every cold boot would copy ~10K into the
16K `C:` RAM disk before the first prompt.  The file itself works: add it to a
disk and it runs as it did on the original system.

`PMAUTOAE.COM` (the PMARC toolkit self-extractor by Yoshihiko Mino) is
handled differently: it is third-party too, so it goes **only on the 720K
test image**, and only when `tools/fetch_pmautoae.py` has downloaded it into
`references/binaries/`.  The 720K image has room for the 31K archive *and*
the ten files it extracts, which the 180K distribution image does not.  The
720K distribution image deliberately carries neither.

### Testing

Use the [zx84](https://github.com/damieng-zx/zx84) MCP emulator:

```
model +3
load build/cpm3.dsk          ; the distribution image
disk_boot
run 1000
```

To run the on-disk test suite use `build/cpm3-test.dsk` instead; the programs
and what each covers are listed in the [smoke test](docs/mcp-smoke-test.md).

zx84 snapshots can also be saved and loaded through MCP. After reaching a clean
prompt, use `save build/prompt.szx`; later use `load build/prompt.szx` to resume
testing from that prompt without rebooting the disk image.

Automated runners:

```bash
python3 tools/zx84_smoke.py              # boot, system tests, CCP, terminal
python3 tools/zx84_negative.py           # corrupted images must not boot
python3 tools/zx84_dri.py                # DRI utilities (needs local copies)
python3 tools/zx84_realworld.py          # the third-party packages
python3 tools/screen_bench.py            # screen rendering, in T-states
python3 -m unittest discover -s tests -t .
```

The screen benchmark runs the same binary on this system and on Locomotive's
CP/M Plus, and `--compare` tabulates the two; see
[screen benchmark](docs/screen-benchmark.md).

The smoke runner defaults to the test image; pass `--dsk build/cpm3.dsk` to
boot the distribution image (that only makes sense with `--quick`).  When BBC
BASIC is in `references/binaries/` the smoke also boots a copy of the
distribution image and checks that it starts (`BBC BASIC (Z80)` and the `>`
prompt).

### Project Structure

```
src/
  boot/     Boot sector and stage-2 loader
  bios/     BIOS, screen/keyboard/FDC drivers, common memory stub, fonts
  bdos/     BDOS (console + file I/O)
  ccp/      MiniCCP command processor
  fid/      RAM disk FID module
  util/     CP/M utilities
  test/     Sources for the on-disk regression programs
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
- [Screen Rendering Benchmark](docs/screen-benchmark.md)
- [zx84 MCP Smoke Test](docs/mcp-smoke-test.md)
- [Third-party Application Tests](docs/third-party-tests.md)
- [CI with zx84](docs/ci.md)

## License

This project is licensed under the [MIT License](LICENSE).
