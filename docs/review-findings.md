# Code Review Findings

Recorded from the full-project review. Issues 1–20 are tracked as the
"fix one per commit" set; P2 items are candidates for later.

Status: `[ ]` open, `[x]` fixed.

## P0 — Critical

- [x] **1. TPA stack top is above `COMMON_BASE`.**
  The CCP loader sets `SP = word at 0006h` (`bdos_stub`, F723) and
  `scb_tpa` is patched to `bdos_stub`.  The stack therefore grows down
  through `bv_shim` (F71B–F722), `bv_tramp`, `bios_visible`, and the SCB
  (F600–F663).  The first TPA `CALL 5` overwrites `bv_shim`'s final `JP`
  target.  `0006h` is the BDOS entry, not the TPA top.
  Files: `src/ccp/miniccp.zpa`, `src/bios/bios.zpa`, `src/bios/common.zpa`,
  `docs/API.md`, `docs/boot.md`.

- [x] **2. IM 1 ISR at 0038h overwrites BIOS jump-table entries 18/19.**
  `cold_boot` wrote a `JP` at 0038h; `fn_auxis`/`fn_auxos` used to start at
  0036h/0039h.  The bank-4 table now starts at `BIOS4_BASE=0040h`; the
  visible trampoline block covers fn 2..32 (fn 32 was previously mapping
  into `bv_shim`).  Dead XBIOS stubs were removed to make room.
  Files: `src/bios/bios.zpa`, `src/bios/common.zpa`, `src/bios/screen.zpa`.

- [x] **3. `ensure_sector` publishes the deblock cache key before a
  successful read.**  A seek/read error left the cache claiming to hold
  the requested sector, so the next access returned stale data.  The key is
  now invalidated while reading, published only after success, and a failed
  flush is propagated instead of discarding dirty data.
  File: `src/bios/fdc765.zpa`.

- [x] **4. F34/F40 random write does not locate or create the target
  extent.**  A random write to `EX > 0` used the current FCB map, wrote
  the wrong block, and was not closed into the directory.  F34/F40 now
  use `find_fcb_extent` and create the target extent when needed.
  `DISKTEST` T11 now writes/reads record 200 (EX=1).  F40 zero-fill
  followed separately (see the P2 list).
  File: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **5. `select_drive` errors are ignored by most file functions.**
  Invalid-drive operations proceeded against the previously cached drive;
  `CLOSE` could update a same-named file on the wrong drive.  A shared
  `select_fcb_drive` now returns CF and every file function checks it.
  File: `src/bdos/bdos.zpa`.

## P1 — Functional

- [x] **6. F31/F27 are stale after F14.**  `SHOWXDPB` printed A:'s DPB
  for B: because F31 returned `cached_dpb` without selecting `cur_disk`.
  F31/F27 now select `cur_disk` first.  `DISKTEST` T14 checks A: vs C:.
  Files: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **7. F28 write-protect and F45 error mode are never enforced.**
  Write functions now call `is_fcb_readonly`; F45 bit 0 chooses between
  returning 2 and the classic abort (message + warm boot).  `DISKTEST` T15
  covers F28 with F45 in return mode.
  File: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **8. `build_alv` size uses the low byte of DSM; block numbers are
  8-bit.**  The ALV size is now computed in 16 bits (44 bytes for DSM=351).
  Full 16-bit block I/O is not implemented yet, so `select_fcb_drive`
  rejects DSM>255 with CF=1 and the ALV marks all blocks used; the drive is
  detection/SHOWXDPB-only.  README no longer claims 720K file I/O.
  Files: `src/bdos/bdos.zpa`, `src/bios/fdc765.zpa`, `README.md`.

- [x] **9. BIOS MOVE (fn 25) is reversed** relative to
  `docs/API.md` (`HL=dst, DE=src`) and to `interbank_move`.  `bios_move`
  now swaps for LDIR, and `bios_call_bank4`/`bv_shim` preserve HL/DE/BC
  (and IY) so the visible-table path can pass MOVE's arguments.  SYSTEST
  covers MOVE.
  Files: `src/bios/bios.zpa`, `src/bios/common.zpa`, `src/test/systest.asm`.

- [x] **10. Loader directory loop counter never terminates.**  `ld de,32`
  cleared D, so `dec d` never reached zero and the "not found" path was
  unreachable.  The counter now lives in `entry_count`.
  File: `src/boot/loader.asm`.

- [x] **11. CCP `try_sub` leaves DMA at `sub_dma`.**  `DIR` after a
  SUBMIT line read 0080h instead of the buffer F17 filled.  `try_sub` now
  restores DMA to 0080h and looks for $$$.SUB on the current drive (not
  just A:).
  File: `src/ccp/miniccp.zpa`.

- [x] **12. RTC only ticks in system mode.**  TPA 0038h was `EI; RETI`, so
  the clock and keyboard repeat stalled during TPA execution.  `start_tpa`
  now installs `JP isr_handler` (common memory); SYSTEST polls SCB
  seconds without making BDOS calls and requires CLOCK OK.
  Files: `src/bios/common.zpa`, `src/test/systest.asm`, docs.

- [x] **13. `echo_sub_line` never runs.**  `xor a` before `call nz` made
  the SETDEF DISPLAY path dead; it now tests `and CON_MODE_DISPLAY`.
  File: `src/ccp/miniccp.zpa`.

- [x] **14. COM loader FCB sits at F5DC (inside the TPA) and can be
  overwritten mid-load.**  The FCB now lives in common memory
  (`ccp_fcb`, asserted at 0xFB91), above `COMMON_BASE`.
  Files: `src/ccp/miniccp.zpa`, `src/bios/common.zpa`.

- [x] **15. FDC has no timeouts and ignores EXM in the 512-byte transfer
  loops.**  `fdc_send_byte`/`fdc_read_byte` have bounded RQM polls and
  `fdc_wait_seek` has a 0x2000-poll timeout.  The data loops count 512 bytes
  with a per-byte RQM timeout (an EXM check there raced the command phase
  and produced zero-byte reads); the loader still checks EXM.
  Files: `src/bios/fdc765.zpa`, `src/boot/loader.asm`.

- [x] **16. ISR motor-off does not clear the spin-up flag.**
  `fdc_motor_on` (bank 4, unreachable from the ISR) is replaced by a
  common-memory `motor_running` flag that the ISR clears.
  Files: `src/bios/fdc765.zpa`, `src/bios/common.zpa`.

- [x] **17. Multi-extent reads fail for files with attribute bits.**
  F20/F33 now mask the FCB byte with 0x7F as well as the directory byte.
  DISKTEST T12 re-reads a 136-record file after setting R/O.
  File: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **18. `scb_write_field` syncs unrelated BDOS state from stale SCB
  fields.**  It now refreshes BDOS→SCB first and pulls back only the field
  written (DMA/current disk/current user).  DISKTEST T16 covers it.
  File: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **19. F30 ignores the user number.**  It now checks the directory
  entry's user against `cur_user`; DISKTEST T17 covers a user-0 file while
  user 1 is current.
  File: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.

- [x] **20. BSH=0 hangs F20/F21; F46 uses undocumented IXH/IXL.**
  All six `CR >> BSH` / `block << BSH` loops now skip the loop when BSH=0;
  the F46 IXH/IXL body was replaced by a stub earlier, and that stub has
  since become the real allocation-vector scan.
  File: `src/bdos/bdos.zpa`.

## Verification follow-ups (zx84 MCP run)

These were found while running the smoke tests in `docs/mcp-smoke-test.md`
after the 20 fixes landed.  They are fixed on `main` alongside the review
set.

- **Directory cache key was taken from `BC` after it had been reloaded.**
  `read_dir_entry` saved the directory sector number in `B`, then called
  `dir_sector_to_bios`/`set_dma`/`disk_read`, all of which clobber `BC`.
  The key was therefore stored as 0xFA/0xCF (the `dirbuf` pointer), so
  `write_dir_entry` wrote the directory buffer to track 7.  `DISKTEST T4`
  exposed it as a file that could be created and closed but never
  reopened.  The sector is now saved on the stack before the BIOS calls
  and restored in the correct LIFO order.
  File: `src/bdos/bdos.zpa`.

- **F21/F34 only flushed the last extent.**  Random writes into a second
  extent left the first extent's directory entry at RC=0/alloc=0 because
  only `CLOSE` updated the directory.  `bf_f21_core` now runs
  `close_dir_update` after every successful write (using the existing
  `bdos_eok` tail to stay within the 16K image).  `DISKTEST T11` covers
  records in EX=0 and EX=1.
  File: `src/bdos/bdos.zpa`.

- **FDC execution phase poll polarity/EXM.**  `fdc_send_byte`/
  `fdc_read_byte` treated RQM=0 as ready and timed out after 256 polls;
  the 512-byte loops also aborted on EXM during the command phase.  The
  polls now test RQM correctly, use a 16-bit counter, and count the 512
  data bytes.  `fdc_init` leaves the motor off, so `load_fonts` now calls
  `motor_on` explicitly.
  Files: `src/bios/fdc765.zpa`, `src/bios/bios.zpa`.

- **`SYSTEST` computed BIOS entries as 4×fn, not 3×fn.**  The test
  therefore called 0xF6C8 (mid-trampoline) for fn 25 and landed in its own
  `fail` label.  It now computes 3×fn.  `MOVE` is also preceded by
  `XMOVE` (fn 29) selecting TPA→TPA banks, since `MOVE` executes in the
  bank chosen by `XMOVE`.
  File: `src/test/systest.asm`.

- **`DISKTEST T10` expected a working F46.**  F46 was then a documented
  stub, so the test asserted the stub contract (`A=0`, `HL=0`, DMA
  untouched).  Both have since been superseded by the real accounting:
  the count is non-zero, drops by 8 records per 1K block written, and is
  restored when the file is deleted.
  File: `src/test/disktest.asm`.

## P2 — Later candidates (addressed)

- [x] **Dead code.** Removed the unused `fdc_seek_1` boot-sector helper;
  the other named labels were already gone. `xdph_c_login_slot` stays: it
  is part of the 10-byte XDPH prefix and the FID copies `rd_login` into it.
- [x] **F6 pagination.** F6 direct console output bypasses
  `bdos_con_out`; F2/F9/F111 still paginate.
- [x] **F110 delimiter.** Get/set implemented; F9 terminates on
  `out_delim`. `SYSTEST` covers set/get and termination.
- [x] **Page-zero 0003/0004.** `start_tpa` writes IOBYTE and
  `(user << 4) | drive`; F8/F14/F32 keep them current. `SYSTEST`
  covers it.
- [x] **TAB handling.** Console TAB pads to the next 8-column stop.
  `SYSTEST` covers it.
- [x] **F34/F40 return codes.** 1 = directory full (F34), 2 = disk full,
  5 = no directory space (F40).
- [x] **F36 return registers.** A=0/HL=0 via `bdos_eok`.
- [x] **F49 offset range check.** Offsets 0x63+ return A=0xFF/HL=0.
- [x] **FDC ST1 mask.** 0x3B (DE, OR, ND, NW, MA); EN is normal.
- [x] **Write-protect detection.** ST1.NW returns BIOS WRITE code 2 and
  F21/F34 propagate it as read-only.
- [x] **Disk-change invalidation.** F13 flushes, then invalidates
  `last_dir_sec`, `last_dir_drv` and `deblock_drv` as well as
  `cached_drive`.
- [x] **Build/tooling.** LF `build.sh` + configurable assembler + lint
  failure; recursive ZPA discovery; `BUILD_NUM` in `build/buildnum`
  passed as `-DBUILD_NUM`; patchsum error check; obsolete
  `check_clobber.py`/`zpa_compare.py` removed; lint covers boot/FID/tools.
- [x] **XBIOS/TE docs.** `docs/cpm-plus-xbios.md` documents the inline-ID
  convention, supported IDs and the unimplemented TE calls.
- [x] **Stale README/comments.** README refreshed (61K/F600 map,
  built-ins, test suites, wishlist).
- [x] **F46 free-space accounting.** `bf_f46` scans the selected drive's
  allocation vector (ALV bits `0..DSM`), scales free blocks to 128-byte
  records with `BSH` and returns the count as three bytes (low, high, 0)
  at the DMA address, with the DMA pointer unchanged; an invalid drive
  returns `A=0xFF`.  `DISKTEST T10` checks a non-zero count, the 8-record
  drop after writing one 1K block, and the restore after the delete.
  Files: `src/bdos/bdos.zpa`, `src/test/disktest.asm`.
- [x] **F40 zero-fill.**  A newly allocated data block is written with
  zeros before the target record, as CP/M 3 requires: `bf_f40` raises a
  one-shot `f40_zfill` flag, `bf_f21_core` consumes it, and the single
  block-allocation path calls `zero_fill_block`, which writes every record
  of the block from a 128-byte zero buffer in common memory (`f40_zero`,
  above the BDOS stack) so the user's DMA area is untouched.  `DISKTEST
  T22` covers a fresh block, a reused block whose 0xAA contents must be
  cleared, and F34 leaving that data in place.
  Files: `src/bdos/bdos.zpa`, `src/bios/common.zpa`,
  `src/test/disktest.asm`.
- [x] **Pagination runtime test.** The smoke runner now drives it through the
  `PAGE.TXT` fixture: with `SETDEF [PAGE]`, `TYPE PAGE.TXT` must stop after
  `LINE 24` with the pager prompt on screen and `LINE 25`..`LINE 30`
  withheld; RETURN must erase the prompt and print the rest; with
  `SETDEF [NOPAGE]` the whole file must print without a prompt or a key.
  Files: `tools/zx84_smoke.py`, `src/test/page.txt`, `src/bdos/bdos.zpa`
  (the prompt now ends in a plain period instead of a stray 0x80 byte).

## P3 — Remaining follow-ups

- Full `TE_*` / `SCR_RUN_ROUTINE` XBIOS functions.
- 16-bit block formats (PCW 720K file I/O).
