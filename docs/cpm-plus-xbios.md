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

## Important: the inline word is a jumpblock entry address

The real +3 extended BIOS jumpblock lives in bank 0 at `0x0080-0x00EC`.
`USERF` takes the address of one of those entries as its inline parameter:

```asm
        ld   hl, argument       ; not the function address
        call userf_entry
        dw   0x00BF             ; extended jumpblock entry "TE ASK"
```

The current stub reads only the **low byte** of that inline word, so the
dispatch key is `0x00..0xFF`; the high byte is ignored.  The documented
TE entries are `0x00BF` (`TE_ASK`), `0x00C2` (`TE_RESET`), `0x00C5`
(`TE_STL_ASK`), `0x00C8` (`TE_STL_ON_OFF`), `0x00CB` (`TE_SET_INK`),
`0x00CE` (`TE_SET_BORDER`), `0x00D1` (`TE_SET_SPEED`) and `0x00E9`
(`SCR_RUN_ROUTINE`).  `XTETEST.COM` uses those values.

## Supported function IDs

| ID | Name | Input | Output |
|----|------|-------|--------|
| `0x98` | `DD_DRIVE_STATUS` | C = unit (bits 1-0), head (bit 2) | A = ST3.  Unit 0 returns `0x30` (Ready + Track 0 + unit 0); other units return `0x01` (not fitted). |
| `0xBF` | `TE_ASK` | - | B = viewport top row, C = viewport left column, D = height - 1, E = width - 1, H = cursor row, L = cursor column.  The viewport is always the full screen, so B = C = 0, D = 23 and E = current columns - 1. |
| `0xC2` | `TE_RESET` | - | Re-initialise the terminal emulator: restore the default white-on-blue palette, wrapping and page mode, clear the screen and home the cursor.  The current screen width is kept. |
| `0xC5` | `TE_STL_ASK` | - | A = 0, Z set.  Status line is always off. |
| `0xC8` | `TE_STL_ON_OFF` | - | Swallowed; returns with A unchanged and Z set. |
| `0xCB` | `TE_SET_INK` | A = ink (0 = background/border, 1 = foreground), B = colour, C = flash colour | Sets the colours used by future characters.  Colour is 0-63: bits 0-1 blue, 2-3 red, 4-5 green, each pair `00` off, `01`/`10` normal, `11` high.  The cell is bright only when both inks are high.  If `C & 0x3F` differs from `B & 0x3F` the ink flashes; the hardware FLASH attribute is set only when both inks flash.  Inks above 1 are ignored. |
| `0xE3` | `CD_VERSION` | - | A = 3 (machine type), BC = `0x0100` (version 1.0). |
| `0xE6` | `CD_INFO` | - | A = 0, B = 8 (16K banks), C = 0 (no serial), D = 0 (no B: drive), E = `0x15` (SS 40-track 3-inch), HL = empty buffer table (`0xFF`). |
| other | - | - | A = `0xFF` (unknown). |

## Not implemented

The following +3 TE operations have no handler yet:

- `TE_SET_BORDER` (`0x00CE`)
- `TE_SET_SPEED` (`0x00D1`)
- `SCR_RUN_ROUTINE` (`0x00E9`)

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
