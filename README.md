# OpenCP/M +3

A brand-new CP/M Plus (CP/M 3.1) for the ZX Spectrum +3, written from scratch.

Boot the disc and you get the familiar `A>` prompt, a choice of 32, 51 or 64
column text, an 80-column virtual screen, a RAM disk, a full-screen editor and
a set of disc tools — and the classic CP/M software of the 1980s (WordStar,
dBASE II, Turbo Pascal, the Infocom adventures and plenty more) runs on it.

**It is not Locomotive Software's CP/M Plus, and contains none of it.** Every
part of the system, from the BIOS to the utilities, was written for this
project from the published CP/M 3 documentation and the +3's documented
hardware.

## Getting started

Use `cpm3.dsk`, the 180K distribution disc:

- **In an emulator** — select a Spectrum +3, insert `cpm3.dsk` in drive A: and
  choose **Loader** from the start-up menu.
- **On a real +3** — write `cpm3.dsk` to a 3" disc (or put it on a Gotek or
  similar drive emulator) and choose **Loader**.

After a few seconds you are at the `A>` prompt. Type `DIR` to see what is on
the disc and `HELP` for the built-in commands.

To build the disc yourself, see [Building from source](#building-from-source).

## How it compares with Locomotive's CP/M Plus

Both speak CP/M 3.1 and the +3's extended BIOS, so the same applications run.
On top of that you get:

| | Locomotive CP/M Plus (+3) | OpenCP/M +3 |
|---|---|---|
| Text widths | 32 and 51 columns | 32, 51 and **64** columns |
| Virtual 80-column screen | shown in 51 columns | shown in **51 or 64** columns |
| Full-screen text editor | — (`ED`, a line editor) | **`EDIT`** |
| Formatting a disc | `DISCKIT` | **`FORMAT`** (7 layouts) |
| Copying a disc | `DISCKIT` | **`DISKCOPY`** (verified) |
| Undeleting a file | — | **`UNDELETE`** |
| File checksums | — | **`CRC`** |
| Command-line recall | — | **cursor up** brings back the last command |
| RAM disk | `RAMDISC.FID` | **`RAMDISK.FID`**, 16K `C:` |
| Serial and parallel ports | supported | **not yet** |
| BASIC | Mallard BASIC | **BBC BASIC** (optional, see below) |

## Using the system

### The screen

| Width | Font | Command |
|---|---|---|
| 32 columns | 8 pixels | `SCREEN 32` |
| 51 columns | 5 pixels | `SCREEN 51` (the default) |
| 64 columns | 4 pixels | `SCREEN 64` |
| 80 columns | current font | `SET24X80` |

The 80-column screen is a virtual one: the Spectrum shows part of it, and
**EXTEND+Enter** flips to the other half. `<` and `>` on the status line show
when text is hidden off either edge. `SET24X80 OFF` goes back to normal.

The bottom line can show a status line with the time (`ESC 0` / `ESC 1` turn
it off and on).

### The keyboard

| Keys | Does |
|---|---|
| BREAK (Caps Shift+Space) | ESC |
| EXTEND (Caps Shift+Symbol Shift) then a letter | that control key |
| EXTEND+Enter | flip halves of the 80-column screen |
| Caps+5/6/7/8 | cursor keys |
| Caps+0 | delete |

### Typing commands

The command line is a proper line editor: **cursor up** (or EDIT) on an
empty line brings back the previous command, the cursor keys move along it,
typing inserts, Caps+0 and Caps+9 delete, and EXTEND+K / EXTEND+X delete to
the end or the start. The same editor works in any program that reads a line
of input from CP/M.

These commands are built in:

| Command | Does |
|---|---|
| `DIR [filespec]` | list files (`DIR *.COM`) |
| `DIRSYS` / `DIRS` | list the system (hidden) files |
| `ERA filespec` | delete files (asks first when there is a wildcard) |
| `REN new=old` | rename a file |
| `TYPE filespec` | show a text file, a screenful at a time |
| `USER n` | change user area (0-15) |
| `HELP` | list the built-ins |
| `A:` `B:` `C:` | change drive |

Anything else runs the program of that name, so `EDIT LETTER.TXT` runs
`EDIT.COM`. `DIR` and `ERA` take an option list too (`DIR [FULL]`,
`ERA *.BAK [CONFIRM]`), and several commands can go on one line separated by
`!` (`DIR!TYPE README.TXT`).

`C:` is a 16K RAM disk: quick, but emptied when the machine is switched off.

## What's on the disc

### Everyday programs

| Program | What it is for |
|---|---|
| `EDIT` | full-screen text editor |
| `DIR` | directory listings with sizes, attributes and sorting |
| `ERASE` | delete files, asking about each one |
| `STAT` | free space, file sizes, and read-only / system attributes |
| `TYPE`, `DUMP` | show a file as text or as hex |
| `DATE` | show or set the date and time |
| `SUBMIT` | run a batch file of commands |

### Disc tools

| Program | What it is for |
|---|---|
| `FORMAT` | format a disc in one of seven layouts |
| `DISKCOPY` | copy a whole disc, on one drive or two |
| `SYSGEN` | make a formatted disc bootable |
| `UNDELETE` | get back a file you deleted |
| `CRC` | checksum files, to check a copy is good |
| `SHOWXDPB` | show a disc's format |

### Setting things up

| Program | What it is for |
|---|---|
| `SCREEN` | 32, 51 or 64 columns |
| `SET24X80` | the 80-column virtual screen on or off |
| `SETKEYS` | redefine keys from a key-definition file |
| `SETDEF` | where to look for programs, and screen paging |
| `DEVICE` | show and assign the printer and auxiliary devices |

### Optional extras

Builds made with the third-party programs present (see
[Building from source](#building-from-source)) also carry Digital Research's
`PIP` (file copying), `ED`, `SET` and `SHOW`, and R.T. Russell's
**BBC BASIC**.

## Program guide

### EDIT

`EDIT [file]` opens the file, or an empty page. You get 23 rows of text and a
status line showing the file name, the cursor's `line:col` and the modes in
use, at any screen width including 80 columns.

The cursor keys move, typing inserts (or overwrites), Caps+0 deletes
backwards and Caps+4 types a tab. Commands are EXTEND or BREAK followed by a
letter — or press BREAK on its own, or hold EXTEND for a second, to see the
menu:

| Key | Command | Key | Command |
|---|---|---|---|
| `O` | open a file | `S` | save |
| `N` | new, empty file | `Q` | quit |
| `F` | find | `R` | replace (`Y`/`N`/`A`ll/`Q`uit at each match) |
| `V` | show spaces and tabs | `W` | word wrap on/off |
| `I` | insert/overwrite | `Z` | undo |
| `D` | delete the character under the cursor | `L` | redraw the screen |
| `H` | help | | |

EXTEND+C in the find and replace prompts switches between matching case
(`[Aa]`) and ignoring it (`[aa]`). EDIT asks before throwing away unsaved
changes, and saving is safe: the new text is written in full before it
replaces the old file, so a full disc never costs you the original. Files can
be up to about 48K.

### DIR

`DIR` with an option list in square brackets. Options can be shortened as
long as they stay unambiguous:

| Option | Shows |
|---|---|
| `FULL` | name, size, records and attributes, then totals (the default) |
| `SIZE` | names and sizes, several to a line |
| `ATT` | also the user attributes F1-F4 |
| `DIR` / `SYS` | only ordinary / only system files |
| `RO` / `RW` | only read-only / only read-write files |
| `DRIVE=ALL`, `d` or `(d,d)` | other drives |
| `USER=ALL`, `n` or `(n,n)` | other user areas |
| `EXCLUDE` | the files that do **not** match |
| `NOSORT` | directory order instead of alphabetical |
| `NOPAGE` | no pause when the screen fills |

Several filespecs may be given: `DIR *.COM *.SUB [SIZE]`.

### ERASE

`ERA filespec [CONFIRM]` asks `A:NAME.TYP (Y/N)?` for each matching file.

### STAT

`STAT` shows each drive's free space (`A: 59K free of 175K`). `STAT filespec`
lists matching files with their size and attributes, and
`STAT filespec $R/O`, `$R/W` or `$SYS` changes them.

### FORMAT

`FORMAT A:` or `FORMAT B:` asks you to put in the disc, then for a layout:

| # | Layout | Notes |
|---|---|---|
| 1 | 180K +3 / PCW | the standard +3 disc |
| 2 | 720K PCW | double-sided, 80 tracks |
| 3 | CPC System | |
| 4 | CPC Data | |
| 5 | HiForm 203 | 203K on a standard disc |
| 6 | SuperMat 192 | 192K on a standard disc |
| 7 | CPC IBM | |

Each track is formatted and then read back to check it, with a progress line
as it goes. `FORMAT A: /Q` skips the read-back for about a third off the
time. Making the result bootable is `SYSGEN B:` afterwards.

### DISKCOPY

`DISKCOPY A: B:` copies a whole disc, track by track, and checks every track
it writes. With a single drive, `DISKCOPY A: A:` reads as much as fits in
memory and asks you to swap discs. The target does not need formatting first:
each track is formatted to match the source as it is copied.

### SYSGEN

`SYSGEN B:` (or `SYSGEN A:`) copies the system from the disc in A: onto
another formatted disc so it can boot. Other files on the target are kept,
and everything written is read back to check it. With one drive it asks you
to swap discs.

### UNDELETE

`UNDELETE` lists the deleted files that can still be recovered
(`UNDELETE B:` or `UNDELETE *.TXT` to narrow the list).
`UNDELETE LETTER.TXT R` brings one back, and `R U=n` restores it into user
area *n*. A file is only restored if nothing written since has reused its
space, so what comes back is intact. Works on A: and B: with the standard
+3 formats (not 720K discs).

### CRC

`CRC filespec` prints each matching file's CRC-32 (`CRC *.COM` does a whole
set). It is the same CRC-32 that `zip`, 7-Zip and `crc32` use on a PC, so you
can check a file survived a copy to or from the +3.

### And the rest

- `DATE` shows the date and time, `DATE S` sets them and `DATE C` keeps the
  display running.
- `DUMP file` shows a file in hex and ASCII, sized to the screen width.
- `SUBMIT file [args]` runs a `.SUB` file of commands, with `$1`..`$9`
  replaced by the arguments. A line starting with `<` is typed into the
  running program instead, so a script can drive `PIP`.
- `SETDEF` shows the settings; `SETDEF [PAGE]` / `[NOPAGE]` turn the
  screenful pause on and off, and `SETDEF A:,B:` sets where programs are
  looked for.
- `SETKEYS [file]` loads a key-definition file (`SETKEYS.KEY` by default);
  the `RESET.KEY` from Locomotive's CP/M Plus works unchanged.
- `DEVICE` shows the devices; `DEVICE LST:=NULL` and similar reassign them,
  and `DEVICE CONSOLE [PAGE | LINES=n | COLUMNS=n]` sets up the screen.
- `SHOWXDPB` shows the format of each drive's disc.

## Running CP/M software

Dozens of classic packages have been tested from their original files:

- **Word processing and business** — WordStar, WordMaster, VEDIT Plus,
  dBASE II, SuperCalc and Multiplan.
- **Programming** — Turbo Pascal, BASIC-80, BBC BASIC, M80/L80, FORTRAN-80,
  the BASIC Compiler, Aztec C, Pascal/Z and the Z80ASM assembler.
- **Adventures** — Zork I-III, Hitchhiker's Guide, Planetfall, Starcross and
  Colossal Cave, including saving and restoring games.
- **Games** — Pac-Man 95, Ladder, STAR, Hunt, Othello and MSCP chess.

Programs written for an 80-column terminal (WordStar, SuperCalc2, Multiplan,
Turbo Pascal) want `SET24X80` first; Turbo Pascal also works in `SCREEN 64`
once installed for 64 columns. Discs in the CP/M 3 16-bit block format and
PCW 720K discs can be read as well as the standard +3 format.

The full list, with what was checked for each, is in the
[compatibility tables](docs/compatibility.md).

## Building from source

You need [sjasmplus](https://github.com/z00m128/sjasmplus) and Python 3.

```bash
build.cmd        # Windows
./build.sh       # Linux, macOS
build.cmd --add FILE ...   # put extra files on the discs
```

That makes:

| Image | What it is |
|---|---|
| `build/cpm3.dsk` | the 180K distribution disc, for real hardware |
| `build/cpm3-dist720.dsk` | the same files on a 720K PCW disc, with more free space |
| `build/cpm3-test.dsk` | the 720K disc plus the test programs |

To include the optional extras, put `PIP.COM`, `ED.COM`, `SET.COM`,
`SHOW.COM`, `TYPE.COM` and `BBCBASIC.COM` in `references/binaries/` before
building. They are copyrighted by their authors and are not part of this
repository.

How the system works inside — memory banking, the boot sequence, the BDOS
and extended BIOS calls — and how it is tested are covered in the
documentation:

- [Boot, Paging and Common Memory](docs/boot.md)
- [CP/M 3.1 BDOS API Reference](docs/API.md)
- [XBIOS/TE Interface](docs/cpm-plus-xbios.md)
- [Filesystem Layout](docs/filesystem.md)
- [CP/M Software Compatibility](docs/compatibility.md)
- [Real-world CP/M Suite](docs/realworld-suite.md)
- [zx84 MCP Smoke Test](docs/mcp-smoke-test.md)
- [Screen Rendering Benchmark](docs/screen-benchmark.md)
- [CI with zx84](docs/ci.md)

## Credits and licences

OpenCP/M +3 is released under the [MIT License](LICENSE).

The optional Digital Research programs (`PIP`, `ED`, `SET`, `SHOW`, `TYPE`)
are © 1982 Digital Research and may be redistributed under the
[CP/M licence](http://www.cpm.z80.de/license.html).

[BBC BASIC (Z80)](https://github.com/rtrussell/BBCZ80) is © R.T. Russell,
who makes it available free of charge.
