# XBIOS / TE Interface

This project implements the Amstrad +3 XBIOS terminal-emulator (TE)
extensions.  The entry point is **BIOS function 30 (`USERF`)**.  Unlike a
normal BIOS call, `USERF` takes the address of an extended-jumpblock entry
from a 16-bit word placed immediately after the `CALL`:

```asm
        ; TE_ASK takes no arguments
        call userf_entry          ; BIOS jump-table entry 30
        dw   0x00BF               ; extended jumpblock entry "TE ASK"
```

`userf_stub` (common memory) replaces the return address with the address
after the inline word, then dispatches to `xbios_handler` in bank 4.  The
caller's `HL`, `IX` and `IY` are passed through and returned; the TE
handlers document which of `AF`, `BC`, `DE` and `HL` they preserve.

## Important: the inline word is a jumpblock entry address

The real +3 extended BIOS jumpblock lives in bank 0 at `0x0080-0x00EC`.
`USERF` takes the address of one of those entries as its inline parameter:

```asm
        ; SCR_RUN_ROUTINE: BC = routine address, DE/HL/IX/IY = arguments
        ld   bc, routine
        ld   de, first_argument
        ld   hl, second_argument
        call userf_entry
        dw   0x00E9             ; extended jumpblock entry "SCR RUN ROUTINE"
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
| `0xC8` | `TE_STL_ON_OFF` | A = enable/disable | Accepted and ignored; returns with Z set. |
| `0xCB` | `TE_SET_INK` | A = ink (0 = background/border, 1 = foreground), B = colour, C = flash colour | Sets the colours used by future characters.  Colour is 0-63: bits 0-1 blue, 2-3 red, 4-5 green, each pair `00` off, `01`/`10` normal, `11` high.  The cell is bright only when both inks are high.  If `C & 0x3F` differs from `B & 0x3F` the ink flashes; the hardware FLASH attribute is set only when both inks flash.  Inks above 1 are ignored. |
| `0xCE` | `TE_SET_BORDER` | B = colour (0-63) | Sets the border colour using the same encoding as `TE_SET_INK`; the bright and flash bits are ignored.  `TE_SET_INK` ink 0 also changes the border. |
| `0xD1` | `TE_SET_SPEED` | H = main flash time, L = alternate (50ths) | Accepted and ignored: the +3 flashes in hardware with a fixed rate. |
| `0xE3` | `CD_VERSION` | - | A = 3 (machine type), BC = `0x0100` (version 1.0). |
| `0xE6` | `CD_INFO` | - | A = 0, B = 8 (16K banks), C = 0 (no serial), D = 0 (no B: drive), E = `0x15` (SS 40-track 3-inch), HL = empty buffer table (`0xFF`). |
| `0xE9` | `SCR_RUN_ROUTINE` | BC = routine address, DE/HL/IX/IY = arguments | Runs the routine with the screen (bank 5) paged in at 4000h.  Returns AF/DE/HL/IX/IY as the routine left them and BC corrupt.  The routine must live in common memory (`C000-F5FF`) and must not call BDOS/BIOS: those switch back to TPA/system mode and page the screen out. |
| other | - | - | A = `0xFF` (unknown). |

## Not implemented / limitations

All six documented TE operations (`TE_ASK`, `TE_RESET`, `TE_SET_INK`,
`TE_SET_BORDER`, `TE_SET_SPEED` and `SCR_RUN_ROUTINE`) have handlers.  The
remaining extended BIOS entries (`DD_*`, `CD_SA_*`, `KM_*`, `FIND_FID`)
are not implemented; unknown IDs return `A = 0xFF`.

`SCR_RUN_ROUTINE` only supports routines in common memory (`C000-F5FF`).
The +3 memory map used here pages bank 5 (the screen) over `4000-7FFF` in
screen mode, so the rest of the TPA is not visible while the routine runs.
Routines that call BDOS or BIOS also leave screen mode and will not see the
screen afterwards, so keep the routine a leaf.

Screen control is otherwise available through the normal BIOS console/scroll
functions and the VT52-style escape sequences documented in
[API.md](API.md#6-terminal-screen--keyboard).  `XTETEST.COM` exercises every
implemented TE call; `7.RUN` checks the `SCR_RUN_ROUTINE` register
round-trip and leaves `5Ah` in the bottom-right attribute cell (bank 5,
`5AFFh`).

## Calling from a .COM program

The visible `USERF` entry is at `bios_visible + 3*30`.  Compute
`bios_visible` from the WBOOT vector at 0001h (`bios_visible = word[0001] -
3`) and place the jumpblock entry word immediately after the `CALL`.  `HL`,
`IX` and `IY` are passed through to the handler; preserve them if you use
them as arguments.  `src/test/xtetest.asm` contains a complete trampoline
that patches the `CALL` target at runtime.
