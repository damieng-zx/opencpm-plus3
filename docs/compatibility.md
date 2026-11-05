# CP/M software compatibility

Compatibility of third-party CP/M software with this CP/M 3.1 implementation
on the ZX Spectrum +3.

- **Tested:** booted through the zx84 MCP server from a 40-track +3 DSK built
  with `tools/zx84_realworld.py` (or the stated manual method).
- **Works:** the listed program starts and the checked behavior is present.
- **Doesn't work:** the observed failure is described below.
- **Not yet tested:** candidate software; no claim either way.

Build used for the current results: `CPM3.SYS` 16,253 bytes + `CPM3C.SYS` 1,807 bytes plus `CCP.COM` 3,620 bytes (the CCP is loaded from the disk), no FDC retries.
Tests were run on 2026-10-28 through the zx84 MCP server.

## ✅ Works

| Title | Version | What was checked | Notes |
|---|---|---|---|
| **Zork I** | Revision 88 | Boots, prints the Zork banner, reaches “West of House” | Large `.DAT` file, random reads |
| **Zork II** | Release 48 | Banner, “Inside the Barrow”, inventory, `save` writes `ZORK2.SAV`, `quit` returns to `A>` | Large `.DAT` reads plus a save-file write |
| **Zork III** | Release 17 | Paged intro (one More prompt), save and quit | Same engine as Zork I/II |
| **ZSID** | 1.4 | Loads a `.COM`, `D100` dumps memory, `G0` warm-boots | Debugger file load and console output |
| **SuperCalc** | 1.05 | Banner, grid, cell entry, `/Q` + `Y` quit | `SCHAZ15.COM`, the Hazeltine build. Saving a `.CAL` fails its “program diskette” media check |
| **WordMaster** | 1.07A | Banner, edit, `BREAK` (Caps+Space = ESC) to leave insert mode, `E` saves, `TYPE` shows the text | Uses the official +3 BREAK mapping |
| **dBASE II** | 2.43 | Starts, date prompt, dot prompt, `QUIT` returns to `A>` | FCB random I/O, overlays |
| **Multiplan** | 1.05 | Banner, command bar, 80-column grid; the 24x80 variant flips to the right half | Needs the `MP80` data overlay; terminal escapes leave artifacts |
| **VEDIT Plus** | 2.33 | CRT installer selects VT-52 and writes `VPLUS.COM`; opens `SMOKE.TXT` and shows the `LINE:`/`FILE:` status line | The installer is interactive; the manifest drives it |
| **Microsoft COBOL-80** | 4.01 | Compiles `=HELLO` and writes `HELLO.REL` | Link/runtime blocked: the 4.01 archive lacks the CRT driver and the complete 4.65 set does not fit 174 KB |
| **SuperCalc2** | 1.00 | Starts and prints the SuperCalc2 banner/version | ⚠️ VT-100 escapes such as `ESC[?3h`, `ESC[2J`, `ESC[H` remain visible; `supercalc2_80` confirms 24x80 fixes only the width, not the terminal |
| **Microsoft BASIC-80** | 5.21 | Banner, `Ok` prompt, runs `HELLO.BAS` and prints `REAL OK` | Was hanging before the page-zero memory-ceiling fix |
| **Turbo Pascal** | 3.0A | Banner, `Include error messages (Y/N)?`, loads `TURBO.MSG`, IDE menu and Work file prompt | 80-column IDE wraps on the 51-column screen; TINST+`SCREEN 64` or `turbo3_80` (24x80) fit it, though Kaypro escapes leave stray `1` characters |
| **WordStar** | 3.0 | Banner and no-file menu appear; `INSTALL` patches terminals and writes `WS.COM` | 80-column layout wraps on the 51-column screen by default; `wordstar30_80` runs it under `SET24X80`, where the menu and right half are readable (Visual 200 escape artifacts remain) |
| **BBC BASIC** | — | Previously exercised from the disk image | Visual/interactive test; see the smoke-test notes |
| **PIP** | reference binary | `PIP C:=A:DATE.COM`, then `DIR C:`; local harness copies `SMOKE.TXT` interactively | Covered by the automated smoke test; `tools/zx84_pip.py` runs a local copy end to end (F44 caller) |
| **Microsoft M80 + L80** | MACRO-80 / Link-80 3.44 | `M80 =HELLO` assembles and links to `HELLO.COM`, which prints `HELLO, WORLD` | Exercises REL output, the linker's random I/O and the FCB command line |
| **Microsoft FORTRAN-80** | 3.44 | `F80 CHELLO=CHELLO` compiles, `L80 CHELLO,FORLIB,CHELLO/N/E` links, `CHELLO` prints `HELLO, WORLD` | Library search, larger REL files |
| **Microsoft BASIC Compiler** | 5.3 | `BASCOM =CHELLO/O` compiles, `L80 CHELLO,OBSLIB,CHELLO/N/E` links, `CHELLO` prints `HELLO, WORLD` | Stand-alone `/O` output links the 48 KB OBSLIB runtime. `BASCOM53.ZIP` is an OEM build that probes banked memory and exits; use `BASCOM.ZIP` |
| **Aztec C** | 1.06D | `CC CHELLO`, `AS CHELLO`, `LN CHELLO.O C.LIB`, then `CHELLO` prints `HELLO, WORLD` | Compiler, assembler, linker and C.LIB. Keep `LIBC.REL` off the image: with it the disk is too full for the `.O` file |
| **Pascal/Z** | 4.0 | `PASCAL54 HELLO`, `ASMBL MAIN,HELLO/REL`, `LINK /N:A:HELLO A:HELLO /G` prints `HELLO, WORLD` | Overlaying 54K compiler with PAS254, assembler, linker and LIB.REL. The source needs the `{$i+ }` I/O-check directive |
| **muLISP-80** | 10/06/80 | `MULISP`, `(PLUS 2 3)` → `5`, `(TIMES 6 7)` → `42` | The Soft Warehouse LISP read-eval-print loop at the `$` prompt |
| **APL/Z** | 1.1 | `APL`, date `010180`, `2+2` → `4`, `1 2 3 + 4 5 6` → `5 7 9` | Start-up asks for `mmddyy`; 30 KB workspace |
| **SUBMIT** (our build) | — | Explicit `SUBMIT SMOKE.SUB`, implicit `SMOKE`, `$1`/`$2` substitution, missing-file/missing-parameter paths | Project tool, not third-party |
| **SHOW** | DRI CP/M 3 | Prints `A: RW, Space: ...` | Local-only harness `tools/zx84_dri.py` |
| **ED** | DRI CP/M 3 | Appends/types a line, inserts text, `Q`/`Y` quits | Read/edit and quit work; `E` (save) hangs, see below |

## ❌ Doesn’t work yet

| Title | Observed behavior | Investigation so far |
|---|---|---|
| **WordStar 3.0 display** | The default run still wraps at 51 columns, but `wordstar30_80` enters `SET24X80` first: the no-file menu fits 80 columns and EXTEND+Enter shows the right half. Visual 200 escape codes leave artifacts at the line starts. | The original crash was a page-zero bug: `(0006h)` pointed at `bdos_stub` (F737) instead of the TPA top (F600), so WordStar's screen buffer landed on the BIOS jump table and destroyed it. Fixed in `common.zpa` (`bdos_vector` at F600). Remaining work: terminal escape handling. |
| **Turbo Pascal display** | The default run wraps; `turbo3_80` fits the IDE in 80 columns. Kaypro terminal escapes leave stray `1` characters in the buffer. | 24x80 solves the width; the remaining work is the Kaypro terminal escape set. |
| **SuperCalc2 display** | Program logic works, but VT-100 escape sequences are treated as printable text. `supercalc2_80` fits the banner and right half in 24x80; the escapes remain. | Add VT-100 (`ESC[...`) handling to `screen.zpa`, or install SuperCalc for a VT52/ADM-3A terminal. |
| **ED `E` (save)** | Writes the data and directory sector, then stops with `*e` still on the line; no further BDOS/XBIOS calls. | Found with `tools/zx84_dri.py`; `Q`/`Y` exits normally, so the failure is in ED's end-of-edit path after the write. |
| **SET** | Reads the disk indefinitely instead of drawing its menu. | Found with `tools/zx84_dri.py`; not investigated yet. |
| **SETKEYS** | Stops after opening its key file. | Found with `tools/zx84_dri.py`; try it with a known `.KEY` file. |

Recently fixed: **SLR Z80ASM 1.32** used to fail with `Line Too Long`
because it sets a multi-sector count (8) with F44 and assumes one F20 moved
the whole source block.  F20/F21 now apply the count to both sequential
directions (1..127) and report the records moved in H.  An invalid count
resets to 1, which is what lets PIP's 128 request fall back cleanly.  The
real-world suite reports it as `PASS`.

## WordStar 3.0 display width

WordStar 3.0 stores its screen size in two bytes at `0248h` (rows) and
`0249h` (columns) of the installed `WS.COM`; `INSTALL` patches them per
terminal. Reading the patch table out of `INSTALL.COM` (and confirming at
runtime by breaking on WordStar's memory check at `3CA8h`):

| Terminal | Rows x Cols | Output path |
|---|---|---|
| default (ADM-3A, Hazeltine, Televideo, Visual 200, ...) | 24 x 80 | escape sequences |
| SWTPC CT-82 | 20 x 82 | escape sequences |
| Compucolor 8001G | 48 x 80 | escape sequences |
| Processor Tech SOL / VDM | 16 x **64** | memory-mapped VDM at `CC00h`, port `FEh` |
| Flashwriter I/II ("mindless") | 24 x **64** | memory-mapped video RAM at `F000h` |
| (one further entry) | 50 x 96 | - |

Both 64-column configurations are memory-mapped terminal drivers, not
escape-sequence terminals, so they cannot drive our console. Every
escape-based WordStar 3.0 terminal is 80 columns wide (or 82/96), which is
why WordStar needs an 80-column screen mode here: 80 characters at a 3-pixel
pitch is 240 of the 256 available pixels, so it fits without a horizontal
scrolling/tab-flip trick. A 64-column mode (4-pixel pitch) would suit Turbo
Pascal via TINST and leave WordStar unchanged.

That 64-column mode now exists (`SCREEN 64`, 4-pixel "Compression" font):
it fits Turbo Pascal's IDE once TINST installs the editor for 64 columns.
It does not help WordStar, whose 80-column layout is unchanged.

## Not yet tested

### Word processing and text

- [ ] WordStar 3.3
- [ ] WordStar 4.0
- [x] WordMaster - works, saves with BREAK/ESC (automated)
- [ ] Perfect Writer 1.03
- [ ] SpellStar 3.30
- [ ] SuperWriter 1.02
- [ ] T/Maker 4.03
- [ ] Magic Wand
- [ ] DataStar
- [x] VEDIT Plus 2.33 - works (automated: CRT installer + editor)
- [ ] PeachText / PeachCalc

### Languages and development tools

- [x] Microsoft BASIC compiler 5.3 (BASCOM) - works (automated, uses the generic BASCOM.ZIP build)
- [ ] Microsoft BASIC 5.29
- [x] Microsoft FORTRAN-80 3.44 - works (automated)
- [x] Microsoft COBOL-80 4.01 - compiles (link/runtime blocked, see above)
- [x] Aztec C 1.06D - works (automated)
- [ ] BDS C
- [ ] Software Toolworks C80 3.1
- [ ] Tiny C
- [ ] JRT Pascal 3.0
- [ ] Pascal/Z 4.0
- [ ] FTL Modula-2 1.30
- [ ] APL/Z 1.1
- [ ] LISP/80
- [x] Microsoft M80 / L80 - works (automated)
- [x] Microsoft MACRO-80 package - same binaries as M80 / L80 (automated)
- [x] SLR Z80 assembler - works (multi-sector F20; automated)
- [x] ZSID debugger - works (automated)

### Spreadsheets, business and databases

- [x] SuperCalc (original) - works; .CAL save blocked by its media check (automated)
- [x] Microsoft Multiplan 1.05 - works (automated; 24x80 variant too)
- [ ] Plan-80
- [ ] MicroStat
- [ ] Money Maestro
- [ ] dBASE II 2.4
- [ ] Friday!
- [ ] Condor Jr
- [ ] CardFile
- [ ] What’sit

### Games and entertainment

- [ ] Zork II
- [ ] Zork III
- [ ] Sargon chess
- [ ] Creative Computing games
- [ ] Nemesis
- [ ] Ladder
- [ ] Catchum
- [ ] Manygame text-adventure collection

### Bundles and machine-specific software

- [ ] Kaypro 2X application bundle
- [ ] Mallard BASIC / LocoScript CP/M suite
- [ ] +3 3CLCK clock
- [ ] +3 3SAVR screensaver
- [ ] +3 P3CPM utilities
- [ ] +3 P3GIF viewer
- [ ] +3 P3BMP viewer
- [ ] +3 TDISC tape reader
- [ ] +3 DSKWRITE
- [ ] +3 SALVAGE
- [ ] +3 CRT+ screen driver
- [ ] +3 FSWP file sweep
- [ ] +3 NEWDRV2
- [ ] +3 SETFONT
- [ ] ZPM3
- [ ] ZCCP
- [ ] DU54 disk utility

## Reproducing

```bash
python3 tools/zx84_realworld.py --list
python3 tools/zx84_realworld.py --package zork1 dbase2 supercalc2
python3 tools/zx84_realworld.py --package mbasic turbo3 wordstar30
```

`tools/zx84_realworld.py` reports `PASS`, `KNOWN`, or `FAIL`. Known issues are
recorded in `tests/realworld/manifest.json`. The broader source catalog and
format/conversion notes are in [realworld-suite.md](realworld-suite.md).
