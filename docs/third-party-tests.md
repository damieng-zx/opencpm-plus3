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
Locomotive banner appears.  Nothing is written back to `references/` and
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

It copies the built image to `build/dri-test.dsk`, adds the local
`SHOW.COM`/`ED.COM` and checks:

* `SHOW` prints the drive status and free space (`A: RW, Space: ...`).
* `ED SMOKE.TXT` appends and types a line (`SMOKE OK`), then quits with
  `Q` and `Y`.
* `ED NEW.TXT` inserts a line and discards it with `Q`/`Y`.

Known issues, found with this harness and not yet run by it:

* **ED `E` (end/save)** writes the data and directory sector, then stops
  with `*e` still on the line; no further BDOS or XBIOS calls are made.
* **SET** keeps reading the disk instead of drawing its menu.
* **SETKEYS** stops after opening its key file.

Without `SHOW.COM`/`ED.COM` the tool prints the notice and exits 0, so CI
never needs the binaries.

## Other local utilities

`references/binaries/` may also contain tools with different provenance
(for example a host-generated `FORMAT.COMx`); the DISCKIT harness only
targets `DISCKIT.COMx` and checks the banner, never a destructive action.
