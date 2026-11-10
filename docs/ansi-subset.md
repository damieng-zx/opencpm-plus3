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

SGR is implemented to the extent the Spectrum attribute register allows.
There is one ink and one paper with a single BRIGHT bit and a single FLASH
bit for the whole cell, so "bold" brightens the cell rather than a single
colour, and reverse video is a swap of the stored pair.  Faint, underline,
italic, strike-through and the 256-colour/24-bit extended forms are
accepted and ignored.

`tools/zx84_ansi.py` covers all of it at run time; the bank-4 head has
about 2,100 bytes of slack (see `docs/boot.md`, *Image headroom*).  The
common stub is the tight region, with 25 bytes free, so no new helper was
put there: `_apply_attr` stays in bank 4 next to the CSI parser and only
calls the existing `_set_attr`.

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
| `ESC [ n m` | SGR | `0`/empty resets to white on blue and clears bold, blink and reverse; `1`/`22` set/clear bright; `5`/`25` set/clear flash; `7`/`27` set/clear reverse video; `30-37`/`90-97` ink, `40-47`/`100-107` paper (ANSI order, mapped to the Spectrum's GRB bits); `39`/`49` restore the default ink/paper. Several parameters apply in sequence (`1;31;47m`). `38`/`48` are recognised and the rest of the sequence is dropped, since there is no 256-colour or 24-bit palette. Faint, underline and 50-89/98-99 are ignored. |
| `ESC [ ? 7 h/l` | Autowrap | Sets/clears `scr_wrap`, exactly as `ESC v`/`ESC w` do: `h` wraps at the right edge, `l` overwrites the last column. |
| `ESC [ ? 3 h/l` | DECCOLM | Accepted and ignored; the column count is a mode choice. |
| `ESC [ ? 8 h/l` | Autorepeat | Accepted and ignored; key repeat is a BIOS setting. |

## Test coverage

`tools/zx84_ansi.py` currently checks CUP at an interior cell, HVP, the
bottom-right clamp (23,50 at 51 columns), home, `0;0` defaulting to 1,1,
each relative movement including its top/bottom/left/right clamp, all three
ED and EL modes, cursor save/restore, the SGR codes above against the
resulting `scr_attr` byte, and `?7 h/l` against the wrap flag and a
40-character line at 32 columns.
`tests/test_terminal.py` checks the parser wiring and that the handlers use
`vp_height` and `_lg_width` and reuse the VT-52 erase/cursor handlers, plus
the SGR parameter walk, the 38/48 cutoff, the ANSI-to-GRB colour table and
the reverse-video swap around `_set_attr`.

The screen colour/maths helpers (`_decode_colour`, `_decode_te_colour`,
`_set_attr`, `_mul80`, `_lg_width`, `_cancel_paging`) live in the common
stub, which keeps the bank-4 head above its 256-byte growth margin as the
CSI code grows.
