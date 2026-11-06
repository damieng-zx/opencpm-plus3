# Third-party application tests

The +3 CP/M utilities are separate programs with their own copyright.  They
are **not** part of this repository and are never redistributed with the
built image.

## DISCKIT

`DISCKIT` is Copyright 1988 Locomotive Software Ltd.  The licence is still
enforced, so this project does not ship or embed it.  If you own a legal
copy, put it at:

```text
references/binaries/DISCKIT.COMx
```

`references/` is git-ignored.  Then run:

```text
python tools/zx84_diskit.py
python tools/zx84_diskit.py --bin /path/to/your/tools
```

The tool copies the **built** image to `build/disckit-test.dsk`, adds your
local `DISCKIT.COM` to that disposable copy, boots it and checks that the
Locomotive banner appears.  It then follows the first prompt - press a key,
remove the disc, press a key again - and requires the main menu (Format /
Verify) to appear, which covers `DD_DRIVE_STATUS` reporting a disc removal
through SENSE DRIVE STATUS and `KM_KT_GET` delivering ordinary keypresses.  Nothing is written back to `references/` and
nothing is committed.  Without a local copy the tool prints the notice and
exits 0, so CI does not need the binary.

The same rule applies to any other utility you drop into that folder: the
test harness may use it locally, but do not add it to the repository, the
DSK images or a release.

## PIP

`PIP` is Copyright Digital Research.  Like DISCKIT it is not included or
redistributed; the harness reads your own copy from
`references/binaries/PIP.COM` (git-ignored) or `--bin DIR`.  Then run:

```text
python tools/zx84_pip.py
python tools/zx84_pip.py --bin /path/to/your/cpm/tools
```

The tool copies the built image to `build/pip-test.dsk`, adds your
`PIP.COM`, boots it, runs the interactive copy
`A:COPY.TXT=A:SMOKE.TXT`, exits with a blank line and types the copy back,
requiring `SMOKE OK`.  PIP is a real F44 multi-sector caller, so this also
checks the BDOS read/write path with a third-party program.  Without a
local copy the tool prints the notice and exits 0.

## DRI CP/M 3 utilities

The DRI utilities (`SHOW`, `ED`, `SET`, `SETKEYS`, `PIP`, ...) are Copyright
Digital Research and are not included or redistributed.  The harness reads
your own copies from `references/binaries/` (git-ignored) or `--bin DIR`:

```text
python tools/zx84_dri.py
python tools/zx84_dri.py --bin /path/to/your/cpm/tools
```

It builds a clean `build/dri-test.dsk` from the boot/system files and the
local copies (the shipped image is packed with the smoke-test programs), then
checks:

* `SHOW` prints the drive status and free space (`A: RW, Space: ...`).
* `ED SMOKE.TXT` appends and types a line (`SMOKE OK`), then quits with
  `Q` and `Y`.
* `ED NEW.TXT` inserts a line, saves it with `E` (END) and reads it back
  with `TYPE NEW.TXT`; this covers ED's save path end to end.
* `SET` reports `ERROR: No options specified.` with no arguments, and
  `SET RO.TXT [RO]` prints `Read Only (RO)`.  DRI's SET takes its options
  in square brackets.
* The R/O attribute is then enforced: `ERA RO.TXT` and
  `REN NEW.TXT=RO.TXT` print `Bdos Err: R/O` and the file stays put.
  `SET RO.TXT [RW]` clears the attribute and `ERA` deletes it.
* `SETKEYS RESET.KEY` parses the key file and programs the +3 key override
  table (XBIOS `KM_SET_KEY`); the harness snapshots the table before and
  after and fails if nothing changed.

The three failures this harness originally found are fixed:

* **ED `E` (end/save)** built its records at address 0 and destroyed page
  zero.  ED keeps its record-buffer base at `FCB+21h`, i.e. right after a
  33-byte FCB, and the BDOS copied 36 bytes back into the FCB after every
  file call, zeroing it.  `writeback_fcb` now stops at byte 32; only F35
  (file size) and F36 (set random record) write the random-record bytes.
* **SETKEYS** crashed on exit because it ends with `RET` and the CCP never
  pushed a return address.  The CCP now pushes 0000h, exactly like the
  CP/M 3 CCP, so the entry stack is `SP = TPA_TOP - 2` with `(SP) = 0000h`.
* **SET** is a GENCOM "COM file with header" (first byte `RET`, module at
  0200h, `comsize` at 0101h).  The CCP now performs the CP/M 3 loader's
  module move from 0200h down to 0100h.  Attached RSX modules are not
  installed (this system has no RSX chain), and SET runs without its RSX.

Without the binaries the tool prints the notice and exits 0, so CI never
needs them.

## Other local utilities

`references/binaries/` may also contain tools with different provenance
(for example a host-generated `FORMAT.COMx`); the DISCKIT harness only
targets `DISCKIT.COMx` and checks the banner, never a destructive action.
