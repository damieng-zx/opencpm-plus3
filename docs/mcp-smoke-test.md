# zx84 MCP Smoke Test

Manual pre-commit smoke test for the built **test** image
(`build/cpm3-test.dsk`) using the zx84 MCP emulator.  The distribution image
(`build/cpm3.dsk`) carries the system and the utilities but none of the
`*TEST.COM` programs, so the smoke boots the test image; the one check that
needs the distribution image (BBC BASIC) boots a scratch copy of it at the
end.

## Automated runner

`tools/zx84_smoke.py` boots the built image through the zx84 MCP server,
checks that the stage-2 loader staged the three fonts and `RAMDISK.FID`
byte-for-byte in bank 6 (plus `LF_FLAGS`/`LF_CCP_LEN`), fills the remaining
free bank-6 gaps with a sentinel and verifies they survive the app runs,
then runs
`SYSTEST`, `XTETEST`, `STLTEST`, `M80TEST`, `DISKTEST`, `BDOSTEST` (now including an end-to-end
`F59` overlay load and an `F111` print-block check), and the main CCP flows,
and asserts the 51x24 character buffer plus an empty FDC retry log:

`XTETEST` covers the XBIOS TE calls: `TE_ASK` geometry (including a set
`ESC X` viewport and the 23-row status-line viewport), `TE_RESET`,
`TE_STL_ASK`/`TE_STL_ON_OFF` (the full status-line toggle and 23-row
scroll are covered by `STLTEST` below),
`TE_SET_INK` (including FLASH), `TE_SET_BORDER`, `TE_SET_SPEED` and
`SCR_RUN_ROUTINE`, plus the disc calls (`DD_INIT`, `DD_SETUP`,
`DD_LOGIN`, `DD_SEL_FORMAT`, `DD_READ_ID`, `DD_READ_SECTOR`, `DD_WRITE`,
`DD_CHECK_SECTOR`, `DD_FORMAT`, motor on/off/timeout, `DD_L_SEEK`).  The
runner requires `7.RUN..OK`, `8.DISK..OK`, `9.RW..OK`,
`11.SETUP..OK`, `12.DPB..OK`, `13.XDPB..OK`, `14.LREAD..OK`,
`15.LWRITE..OK`, `16.KMSPD..OK`, `17.KTPUT..OK`, `18.KTGET..OK`,
`19.KTAB..OK`, `19.CAPS..OK`, `20.EXP..OK`, `21.CDVER..OK`, `22.CDINFO..OK`, `23.DRIVESTAT..OK`, `24.KTWRAP..OK`,
`25.SETKEY..OK`, `26.EXPMAX..OK`, `27.KMZERO..OK`, `28.LREADX..OK`, `29.BADSPEC..OK`, `30.SETUPX..OK`,
`31.KREPEAT..OK`, `32.FMTBAD..OK`, `33.VIEWPORT..OK`, the `5Ah` marker somewhere in the screen
attribute plane (bank 5, `5800h`-`5AFFh`)
and the `D100h` input-pass-through flag.  It also checks
that `DD_SETUP` produced the edge values above and then the restored
defaults `motor_off_ticks=250`, `fdc_spec1=4Fh`, `fdc_spec2=05h`.  It then boots a scratch copy, sets the `DC00h` magic
byte, runs `XTETEST` again, requires `10.FMT..OK` and checks the formatted
track with `sector_read`.

It then formats a disc for every `FORMAT` layout.  A 180K SS/40-track disc
on A: is formatted from a scratch copy of the test image with the target
hot-swapped in at the "put the disc in" prompt, which exercises both
disc-change prompts; `FORMAT`, `FORMAT C:` and ESC-cancel are checked first.
The rest run on B: with a scratch copy of `build/cpm3_720.dsk` mounted
there: 720K DS/80, CPC System, CPC Data, HiForm 203 (42 tracks, 10
sectors), SuperMat 192 and CPC IBM.

The checks require the `percentage / Track / Side / FORMAT|VERIFY` progress
line, the layout-named summary, `E5` on the last track, the boot-sector
spec (`00 00 28 09 ...` for 180K, `03 01 50 09 ...` for 720K, `01 00 28 09
02 02 ...` for CPC System, `00 00 2A 0A 02 01 03 02 0C 16` for HiForm,
`00 00 28 0A 02 01 03 03 ...` for SuperMat, `00 00 28 08 02 01 03 02 ...`
for CPC IBM), and the physical ID order from `track_geometry` (HiForm
`1 8 5 2 9 6 3 10 7 4`, SuperMat `1..10`, CPC IBM `1 5 2 6 3 7 4 8`, and
  `SHOWXDPB` must show
the detected geometry for the layouts with a boot sector (42 tracks x 10
sectors, `DSM=204` / `DSM=194`, the CPC `First=41h`/`C1h`), which proves the
login re-probed the disc and rebuilt the XDPB from the spec block.  CPC
Data reserves no track: its first sector stays filler and its IDs
identify it.  The
emulator keeps disc writes in memory rather than writing the `.dsk` back,
so sectors are read back through the FDC with `sector_read`.

`STAT` is checked next: the drive summary (`A:`, `K free of`, `C:`), a file
listing with sizes (`STAT *.TXT` reports `2 file(s)`), setting and clearing
the R/O attribute (`$R/O` shows `R/O` in the listing, `$R/W` clears it), the
wildcard refusal for attribute changes, and the usage text for a bad option.

`PROFILE.SUB` is checked twice, on scratch images.  The first profile turns
page mode off, so after boot `SETDEF` must report `Page mode: OFF`; the check
then turns page mode back on, runs a program (which warm-boots) and requires
it to stay on — proving the profile ran at the cold boot only.  The second
profile runs `INPTEST` (a test program that reads a line with F10 and prints
it back) followed by a `<` line and then `STAT`: the program must print
`GOT: HELLO FROM PROFILE`, and `STAT` must still run afterwards, which covers
program input from a submit file and the return to the CCP.

`SYSGEN` is checked twice.  With the distribution image in B:, `SYSGEN B:`
must copy track 0 (every sector is compared byte for byte through
`sector_read`) and the three system files, report `Checking ... ok` for
each after reading it back, and leave the target's other files in place
(`STAT B:FORMAT.COM`).  `SYSGEN A:` buffers the system, asks for the target
disc in A:, and writes it after the swap; its boot track must match too.
The usage paths (`SYSGEN`, `SYSGEN C:`) are checked first.

`DISKCOPY` is then checked three times.  `DISKCOPY A: B:` copies the source
onto a scratch copy of the *720K* image - a different layout - so the copy
has to format every target track as it goes; a sample of sectors across the
disc (boot sector, directory, file data, last track) must match the source
byte for byte, the target track must end up with the source's 9-sector
layout, and the summary must report "Every track verified." (each written
track is read back with DD_CHECK_SECTOR).  The usage errors for a missing argument and for `C:` are checked
first.  `DISKCOPY A: A:` exercises the single-drive swapping: the 48K
buffer takes ten tracks a pass, so the harness answers the "put the TARGET
disc in A:" prompt by swapping the target image in and the "put the SOURCE
disc back in A:" prompt by swapping the source back, four passes in all.
The first pass is compared against the source while the target is still
mounted; the remaining passes only have to reach "Copied 40 tracks." (the
emulator discards a disk image's in-memory writes when it is ejected, so
tracks from earlier passes cannot survive here).  Finally a HiForm disc
(42 tracks, 10 sectors, interleave 3) is formatted on B: and copied to A:;
the target's track 0 must have 10 sectors, gap 16h and the same sector
cycle as the source (any rotation is accepted, since READ ID cannot see the
index phase), which proves the layout was captured and re-applied instead
of being re-chosen.

```text
python3 tools/zx84_smoke.py
python3 tools/zx84_smoke.py --zx84 /path/to/zx84 --dsk build/cpm3-test.dsk
python3 tools/zx84_smoke.py --quick     # skip the destructive format tests
```

`--quick` runs everything except the scratch-image `DD_FORMAT` and `FORMAT`
tests, which are the parts that reboot other images.

The CCP checks cover `DIR`, `TYPE SMOKE.TXT`, `HELP`, the `SCREEN` utility
(`SCREEN 32`/`SCREEN 51`),
`ERA` (usage, `No file`, the `ALL (Y/N)?` guard and a real delete), `REN`
(`REN new=old`, `No file`, a real rename and the wildcard refusal), `USER`
(query, `USER 3`/`USER 10`, range and junk rejection, restore to 0),
`DATE`, invalid `D:`, and the C: prompt. They also verify that `CCP.COM` is
on the disk and staged byte-for-byte at `CCP_STAGE` (bank 6, B000h), and that
`CPM3.SYS` no longer embeds the CCP image. The common stub is staged as
`CPM3C.SYS` at `SYS2_STAGE` (bank 6, 9C00h) and copied to F600h by `init`. `SCREEN 64` is checked against the
font binary pixel-for-pixel (two 4-pixel glyphs per attribute cell) and `DIR`
must switch to four entries per line. The runner also runs `SUBMIT SMOKE.SUB`, the
implicit `SMOKE` -> `SUBMIT SMOKE.SUB` chain, the missing-file path,
`$1`/`$2` substitution via `SUBMIT PARAM SMOKE.TXT *.TXT`, and the
missing-parameter error. When the untracked reference binaries are on the
image, it checks a third-party `RENAME` (added to a scratch copy of the DSK)
with wildcard `DIR`, and the C: PIP/DATE flow.

Pagination is checked with `SETDEF [PAGE]` and the 30-line `PAGE.TXT`
fixture: `TYPE PAGE.TXT` must stop at `LINE 24` with the pager prompt shown
and `LINE 25`..`LINE 30` withheld, RETURN must resume and erase the prompt,
and `SETDEF [NOPAGE]` must print the whole file with no prompt and no key.

16-bit block numbers are checked with the PCW DS/DD image built as
`build/cpm3_720.dsk` (80 cylinders x 2 sides, 2K blocks, DSM=351).  The
runner mounts it on B: after boot, lists and types `HELLO16.TXT`, then runs
`DISKTEST 30` (T30 is the 16-bit block test, skipped when B: is not a
2K-block/16-bit-block disk).  T30 creates a file, writes 20 records, checks
F35, the F46 free-space delta (two blocks = 32 records), reads records back,
truncates with F99 (one block comes back) and deletes it, requiring
`T30 B16 16-bit blocks PASS`.

`tools/zx84_negative.py` builds corrupted copies of the image and requires
that they do **not** reach `A>`:

```text
python3 tools/zx84_negative.py
```

Cases: missing/deleted `CPM3.SYS`, truncated allocation map, block number
past the end of the disk, deleted `CPM3C.SYS` (common stub), corrupted
boot-sector checksum, deleted `CCP.COM` (boots, prints `CCP.COM missing`,
no prompt), and no disk in drive A:.

Optional-file cases (the boot must still reach `A>`): deleted `FONT64.BIN`
(and `SCREEN 64` is refused, width stays 51), deleted `FONT51.BIN`, deleted
`RAMDISK.FID`, and a corrupted `OCFID` magic.  The two FID cases also check
that `drive_table_c_slot` stays zero, i.e. C: is not registered.

Both scripts exit 0 on success and 1 on a failed assertion. Set `ZX84_DIR`
or pass `--zx84` when the emulator checkout is not next to this repository.
The manual flow below remains useful for interactive debugging.

Run this after:

- `python3 tools/z80lint.py`
- `build.cmd`

The goal is to catch:

- boot regressions
- CCP command regressions
- BBC BASIC launch/exit regressions
- file operation regressions (`TYPE`, `ERA`, `REN`, `USER`, wildcard `DIR`)
- disk-performance regressions (extra retries or materially higher cycle counts)

## Setup

Start the emulator and boot the image:

```text
model +3
load build/cpm3-test.dsk
disk_boot
run 1000
```

After the initial boot reaches a clean `A>` prompt, save a reusable baseline:

```text
save build/prompt.szx
```

For individual command checks, reload that snapshot instead of rebooting the
disk image:

```text
load build/prompt.szx
```

Find the screen buffer address from the BIOS listing:

```text
rg "char_buffer" build/bios.lst
```

`char_buffer` is an `equ` constant (currently `0xA000`) in **bank 6**.
Use that address with the emulator's memory viewer and select bank 6.
OCR is not reliable with the 5px font, so prefer the character buffer over OCR.

## Performance Notes

At each disk-heavy step below:

- inspect `fdc_log`
- confirm there are no retries
- note the cycle counts for comparison with previous runs

Treat retries as a bug. Treat a noticeable cycle-count increase across the same
workflow as a regression to investigate before committing.

## Test Flow

## Fast Regression Gate

Use this shorter gate whenever boot/common/BDOS layout changes:

```text
model +3
load build/cpm3-test.dsk
disk_boot
run 1000
```

Read `char_buffer` (bank 6, address from `build/bios.lst`) and require:

- the signon line contains `Open CP/M +3`
- the signon line reports the expected TPA size
- a later row contains `A>`

Then run:

```text
type "DUMP RPED.SUB`enter`"
run 2000
```

Read `char_buffer` again and require:

- the command line contains `A>DUMP RPED.SUB`
- output contains `0000:`
- execution is not spinning in common-memory copy code

`RAMDISK.FID` is included in the default disk image, so the boot path
already exercises `load_fid` on every build. Watch for `A>` to appear —
if the boot hangs after `Open CP/M +3`, suspect a FID/layout regression
in page-zero setup, the BDOS stack, or the bank-4 system image.

### Invalid drive

Run:

```text
DIR D:
```

Require `No files` and no directory listing from the previous drive.  An
invalid drive must return "not found" instead of searching the last cached
drive.

### System / console regression suite

Run:

```text
type "SYSTEST`enter`"
run 2500
```

Require all of:

- `STACK OK`, `MOVE OK`, `CLOCK OK`
- `P0 PASS`
- `TAB:` followed by `A       B` (`A` in column 0, `B` in column 8)
- `DELIM PASS`

`SYSTEST` combines the old STKTEST, P0TEST, TABTEST and DELIMTES checks.
A stack failure stops the run; the other checks continue after a failure.

Then run `DIR`: the listing must be normal.  A garbled/run-on listing means
the F110 delimiter leaked into the CCP's `$`-terminated messages instead of
being reset at warm boot.

### XBIOS TE regression suite

Run:

```text
type "XTETEST`enter`"
run 1200
```

Require `7.RUN..OK`, `8.DISK..OK`, `9.RW..OK` and `DONE`, with no `FAIL`.
`XTETEST` calls every implemented TE entry through `USERF`: `TE_ASK`
reports `51x24`, `TE_RESET` clears, the ink/border tests change the
palette, and `TE_SET_SPEED` is accepted.  Test 4 disables then enables the
status line with `TE_STL_ON_OFF`, checks `TE_STL_ASK`'s A/Zero contract
and that `TE_ASK` drops to 23 rows, then disables it again and checks that
24 rows come back.  Test 7 stages a routine at
`D000h`, runs it via `SCR_RUN_ROUTINE`, checks DE/HL/IX/IY pass-through
and leaves:

- `5Ah` in the screen attribute plane (bank 5, `5800h`-`5AFFh`); it is
  written to the bottom-right cell (`1AFFh`/`5AFFh`) and may scroll
- `01h` in the common-memory flag at `D100h`

Test 8 runs the phase-1 disc calls: it loads the standard XDPB template to
`D200h`, spins the motor up, seeks track 0, reads the first sector ID and
checks the result buffer, then stops the motor.  It also verifies that
`DD_L_ON_MOTOR` and `DD_L_T_OFF_MOTOR` preserve AF/BC/DE/HL.

Test 9 runs `DD_LOGIN` (checking the returned disc type, ALV and hash
sizes), reads the boot sector with `DD_READ_SECTOR`, writes it back
unchanged with `DD_WRITE`, and checks `DD_CHECK_SECTOR` reports both equal
and different buffers correctly.  It also confirms `DD_FORMAT` rejects an
unsupported bank without formatting.

Test 10 is the destructive format check.  It only runs when the harness
sets the `DC00h` magic byte.  It builds a standard 9-sector header table at
`D500h`, formats track 39 with filler `E5h`, reads the track back and
checks the data area, then reads the sector ID.  It then copies the XDPB,
sets 8 sectors/track, formats track 38 with an 8-entry header at `D520h`,
checks `READ ID` never reports sector 9 and reads the eighth sector back.
It then fills a 1K buffer at `C000h` (`AAh` then `55h`) and writes sectors
1-2 of track 38 with one `DD_L_WRITE` WRITE DATA MULTIPLE command (EOT=2),
then reads each sector back with `DD_L_READ` and compares the halves.  The
smoke runner does this on a scratch copy and uses `sector_read` to confirm
the filler.

Test 11 applies the default `DD_SETUP` parameter block at `D600h`.  The
smoke runner then checks the translated fields: `motor_off_ticks=250`
(50 × 100 ms in 50 Hz frames), `fdc_spec1=4Fh` (SRT 4 = 12 ms step, HUT
15) and `fdc_spec2=05h` (HLT 2 = 4 ms head load, non-DMA).

Test 12 builds a standard +3 10-byte disc specification at `D700h`, calls
`DD_L_DPB` and checks the 17-byte DPB at `D800h`: SPT=36, BSH=3, BLM=7,
EXM=0, DSM=174, DRM=63, AL0=C0h, AL1=00h, CKS=16, OFF=1, PSH=2, PHM=3.

Test 13 runs `DD_L_XDPB` with the same spec and checks the 27-byte XDPB at
`D820h`, including the extension: sides=0, tracks=40, sectors=9, first
sector=1, sector size=512, gap1=42, gap2=82, flags=40h, freeze=FFh.

Test 14 drives `DD_L_READ` directly: a READ ID command returns seven
result bytes with a valid R, and a READ DATA command reads the boot sector
into `D300h` and returns a clean result phase.

Test 15 uses `DD_L_WRITE` with WRITE DATA to write the same boot sector
back unchanged, then re-reads it with `DD_L_READ` and checks the prefix.

Test 16 calls `KM_SET_SPEED` with H=10, L=5 (exercising the setter), then
test 27 sets 0/0: the runner checks both stored words are 256 scans, the
documented meaning of zero.  The repeat path itself reads those variables
(`_kbd_scan`).

Test 31 proves the timings actually drive auto-repeat.  It sets delay 1 /
rate 1, the runner holds a key for 60 frames, and the test counts the
characters until 2000 empty reads (at least three must arrive).  It then
sets delay 250, holds another key for the same 60 frames and requires
exactly one character: the start-up delay outlasts the hold, so a repeat
that ignored the stored timings would fail the second half.  It leaves 0/0
in place so the test-27 read-back still sees 256.

Test 32 checks the two remaining `DD_FORMAT` guards: an XDPB below `C000h`
(bank 1 still) and an unfitted unit.  Both return before any FDC access, so
the boot disk is untouched: A=9 with carry clear for the low XDPB, A=0 for
unit 2 (units 0 and 1 are the two FDC drives the disc calls address).  Bank
0 is already covered by test 9.

Test 17 calls `KM_KT_PUT` twice (shift 08h/key 2Bh, then 00h/1Fh) and
verifies BC survives.  Test 18 then drains both with `KM_KT_GET`, checks
the returned shift/key pairs, that an empty queue returns carry clear, and
that DE/HL survive the call.
The smoke runner checks the queued bytes `08 2B 00 1F`, `kbd_token_count=0`
and `kbd_token_head=2`.

Test 19 remaps the Z key (raw key 1) to `Q` in the normal translation table
with `KM_SET_KEY`, prints `19.KTAB..` and polls the keyboard without echo
until a key arrives.  The runner waits for that marker, presses Z and then
waits for `19.KTAB..OK`; the test restores the built-in mapping afterwards
and the runner checks `KMTAB[4]` is `FFh`.

It then repeats the exercise on the CAPS table: X (raw key 2) is remapped to
`Q`, the runner presses CAPS+X (`shift+x` in the MCP) and waits for
`19.CAPS..OK`, which proves the CAPS-shift index and mask work through the
real scanner, not just the setter.  Short polling steps are used because the
run races on to tests 20-30 once the key arrives.

Test 20 stores `HELLO` under expansion token `85h` with `KM_SET_EXPAND`,
checks that token `7Fh` and a 32-character string are rejected, and the
runner reads back the slot at `A9A0h + 5*32` (length 5 plus `HELLO`).

Tests 21-23 cover the remaining dispatched IDs: `CD_VERSION` (machine 3,
version 1.0), `CD_INFO` (one drive, 8 banks, no serial/B:, SS 40-track
3-inch, HL pointing at the `0xFF` buffer table in common memory) and
`DD_DRIVE_STATUS` (unit 0 ready/track 0 with the head bit, unit 1 not
fitted, B/DE preserved).  Test 24 fills the key queue to 16, checks the
17th token is dropped, drains it in order, then runs 20 put/get cycles to
exercise head/tail wrap; the runner checks count 0 and head/tail 6.

Test 25 sets `KM_SET_KEY` entries in the CAPS, SYMB and EXTEND tables
(single and combined masks), then checks that an invalid key number (40)
and a zero mask leave the entry unchanged.  The runner reads the table
back, then restores those entries so later upper-case typing is unaffected.

Test 26 exercises `KM_SET_EXPAND` boundaries: token `80h` with length 0
(no-op copy), the same token with an over-long 32-byte string (rejected,
slot stays empty), token `9Eh` with the maximum 31 bytes, and invalid
token `9Fh`.  The runner checks the empty slot and the full 31-byte slot
at `A9A0h + 30*32`.

Test 33 parks the cursor with `ESC Y`, sets a 4x10 viewport at (2,3) with
`ESC X`, and calls `TE_ASK`: it must report `B=2 C=3 D=3 E=9` with the
cursor clamped into the rectangle (`H=L=0`).  It then restores the
full-screen viewport with `ESC X 0 0 23 50` and prints `33.VIEWPORT..OK`.
The viewport state lives in bank 6 (`A73A-A73F`), and the loader stages
the screen row-address table at `A890` so it costs no image space.

### Status-line suite (`STLTEST`)

Run:

```text
type "STLTEST`enter`"
run 1500
```

Require `STL..OK`.  The program disables the status line, checks
`TE_STL_ASK` (`A=00h`, Zero set), enables it with `TE_STL_ON_OFF`
(`A=FFh`, Zero clear), and checks that `TE_ASK` drops to 23 rows
(`D=22`).  It then turns page mode off and scrolls 30 numbered lines
through the 23-row viewport, which exercises the height-parameterised
fast scroll and must leave the status row alone.  Disabling again must
give `D=23` and `A=00h`/Zero set.  XTETEST test 4 runs the same checks,
but so early in its burst that the runner's frame sampling misses the
marker; `STLTEST` is the one the smoke gates on.

### 24x80 suite (`M80TEST`) and `SET24X80`

`M80TEST` enters `ESC x`, checks `TE_ASK` reports an 80-column viewport
(`E=79`), moves the cursor to column 70 (auto-flip), checks the logical
cursor (`L=70`), leaves with `ESC y` and checks the width is back to
`E=50`.  It prints `M80..OK`; the runner also checks that the physical
width and 24x80 flag are restored afterwards.

The runner then exercises `SET24X80.COM` from the prompt: no argument and
`ON` must enter 24x80, `OFF` must leave it, the prompt must still appear,
and `SET24X80 JUNK` must print `SET24X80 [ON|OFF]`.  After each switch it
reads `mode80` (bank 6, `A8C1h`) and requires the expected state.

`M80BIT` covers the fast page flip itself.  It writes `W` at logical column
29, moves to column 51 (which leaves the first 51-column page) and writes
`Q` there, then prints `M80BIT..OK` without a newline so the cursor stays
on page 29.  The runner reads the logical buffer (`LG_BUF`, bank 5
`5B00h`), the page offset (`A8C2h`) and the bitmap, renders rows 0-2 with
an independent reference (5px font) and requires an exact match for all
eight scan lines.  A wrong shift direction, a bad source address in the
exposed-column re-render or a missing 51-column clip all fail here.  After
the check a key press makes `M80BIT` leave 24x80 itself, so the following
tests start at a 51-column prompt.

### BDOS file regression suite

Run:

```text
type "DISKTEST`enter`"
run 3000
```

Require every line from `T1 Search PASS` through `T29 F99 truncate PASS`
and `All tests done.` in `char_buffer`.  T10 (`F46 free space`) is a real
accounting check, not a stub: the count is non-zero, drops by 8 records
after writing one 1K block, and returns to its original value once the
file is deleted.

T23/T27/T28 cover the F44 multi-sector path: T23 reads four records of
`CPM3.SYS` in one `F20` (EOT-style count 4, H=4) and compares them with four
single-record reads; T27/T28 write four records in one `F21` to A: and C:
and read each marker back.

`fdc_log` must stay retry-free.  A `FAIL` on T4 usually means the directory
cache key/sector was corrupted; a `FAIL` on T11 means an extent's RC/alloc
was not flushed.

### 1. Boot and initial directory

At the CCP prompt, run:

```text
DIR
```

Check:

- the screen buffer shows the signon line and a directory listing
- `fdc_log` shows normal reads with no retries

### 2. Launch BBC BASIC and run a program

At the CCP prompt, run:

```text
BBCBASIC
```

Then type:

```text
10 PRINT "Hello"
RUN
```

Check:

- the screen buffer shows the BBC BASIC banner or prompt
- after `RUN`, the screen buffer contains `Hello`
- `fdc_log` does not show retries during launch

Exit BBC BASIC:

```text
QUIT
```

Check:

- control returns to the CCP prompt cleanly

### 3. Directory again

Run:

```text
DIR
```

Check:

- the CCP prompt and directory listing still render correctly
- `fdc_log` remains retry-free

### 4. TYPE a SUB file

Run:

```text
TYPE RPED.SUB
```

Check:

- file contents display in the screen buffer
- `fdc_log` remains retry-free

### 5. Rename the SUB file

`miniccp` has a built-in `REN`, which takes `NEW=OLD` or `NEW OLD` (both in
RENAME.COM's new-then-old order). `RENAME.COM` itself is not bundled; the
scripted smoke test adds it to a scratch copy of the DSK when the reference
binaries are present.

Run:

```text
REN TEST.SUB=RPED.SUB
DIR A:*.SUB
```

Check:

- the wildcard directory shows `TEST.SUB`
- `RPED.SUB` no longer appears
- `fdc_log` remains retry-free

### 6. Optional cleanup

To restore the original filename before finishing:

```text
REN RPED.SUB=TEST.SUB
DIR A:*.SUB
```

Check:

- `RPED.SUB` is present again

### 7. C: ramdisk — copy a COM and execute from it

Requires the build to have included `RAMDISK.FID` (rebuild with
`build.cmd --add build\RAMDISK.FID` if it isn't already on the disk).

At the CCP prompt:

```text
DIR C:
PIP C:=A:DATE.COM
DIR C:
C:
DATE
A:
```

Check:

- the first `DIR C:` shows an empty directory (`No file` or similar) — proves
  C: is registered and the FID's `rd_init` zeroed block 0
- `PIP` completes without error; `fdc_log` shows reads of `DATE.COM` from A:
  but **no FDC writes** (C: writes go through `rd_write` into bank 7)
- the second `DIR C:` lists `DATE.COM`
- `C:` switches the prompt to `C>`
- `DATE` runs from C: and prints the current date/time — proves the FID's
  `rd_read` deblocked the COM correctly into the TPA via `copy_record_to_tpa`
- returning to `A:` works

If `DIR C:` reports an invalid drive, `load_fid` either didn't find
`RAMDISK.FID` or the magic check failed — check `_fid_block` and the FID
header at `0x9000` in bank 6.

## Suggested MCP Input Pattern

When driving the emulator interactively, the typical pattern is:

```text
type "DIR"
key enter
```

Repeat that for each command (`BBCBASIC`, `RUN`, `QUIT`, etc.). After each
step, inspect:

- screen contents via `char_buffer`
- disk behaviour via `fdc_log`

## Commit Gate

Before committing, this smoke test should pass with:

- successful boot
- correct screen-buffer contents at each checkpoint
- BBC BASIC launch, `RUN`, and `QUIT` working
- successful `TYPE`, `ERA`, `REN`, and wildcard `DIR`
- no FDC retries
- no unexplained cycle-count regression
