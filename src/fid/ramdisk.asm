; ==========================================================================
; RAMDISK.FID — 16K RAM disk for opencpm-plus3
; ==========================================================================
;
; Loadable BIOS module that registers C: as a 16K RAM disk.  Optional:
; if RAMDISK.FID is absent from A: at cold boot, no C: drive appears.
;
; Loaded at 0x9000 in bank 6 by the BIOS FID loader.  Storage uses the
; entire 16K of bank 7 (mapped at 0x4000-0x7FFF in system mode).
;
; The BIOS dispatcher in disk_read/disk_write passes parameters in
; registers so the FID has zero hardcoded BIOS data addresses:
;
;   rd_init   — In: nothing.        Out: A=0 success, 1 fail.
;   rd_login  — In: nothing.        Out: A=0 success.
;   rd_read   — In: HL=sector(0..127), DE=DMA.  Out: A=0 ok, 1 error.
;   rd_write  — In: HL=sector,      DE=DMA, C=wtype (ignored).
;                                    Out: A=0 ok, 1 error.
;
; The two helper stubs (helper_to_tpa / helper_from_tpa) call directly
; into copy_record_to_tpa / copy_record_from_tpa in common memory.  Their
; addresses are hardcoded below; common.zpa carries asserts that verify
; the labels still resolve to these addresses (build fails if they drift,
; signalling that this file needs updating).  When the BIOS calls into
; the FID, mode 3 (banks 4,7,6,3) is active, so:
;   - bank 4 (BIOS code at 0x0000-0x3FFF) is callable
;   - bank 7 (RAM disk storage at 0x4000-0x7FFF) is readable/writable
;   - bank 6 (this code at 0x9000+) is executing
;   - bank 3 common (0xF600-0xFFFF) is callable
;
; Cold boot: rd_init checks for a magic signature at the end of bank 7
; and zeroes the directory if absent (RAM is random on power-up).
; A soft reset that preserves RAM keeps the disk contents intact.
;
; Assembled with:
;   sjasmplus --raw=build/RAMDISK.FID src/fid/ramdisk.asm
; ==========================================================================

    device zxspectrum128
    org 0x9000

FID_LOAD       equ 0x9000
HEADER_SIZE    equ 64
STATUS_MSG     equ 0x93E0
RAMDISK_BASE   equ 0x4000          ; Bank 7 in system mode
RAMDISK_SIZE   equ 16384
DIR_BLOCK_SIZE equ 1024
MAGIC_OFFSET   equ RAMDISK_SIZE - 8

; --- BIOS ABI (must match common.zpa; asserted there) -------------------
COPY_RECORD_TO_TPA   equ 0xF9CA     ; HL=src(system), DE=dst(TPA), 128 bytes
COPY_RECORD_FROM_TPA equ 0xF9D0     ; HL=src(TPA), DE=dst(system), 128 bytes

; --- Header (64 bytes) ----------------------------------------------------
header:
    db "OCFID", 0                  ; +0   magic (6 bytes)
    db 1                           ; +6   version
    db 0                           ; +7   type: 0 = drive driver
    db 'C'                         ; +8   preferred drive letter
    db 0                           ; +9   reserved
    dw fid_end - header            ; +10  total size
    ; Entries +12..+19 are laid out to match xdph_c's prefix slots
    ; (write, read, login, init) so the loader can copy them with one LDIR.
    dw rd_write                    ; +12  write entry
    dw rd_read                     ; +14  read entry
    dw rd_login                    ; +16  login entry
    dw rd_init                     ; +18  init entry
    dw helper_to_tpa               ; +20  to-TPA helper stub (unused; reserved)
    dw helper_from_tpa             ; +22  from-TPA helper stub (unused; reserved)

    ; XDPB template — copied verbatim into xdpb_c by the loader
    dw 128                         ; +24  SPT (logical sectors per track)
    db 3                           ; +26  BSH
    db 7                           ; +27  BLM
    db 0                           ; +28  EXM
    dw 15                          ; +29  DSM (16 blocks - 1)
    dw 31                          ; +31  DRM (32 entries - 1)
    db 0x80                        ; +33  AL0 (block 0 = directory)
    db 0x00                        ; +34  AL1
    dw 0                           ; +35  CKS (fixed disk: no checksum)
    dw 0                           ; +37  OFF (no reserved tracks)
    db 0                           ; +39  PSH
    db 0                           ; +40  PHM
    db 0                           ; +41  sidedness
    db 1                           ; +42  tracks
    db 128                         ; +43  sectors
    db 0                           ; +44  first sector ID
    dw 128                         ; +45  physical sector size
    db 0                           ; +47  gap1
    db 0                           ; +48  gap2
    db 0                           ; +49  flags
    db 0xFF                        ; +50  freeze (locked — never re-detect)

    ds HEADER_SIZE - ($ - header), 0
    assert ($ - header) == HEADER_SIZE, "FID header must be 64 bytes"

; --- Helper stubs (hardcoded; common.zpa asserts addresses match) -------
helper_to_tpa:
    call COPY_RECORD_TO_TPA
    ret
helper_from_tpa:
    call COPY_RECORD_FROM_TPA
    ret

; --- rd_init: validate magic, cold-init directory if absent --------------
rd_init:
    ld hl, RAMDISK_BASE + MAGIC_OFFSET
    ld de, magic_bytes
    ld b, 8
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .fresh
    inc hl
    inc de
    djnz .cmp
    xor a                           ; Magic present — preserve RAM contents
    ret

.fresh:
    ; Zero block 0 (directory) with the CP/M empty-entry marker
    ld hl, RAMDISK_BASE
    ld (hl), 0xE5
    ld de, RAMDISK_BASE + 1
    ld bc, DIR_BLOCK_SIZE - 1
    ldir
    ; Stamp the magic so future warm boots preserve contents
    ld hl, magic_bytes
    ld de, RAMDISK_BASE + MAGIC_OFFSET
    ld bc, 8
    ldir
    xor a
    ret

magic_bytes: db "OCRAMD!", 0        ; 8 bytes

; --- rd_login: no-op (always logged in) ----------------------------------
rd_login:
    xor a
    ret

; --- rd_read: copy 128 bytes from RAM disk to DMA -------------------------
;   In:  HL = sector (0..127), DE = DMA address
;   Out: A = 0 ok, 1 error
rd_read:
    ld a, h
    or a
    jr nz, .err
    ld a, l
    cp 128
    jr nc, .err
    ; HL = RAMDISK_BASE + (sector << 7)
    ld h, l
    ld l, 0
    srl h
    rr l
    ld a, h
    or RAMDISK_BASE >> 8
    ld h, a
    ; HL = src in bank 7, DE = DMA target
    ld a, d
    cp 0xC0
    jr nc, .direct
    call helper_to_tpa
    xor a
    ret
.direct:
    ld bc, 128
    ldir
    xor a
    ret
.err:
    ld a, 1
    ret

; --- rd_write: copy 128 bytes from DMA into RAM disk ---------------------
;   In:  HL = sector (0..127), DE = DMA address
;   Out: A = 0 ok, 1 error
rd_write:
    ld a, h
    or a
    jr nz, .err
    ld a, l
    cp 128
    jr nc, .err
    ; HL = RAMDISK_BASE + (sector << 7) — destination in bank 7
    ld h, l
    ld l, 0
    srl h
    rr l
    ld a, h
    or RAMDISK_BASE >> 8
    ld h, a
    ; copy_record_from_tpa expects HL=src(TPA), DE=dst(system).  Swap.
    ex de, hl                       ; HL = DMA, DE = RAM dest
    ld a, h
    cp 0xC0
    jr nc, .direct
    call helper_from_tpa
    xor a
    ret
.direct:
    ld bc, 128
    ldir
    xor a
    ret
.err:
    ld a, 1
    ret

RAMDISK_KB equ RAMDISK_SIZE / 1024

    ds STATUS_MSG - $, 0
fid_status_msg:
    db "RAMdisc loaded: "
    db '0' + (RAMDISK_KB / 10) % 10
    db '0' + RAMDISK_KB % 10
    db "K as C:", 0x0D, 0x0A
    db 0

fid_end:

    assert fid_status_msg == STATUS_MSG, "RAMDISK.FID status message address changed"
    assert fid_end - header <= 1024, "RAMDISK.FID must fit in one 1K disk block"
