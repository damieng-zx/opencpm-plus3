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
| `0x80` | `DD_INIT` | - | Reset the disc driver to defaults and turn the motor off. |
| `0x83` | `DD_SETUP` | HL = 7-byte parameter block in common memory | Applies the motor-off timeout (100 ms units, 0 = never) and sends the uPD765A SPECIFY command with the step/head timings.  The motor-on timeout and write-current-off time are stored in the block but not otherwise used. |
| `0x86` | `DD_READ_SECTOR` | B = CP/M bank, C = unit, D = logical track, E = logical sector, HL = destination, IX = XDPB | Reads one 512-byte sector.  Carry set OK; carry clear + A = error.  Only bank 1 (TPA) is accepted. |
| `0x89` | `DD_WRITE` | B = CP/M bank, C = unit, D = logical track, E = logical sector, HL = source, IX = XDPB | Writes one 512-byte sector.  Carry set OK; carry clear + A = error (1 = write protected).  Only bank 1 (TPA) is accepted. |
| `0x8C` | `DD_CHECK_SECTOR` | B = CP/M bank, C = unit, D = logical track, E = logical sector, HL = compare buffer, IX = XDPB | Reads the sector and compares it with the buffer.  Carry set + Z set if equal, carry set + Z clear if different, carry clear + A = error. |
| `0x8F` | `DD_FORMAT` | B = CP/M bank, C = unit, D = logical track, E = filler, HL = header table (track, head, sector, size), IX = XDPB | Formats one track with the uPD765A FORMAT TRACK command.  Carry set OK; carry clear + A = error.  Only bank 1 (TPA) is accepted. |
| `0x92` | `DD_LOGIN` | C = unit, IX = destination XDPB in common memory | Re-detects the format, copies the XDPB, and returns carry set + A = disc type, DE = ALV size, HL = hash-table size; carry clear + A = error. |
| `0x95` | `DD_SEL_FORMAT` | A = format 0-3, IX = destination XDPB in common memory | Carry set + A = format, or carry clear + A = 6 (bad format).  Loads one of the four standard XDPB templates. |
| `0x98` | `DD_DRIVE_STATUS` | C = unit (bits 1-0), head (bit 2) | A = ST3.  Unit 0 returns `0x30` (Ready + Track 0 + unit 0); other units return `0x01` (not fitted). |
| `0x9B` | `DD_READ_ID` | C = unit, D = logical track, IX = XDPB | Carry set + A = sector number, or carry clear + A = error (0 not ready, 2 seek, 3 data, 5 missing address mark); HL = `dd_results` (count + ST0 ST1 ST2 C H R N). |
| `0x9E` | `DD_L_DPB` | HL = 10-byte disc spec in common memory, IX = destination 17-byte DPB | Builds a standard DPB from the spec.  Carry set + A = disc type, or carry clear + A = 6 (bad format). |
| `0xA1` | `DD_L_XDPB` | HL = 10-byte disc spec in common memory, IX = destination 27-byte XDPB | Builds a standard XDPB (DPB plus Amstrad geometry extension) from the spec.  Carry set + A = disc type, or carry clear + A = 6 (bad format). |
| `0xA4` | `DD_L_ON_MOTOR` | - | Turn the motor on and wait for spin-up.  All registers and flags preserved. |
| `0xA7` | `DD_L_T_OFF_MOTOR` | - | Arm the motor-off timeout (about one second).  All registers and flags preserved. |
| `0xAA` | `DD_OFF_MOTOR` | - | Turn the motor off immediately. |
| `0xAD` | `DD_L_READ` | HL = parameter block in common memory: bank, buffer, byte count, command count, command bytes | Raw uPD765A read-type command driver: sends the command bytes, reads the data phase into the buffer and returns the result bytes in `dd_results`.  Only CP/M bank 1 (TPA) is supported. |
| `0xB0` | `DD_L_WRITE` | HL = parameter block in common memory: bank, buffer, byte count, command count, command bytes | Raw uPD765A write-type command driver: sends the command bytes, writes the data phase from the buffer and returns the result bytes.  Only CP/M bank 1 (TPA) is supported. |
| `0xB3` | `DD_L_SEEK` | C = unit (bits 0-1) + head (bit 2), D = physical track, IX = XDPB | Carry set on success, or carry clear + A = 0 (not ready) / 2 (seek fail).  The motor must already be running. |
| `0xBF` | `TE_ASK` | - | B = viewport top row, C = viewport left column, D = height - 1, E = width - 1, H = cursor row, L = cursor column.  The viewport is always the full screen, so B = C = 0, D = 23 and E = current columns - 1. |
| `0xC2` | `TE_RESET` | - | Re-initialise the terminal emulator: restore the default white-on-blue palette, wrapping and page mode, clear the screen and home the cursor.  The current screen width is kept. |
| `0xC5` | `TE_STL_ASK` | - | A = 0, Z set.  Status line is always off. |
| `0xC8` | `TE_STL_ON_OFF` | A = enable/disable | Accepted and ignored; returns with Z set. |
| `0xCB` | `TE_SET_INK` | A = ink (0 = background/border, 1 = foreground), B = colour, C = flash colour | Sets the colours used by future characters.  Colour is 0-63: bits 0-1 blue, 2-3 red, 4-5 green, each pair `00` off, `01`/`10` normal, `11` high.  The cell is bright only when both inks are high.  If `C & 0x3F` differs from `B & 0x3F` the ink flashes; the hardware FLASH attribute is set only when both inks flash.  Inks above 1 are ignored. |
| `0xCE` | `TE_SET_BORDER` | B = colour (0-63) | Sets the border colour using the same encoding as `TE_SET_INK`; the bright and flash bits are ignored.  `TE_SET_INK` ink 0 also changes the border. |
| `0xD1` | `TE_SET_SPEED` | H = main flash time, L = alternate (50ths) | Accepted and ignored: the +3 flashes in hardware with a fixed rate. |
| `0xD7` | `KM_SET_KEY` | B = new translation, C = key number (0-39), D = table mask (bit 0 normal, 1 CAPS, 2 SYMB, 3 EXTEND) | Writes the translation into the 40-key × 4-shift override table in bank 6.  Invalid key numbers or a zero mask are ignored.  A translation of `0xFF` restores the built-in mapping.  AF and HL corrupt; all other registers preserved. |
| `0xDA` | `KM_KT_GET` | - | Removes the oldest key token.  Carry set + B = shift state + C = key number, or carry clear + B = current lock state (C undefined).  The token's lock bits (3-6) update the reported lock state. |
| `0xDD` | `KM_KT_PUT` | B = shift state, C = key number | Appends a key token to the 16-entry token queue (silently dropped when full).  All registers and flags preserved. |
| `0xE0` | `KM_SET_SPEED` | H = start-up delay, L = repeat speed (50 Hz scans; 0 = 256) | Sets the keyboard repeat timings.  AF corrupt; all other registers preserved. |
| `0xE3` | `CD_VERSION` | - | A = 3 (machine type), BC = `0x0100` (version 1.0). |
| `0xE6` | `CD_INFO` | - | A = 0, B = 8 (16K banks), C = 0 (no serial), D = 0 (no B: drive), E = `0x15` (SS 40-track 3-inch), HL = empty buffer table (`0xFF`). |
| `0xE9` | `SCR_RUN_ROUTINE` | BC = routine address, DE/HL/IX/IY = arguments | Runs the routine with the screen (bank 5) paged in at 4000h.  Returns AF/DE/HL/IX/IY as the routine left them and BC corrupt.  The routine must live in common memory (`C000-F5FF`) and must not call BDOS/BIOS: those switch back to TPA/system mode and page the screen out. |
| other | - | - | A = `0xFF` (unknown). |

## Not implemented / limitations

All six documented TE operations (`TE_ASK`, `TE_RESET`, `TE_SET_INK`,
`TE_SET_BORDER`, `TE_SET_SPEED` and `SCR_RUN_ROUTINE`) have handlers, and
the disc calls above are implemented: phase 1 (`DD_INIT`, `DD_SETUP`,
`DD_SEL_FORMAT`, `DD_READ_ID`, `DD_L_ON_MOTOR`, `DD_L_T_OFF_MOTOR`,
`DD_OFF_MOTOR`, `DD_L_SEEK`) and phase 2 (`DD_LOGIN`, `DD_READ_SECTOR`,
`DD_WRITE`, `DD_CHECK_SECTOR`, `DD_FORMAT`, `DD_L_DPB`, `DD_L_XDPB`,
`DD_L_READ`, `DD_L_WRITE`).

Still unimplemented: the serial calls (`CD_SA_*`), `KM_SET_EXPAND` and
`FIND_FID`.  Unknown IDs return `A = 0xFF`.

`DD_READ_SECTOR`, `DD_WRITE`, `DD_CHECK_SECTOR` and `DD_FORMAT` currently
accept only CP/M bank 1 (the TPA); other bank numbers return `A = 9`.
`DD_FORMAT` uses the XDPB's physical sector count, `PSH` size code and
format gap, and is destructive by definition.  `DD_LOGIN`'s probe falls
back to the standard type-0 template if the READ ID/boot-sector read
fails, so it does not yet propagate the 0/2/3/4/5 login error codes.

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
`5AFFh`); later screen scrolling carries it elsewhere in the attribute
plane, so the smoke runner searches all of `5800h`-`5AFFh`.  `8.DISK` runs the phase-1 disc calls and verifies the standard
XDPB template, the motor/seek path and the `DD_READ_ID` result buffer.
`9.RW` exercises `DD_LOGIN`, `DD_READ_SECTOR`, `DD_WRITE` and
`DD_CHECK_SECTOR` against the boot sector (writing the same data back).
`10.FMT` is an optional destructive `DD_FORMAT` test: it runs only when
the harness sets the `DC00h` magic byte, formats track 39 and checks the
`0xE5` fill.  The smoke runner does this on a scratch image.  Tests 11-18
cover `DD_SETUP`, `DD_L_DPB`, `DD_L_XDPB`, `DD_L_READ`, `DD_L_WRITE`,
`KM_SET_SPEED`, `KM_KT_PUT` and `KM_KT_GET`.  Test 19 remaps the Z key to
`Q` with `KM_SET_KEY` and waits for the harness to press Z, so the whole
scanner-to-ASCII path is exercised end to end.

## Calling from a .COM program

The visible `USERF` entry is at `bios_visible + 3*30`.  Compute
`bios_visible` from the WBOOT vector at 0001h (`bios_visible = word[0001] -
3`) and place the jumpblock entry word immediately after the `CALL`.  `HL`,
`IX` and `IY` are passed through to the handler; preserve them if you use
them as arguments.  `src/test/xtetest.asm` contains a complete trampoline
that patches the `CALL` target at runtime.
