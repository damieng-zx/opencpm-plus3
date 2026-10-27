# XBIOS / TE Interface

This project implements a small subset of the Amstrad +3 XBIOS terminal
extensions.  The entry point is **BIOS function 30 (`USERF`)**.  Unlike a
normal BIOS call, `USERF` takes its function identifier from a 16-bit word
placed immediately after the `CALL`:

```asm
        ld   hl, function_id
        call userf_entry          ; BIOS jump-table entry 30
        dw   function_id
```

`userf_stub` (common memory) replaces the return address with the address
after the inline word, then dispatches to `xbios_handler` in bank 4.  The
caller's `HL` is preserved as an input/output register.

## Important: function IDs are bytes, not +3 addresses

The current stub reads only the **low byte** of the inline word.  The
identifier is therefore `0x00..0xFF`; the high byte is ignored.

The real +3 XBIOS jump table lives at bank 0 `0x0080-0x00EC`, and the
`TE_*` symbols used by `XTETEST.COM` (`0x0883`, `0x0894`, `0x08B5`,
`0x08B7`, `0x08B8`, `0x08F9`, `0x0905`, `0x0906`) are **addresses in that
table**, not inline IDs.  This implementation does not provide that jump
table, so `XTETEST` currently exercises the low-byte/unknown-ID path for
most of those calls.  Use the IDs below for new code.

## Supported function IDs

| ID | Name | Input | Output |
|----|------|-------|--------|
| `0x98` | `DD_DRIVE_STATUS` | C = unit (bits 1-0), head (bit 2) | A = ST3.  Unit 0 returns `0x30` (Ready + Track 0 + unit 0); other units return `0x01` (not fitted). |
| `0xC5` | `TE_STL_ASK` | - | A = 0, Z set.  Status line is always off. |
| `0xC8` | `TE_STL_ON_OFF` | - | Swallowed; returns with A unchanged and Z set. |
| `0xE3` | `CD_VERSION` | - | A = 3 (machine type), BC = `0x0100` (version 1.0). |
| `0xE6` | `CD_INFO` | - | A = 0, B = 8 (16K banks), C = 0 (no serial), D = 0 (no B: drive), E = `0x15` (SS 40-track 3-inch), HL = empty buffer table (`0xFF`). |
| other | - | - | A = `0xFF` (unknown). |

## Not implemented

The following +3 TE operations have no handler yet:

- `TE_ASK` (`0x0883`) - query the text window
- `TE_RESET` (`0x0894`) - reset the terminal
- `TE_SET_INK` (`0x08B8`)
- `TE_SET_BORDER` (`0x08F9`)
- `TE_SET_SPEED` (`0x0905`)
- `SCR_RUN_ROUTINE` (`0x0906`)

Screen control is available through the normal BIOS console/scroll
functions and the VT52-style escape sequences documented in
[API.md](API.md#6-terminal-screen--keyboard).  `XTETEST.COM` remains a
hardware-probe utility; its printed `OK` lines do not currently mean the
corresponding TE call was implemented.

## Calling from a .COM program

The visible `USERF` entry is at `bios_visible + 3*30`.  Compute
`bios_visible` from the WBOOT vector at 0001h (`bios_visible = word[0001] -
3`), place the function word immediately after the `CALL`, and preserve
`HL` if you need it as an input.  `src/test/xtetest.asm` contains a complete
trampoline that patches the `CALL` target at runtime.
