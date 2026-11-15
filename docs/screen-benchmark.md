# Screen rendering benchmark

`SCREENBM.COM` (`src/test/screenbm.asm`) is a screen-rendering benchmark that
runs unchanged on this system and on Locomotive's CP/M Plus for the +3, so the
two can be compared on identical work.  `tools/screen_bench.py` boots a disk,
runs the benchmark and reports the Z80 T-states each phase costs.

```bash
python3 tools/screen_bench.py                            # this build
python3 tools/screen_bench.py --dsk build/cpm3.dsk
python3 tools/screen_bench.py --compare /path/to/locomotive.dsk
python3 tools/screen_bench.py --compare ... --json results.json
```

`references/` is git-ignored, so a Locomotive image is never committed.  Point
`--compare` at your own copy.

## Why it is measured from outside

The benchmark carries no clock: a program clock is one more thing the two
systems could disagree about.  Each phase writes a marker byte to `3F00h`
before and after its work, and the harness arms a memory-write watchpoint on
that byte and reads the CPU's T-state counter at each stop.  Only the
benchmark writes that address, so unlike a PC breakpoint the watchpoint cannot
fire on CCP or BDOS code that happens to sit at a similar address.

The escape sequences are the ones Appendix III of the +3 CP/M manual defines,
so both systems implement them: `ESC E` (clear the viewport), `ESC H` (home),
`ESC Y` (absolute cursor), `ESC K` (erase to end of line), `ESC 3 2` (24x80)
and `ESC 5 n` (automatic paging).  Output goes through BDOS function 2 only.

Every phase first normalises the terminal with `ESC 0` (status line off, so
the viewport is the full 24 rows) and `ESC 3 1` (24x51, viewport reset and
cleared), outside the timed region.  Locomotive switches the status line on at
boot, so without this the same workload would not be doing the same work.

## Phases

| # | Phase | Work |
|---|-------|------|
| 1 | `glyphs` | 9384 glyphs (8 pages of 23x51), no scrolling |
| 2 | `scroll` | 640 line feeds from the bottom row |
| 3 | `clear` | 40 x `ESC E` (clear the viewport) |
| 4 | `cursor` | 2000 x `ESC Y` to row 20, column 5 |
| 5 | `page` | 4 full screens of 23x51 glyphs, wrapping at the right edge |
| 6 | `call` | 2000 x BDOS function 2 with `01h`, an ignored control code |
| 7 | `noflip` | 25 x 51-character rows in 24x80, automatic paging off |
| 8 | `flip` | the same, paging on, plus the character that pages the display |
| 9 | `erase` | 1000 x `ESC K` from column 0 (a whole row of cells) |

Phase 6 isolates the per-call cost from the per-glyph cost.  Phase 8 minus
phase 7 (and one glyph) is the cost of a 24x80 page flip.

## Results

Measured with this build against Locomotive's CP/M Plus 1.0 (`relative` =
this system / Locomotive; above 1.0 means this system spends more T-states).
The T-state totals move by well under 0.1% between runs, because the boot
state the measurement starts from is the same every time:

| Phase | OpenCP/M +3 | Locomotive | Relative |
|-------|------------:|-----------:|---------:|
| `glyphs` | 39,535,547 | 79,544,264 | **0.50x** |
| `scroll` | 152,289,125 | 181,510,689 | **0.84x** |
| `clear` | 10,189,128 | 13,092,522 | **0.78x** |
| `cursor` | 10,253,981 | 35,453,957 | **0.29x** |
| `page` | 19,763,054 | 39,851,546 | **0.50x** |
| `call` | 2,149,835 | 9,299,178 | **0.23x** |
| `noflip` | 12,980,073 | 29,430,039 | **0.44x** |
| `flip` | 25,731,030 | 30,099,588 | **0.85x** |
| `erase` | 15,421,499 | 33,945,174 | **0.45x** |

Per glyph, this system costs 4213 T-states and Locomotive 8477; per BDOS
console call, 1075 against 4650.

One page flip, isolated as phase 8 minus phase 7 minus one glyph, costs about
506,000 T-states here against 18,305 on Locomotive - about 28x.  That is
consistent with the `flip` row: phase 8 is dominated by drawing 1,275
characters, and in 24x80 mode a character costs 10,181 T-states here against
23,082 on Locomotive (2.3x cheaper), which absorbs most of the flip's cost.  So
the phase as a whole wins at 0.85x while each individual flip loses.
(`screen_bench.py` labels this derived figure `(flip)`; its cross-image ratio
reads 19x because it divides the two phase 8 minus phase 7 totals without
removing the per-flip glyph, and this system's cheaper glyph flatters the
ratio.)

## What the numbers say

- **Per-call overhead dominates small output.**  A BDOS console call costs
  1075 T-states here against 4650 on Locomotive, so anything that writes a
  character at a time is much cheaper.  This is the single biggest reason
  `glyphs`, `cursor` and `page` come out ahead.
- **Erasing a row does not render glyphs.**  `ESC E` and `ESC K` blank the
  row's bitmap, attribute cells and logical buffer directly
  (`_blank_row_direct`) instead of re-rendering one space glyph per cell, so
  `clear` costs 254,728 T-states per call and `erase` 15,422 per row.  Both
  are ahead of Locomotive.
- **A page flip is the one operation still behind.**  A flip shifts 24 rows x
  8 scan lines of bitmap, stamps a whole attribute row, mirrors the window
  into `char_buffer` and draws only the non-blank cells of the exposed strip.
  Locomotive's 18,305 T-states per flip shows it does not re-render the
  exposed columns at all; closing the remaining 28x needs the strip maintained
  incrementally in `LG_BUF` rather than drawn at flip time.

## Adding a phase

Add a `begin_N` / `end_N` marker pair (and the phase body) to
`src/test/screenbm.asm`, add it to `phase_table` and `run_all`, then add the
matching entry to `PHASES` and `PHASE_OPS` in `tools/screen_bench.py`.  The
harness reads the marker values, not addresses, so no listing maintenance is
needed beyond keeping the numbers in step.

## FONTTEST page draws

`tools/fonttest_bench.py` times how long `FONTTEST.COM` takes to draw each of
its seven pages at 32, 51 and 64 columns.  The program writes 1 to `0x3F00`
as a draw starts and 2 when it ends, and the tool reads the emulator's
T-state counter at each write, the same way `screen_bench.py` does.

A page draw costs most of a second at 51 columns.  A page is about a thousand
characters, and the console costs around 4,000 T-states for each rendered
glyph, so the program's own overhead is the smaller part:

| | 32 col | 51 col | 64 col |
|---|---:|---:|---:|
| One BDOS function 2 call per byte | 17.1M | 23.5M | 20.9M |
| One BDOS function 111 call per page | 15.4M | 21.7M | 19.0M |

(T-states for all seven pages.)  Buffering the output and sending it with
function 111 saves about 8%: it removes a BDOS call per byte, and four per
cursor move, but not the time the BIOS spends rendering.  Replacing each space
with a cursor-forward escape makes no difference, since blanks are already
cheap in the BIOS.  An instruction trace of a page draw puts about 56% of the
executed instructions in the bank-5 glyph renderer, with the attribute stamp
and the page-in/page-out port writes next, so further gains are in the
console path, where they would speed up every program.
