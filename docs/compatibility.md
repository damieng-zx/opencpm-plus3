# CP/M software compatibility

Compatibility of third-party CP/M software with this CP/M 3.1 implementation
on the ZX Spectrum +3.

- **Tested:** booted through the zx84 MCP server from a 40-track +3 DSK built
  with `tools/zx84_realworld.py` (or the stated manual method).
- **Works:** the listed program starts and the checked behavior is present.
- **Doesn't work:** the observed failure is described below.
- **Not yet tested:** candidate software; no claim either way.

Build used for the current results: `CPM3.SYS` 14,392 bytes, no FDC retries.
Tests were run on 2026-10-27 through the zx84 MCP server.

## ✅ Works

| Title | Version | What was checked | Notes |
|---|---|---|---|
| **Zork I** | Revision 88 | Boots, prints the Zork banner, reaches “West of House” | Large `.DAT` file, random reads |
| **dBASE II** | 2.43 | Starts, date prompt, dot prompt, `QUIT` returns to `A>` | FCB random I/O, overlays |
| **SuperCalc2** | 1.00 | Starts and prints the SuperCalc2 banner/version | ⚠️ VT-100 escapes such as `ESC[?3h`, `ESC[2J`, `ESC[H` remain visible; the screen layer implements VT52 + ADM-3A, not VT-100 |
| **Microsoft BASIC-80** | 5.21 | Banner, `Ok` prompt, runs `HELLO.BAS` and prints `REAL OK` | Was hanging before the page-zero memory-ceiling fix |
| **Turbo Pascal** | 3.0A | Banner, `Include error messages (Y/N)?`, loads `TURBO.MSG`, IDE menu and Work file prompt | 80-column IDE layout wraps on the 51-column screen |
| **WordStar** | 3.0 | Banner and no-file menu appear; `INSTALL` patches terminals and writes `WS.COM` | 80-column layout wraps on the 51-column screen, so the display is not usable yet (needs an 80-column mode) |
| **BBC BASIC** | — | Previously exercised from the disk image | Visual/interactive test; see the smoke-test notes |
| **PIP** | reference binary | `PIP C:=A:DATE.COM`, then `DIR C:` | Covered by the automated smoke test |
| **Microsoft M80 + L80** | MACRO-80 / Link-80 3.44 | `M80 =HELLO` assembles and links to `HELLO.COM`, which prints `HELLO, WORLD` | Exercises REL output, the linker's random I/O and the FCB command line |
| **Microsoft FORTRAN-80** | 3.44 | `F80 CHELLO=CHELLO` compiles, `L80 CHELLO,FORLIB,CHELLO/N/E` links, `CHELLO` prints `HELLO, WORLD` | Library search, larger REL files |
| **Microsoft BASIC Compiler** | 5.3 | `BASCOM =CHELLO/O` compiles, `L80 CHELLO,OBSLIB,CHELLO/N/E` links, `CHELLO` prints `HELLO, WORLD` | Stand-alone `/O` output links the 48 KB OBSLIB runtime. `BASCOM53.ZIP` is an OEM build that probes banked memory and exits; use `BASCOM.ZIP` |
| **Aztec C** | 1.06D | `CC CHELLO`, `AS CHELLO`, `LN CHELLO.O C.LIB`, then `CHELLO` prints `HELLO, WORLD` | Compiler, assembler, linker and C.LIB. Keep `LIBC.REL` off the image: with it the disk is too full for the `.O` file |
| **SUBMIT** (our build) | — | Explicit `SUBMIT SMOKE.SUB`, implicit `SMOKE`, `$1`/`$2` substitution, missing-file/missing-parameter paths | Project tool, not third-party |

## ❌ Doesn’t work yet

| Title | Observed behavior | Investigation so far |
|---|---|---|
| **WordStar 3.0 display** | The program runs and draws its menu, but WordStar is an 80×24 program and the character buffer is 51 columns, so each 80-column line wraps and overlaps the next. | The crash was a page-zero bug: `(0006h)` pointed at `bdos_stub` (F737) instead of the TPA top (F600), so WordStar's screen buffer landed on the BIOS jump table and destroyed it. Fixed in `common.zpa` (`bdos_vector` at F600). Remaining work: an 80-column screen mode (3px font) or a WordStar install with a ≤51-column terminal. |
| **Turbo Pascal display** | Runs correctly; the 80-column IDE frames wrap on screen. | Same root cause as WordStar's display: no 80-column mode. |
| **SuperCalc2 display** | Program logic works, but VT-100 escape sequences are treated as printable text. | Add VT-100 (`ESC[...`) handling to `screen.zpa`, or install SuperCalc for a VT52/ADM-3A terminal. |
| **SLR Z80ASM 1.32** | Reads part of its source, reports `Line Too Long`, and assembles a corrupt `.COM`. | Z80ASM sets a multi-sector count with F44 and assumes one F20 transferred the whole block. This BDOS transfers one record per call (a legal partial transfer, H reports the count), so the rest of the source buffer is stale. Needs full multi-sector transfers, which broke PIP's copy in the prototype. |

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

## Not yet tested

### Word processing and text

- [ ] WordStar 3.3
- [ ] WordStar 4.0
- [ ] WordMaster
- [ ] Perfect Writer 1.03
- [ ] SpellStar 3.30
- [ ] SuperWriter 1.02
- [ ] T/Maker 4.03
- [ ] Magic Wand
- [ ] DataStar
- [ ] VEDIT Plus
- [ ] PeachText / PeachCalc

### Languages and development tools

- [x] Microsoft BASIC compiler 5.3 (BASCOM) - works (automated, uses the generic BASCOM.ZIP build)
- [ ] Microsoft BASIC 5.29
- [x] Microsoft FORTRAN-80 3.44 - works (automated)
- [ ] Microsoft COBOL-80 4.01
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
- [x] SLR Z80 assembler - known issue (needs multi-sector F20)
- [ ] ZSID debugger

### Spreadsheets, business and databases

- [ ] SuperCalc (original)
- [ ] Microsoft Multiplan 1.05
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
