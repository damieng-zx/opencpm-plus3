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

Phase 6 isolates the per-call cost from the per-glyph cost.  Phase 7 minus
phase 8's difference is the cost of a 24x80 page flip.

## Results

Measured with this build against Locomotive's CP/M Plus 1.0 (`relative` =
this system / Locomotive; above 1.0 means this system spends more T-states).
The T-state totals move by well under 0.1% between runs, because the boot
state the measurement starts from is the same every time:

| Phase | OpenCP/M +3 | Locomotive | Relative |
|-------|------------:|-----------:|---------:|
| `glyphs` | 39,665,631 | 79,612,208 | **0.50x** |
| `scroll` | 152,265,060 | 181,510,689 | **0.84x** |
| `clear` | 10,168,529 | 13,090,080 | **0.78x** |
| `cursor` | 10,210,924 | 35,454,124 | **0.29x** |
| `page` | 19,834,545 | 39,772,237 | **0.50x** |
| `call` | 2,146,319 | 9,299,178 | **0.23x** |
| `noflip` | 12,922,808 | 29,430,207 | 0.44x |
| `flip` | 59,402,555 | 30,099,588 | 1.97x |
| `erase` | 15,395,919 | 33,948,037 | **0.45x** |

Per glyph, this system costs 4227 T-states and Locomotive 8484; per BDOS
console call, 1073 against 4650.

## What the numbers say

- **Per-call overhead dominates small output.**  A BDOS console call costs
  1074 T-states here against 4650 on Locomotive, so anything that writes a
  character at a time is much cheaper.  This is the single biggest reason
  `glyphs`, `cursor` and `page` come out ahead.
- **A full-row erase must not draw glyphs.**  `ESC E` and `ESC K` both used to
  re-render one space glyph per cell: a font load and eight masked scan-line
  merges per cell, to produce "these bytes are zero".  Blanking the row's
  bitmap, attribute cells and buffer directly is the same work the scroll path
  already did (`_blank_row_direct`), and it took `clear` from 2,884,815 to
  254,213 T-states per call and `erase` from 125,002 to 15,396 per row.
  Both are now faster than Locomotive.
- **Paging is the one phase still behind.**  Locomotive's flip costs about
  18,000 T-states; ours about 1,855,000.  A flip here shifts 24 rows x 8 scan
  lines of bitmap, stamps a whole attribute row, mirrors the window into
  `char_buffer` and re-renders the newly exposed columns one glyph at a time
  (29 cells x 24 rows at 51 columns).  At 4227 T-states per glyph that
  re-render alone is about 2.9 million T-states, so Locomotive is evidently
  not re-rendering 696 glyphs per flip.  Matching it needs the exposed strip
  drawn from the logical buffer without a full per-glyph render pass; that is
  the next piece of work, and the benchmark is now in place to prove a change
  helps.

## Three compatibility bugs it found

Building the benchmark turned up three places where this system disagreed with
the +3 manual and with Locomotive.  All three are fixed.

1. **`ESC 5 n` polarity was inverted.**  The manual (Appendix III) defines
   `0` = enable automatic paging and `1` = disable.  This system read it the
   other way round, so software that turned paging on silently turned it off.
   `src/test/termtest.asm` now checks the documented polarity.
2. **`ESC 3 2` did not clear when already in 24x80.**  `_enter80` returned
   immediately if `mode80` was already set, so re-entering 24x80 to reset the
   logical screen (which is how software refreshes it) left the old contents
   and the old window offset in place.  It now always clears, and keeps
   `lg_savecols` intact across a re-entry.
3. **A page flip triggered on cursor motion.**  This system re-pages when the
   cursor moves outside the window; Locomotive pages when a character is
   *written* past it.  Phase 8 of the benchmark writes the extra character so
   both do the same work.

## Adding a phase

Add a `begin_N` / `end_N` marker pair (and the phase body) to
`src/test/screenbm.asm`, add it to `phase_table` and `run_all`, then add the
matching entry to `PHASES` and `PHASE_OPS` in `tools/screen_bench.py`.  The
harness reads the marker values, not addresses, so no listing maintenance is
needed beyond keeping the numbers in step.
