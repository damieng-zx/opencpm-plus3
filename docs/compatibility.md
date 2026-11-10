# CP/M software compatibility

Compatibility of third-party CP/M software with this CP/M 3.1 implementation
on the ZX Spectrum +3.

- **Tested:** booted through the zx84 MCP server from a 40-track +3 DSK built
  with `tools/zx84_realworld.py` (or the stated manual method).
- **Works:** the listed program starts and the checked behavior is present.
- **Doesn't work:** the observed failure is described below.
- **Not yet tested:** candidate software; no claim either way.

Build used for the current results: `CPM3.SYS` 16,107 bytes + `CPM3C.SYS` 2,551 bytes plus `CCP.COM` 3,845 bytes (the CCP is loaded from the disk), no FDC retries.
Tests were run on 2026-10-28 through the zx84 MCP server; the language results were re-checked on 2026-11-07.

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
| **Microsoft COBOL-80** | 4.65 | `COBOL` compiles `=HELLO`, `L80` links it, `HELLO` prints `HELLO, WORLD` | Full chain on a 720K image: the 4.65 set does not fit the 174 KB data area of a 180K disc, and the 4.01 archive has no `CRTDRV.REL` |
| **3CLCK** | 2.10 | Extractor writes `CLOCK.FID`/`CLOCK.F64`/`CLOCK.DOC`/`CLOCKCLR.COM`; CLOCKCLR reports the FID state | The clock FID is not loaded at boot; see below |
| **BDS C** | 1.60 | `CC HELLO.C` compiles to `HELLO.CRL`, `CLINK HELLO` links it, and `HELLO` prints `HELLO, WORLD` | Full chain. `DEFF2.CRL` (the part-II library) must be on the disk or `CLINK` stops at `Missing function(s): PUTCHAR` |
| **SuperCalc2** | 1.00 | Starts and prints the SuperCalc2 banner/version | Its VT-100 output (`ESC[?3h`, `ESC[2J`, `ESC[H`) is consumed by the [CSI subset](ansi-subset.md); SGR attribute switching is still ignored, so colour/reverse requests have no effect |
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
| **ED** | DRI CP/M 3 | Appends/types a line, inserts text, `E` (END) saves and the text reads back with `TYPE`, `Q`/`Y` quits | Local-only harness; the save used to hang (see below) |
| **SET** | DRI CP/M 3 | Reports `ERROR: No options specified.` and applies a bracketed attribute (`SET FILE [RO]` prints `Read Only (RO)`) | Local-only harness; options go in `[...]` |
| **SETKEYS** | ours (`src/tools/setkeys.asm`) | Applies a key file: parses `RESET.KEY` and programs the +3 key table through XBIOS `KM_SET_KEY`/`KM_SET_EXPAND`.  Amstrad's original is Locomotive code and is not shipped or needed | DRI harness builds a scratch image and checks the table changed |

## ❌ Doesn’t work yet

| Title | Observed behavior | Investigation so far |
|---|---|---|
| **WordStar 3.0 display** | The default run still wraps at 51 columns, but `wordstar30_80` enters `SET24X80` first: the no-file menu fits 80 columns and EXTEND+Enter shows the right half. Visual 200 escape codes leave artifacts at the line starts. | The original crash was a page-zero bug: `(0006h)` pointed at `bdos_stub` (F737) instead of the TPA top (F600), so WordStar's screen buffer landed on the BIOS jump table and destroyed it. Fixed in `common.zpa` (`bdos_vector` at F600). Remaining work: terminal escape handling. |
| **Turbo Pascal display** | The default run wraps; `turbo3_80` fits the IDE in 80 columns. Kaypro terminal escapes leave stray `1` characters in the buffer. | 24x80 solves the width; the remaining work is the Kaypro terminal escape set. |
| **3CLCK clock display** | `CLOCKCLR` says `CLOCK.FID is not loaded`; the clock never appears on the status line. | The FID is not loaded, and is not a gap to close: `CLOCK.FID` and `SERIAL.FID` are built for Locomotive's private common-memory ABI (they `CALL` fixed addresses such as `FF04`/`FF05`/`FF08`/`FF09`, which land inside this system's `close_dir_update`) and carry a different header format, so loading them would mean reserving those addresses and reimplementing an undocumented interface. The status line now shows `HH:MM` natively instead (see `docs/API.md`, *Status line*), from the `scb_date`/`scb_minute`/`scb_sec` the ISR maintains. |
| **ZSID / SID / DDT breakpoints** | `G` with a stop address (and `T`/`U` tracing) stops at a random address inside the program instead of at the breakpoint, and a long ZSID command such as a large `F` fill is cut short the same way. Loading, short dumps and `G0` work. | Not fixable without breaking +3 compatibility; see [Debuggers and RST 7](#debuggers-and-rst-7). Automated as `zsid_break` (known issue). |
| **Sargon (chess)** | Prints nothing after the command line; the CPU spins polling port `2FFD`. | Copy protection. The program issues raw uPD765 `READ DATA` commands against the boot track (`C=1`, `R=1..N`) and waits for the original disk's sector IDs, which never match, so it never reaches its title screen. Not a BIOS bug: no CP/M file or console call is involved. |

Recently fixed: **DRI ED/SET/SETKEYS**.  ED's `E` command corrupted page
zero because its record-buffer base lives at `FCB+21h` (a 33-byte FCB) and
`writeback_fcb` copied 36 bytes back after every file call, zeroing that
base; ED then built records at address 0.  The FCB write-back now stops at
byte 32 and only F35/F36 (which produce R0/R1/R2) write the full FCB.
SETKEYS crashed because our CCP did not push the warm-boot return address
(it exits with `RET`); the CCP now pushes 0000h like the real one, so
`SP = TPA_TOP - 2` on entry.  SET.COM is a GENCOM COM-with-header file: its
first byte is `RET` and the module sits at 0200h, so the CCP now implements
the CP/M 3 COM header move (`comsize` at 0101h) before jumping to 0100h.
Attached RSX modules are not installed.  `SET` options need the brackets:
`SET FILE [RO]`.  The R/O attribute is now enforced: F19 (delete) and F23
(rename) refuse a directory entry whose filetype byte has bit 7 set,
returning 0xFF in error mode or printing `Bdos Err: R/O` and warm booting,
and the F21/F34/F40 write core refuses to write through an FCB opened from
such an entry.  `DISKTEST` T13 checks delete and rename, then clears the
attribute and deletes.

Recently fixed: **SLR Z80ASM 1.32** used to fail with `Line Too Long`
because it sets a multi-sector count (8) with F44 and assumes one F20 moved
the whole source block.  F20/F21 now apply the count to both sequential
directions (1..128) and report the records moved in H, stopping at a block
boundary as DRI's non-banked BDOS does.  PIP's 128 request is now accepted
outright instead of falling back.  The real-world suite reports it as `PASS`.

Recently fixed: **SuperCalc2 display**.  Its VT-100 output (`ESC[?3h`,
`ESC[2J`, `ESC[H`, `ESC[row;colH`) used to appear in the character buffer
as printable text; the [CSI subset](ansi-subset.md) now parses it, so the
banner and grid are drawn through the escape sequences instead.  Attribute
requests (SGR, `ESC [ … m`) are still consumed and ignored, so colour and
reverse have no effect, and `supercalc2_80` remains the run that fits the
banner in 80 columns.

## Debuggers and RST 7

The system tick is an IM 1 interrupt, so every 50 Hz frame the Z80 executes
the equivalent of `RST 38h`: in TPA mode it jumps through page-zero `0038h`,
where `start_tpa` installs `JP isr_handler`.  CP/M reserves `0008h-003Ah`
for restarts 1-7 (CP/M 3 Programmer's Guide, Table 2-11), and DRI's
debuggers use RST 7 (`0038h`) for breakpoints: ZSID replaces our jump with
one to its own handler when it loads, and it enables interrupts when `G`
starts the program.  The first tick after that enters ZSID's handler, which
reports it as a breakpoint at whatever address was running.  Making the
BDOS leave interrupts off while `0038h` is not ours does not help, because
ZSID turns them back on itself.

Locomotive's own +3 CP/M Plus behaves identically: it also runs IM 1 with
`JP FB75` at `0038h`, ZSID overwrites it with `JP E086`, and `G100,10C` on
a three-second loop stops at `*0105`.  Programs written for that system may
rely on the IM 1 call through `0038h`, so this implementation keeps it.
Moving the tick to IM 2 would free RST 7 for debuggers, at the cost of that
compatibility and of relying on the +3 data bus reading `FFh` during the
interrupt acknowledge.

What the suite shows still working under ZSID: loading a file, a short `D`
dump and `G0`.  Anything that runs for longer than about a frame with
interrupts on is exposed, including ZSID's own commands: `F100,CFFF,0` was
cut short with `*E517`, an address inside ZSID.  Warm boot restores our
vector, so leaving the debugger returns the system to normal.

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
- [x] Microsoft COBOL-80 4.65 - works end to end on a 720K image (automated as `cobol80`)
- [x] Aztec C 1.06D - works (automated)
- [x] BDS C 1.60 - works end to end (automated as `bdsc`)
- [ ] Software Toolworks C80 3.1
- [ ] Tiny C
- [ ] JRT Pascal 3.0
- [x] Pascal/Z 4.0 - works (automated as `pascalz`)
- [ ] FTL Modula-2 1.30
- [x] APL/Z 1.1 - works (automated as `aplz`)
- [x] LISP/80 - automated as `mulisp` (muLISP-80)
- [x] Microsoft M80 / L80 - works (automated)
- [x] Microsoft MACRO-80 package - same binaries as M80 / L80 (automated)
- [x] SLR Z80 assembler - works (multi-sector F20; automated)
- [x] ZSID debugger - loads, dumps and exits (automated as `zsid`); breakpoints
  do not work, as on Locomotive's +3 CP/M (`zsid_break`, known issue)

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

- [x] Pac-Man 95 - automated as `pacman95`
- [x] STAR (Star Trek) - automated as `star`
- [x] Hunt - automated as `hunt`
- [x] Ladder - automated as `ladder`
- [x] Othello - automated as `othello`
- [x] Colossal Cave Adventure - automated as `advent`
- [x] The Hitchhiker's Guide to the Galaxy - automated as `hitchhiker`
- [x] Planetfall - automated as `planetfall`
- [x] Starcross - automated as `starcross`
- [x] Sargon chess - automated as `sargon` (fails its copy-protection check)
- [ ] Creative Computing games
- [ ] Nemesis
- [ ] Catchum
- [ ] Manygame text-adventure collection

### Bundles and machine-specific software

- [ ] Kaypro 2X application bundle
- [ ] Mallard BASIC / LocoScript CP/M suite
- [x] +3 3CLCK clock - extractor/CLOCKCLR work; the FID itself needs
  Locomotive's private ABI, but the status line shows the time natively
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
