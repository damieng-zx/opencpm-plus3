# Boot, Paging & Common Memory — Quick Reference

A human-friendly map of how Open CP/M +3 gets from "ROM hands us PC=FE10" to
"CCP prompt at A>". Every time something breaks, check the labels and stage
boundaries here first. Source files referenced inline.

---

## 1. Banking modes (port `0x1FFD`)

The +3 has four 16K slots: `0000-3FFF`, `4000-7FFF`, `8000-BFFF`, `C000-FFFF`.
"Special paging" (1FFD bit 0 = 1, bits 2:1 = mode) selects a fixed bank quartet.
Bit 3 is the disk motor — we OR it in via `motor_flag` on every write.

| Mode | 1FFD val | 0000-3FFF | 4000-7FFF | 8000-BFFF | C000-FFFF | Used for |
|------|----------|-----------|-----------|-----------|-----------|----------|
| 0    | `0x01`   | bank 0    | bank 1    | bank 2    | **bank 3** | TPA — user/CCP code runs here |
| 2    | `0x05`   | bank 4    | bank 5    | bank 6    | **bank 3** | Boot loader; screen RAM access |
| 3    | `0x07`   | bank 4    | bank 7    | bank 6    | **bank 3** | System — BIOS, BDOS, drivers |

**Bank 3 (`C000-FFFF`) is always mapped.** That's why every page-switching
helper, the BDOS dispatcher, the ISR, FCB buffers, and the BDOS stack live in
bank 3 at `F600-FFFF` (the "common memory stub"). If you put writable code or
data anywhere else and try to bank-switch, you lose access mid-instruction.

`BANK0_1FFD = 0x01`, `BANK1_1FFD = 0x07`, `MOTOR_BIT = 0x08` — see
`src/bios/bios.zpa`.

---

## 2. Boot sequence — stage by stage

```
ROM ──> boot sector ──> loader ──> CPM3.SYS init ──> cold_boot ──> warm_boot ──> CCP
       (FE00, 512B)    (0000)     (C000)            (bank 4)      (bank 4)     (TPA)
```

### Stage 0 — +3 ROM

`DOS_BOOT` reads logical sector 0 (512 bytes), checks `sum mod 256 == 3`, copies
it to `0xFE00` in **mode 2** (banks 4-5-6-3), and jumps to `0xFE10`. PC=FE10,
DI not yet asserted.

### Stage 1 — boot sector (`src/boot/bootsect.asm`)

- `org 0xFE00`. Bytes 0-15 are a header. Entry at `0xFE10`.
- `di`; `ld sp, 0xFE00`; turn motor on (`1FFD = 0x0D` = mode 2 + motor).
- Reads track 0 sectors 2-9 (4KB) into `0x0000` via direct uPD765A I/O.
- `jp 0x0000`.

### Stage 2 — loader (`src/boot/loader.asm`)

- `org 0x0000`. Still in mode 2. Stack moved to `BIOS_ADDR = 0xC000` so a
  16K system image padded to FE00 doesn't trample the loader's stack.
- Seeks track 1 (OFF=1), scans the directory (sectors 1-4) for `CPM3    SYS`.
- Walks the matched directory entry's allocation map (16 block pointers, 1K
  each = 2 physical sectors), loading each block to `BIOS_ADDR` and bumping.
- `jp BIOS_ADDR` (= `0xC000`).

The system image lands in **bank 3** at `C000-FFFF` because that's what mode 2
maps there.

### Stage 3 — CPM3.SYS init (`src/bios/bios.zpa`)

Runs at `C000` in bank 3. **One-shot setup** — its job is to relocate the
real code into the right banks before jumping into bank 4.

```
   C000 --init--+
                +--> LDIR     system_image   --> 0000 (bank 4 @ 0000-3FFF, mode 2)
                +--> LDIR/LDDR common_image  --> F600 (bank 3)
                +--> jp cold_boot              (bank 4)
```

The system-image copy must happen before installing common. `CPM3.SYS` is
loaded in bank 3 at `C000-FFFF`; with `COMMON_BASE=F600`, the common-memory
destination overlaps the physical source bytes for the tail of `system_image`.
Copying common first corrupts the bytes that are later relocated into bank 4,
usually showing up as no `A>` prompt or BDOS walking through SCB-looking data.

Direction of the common-memory copy is still decided at assembly time (`IF
common_image < COMMON_BASE` -> LDDR else LDIR) so the common copy itself does
not clobber overlapping source/destination ranges. The system-image copy uses
LDIR with an assert that `system_image >= 0x0000 + size` — i.e. source is above
destination.

After init, **bank 3 still holds the rest of the loaded CPM3.SYS image from
C000 up to the image end (~F28x for a 12.9K image), but nothing references it
again** — it's just whatever the loader deposited there. Common memory at
F600+ is the live copy.

### Stage 4 — `cold_boot` (`src/bios/bios.zpa`, runs in bank 4)

```
di
ld sp, bdos_stack       ; common-memory stack (F600+ region)
call scr_init           ; clear screen, set attrs
call kbd_init           ; reset keyboard state
call fdc_init           ; recalibrate FDC
call load_fonts         ; scan directory; pull FONT51/FONT32 into bank 6
call load_ccp           ; read CCP.COM into bank 6 at B000 (staged)
call load_fid           ; optional: register C: ramdisk if RAMDISK.FID present
call motor_off          ; spin down before CCP
print signon
halt with a diagnostic if CCP.COM was not found
patch SCB:              scb_common = scb_base; scb_tpa = bdos_stub
install ISR vector at 0x0038 (system bank's bank 4 page zero)
fall through ──> warm_boot
```

### Stage 5 — `warm_boot` (`src/bios/bios.zpa`)

```
di
ld sp, bdos_stack
copy_block_to_tpa(CCP_STAGE ──> 0x0100, _ccp_len)
                                ; cross-bank copy: bank 6 → bank 0
                                ; (staged by load_ccp; no disk access here)
ld (disk_dma), 0x0080
clear xmove_active, dma_bank, multi_count
jp start_tpa            ; in common memory — never returns
```

### Stage 6 — `start_tpa` (`src/bios/common.zpa`)

Runs in common memory because it switches *out* of bank 4.

```
1FFD ←── motor_flag | BANK0_1FFD     ; mode 0 (TPA banks)
0000: JP bios_visible+3              ; WBOOT vector — programs read 0001
0005: JP bdos_stub                   ; BDOS vector — programs read 0006
0038: JP isr_handler                ; common tick/motor ISR (Mallard may override)
im 1; ei
jp 0x0100                            ; CCP entry
```

That's the boot. From this point, the CPU is running in mode 0 with the CCP
mapped at `0x0100`, and only the `F600-FFFF` common stub bridges it back to
bank 4 when the user calls BDOS or BIOS.

---

## 3. Memory map after boot

### Mode 0 (TPA — what user programs see)

| Range       | Contents                                                  |
|-------------|-----------------------------------------------------------|
| `0000-00FF` | Page zero. JP at 0000 → WBOOT, JP at 0005 → bdos_stub.    |
| `0100-`     | CCP (copied from the bank-6 staging area on every boot).  |
| up to TPA top | TPA proper — programs load and run here.                |
| `F600-F5FF`*  | (bank 3, always visible) — common stub starts at F600.  |
| `F600-FFFF` | SCB, bios_visible jump table, **bdos_stub**, BDOS stack, FCB buf, dirbuf, drive table, XDPHs/XDPBs. |

`TPA_TOP = 0xF600` (`COMMON_BASE`) is the published top-of-TPA and the
initial SP. The stack grows down from F600 into the TPA, so everything in
common memory (F600 and above) is safe.

Page zero 0005h jumps to `bdos_vector` at F600 and the word at 0006h is
that same address. CP/M 3 programs use `(0006h)` as their memory ceiling
(WordStar, MBASIC and Turbo Pascal all do), so it must be the TPA top and
not `bdos_stub` (F737), which would let them overwrite the BIOS jump table
and trampolines. `scb_tpa` is patched to `TPA_TOP` too.

### Mode 3 (System — BDOS/BIOS bank)

| Range       | Contents                                                  |
|-------------|-----------------------------------------------------------|
| `0000-3FFF` | Bank 4. BIOS jump table at 0000, then state, drivers, font/CCP/FID loaders, BDOS. Asserted ≤ 16K (`system_end <= 0x4000`). |
| `0038`      | ISR vector — JP isr_handler (in common memory).           |
| `4000-7FFF` | Bank 7. C: RAM disk (16K) when RAMDISK.FID is loaded.     |
| `8000-BFFF` | Bank 6. FONT51 at `8000`, FONT32 at `8800`, RAMDISK.FID at `9000` if loaded, FONT64 at `9400`, FDC deblock buffer at `9C00`, `DD_CHECK_SECTOR` compare buffer at `9E00`; text/scroll buffers at `A000-A5FF`; BIOS/BDOS scratch at `A600-A6FF` and `A82D-A83C`; screen cursor/ESC scratch at `A730-A739`; row table at `A700`, CSV/ALV at `A740-A82C`; `KM_SET_KEY` translation table at
`A900-A99F`, `KM_SET_EXPAND` slots at `A9A0-AD7F`, FCB shadow at `AD80-ADA3`; staged `CCP.COM` at
`B000-BFFF`. |
| `F600-FFFF` | Common stub (bank 3). Same content as in mode 0 — that's the point. |

---

## 4. Common memory layout (bank 3, `F600-FFFF`)

This is the most fragile region. **Order matters.** The TPA stack grows down
from `TPA_TOP` (F600) into the TPA, so the common stub must start at F600 and
must not place anything below it. Source: `src/bios/common.zpa`.

```
F600  scb_base            ┐
F600  jp bdos_stub        │  bdos_vector (page zero 0006h)
F603  ds 2                │  (rest of the 5 reserved SCB bytes)
F605  scb_version (0x31)  │
F61A  scb_conwidth        │  100-byte SCB
F634  scb_tempdrv         │  (offsets are publicly documented;
F63A  scb_common ←patch   │   programs read these directly)
F63C  scb_dma  (=0x0080)  │
F644  scb_user            │
F662  scb_tpa  ←patch     │
F664  ───────────────────┘
      bios_visible        ┐
      33 × 3 = 99 bytes   │  Visible BIOS jump table.
      (entry 1 = WBOOT)   │  Programs derive BIOS base from word at 0001.
      ────────────────────┘
      bv_tramp (84 B)        Trampoline — 28 × `call bv_shim`.
      bv_shim                Recovers fn# from return addr → bios_call_bank4.
      ────────────────────
      bdos_stub  ◄═══════════ BDOS entry (JP from 0x0005 lands here).
      ────────────────────    TPA_TOP = F600 is above the SCB; the TPA stack
                              grows DOWN from F600, so every label in this
                              diagram is outside the stack's path.
      saved_sp, motor_flag, motor_countdown, fdc_busy, last_1ffd,
      isr_tick, isr_frac, isr_installed
      bios_call_bank4 + trampoline stack (_bc4_stack)
      userf_stub             XBIOS fn 30 dispatcher
      write_1ffd             1FFD writer + last_1ffd shadow
      warm_boot_stub         Entry from JP 0x0000
      isr_handler            IM 1 ISR (motor-off, tick, BCD time)
      start_tpa              Mode 0 + page zero setup + jp CCP
      bank_sel               BIOS fn 27
      setup_fcb / writeback_fcb
      read_user_byte / write_user_byte
      copy_from_user / copy_to_user                 (chunked staging)
      copy_record_to_tpa / copy_record_from_tpa     ◄ pinned addresses
      copy_block_to_tpa
      interbank_move         BIOS fn 25/29 path
      drive_table            16 × DPH ptr (A:, B:, C:, ...)
      XDPH prefixes + xdph_a, xdph_b, xdph_c
      xdpb_a, xdpb_b, xdpb_c (27 bytes each)
      dirbuf       (128 B)   FDC deblock destination, BDOS dir buffer
      fcb_user_addr (2 B)    (fcb_buf itself is in bank 6 at AD80h)
      xfer_staging ( 32 B)   bank-switching staging buffer
      ccp_fcb      ( 36 B)   CCP COM-loader FCB (pinned in miniccp.zpa)
      bdos_stack_base
      bdos_stack equ bdos_stack_base + 128   ◄ SP loads point HERE (top)
      f40_zero equ bdos_stack                ◄ 128-byte zero record
      xbios_arg_a / xbios_arg_af / xbios_ret_ix / xbios_ret_iy /
      xbios_tmp_hl / dd_results / dd_format_hdr
                                             USERF, TE and disc state
FFFF  ────────────────────  hard limit (assert common_end <= 0xFFFF)
```

### Pinned addresses (don't move these without coordinated changes)

| Address  | What                          | Why pinned                                                       |
|----------|-------------------------------|------------------------------------------------------------------|
| `0xF9BF` | `copy_record_to_tpa`          | RAMDISK.FID hardcodes it; assert at common.zpa.              |
| `0xF9C5` | `copy_record_from_tpa`        | Same - assert at common.zpa.                                 |
| `0xFB66` | `ccp_fcb`                     | miniccp.zpa `CCP_FCB_ADDR`; assert at common.zpa.            |
| `bdos_vector` (F600) | itself            | Page zero 0005h/0006h target; (0006h) is the TPA memory ceiling. |
| SCB offsets `0x05, 0x1A, 0x3A, 0x3C, 0x3E, 0x44, 0x58-0x5C, 0x62` | DRI documented | Programs index off scb_base.    |

If common memory grows past these offsets, FID modules break with no error
message — just silent garbage on disk I/O. The asserts are your tripwire.

---

## 5. Stacks — three of them

| Stack             | Lives in          | Used when                                         | Loaded with                       |
|-------------------|-------------------|---------------------------------------------------|------------------------------------|
| Boot loader stack | (transient) FE00, then C000 | While loader.asm executes (stage 2)     | `ld sp, 0xC000`                   |
| TPA / user stack  | TPA (bank 0), grows down from `bdos_stub` | Whenever mode 0 is active   | Saved/restored as `saved_sp`     |
| BDOS stack        | Common memory (`bdos_stack`)              | Inside `bdos_stub`, `warm_boot_stub`, ISR, BIOS calls | `ld sp, bdos_stack` (top), 128 B |
| Trampoline stack  | Common (`_bc4_stack`)                     | The 6 pushes inside `bios_call_bank4` while it's actually flipping 1FFD | Hard-coded, 12 bytes |

**Why we need a separate trampoline stack:** the user's stack may be in bank 1
(`4000-7FFF`), which becomes bank 7 after switching to system mode. A push
mid-switch would land in the wrong physical RAM. The trampoline stack is in
bank 3 (always visible) so its content survives the switch.

The BDOS stack is also in common memory for the same reason — `bdos_stub` is
itself called from TPA mode and switches banks before invoking the real BDOS.
See the dance in `common.zpa`.

---

## 6. The BDOS dispatch — what happens at `CALL 0x0005`

```
TPA mode 0          common stub (bank 3)               system mode 3
─────────             ──────────────                    ────────────
JP bdos_stub  ────►   bdos_stub:
                        di
                        save SP → saved_sp
                        SP ← bdos_stack
                        push BC, DE                ; preserve fn,param
                        write_1ffd(motor|BANK1_1FFD) ; ─ now in mode 3
                        ei                                              ──►
                        pop DE, BC
                        call bdos_entry        ──►  real BDOS in bank 4 runs here
                                                    (fn handler, may call BIOS)
                                                                         ◄──
                        di
                        push HL, AF, BC                ; save return values
                        write_1ffd(motor|BANK0_1FFD)   ; ─ back to mode 0
                        pop BC, AF, HL
                        SP ← saved_sp
                        ei
                        ret  ────────────►  user
```

Important: the system bank's `0x0000` is the BIOS jump table (33 × `JP`), so
when bank 4 is mapped, address 0 gives you `JP cold_boot`. That's why the
TPA's page zero (in bank 0) has to be reconstructed each time we drop back —
luckily we don't, because mode 0 maps a *different* bank 0 with the JPs we
wrote in `start_tpa`.

---

## 7. Common breakage modes — what to look at first

| Symptom                                        | Most likely cause                                                         | Where to look |
|------------------------------------------------|---------------------------------------------------------------------------|---------------|
| Hang at red border immediately after ROM       | Stage 1 FDC read failed (motor not on, head load, sector mismatch)         | `bootsect.asm` |
| Red border after green flicker                 | Loader couldn't find `CPM3    SYS` in directory                            | `loader.asm:.dir_sector` |
| Loader runs, jump to C000, then hang           | CPM3.SYS image truncated or built without proper end pad                   | check `system_end <= 0x4000`, build/cpm3.sys size |
| Boots but garbage after first BDOS call        | Common stub didn't land at F600 (PHASE wrong / size mismatch)              | `bios.zpa`, `common_end` assert |
| RAMDISK.FID disk I/O reads garbage             | `copy_record_*_tpa` moved off pinned addrs                                 | asserts at `common.zpa` |
| TPA program crashes randomly                   | Writable var placed before `bdos_stub` in common; TPA stack overran it     | assert at `common.zpa`, `saved_sp > bdos_stub` |
| Hang on first SELDSK                           | XDPB Freeze byte stuck nonzero with stale geometry                         | `xdpb_a` byte 26, `fdc_login` |
| ISR fires but motor never spins down           | `fdc_busy` left non-zero by a driver path                                  | `isr_handler` motor-off block, `common.zpa` |
| Inter-bank `MOVE` returns wrong data           | xmove banks set with `xmove_active=0`, or copying with stale `_ibm_*_bank` | `bios_xmove`, `interbank_move` |
| Mallard BASIC hangs probing XBIOS              | Unknown XBIOS ID returns 0xFF; TE IDs are handled                           | `xbios_handler` in `bios.zpa` |
| `SCR_RUN_ROUTINE` does nothing or crashes      | Routine is outside common memory; screen mode pages the TPA out             | put the routine in `C000-F5FF` |

---

## 8. Where the labels actually live (one-line cheat sheet)

| Label                  | File                       | Notes                          |
|------------------------|----------------------------|--------------------------------|
| `boot_entry`           | `src/boot/bootsect.asm`    | ROM jumps here at FE10          |
| stage 2 entry (`org 0`)| `src/boot/loader.asm`      | Loaded by stage 1 to 0000       |
| `init`                 | `src/bios/bios.zpa`        | Runs at C000 once               |
| `cold_boot` / `warm_boot` | `src/bios/bios.zpa`     | Bank 4, after init relocates    |
| `bdos_stub`            | `src/bios/common.zpa`      | Top of TPA; published address   |
| `bios_visible`, `bv_tramp`, `bv_shim` | `src/bios/common.zpa` | BIOS dispatch in common      |
| `bios_call_bank4`      | `src/bios/common.zpa`      | The mode-3 / mode-0 dance       |
| `start_tpa`            | `src/bios/common.zpa`      | Final hop into the CCP          |
| `isr_handler`          | `src/bios/common.zpa`      | IM 1 vector body                |
| `bdos_entry`           | `src/bdos/bdos.zpa`        | Real BDOS, runs in bank 4       |
| `bdos_stack`           | `src/bios/common.zpa`      | 128 B at the top of common      |

Memory map dump after a build: `build/memory.map` (regenerated by
`tools/build_memory_map.py`).
