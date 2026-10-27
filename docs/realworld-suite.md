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
| `wordstar30` | WordStar 3.0 | Full-screen editor, terminal escapes | Known issue |
| `mbasic` | Microsoft BASIC-80 5.21 | Interpreter, console/file I/O | Pass |
| `turbo3` | Turbo Pascal 3.0 | Compiler/IDE, overlays, TPA | Pass |
| `m80l80` | Microsoft M80 + L80 | Assembler → REL → `.COM`, then run | Pass |
| `f80344` | Microsoft FORTRAN-80 3.44 | Compiler → REL → link with FORLIB → run | Pass |
| `bascom53` | Microsoft BASIC Compiler 5.3 | BASIC-80 → OBSLIB → stand-alone `.COM`, then run | Pass |
| `aztec106` | Aztec C 1.06D | cc → asm → object → link | Known issue |
| `z80asm` | SLR Z80ASM 1.32 | Direct-to-`.COM` macro assembler | Known issue |

Known issues are recorded in the manifest and printed by the runner:

- **WordStar 3.0** now starts and draws its no-file menu, but it is an
  80-column program: on the 51-column screen each line wraps and overlaps
  the next, so the display is not usable yet.  The underlying crash was a
  page-zero bug - `(0006h)` held `bdos_stub` (F737) instead of the TPA top
  (F600), so WordStar sized its screen buffer from the wrong ceiling and
  overwrote the BIOS jump table.  `common.zpa` now places `bdos_vector` at
  F600 and page zero 0006h points at it.  An 80-column screen mode is the
  remaining piece.
- **Turbo Pascal 3.0** runs (banner, `TURBO.MSG` load, IDE menu) and its
  80-column frames wrap on the 51-column screen for the same reason.
- **BASCOM 5.3** used to exit immediately because the suite pulled
  `BASCOM53.ZIP`, which is an OEM build: its start-up probes a banked
  machine (writes to ports 0/1 and `0EF08h`, and expects a `JP` at `0100h`
  to survive a write) and warm-boots when the probe fails.  `BASCOM.ZIP`
  carries the generic build.  The compile line is `BASCOM =CHELLO/O`;
  `/O` produces a stand-alone program that links against `OBSLIB.REL`
  instead of needing `BRUN.COM` at run time.
- **Aztec C 1.06D** compiles and assembles (`CHELLO.ASM`, `CHELLO.O` are
  produced) but Linker 1.06D rejects the assembler output with
  `Not an object file!`, so no `.COM` is produced.
- **Z80ASM 1.32** sets a multi-sector count with F44 and then reads its
  source once, assuming the whole block was transferred.  This BDOS
  deliberately transfers one record per call and reports it in `H` (a
  legal partial transfer), so the rest of Z80ASM's source buffer is stale
  and it reports `Line Too Long`.  Full multi-sector F20 transfers would
  fix it; the prototype that did so broke PIP's copy, so the documented
  single-record behaviour stands for now.

The assembler/compiler packages use fixtures from
`tests/realworld/fixtures/` (`HELLO.MAC`, `CHELLO.FOR`, `CHELLO.BAS`,
`CHELLO.C`, `HELLO.Z80`).  They are CRLF text files because the CP/M
tools read them directly (see `.gitattributes`).

SuperCalc2 starts successfully, but its VT-100 escape output is still visible
in the character buffer (`[?3h[2J[H`), so terminal escape handling remains a
compatibility area to investigate.

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

`archive` may be `zip` or `file`. For `file`, use `save_as` to name the CP/M
file. `fixtures` refers to `tests/realworld/fixtures/`.

Steps run in order. A step with `text` types a command, `key` presses a key,
and `wait: true` just runs the emulator for `frames` without typing — use it
when a tool needs time after its last output (for example Link-80 writing a
large `.COM`) before the next command is sent.

The runner extracts files by basename, so archives with directory trees are
supported. CP/M names must remain 8.3. Keep each package under the +3 data
capacity of about 174 KB, or trim optional help/install files.

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
| Zork I–III | [ZORK123_80.ZIP](http://www.retroarchive.org/cpm/games/zork123_80.zip) | Use one game at a time; Zork I is ~94 KB |
| VEDIT Plus | [D1](http://www.retroarchive.org/cpm/text/VEDIT_D1.ZIP), [D2](http://www.retroarchive.org/cpm/text/VEDIT_D2.ZIP) | Full-screen editor |
| PeachText/PeachCalc | [PEACHTXT.ZIP](http://www.retroarchive.org/cpm/text/PEACHTXT.ZIP) | Word processor + spreadsheet |
| Kaypro 2X bundle | [KAYPRO2X.ZIP](http://www.retroarchive.org/cpm/os/KAYPRO2X.ZIP) | 279-entry tree of small utilities and apps |

### Languages and development tools

| Software | Download |
|---|---|
| Microsoft BASIC compiler 5.3 | [BASCOM.ZIP](http://www.retroarchive.org/cpm/lang/BASCOM.ZIP) - automated as `bascom53` |
| Microsoft BASIC 5.29 | [MBASIC.ZIP](http://www.retroarchive.org/cpm/lang/mbasic.zip) |
| Microsoft FORTRAN-80 3.44 | [F80-344.ZIP](http://www.retroarchive.org/cpm/lang/F80-344.ZIP) - automated as `f80344` |
| Microsoft COBOL-80 4.01 | [MSCOBOL401.ZIP](http://www.retroarchive.org/cpm/lang/MSCOBOL401.ZIP) |
| Aztec C 1.06D | [AZ106D.ZIP](http://www.retroarchive.org/cpm/lang/az106d.zip) - automated as `aztec106` |
| BDS C user group | [BDSCUG.ZIP](http://www.retroarchive.org/cpm/lang/BDSCUG.ZIP) |
| Software Toolworks C80 3.1 | [C80V31.ZIP](http://www.retroarchive.org/cpm/lang/c80v31.zip) |
| Tiny C | [TINY_C.ZIP](http://www.retroarchive.org/cpm/lang/TINY_C.ZIP) |
| JRT Pascal 3.0 | [JRTPAS30.ZIP](http://www.retroarchive.org/cpm/lang/JRTPAS30.ZIP) |
| Pascal/Z 4.0 | [PASCALZ4.ZIP](http://www.retroarchive.org/cpm/lang/PASCALZ4.ZIP) |
| FTL Modula-2 1.30 | [FTL-MODULA2-V130.ZIP](http://www.retroarchive.org/cpm/lang/FTL-MODULA2-V130.zip) |
| APL/Z 1.1 | [APLZ11.ZIP](http://www.retroarchive.org/cpm/lang/aplz11.zip) |
| LISP/80 | [LISP80.ZIP](http://www.retroarchive.org/cpm/lang/lisp80.zip) |
| M80 + L80 | [M80.COM](http://www.retroarchive.org/cpm/lang/m80.com), [L80.COM](http://www.retroarchive.org/cpm/lang/l80.com) |
| Microsoft MACRO-80 package | [MASM-80.ZIP](http://www.retroarchive.org/cpm/lang/MASM-80.ZIP) - automated as `m80l80` |
| SLR Z80 assembler | [Z80ASM.ZIP](http://www.retroarchive.org/cpm/lang/Z80ASM.ZIP) - automated as `z80asm` |
| ZSID debugger | [ZSID.ZIP](http://www.retroarchive.org/cpm/lang/ZSID.ZIP) |

### Word processing and text

| Software | Download |
|---|---|
| WordMaster | [Wrdmastr.zip](http://www.retroarchive.org/cpm/text/Wrdmastr.zip) |
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
| SuperCalc | [Suprcalc.zip](http://www.retroarchive.org/cpm/business/Suprcalc.zip) |
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
| Large text-adventure collection | [MANYGAME.ZIP](http://www.retroarchive.org/cpm/games/manygame.zip) |
| Sargon chess | [SARGON.ZIP](http://www.retroarchive.org/cpm/games/sargon.zip) |
| Creative Computing games | [CCGAMES.ZIP](http://www.retroarchive.org/cpm/games/ccgames.zip) |
| Nemesis | [nemesis.zip](http://www.retroarchive.org/cpm/games/nemesis.zip) |
| Ladder | [LADDER.ZIP](http://www.retroarchive.org/cpm/misc/LADDER.ZIP) |
| Catchum | [CATCHUM.ZIP](http://www.retroarchive.org/cpm/misc/CATCHUM.ZIP) |

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
