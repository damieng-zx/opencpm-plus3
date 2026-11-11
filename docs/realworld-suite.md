# Real-world CP/M suite

`tools/zx84_realworld.py` downloads a curated set of popular CP/M packages,
builds a bootable +3 DSK for each one, boots it through the zx84 MCP server,
runs a short scripted check, and reports:

- `PASS` — the package started and the expected output appeared.
- `KNOWN` — the package hit its documented known issue.
- `FAIL` — an unexpected compatibility or setup failure.

Downloads are cached in `references/realworld/` (gitignored). Extracted files
and test DSKs are written to `build/realworld/` (also ignored).

## Running it

```bash
# See the package list
python3 tools/zx84_realworld.py --list

# Run one package
python3 tools/zx84_realworld.py --package zork1

# Run several
python3 tools/zx84_realworld.py --package zork1 dbase2 supercalc2

# Download and prepare files without booting
python3 tools/zx84_realworld.py --download-only

# Build the DSKs without booting
python3 tools/zx84_realworld.py --build-only --package zork1

# Re-download a changed archive
python3 tools/zx84_realworld.py --package zork1 --refresh

# Treat known issues as failures
python3 tools/zx84_realworld.py --strict-known
```

The emulator checkout is found through `--zx84`, `ZX84_DIR`, a sibling
`zx84/` checkout, or the local `F:\src\zx\zx84` path. Some ZIPs use a
compression method Python does not support; the runner falls back to
`7z`/`7za`/`7zz` when one is installed.

This suite is **not part of CI by default**. It downloads third-party
software and depends on emulator/ROM availability. Run it manually or from a
separate, explicitly triggered workflow.

## Current automated packages

| ID | Package | What it tests | Status |
|---|---|---|---|
| `zork1` | Zork I | Large `.DAT`, random reads, console | Pass |
| `dbase2` | dBASE II 2.43 | FCB random I/O, overlays, dot prompt | Pass |
| `supercalc2` | SuperCalc2 1.00 | Spreadsheet, overlays, VT-100 output | Pass |
| `supercalc2_80` | SuperCalc2 1.00 (24x80) | 80-column banner, grid and status row, right-half flip | Pass |
| `multiplan` | Microsoft Multiplan 1.05 | Spreadsheet, overlays, 80-column grid | Pass |
| `multiplan_80` | Microsoft Multiplan 1.05 (24x80) | 80-column command bar/grid, right-half flip | Pass |
| `vedit` | VEDIT Plus 2.33 (CRT) | Installer (VT-52), then open/edit a file | Pass |
| `cobol80` | Microsoft COBOL-80 4.65 | `COBOL` → `L80` → `HELLO.COM` prints `HELLO, WORLD` (720K image) | Pass |
| `clck3` | Spectrum +3 clock extractor | Self-extract, `CLOCKCLR` | Pass (FID not loaded) |
| `salvage` | SALVAGE 1.00 (John Elliott) | Self-extract, then a live disc drive picker | Pass |
| `tapedisc` | TAPEDISC (John Elliott) | Self-extract, then the tape device as drive T: | Pass |
| `c80` | Software Toolworks C/80 3.1 | `C` → `AS` → `HELLO.COM` prints a line | Pass |
| `magicwand` | Magic Wand 1.1 (text editor) | Menu, then the 80-column status screen | Pass |
| `dskwrite` | DSKWRITE (John Elliott) | Two-stage self-extract, then its usage text | Pass |
| `bdsc` | BDS C 1.60 | `CC` → `CLINK` → `HELLO.COM` prints `HELLO, WORLD` | Pass |
| `wordstar30` | WordStar 3.0 | Full-screen editor, terminal escapes | Pass (80-column caveat) |
| `wordstar30_80` | WordStar 3.0 (24x80) | 80-column menu, EXTEND+Enter right half | Pass (escape artifacts) |
| `mbasic` | Microsoft BASIC-80 5.21 | Interpreter, console/file I/O | Pass |
| `turbo3` | Turbo Pascal 3.0 | Compiler/IDE, overlays, TPA | Pass (80-column caveat) |
| `turbo3_80` | Turbo Pascal 3.0 (24x80) | 80-column IDE, right-half flip | Pass (escape artifacts) |
| `m80l80` | Microsoft M80 + L80 | Assembler → REL → `.COM`, then run | Pass |
| `f80344` | Microsoft FORTRAN-80 3.44 | Compiler → REL → link with FORLIB → run | Pass |
| `bascom53` | Microsoft BASIC Compiler 5.3 | BASIC-80 → OBSLIB → stand-alone `.COM`, then run | Pass |
| `aztec106` | Aztec C 1.06D | cc → asm → object → link with C.LIB → run | Pass |
| `pascalz` | InterSystems Pascal/Z 4.0 | Compile -> assemble -> link with LIB.REL -> run | Pass |
| `mulisp` | muLISP-80 | LISP read-eval-print arithmetic | Pass |
| `aplz` | APL/Z 1.1 | APL vector/arithmetic expressions, 30 KB workspace | Pass |
| `z80asm` | SLR Z80ASM 1.32 | Direct-to-`.COM` macro assembler (F44 multi-sector read) | Pass |
| `zsid` | Microsoft ZSID 1.4 | Debugger: load, memory dump, `G0` | Pass |
| `zsid_break` | ZSID 1.4 breakpoint | `F100,CFFF,0` then `G100,D000` must stop at `*D000` | Known issue (IM 1 tick shares RST 7; same on Locomotive's +3 CP/M) |
| `zork2` | Zork II | Large `.DAT`, save-file write | Pass |
| `zork3` | Zork III | Paged intro, large `.DAT`, save-file write | Pass |
| `wordmaster` | MicroPro WordMaster 1.07A | Full-screen edit, BREAK/ESC, save, TYPE | Pass |
| `supercalc1` | SuperCalc 1.05 | Spreadsheet start, cell entry, quit | Pass |
| `pacman95` | Pac-Man 95 | Arcade maze redraw, keyboard at speed | Pass |
| `star` | STAR (Star Trek) | Long wrapped console output, name prompt | Pass |
| `hunt` | Hunt | Shop screen, maze redraw | Pass |
| `ladder` | Ladder | High-score menu, live status line, `.DAT` file | Pass |
| `othello` | Othello | Paged prompt, FORTRAN-built board game | Pass |
| `sargon` | Sargon (chess) | Copy-protected; raw boot-track reads spin forever | Known issue |
| `advent` | Colossal Cave Adventure (A02) | 3-digit seed, movement, on-disk message files | Pass |
| `hitchhiker` | The Hitchhiker's Guide to the Galaxy | 113K `.DAT` streamed as the game runs | Pass |
| `planetfall` | Planetfall | Multi-screen intro, status line | Pass |
| `starcross` | Starcross | Game's own status line updates every turn | Pass |

Notes on individual packages (the display caveats are recorded known
issues; the others are history):

- **WordStar 3.0** starts and draws its no-file menu, and the automated
  check (banner and menu) passes.  It is an 80-column program, so on the
  51-column screen each line wraps and overlaps the next; the
  `wordstar30_80` variant runs it after `SET24X80` and flips with
  EXTEND+Enter.  The 80-column menu and the right half are now readable;
  Visual 200 escape codes still leave artifacts at the line starts.
  The original crash was a page-zero bug - `(0006h)` held `bdos_stub`
  (F737) instead of the TPA top (F600), so WordStar sized its screen
  buffer from the wrong ceiling and overwrote the BIOS jump table.
  `common.zpa` now places `bdos_vector` at F600 and page zero 0006h points
  at it.
- **Turbo Pascal 3.0** runs (banner, `TURBO.MSG` load, IDE menu) and its
  80-column frames wrap on the 51-column screen.  TINST can install the
  editor for a 64-column terminal (`SCREEN 64`), and the `turbo3_80`
  variant runs the default install after `SET24X80` and checks the right
  half.  Kaypro terminal escapes still leave stray `1` characters.
- **SuperCalc2 1.00** the `supercalc2_80` variant fits the banner and the
  80-column grid and flips to the right half, and its VT-100 output is
  consumed by the CSI subset (see [ansi-subset.md](ansi-subset.md)).  SGR is
  honoured too: in the 51-column run the grid's column-header row draws 64
  bright cells plus 6 reversed ones (the current-column marker), where every
  cell used to be plain.  The program only ever asks for `ESC[0m`, `ESC[1m`
  and `ESC[7m`, which the Spectrum attribute register can express exactly, and
  both packages assert the attributes with a step's `expect_attrs`.
- **Multiplan 1.05** needs the `MP80` data overlay plus `MP.OVR`,
  `MP.HLP`, `DEFAULT.FK` and `RFILE`; `MP.COM` reports
  "no data file present (MP80 or MP40)" without it.  The
  `multiplan_80` variant fits the command bar and grid in 24x80 and
  flips to the right half; terminal escapes still leave artifacts at
  the line starts.
- **VEDIT Plus 2.33** is a CRT distribution: the archive has a `.SET`
  file, not a runnable editor.  The test runs `INSTALL VPLUSZC.SET
  VPLUS.COM`, selects DEC VT-52 (option 12 then 16), answers the save
  prompt and then opens `SMOKE.TXT` with the generated `VPLUS.COM`.
  The installer ignores the first character of the Y/N answer, so the
  manifest answers `" yes"`.
- **COBOL-80 4.65** runs the whole chain on a 720K image: `COBOL` compiles
  `=HELLO`, `L80` links it and `HELLO` prints `HELLO, WORLD`.  Three things
  had to be right.  The 4.01 archive used to be staged here has no
  `CRTDRV.REL` at all, so the REL could never link; the 221K `mscobol.zip`
  carries the complete 4.65 set.  That set does not fit the 174 KB data
  area of a 180K disc, so the package overrides the boot pair to the 720K
  layout (`"format": "720k"` plus a per-package `base`).  And L80 needs
  `COBLOC` and `COBLBX.REL` staged alongside `COBLIB`, `CRTDRV` and a
  terminal driver (`CDADM3`); without the terminal driver a program that
  does cursor/erase work dies with `NO CRT DRIVER`.  The COBOL source itself
  must give `PROCEDURE DIVISION` a named paragraph: without one the
  compiler reports 1 error and the runtime answers `DATA UNAVAILABLE`.
- **3CLCK** extracts `CLOCK.FID`, `CLOCK.F64`, `CLOCK.DOC` and
  `CLOCKCLR.COM`.  CLOCKCLR runs and correctly reports that the clock
  FID is not loaded: the clock is installed at boot through `CLOCK.FID`,
  while this BIOS only stages `RAMDISK.FID`.  Loading it is deliberately
  not planned: the Locomotive FIDs call fixed addresses in the private
  common-memory ABI (`FF04`/`FF05`/`FF08`/`FF09`) and use their own header,
  so a native status-line clock built on `scb_date`/`scb_minute`/`scb_sec`
  is the better route.  The package stays automated because the extractor
  and CLOCKCLR are still worth covering.
- **BDS C 1.60** now runs end to end: `CC HELLO.C` compiles to `HELLO.CRL`,
  `CLINK HELLO` links it and `HELLO` prints `HELLO, WORLD`.  Two earlier
  notes were wrong.  The compiler does return to the CCP — what looked like
  a hang was the CCP prompt waiting for input.  And `CLINK` failing with
  `Missing function(s): PUTCHAR` was not a CP/M problem: `DEFF2.CRL`, the
  part-II library, was missing from the staged files.  Both `DEFF.CRL` and
  `DEFF2.CRL` must be on the disk.
- **BASCOM 5.3** used to exit immediately because the suite pulled
  `BASCOM53.ZIP`, which is an OEM build: its start-up probes a banked
  machine (writes to ports 0/1 and `0EF08h`, and expects a `JP` at `0100h`
  to survive a write) and warm-boots when the probe fails.  `BASCOM.ZIP`
  carries the generic build.  The compile line is `BASCOM =CHELLO/O`;
  `/O` produces a stand-alone program that links against `OBSLIB.REL`
  instead of needing `BRUN.COM` at run time.
- **Aztec C 1.06D** used to stop at the linker with `Not an object file!`.
  The image was one file too full: including `LIBC.REL` left no free
  block, so `AS` created a zero-length `CHELLO.O`.  With `LIBC.REL`
  omitted, `LN CHELLO.O C.LIB` links and the program runs.
- **Z80ASM 1.32** sets a multi-sector count (8) with F44 and then reads its
  source once, assuming the whole block was transferred.  F20/F21 now apply
  the F44 count (1..128) to both sequential directions and report the records
  moved in H, so the source buffer is complete and the package passes.  PIP's
  128 (a full 16K buffer) is accepted, and its buffered copy, `[V]` verify
  and RAM-disk transfers all work.

- **Pascal/Z 4.0** compiles HELLO.PAS with `PASCAL54 HELLO` (the 54K
  compiler loads the PAS254 overlay), assembles with
  `ASMBL MAIN,HELLO/REL` (MAIN.SRC is the run-time interface), and links
  with `LINK /N:A:HELLO A:HELLO /G`, which also runs the program.  The
  fixture keeps the `{$i+ }` I/O-check directive Pascal/Z expects.
- **muLISP-80** is an interpreter: `MULISP` enters the `$` read-eval-print
  loop, and `(PLUS 2 3)`/`(TIMES 6 7)` must return `5`/`42`.
- **APL/Z 1.1** asks for the date as `mmddyy` before starting; the harness
  enters `010180` so the screen is deterministic, then checks `2+2` and a
  vector sum in the 30 KB workspace.

- **Pac-Man 95** waits for a CR, then a game-mode digit (1-4); it draws an
  arcade maze straight into the screen buffer and reads the keyboard at speed,
  which exercises the console path under load.
- **STAR**, **Hunt**, **Ladder** and **Othello** are scripted through their
  first screen only, so the checks stay deterministic: a random-number prompt
  (Hunt), a randomised starship name (STAR), a menu and status line (Ladder)
  and a paged prompt (Othello).  Ladder needs one settle step after its menu
  appears, otherwise the `P` keypress arrives before the program reads input.
- **Sargon** is copy-protected.  It issues raw uPD765 `READ DATA` commands
  against the boot track (C=1, R=1..N, polled on port `2FFD`) and loops forever
  waiting for the original disk's sector IDs, so it never draws its title.

- **Colossal Cave Adventure** (Mike Goetz's CP/M port of Crowther and Woods)
  takes a 3-digit seed before play; the harness enters `123`.  Its parser only
  accepts short forms (`n`, `s`, not `north`/`south`) and its output is wrapped
  to whatever screen width is current.
- **Hitchhiker's**, **Planetfall** and **Starcross** are Infocom's CP/M builds,
  taken from archive.org `.dsk` images with `"archive": "dsk"` (the runner
  reads the CP/M directory out of the image and copies the named files out).
  `HITCHHIK.COM` and `PLANET.COM` are 256-byte stubs that pick a
  `HITCnnn`/`PLANnnn` build for the TPA size, so the suite runs the 128K
  variants directly and leaves the stubs on the disk.

- **WordMaster 1.07A** edits and saves.  Leaving its insert mode needs
  `ESC`, which on the +3 is the BREAK key (`Caps Shift + Space`) per the
  CP/M Plus manual; the package now runs the full edit-save-`TYPE` cycle.
- **SuperCalc 1.05** runs its grid and accepts cell entries, but saving a
  `.CAL` aborts with `SuperCalc program diskette MUST remain on disk
  drive` — its media check does not accept the image.  The archive's
  `SC.COM` also needs an `SC.HLP` that is not shipped; `SCHAZ15.COM`
  (the pre-installed Hazeltine build) works.

The assembler/compiler packages use fixtures from
`tests/realworld/fixtures/` (`HELLO.MAC`, `CHELLO.FOR`, `CHELLO.BAS`,
`CHELLO.C`, `HELLO.Z80`, `HELLO.COB`, `HELLO.PAS`, `C80HELLO.C`).  They are
CRLF text files because the CP/M tools read them directly (see
`.gitattributes`).  `C80HELLO.C` is separate from `HELLO.C` because C/80
resolves `printf` by `#include`ing `PRINTF.C`, and the package stages it as
`HELLO.C` through a `fixtures` mapping.

SuperCalc2 used to leave its VT-100 escape output visible in the character
buffer (`[?3h[2J[H`); the CSI subset now parses those sequences, so the
banner and grid are positioned by the escapes rather than by stray text.

## Adding a package

Edit `tests/realworld/manifest.json`:

```json
{
  "id": "example",
  "title": "Example CP/M program",
  "url": "http://example.invalid/EXAMPLE.ZIP",
  "archive": "zip",
  "members": ["EXAMPLE.COM", "EXAMPLE.OVR"],
  "fixtures": ["OPTIONAL.TXT"],
  "setup": ["SET24X80"],
  "command": "EXAMPLE",
  "expect": ["READY"],
  "frames": 2500,
  "steps": [
    { "key": "enter", "frames": 800, "expect": ["A>"] }
  ],
  "known_issue": "optional text; omit when the package is expected to pass",
  "notes": "what the package exercises"
}
```

`archive` may be `zip`, `file` or `dsk`. For `file`, use `save_as` to name the
CP/M file.  For `dsk`, `members` names files inside the image's CP/M
directory; they are extracted with `tools/mkdsk.py` (which reads both plain
and extended CPCEMU containers).  `fixtures` refers to
`tests/realworld/fixtures/`.

A `fixtures` entry is either a name or a one-entry mapping when the file has
to land under a different on-disk name: `{"C80HELLO.C": "HELLO.C"}` stages
the fixture as `HELLO.C` for a program that looks for that exact name, which
is better than renaming it at the prompt (a `REN` leaves the old name on the
disk).

Set `"format": "720k"` and a matching per-package `base` to build on the
720K layout instead of 180K.

`setup` is optional: each entry is typed at the `A>` prompt before
`command` (a string is a command, or an object with `command`, `frames` and
`expect`).  The 24x80 variants use `["SET24X80"]` so the same package runs
through the paged 80-column screen.

Steps run in order. A step with `text` types a command, `key` presses a key,
and `wait: true` just runs the emulator for `frames` without typing — use it
when a tool needs time after its last output (for example Link-80 writing a
large `.COM`) before the next command is sent.  `key: "shift+sym+enter"` is
the EXTEND+Enter chord that flips the 24x80 halves.

### Reading the screen

`RealWorld.screen()` adapts to the four display shapes:

| Mode | Source | Width |
|---|---|---|
| 32, 51 or 64 columns | `char_buffer` | `scr_cols` |
| 24x80 | `LG_BUF` in bank 5 | always 80 |

The 24x80 case is the one that catches people out.  `scr_cols` stays the
*physical* width (32/51/64) there, and `char_buffer` only mirrors the window
on show — `lg_off .. lg_off + scr_cols`.  Reading `char_buffer` at that
stride therefore shows the left 51 columns of an 80-column screen and
silently hides the rest, which is why a `_80` package could pass while its
right-hand columns were never checked.

Two helpers cover the other views:

- `window()` — only the columns physically on screen right now, sliced at
  `lg_off` (the full 51-column page, not a spurious overlap).
- `status_line()` — row 23 when the status bar is on, otherwise `None`.
  With the bar on, `screen()` returns 23 rows because row 23 is the bar.
  In 24x80 the bar is the only place the `<` / `>` page markers appear:
  `>` means text is hidden to the right, `<` that it is hidden to the left.
  It is read from `char_buffer`, because `_stl_mark` renders the bar
  straight into the physical buffer rather than into `LG_BUF`.

`screen_state()` returns the raw geometry (`cols`, `mode80`, `lg_off`,
`lg_auto`, `lg_step`, `save_cols`, `status`, `text_rows`) when a test needs
to assert on the mode itself.

Assertions for the right half should name text that lives past column 51 —
SuperCalc2's grid status row is `... ? for HELP` starting at column 43, and
only the last three characters fall outside the window, so `? for HELP`
passes in 24x80 and fails on the left-only read.

The package image is built from the manifest's `base` list: `CPM3.SYS`,
`CPM3C.SYS`, `CCP.COM`, the three fonts, `SET24X80.COM` and
`RAMDISK.FID`.  Keep that list in step with the boot files; a missing
`CPM3C.SYS` stops the loader.

A package may override the base boot pair and ask for a different disc
format.  `"format": "720k"` with `"base": {"boot": "build/bootsect720.bin",
"system": "build/loader720.bin"}` builds a 720K PCW-layout image instead of
the default 180K +3 image; `cobol80` uses this because the complete COBOL-80
4.65 set does not fit the 174 KB data area.

The runner extracts files by basename, so archives with directory trees are
supported. CP/M names must remain 8.3. Keep a 180K package under the +3 data
capacity of about 174 KB, or trim optional help/install files — and leave
room for what the tools write while they run (`.ASM`, `.O`, `.COM`); a full
disk can make an assembler create an empty output file and look like a
format error.  A 720K package has roughly four times that room.

## Curated candidate catalog

These are useful next packages. Most are ZIPs of loose files that can be
added with `build.cmd --add` or `tools/mkdsk.py`; a few are disk images and
need conversion first.

### Start-here set

| Software | Download | Notes |
|---|---|---|
| Turbo Pascal 3.0 | [tpas30.zip](http://www.retroarchive.org/cpm/lang/tpas30.zip) | `TURBO.COM`, `TURBO.OVR`, `TURBO.MSG` |
| WordStar 3.0 | [WS30.ZIP](http://www.retroarchive.org/cpm/text/WS30.ZIP) | `WS.COM` + overlays |
| WordStar 3.3 | [Wskpro33.zip](http://www.retroarchive.org/cpm/text/Wskpro33.zip) | Alternate editor test |
| MBASIC 5.21 | [Mbasic.com](http://www.retroarchive.org/cpm/lang/Mbasic.com) | Single `.COM` |
| SuperCalc2 | [sc2.zip](http://www.retroarchive.org/cpm/business/sc2.zip) | `SC2.COM`, `SC2.OVL`, `SC2.HLP` |
| dBASE II | [DBASEII.ZIP](http://www.retroarchive.org/cpm/dbase/dbaseii.zip) | `DBASE.COM`, `DBASEOVR.COM`, `DBASEMSG.TXT` |
| Zork I–III | [ZORK123_80.ZIP](http://www.retroarchive.org/cpm/games/zork123_80.zip) | Use one game at a time; Zork I is ~94 KB - Zork II/III automated as `zork2`/`zork3` |
| VEDIT Plus | [D1](http://www.retroarchive.org/cpm/text/vedit_d1.zip), [D2](http://www.retroarchive.org/cpm/text/vedit_d2.zip) | Full-screen editor |
| PeachText/PeachCalc | [PEACHTXT.ZIP](http://www.retroarchive.org/cpm/text/PEACHTXT.ZIP) | Word processor + spreadsheet |
| Kaypro 2X bundle | [KAYPRO2X.ZIP](http://www.retroarchive.org/cpm/os/KAYPRO2X.ZIP) | 279-entry tree of small utilities and apps |

### Languages and development tools

| Software | Download |
|---|---|
| Microsoft BASIC compiler 5.3 | [BASCOM.ZIP](http://www.retroarchive.org/cpm/lang/BASCOM.ZIP) - automated as `bascom53` |
| Microsoft BASIC 5.29 | [MBASIC.ZIP](http://www.retroarchive.org/cpm/lang/mbasic.zip) |
| Microsoft FORTRAN-80 3.44 | [F80-344.ZIP](http://www.retroarchive.org/cpm/lang/F80-344.ZIP) - automated as `f80344` |
| Microsoft COBOL-80 4.65 | [mscobol.zip](http://www.retroarchive.org/cpm/lang/mscobol.zip) - automated as `cobol80` (720K) |
| Aztec C 1.06D | [AZ106D.ZIP](http://www.retroarchive.org/cpm/lang/az106d.zip) - automated as `aztec106` |
| BDS C user group | [BDSCUG.ZIP](http://www.retroarchive.org/cpm/lang/BDSCUG.ZIP) |
| Software Toolworks C80 3.1 | [C80V31.ZIP](http://www.retroarchive.org/cpm/lang/c80v31.zip) |
| Tiny C | [TINY_C.ZIP](http://www.retroarchive.org/cpm/lang/TINY_C.ZIP) |
| JRT Pascal 3.0 | [JRTPAS30.ZIP](http://www.retroarchive.org/cpm/lang/JRTPAS30.ZIP) |
| Pascal/Z 4.0 | [PASCALZ4.ZIP](http://www.retroarchive.org/cpm/lang/PASCALZ4.ZIP) - automated as `pascalz` |
| FTL Modula-2 1.30 | [FTL-MODULA2-V130.ZIP](http://www.retroarchive.org/cpm/lang/FTL-MODULA2-V130.zip) |
| APL/Z 1.1 | [APLZ11.ZIP](http://www.retroarchive.org/cpm/lang/aplz11.zip) - automated as `aplz` |
| LISP/80 | [LISP80.ZIP](http://www.retroarchive.org/cpm/lang/lisp80.zip) - automated as `mulisp` (muLISP-80) |
| M80 + L80 | [M80.COM](http://www.retroarchive.org/cpm/lang/m80.com), [L80.COM](http://www.retroarchive.org/cpm/lang/l80.com) |
| Microsoft MACRO-80 package | [MASM-80.ZIP](http://www.retroarchive.org/cpm/lang/MASM-80.ZIP) - automated as `m80l80` |
| SLR Z80 assembler | [Z80ASM.ZIP](http://www.retroarchive.org/cpm/lang/Z80ASM.ZIP) - automated as `z80asm` |
| ZSID debugger | [zsid.zip](http://www.retroarchive.org/cpm/lang/zsid.zip) - automated as `zsid` and `zsid_break` |

### Word processing and text

| Software | Download |
|---|---|
| WordMaster | [Wrdmastr.zip](http://www.retroarchive.org/cpm/text/Wrdmastr.zip) - automated as `wordmaster` |
| Perfect Writer 1.03 | [PERF103.ZIP](http://www.retroarchive.org/cpm/text/PERF103.ZIP) |
| SpellStar 3.30 | [SPELSTAR.ZIP](http://www.retroarchive.org/cpm/text/SPELSTAR.ZIP) |
| SuperWriter 1.02 | [S_writer.zip](http://www.retroarchive.org/cpm/text/S_writer.zip) |
| T/Maker 4.03 | [D1](http://www.retroarchive.org/cpm/text/T-MAKER403_D1.ZIP), [D2](http://www.retroarchive.org/cpm/text/T-MAKER403_D2.ZIP) |
| Magic Wand | [Magicwnd.zip](http://www.retroarchive.org/cpm/text/Magicwnd.zip) |
| DataStar | [Datastar.zip](http://www.retroarchive.org/cpm/text/Datastar.zip) |
| WordStar 4.0 | [WS4.ARK](http://www.retroarchive.org/cpm/text/WS4.ARK) — ARC, needs unpacking |

### Spreadsheets, business and databases

| Software | Download |
|---|---|
| SuperCalc | [Suprcalc.zip](http://www.retroarchive.org/cpm/business/Suprcalc.zip) - automated as `supercalc1` |
| Microsoft Multiplan 1.05 | [MP_105.ZIP](http://www.retroarchive.org/cpm/business/MP_105.ZIP) |
| Multiplan installer | [MULTPLAN.ZIP](http://www.retroarchive.org/cpm/business/MULTPLAN.ZIP) |
| Plan-80 | [PLAN80.ZIP](http://www.retroarchive.org/cpm/business/PLAN80.ZIP) |
| MicroStat | [MICROSTA.ZIP](http://www.retroarchive.org/cpm/business/MICROSTA.ZIP) |
| Money Maestro | [MONYMAES.zip](http://www.retroarchive.org/cpm/business/MONYMAES.zip) |
| dBASE II 2.4 | [Dbase41.zip](http://www.retroarchive.org/cpm/dbase/Dbase41.zip) |
| Friday! | [friday.zip](http://www.retroarchive.org/cpm/dbase/friday.zip) |
| Condor Jr | [CONDORJR.ZIP](http://www.retroarchive.org/cpm/dbase/CONDORJR.ZIP) |
| CardFile | [CARDFILE.ZIP](http://www.retroarchive.org/cpm/dbase/CARDFILE.ZIP) |
| What’sit | [WHATSIT.ZIP](http://www.retroarchive.org/cpm/dbase/whatsit.zip) |

### Games

| Software | Download |
|---|---|
| Large text-adventure collection | [MANYGAME.ZIP](http://www.retroarchive.org/cpm/games/manygame.zip) - automated as `pacman95`, `star`, `hunt` and `othello` |
| Sargon chess | [SARGON.ZIP](http://www.retroarchive.org/cpm/games/sargon.zip) - automated as `sargon` (copy-protected) |
| Creative Computing games | [CCGAMES.ZIP](http://www.retroarchive.org/cpm/games/ccgames.zip) |
| Nemesis | [nemesis.zip](http://www.retroarchive.org/cpm/games/nemesis.zip) |
| Ladder | [LADDER.ZIP](http://www.retroarchive.org/cpm/misc/LADDER.ZIP) - automated as `ladder` |
| Catchum | [CATCHUM.ZIP](http://www.retroarchive.org/cpm/misc/CATCHUM.ZIP) |

### Interactive fiction (CP/M `.dsk` images)

The [IF Archive](https://ifarchive.org/indexes/if-archive/games/cpm/) carries
Mike Goetz's Colossal Cave ports; archive.org has the Infocom CP/M disks as
extended CPCEMU `.dsk` images, which the `dsk` archive type reads directly.

| Software | Download |
|---|---|
| Colossal Cave Adventure A02 | [cpm-advent.zip](https://ifarchive.org/if-archive/games/cpm/cpm-advent.zip) - automated as `advent` |
| Colossal Cave B00-B03 | [cpm-advent.zip](https://ifarchive.org/if-archive/games/cpm/cpm-advent.zip) (other directories in the same ZIP) |
| The Hitchhiker's Guide to the Galaxy | [`.dsk`](https://archive.org/download/Hitchhikers_Guide_to_the_Galaxy_The_1984_Infocom_cpm_version/Hitchhikers_Guide_to_the_Galaxy_The_1984_Infocom_cpm_version.dsk) - automated as `hitchhiker` |
| Planetfall | [`.dsk`](https://archive.org/download/Planetfall_1983_Infocom_cpm_version/Planetfall_1983_Infocom_cpm_version.dsk) - automated as `planetfall` |
| Starcross | [`.dsk`](https://archive.org/download/Starcross_1982_Infocom_cpm_version/Starcross_1982_Infocom_cpm_version.dsk) - automated as `starcross` |
| Enchanter, Suspect, Suspended, Seastalker, Cutthroats, Ballyhoo, Deadline | same archive.org `*_Infocom_cpm_version` naming |

The Infocom disks whose games ship a `*nnn.COM` stub (Enchanter, Hitchhiker's,
Planetfall) need the matching variant run directly, because the stub picks a
build from the detected TPA size.

### +3 / Amstrad-specific

The [seasip Amstrad CP/M page](https://www.seasip.info/Cpm/software/amstrad.html)
hosts runnable self-extracting +3 utilities:

- [3CLCKSEA.COM](https://www.seasip.info/Cpm/software/3clcksea.com) — status-line clock
- [3SAVRSEA.COM](https://www.seasip.info/Cpm/software/3savrsea.com) — screensaver
- [P3CPMSEA.COM](https://www.seasip.info/Cpm/software/p3cpmsea.com) — reboot/+3DOS tools
- [P3GIFSEA.COM](https://www.seasip.info/Cpm/software/p3gifsea.com) — GIF viewer
- [P3BMPSEA.COM](https://www.seasip.info/Cpm/software/p3bmpsea.com) — BMP viewer
- [TDISCSEA.COM](https://www.seasip.info/Cpm/software/tdiscsea.com) — tape-to-disk
- [DSKWRSEA.COM](https://www.seasip.info/Cpm/software/dskwrsea.com) — write `.DSK` images
- [SALVGSEA.COM](https://www.seasip.info/Cpm/software/salvgsea.com) — sector recovery
- [CRTPLSEA.COM](https://www.seasip.info/Cpm/software/crtplsea.com) — enhanced screen driver
- [FSWPSEA.COM](https://www.seasip.info/Cpm/software/fswp_sea.com) — file sweep
- [NEWDRV2.ZIP](https://www.seasip.info/Cpm/software/newdrv2.zip) — extra drive support
- [SETFONT.ARC](https://www.seasip.info/Cpm/software/setfont.arc) — font editor

Advanced +3 tests:

- [ZPM3N10.ARC](http://www.retroarchive.org/cpm/cdrom/DEMON/ZPM3N10.ARC)
- [ZCCP0293.ARC](http://www.retroarchive.org/cpm/cdrom/DEMON/ZCCP0293.ARC)
- `DU54` disk utility, linked from the seasip page; needs PMEXT.

### Bulk archives and disk-image sources

| Source | Contents |
|---|---|
| [Retroarchive CP/M archive](http://www.retroarchive.org/cpm/) | Curated ZIP categories: [languages](http://www.retroarchive.org/cpm/lang/lang.htm), [text](http://www.retroarchive.org/cpm/text/text.htm), [business](http://www.retroarchive.org/cpm/business/business.htm), [databases](http://www.retroarchive.org/cpm/dbase/dbase.htm), [games](http://www.retroarchive.org/cpm/games/games.htm), [misc](http://www.retroarchive.org/cpm/misc/misc.htm) |
| [Walnut Creek CP/M CD archive](http://www.retroarchive.org/cpm/cdrom/) | Thousands of files and machine-specific disk collections |
| [Humongous CP/M Archive Collection](https://archive.org/details/Humongous_CPM_Archive_Collection) | CPMUG, SIG/M, Walnut CD, Maslin, Oak CD and more |
| [Humongous CP/M mirrors](http://cpmarchives.classiccmp.org/) | Web mirror plus Walnut CD ISO |
| [Unofficial CP/M Web site](http://www.cpm.z80.de/binary.html) | DRI binaries, CP/M 2.2 OEM ImageDisk, CP/M 3 binaries |
| [CPM-UG-Disks](https://github.com/agn453/CPM-UG-Disks) | Public-domain 8-inch ImageDisk images |
| [cpmish](https://github.com/davidgiven/cpmish) | Open-source CP/M 2.2 distribution and images |
| [cpmemu / cpm_disk.py](https://github.com/avwohl/cpmemu) | CP/M disk-image manipulation tools |
| [Don Maslin archive](http://cpmarchives.classiccmp.org/maslin/) | Original 8-inch CP/M media images |

## Building a DSK manually

For loose files:

```bat
build.cmd --add C:\Temp\ws\WS.COM C:\Temp\ws\WSMSGS.OVR C:\Temp\ws\WSOVLY1.OVR C:\Temp\ws\WIMSGS.OVR
```

The +3 data area is about 174 KB. Keep all required overlays/messages/data
files. Typical sizes:

- Turbo Pascal 3: ~65 KB
- WordStar 3.x: ~80 KB without installer
- dBASE II: ~120 KB
- Zork I: ~94 KB
- WordStar 4.0, Multiplan and full language suites may need trimming or a
  second disk.

For foreign disk images, use `cpmtools`, `libdsk`, or `samdisk` to extract
files, then rebuild a +3 DSK with `mkdsk.py`. ImageDisk (`.IMD`), Teledisk
(`.TD0`), CPC `.dsk`, and 8-inch formats normally need conversion first.

## Copyright

Most of these packages are commercial software preserved by public archives.
They remain the property of their authors. Keep downloads in `references/`
or `build/`; do not commit them or bake them into release images. Public
domain/open-source packages such as BDS C, ZSDOS, and cpmish are the
exception, not the rule.
