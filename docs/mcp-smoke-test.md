# zx84 MCP Smoke Test

Manual pre-commit smoke test for the default `build/cpm3.dsk` image using the
zx84 MCP emulator.

## Automated runner

`tools/zx84_smoke.py` boots the built image through the zx84 MCP server,
runs `SYSTEST`, `DISKTEST`, `BDOSTEST`, and the main CCP flows, and asserts
the 51x24 character buffer plus an empty FDC retry log:

```text
python3 tools/zx84_smoke.py
python3 tools/zx84_smoke.py --zx84 /path/to/zx84 --dsk build/cpm3.dsk
```

It exits 0 on success and 1 on a failed assertion. Set `ZX84_DIR` or pass
`--zx84` when the emulator checkout is not next to this repository. The
manual flow below remains useful for interactive debugging.

Run this after:

- `python3 tools/z80lint.py`
- `build.cmd`

The goal is to catch:

- boot regressions
- CCP command regressions
- BBC BASIC launch/exit regressions
- file operation regressions (`TYPE`, `RENAME`, wildcard `DIR`)
- disk-performance regressions (extra retries or materially higher cycle counts)

## Setup

Start the emulator and boot the image:

```text
model +3
load build/cpm3.dsk
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
rg "char_buffer:" build/bios.lst
```

Use that address with the emulator's `char_buffer` command or memory viewer.
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
load build/cpm3.dsk
disk_boot
run 1000
```

Read `char_buffer` at the address shown in `build/bios.lst` and require:

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

### BDOS file regression suite

Run:

```text
type "DISKTEST`enter`"
run 3000
```

Require every line from `T1 Search PASS` through `T17 F30 user area PASS`
and `All tests done.` in `char_buffer`.  T10 checks the documented F46
stub (`A=0`, `HL=0`, DMA untouched), not real free-space accounting.

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

`miniccp` has no built-in `REN`; the disk ships `RENAME.COM`, whose syntax is
`RENAME NEWNAME OLDNAME` (destination first).

Run:

```text
RENAME TEST.SUB RPED.SUB
DIR A:*.SUB
```

Check:

- the wildcard directory shows `TEST.SUB`
- `RPED.SUB` no longer appears
- `fdc_log` remains retry-free

### 6. Optional cleanup

To restore the original filename before finishing:

```text
RENAME RPED.SUB TEST.SUB
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
- successful `TYPE`, `RENAME`, and wildcard `DIR`
- no FDC retries
- no unexplained cycle-count regression
