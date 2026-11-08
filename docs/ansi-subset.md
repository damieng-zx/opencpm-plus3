# ANSI / VT-100 output subset

The +3 console already speaks the VT-52 and ADM-3A/Kaypro sequences in
[API.md](API.md#escape-sequences-vt52-compatible-subset-plus-adm-3akaypro-codes).
This document covers the extra `ESC [` (CSI) subset used by programs such as
SuperCalc2.  It is deliberately **output-only** and deliberately small; it is
not a full VT-100 terminal.

The parser understands decimal parameters separated by `;`, an optional
leading `?` for private modes, and a final byte in `40h..7Eh`.  Up to six
numeric parameters are kept.  Missing or empty parameters are treated as the
ANSI default in each handler; unsupported finals are consumed silently rather
than printed as text.

Because there is no serial port and the keyboard is a CP/M keyboard, the
following are **not** emulated: cursor-key/application-keypad input,
device-status reports (`DSR`), insert/delete line or character, scroll
regions, and 132-column mode.  `ESC [ ? 3 h/l` (DECCOLM) is accepted and
ignored; the logical width stays 51, 64 or 80 columns.

**Not yet implemented:** SGR (`ESC [ ... m`, so reverse/bold/blink are
currently consumed and ignored) and the private autowrap modes
(`ESC [ ? 7 h/l`).  The bank-4 head has about 820 bytes of slack (see
`docs/boot.md`, *Image headroom*); bank 5 free RAM and the RST slots are
the next sources if SGR needs more.

The runtime checks live in `tools/zx84_ansi.py`; they type the sequences at
the CCP prompt (whose line editor echoes through the normal console output
path) and inspect the character buffer or cursor state.



## Implemented

| Sequence | Meaning | Notes |
|---|---|---|
| `ESC [ row ; col H` | CUP | 1-based; defaults 1,1; 0 means 1; row clamps to the viewport height and column to the logical width (80 in 24x80 mode). |
| `ESC [ row ; col f` | HVP | Same handler as CUP. |
| `ESC [ H` | Home | CUP with no parameters. |
| `ESC [ n A` | CUU | Cursor up; default/0 count is 1; stops at row 0. |
| `ESC [ n B` | CUD | Cursor down; clamps to the last viewport row. |
| `ESC [ n C` | CUF | Cursor forward; clamps to the logical width minus 1. |
| `ESC [ n D` | CUB | Cursor back; stops at column 0. |
| `ESC [ n J` | ED | 0/default = cursor to end, 1 = start to cursor, 2 = whole viewport; reuses the VT-52 erases. |
| `ESC [ n K` | EL | 0/default = cursor to end of line, 1 = start to cursor, 2 = whole line; reuses the VT-52 erases. |
| `ESC [ s` | DECSC | Save cursor, same slot as `ESC j`. |
| `ESC [ u` | DECRC | Restore cursor, same slot as `ESC k`. |

## Test coverage

`tools/zx84_ansi.py` currently checks CUP at an interior cell, HVP, the
bottom-right clamp (23,50 at 51 columns), home, `0;0` defaulting to 1,1,
each relative movement including its top/bottom/left/right clamp, all three
ED and EL modes, and cursor save/restore.
`tests/test_terminal.py` checks the parser wiring and that the handlers use
`vp_height` and `_lg_width` and reuse the VT-52 erase/cursor handlers.

The screen colour/maths helpers (`_decode_colour`, `_decode_te_colour`,
`_set_attr`, `_mul80`, `_lg_width`, `_cancel_paging`) live in the common
stub, which keeps the bank-4 head above its 256-byte growth margin as the
CSI code grows.
