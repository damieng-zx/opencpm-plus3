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
  `DISKTEST` T11 now writes/reads record 200 (EX=1).  F40 zero-fill is
  still sparse (P2).
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
  (and IY) so the visible-table path can pass MOVE's arguments.  STACKTEST
  covers MOVE.
  Files: `src/bios/bios.zpa`, `src/bios/common.zpa`, `src/test/stacktest.asm`.

- [x] **10. Loader directory loop counter never terminates.**  `ld de,32`
  cleared D, so `dec d` never reached zero and the "not found" path was
  unreachable.  The counter now lives in `entry_count`.
  File: `src/boot/loader.asm`.

- [x] **11. CCP `try_sub` leaves DMA at `sub_dma`.**  `DIR` after a
  SUBMIT line read 0080h instead of the buffer F17 filled.  `try_sub` now
  restores DMA to 0080h and looks for $$$.SUB on the current drive (not
  just A:).
  File: `src/ccp/miniccp.zpa`.

- [ ] **12. RTC only ticks in system mode.**  TPA 0038h is `EI; RETI`, so
  the clock and keyboard repeat stall during TPA execution.
  Files: `src/bios/common.zpa`, `src/bios/keyboard.zpa`.

- [ ] **13. `echo_sub_line` never runs.**  `xor a` before `call nz`
  makes the SETDEF DISPLAY path dead.
  File: `src/ccp/miniccp.zpa`.

- [ ] **14. COM loader FCB sits at F5DC (inside the TPA) and can be
  overwritten mid-load.**  The comment claims it is in page zero.
  File: `src/ccp/miniccp.zpa`.

- [ ] **15. FDC has no timeouts and ignores EXM in the 512-byte transfer
  loops.**  A missing drive or aborted command can hang the machine.
  File: `src/bios/fdc765.zpa`.

- [ ] **16. ISR motor-off does not clear the spin-up flag.**
  `fdc_motor_on` stays 1, so the next `motor_on` skips spin-up.
  Files: `src/bios/fdc765.zpa`, `src/bios/common.zpa`.

- [ ] **17. Multi-extent reads fail for files with attribute bits.**
  F20/F33 mask the directory byte but not the FCB byte.
  File: `src/bdos/bdos.zpa`.

- [ ] **18. `scb_write_field` syncs unrelated BDOS state from stale SCB
  fields.**  Writing tempdrv can reset the current drive/user/DMA.
  File: `src/bdos/bdos.zpa`.

- [ ] **19. F30 ignores the user number.**  Attributes can be changed on
  same-named files in other user areas.
  File: `src/bdos/bdos.zpa`.

- [ ] **20. BSH=0 hangs F20/F21; F46 uses undocumented IXH/IXL.**
  File: `src/bdos/bdos.zpa`.

## P2 — Later candidates

Dead code (`bdos_warm_init`, `multi_count`/F44, `xdph_c_login_slot`,
`fdc_seek_1`, `te_*`/`cd_sa_*`/`cd_version`/`cd_info`/`find_fid`/
`scr_run_routine`), F6 pagination, F110 delimiter, page-zero 0003/0004,
TAB handling, F34/F40 return codes, F36 return registers, F49 offset
range check, FDC ST1 mask (0x37), write-protect detection, disk-change
invalidation, `build.sh` lint/glob, `build.cmd` assembler error checks,
BUILD_NUM auto-bump dirtying tracked source, obsolete
`check_clobber.py`/`zpa_compare.py`, lint coverage of boot/FID/tools,
missing XBIOS/TE docs, stale README/comments.
