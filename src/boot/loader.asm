; ==========================================================================
; CP/M 3.1 Stage 2 Loader — File-based system loader
; ==========================================================================
;
; Loaded by boot sector to 0x0000 (bank 4) in mode 2 (4,5,6,3).
; Reads the CP/M directory from disk, finds CPM3.SYS, and loads
; it to C000h (common memory, bank 3).
;
; The system file is a regular CP/M file on the disk containing
; the complete BIOS+BDOS+CCP. This removes the system track size
; limit — the OS can be as large as needed.
;
; Disk geometry (standard +3 SS):
;   OFF=1 (1 reserved track), 9 sectors/track, 512 bytes/sector
;   Directory at track 1, 1K blocks, sector IDs 1-9
;   Directory entries: 64 (uses blocks 0-1 = 4 sectors)
;
; ==========================================================================

    device zxspectrum128
    org 0x0000

PORT_FDC_ST equ 0x2FFD
PORT_FDC_DT equ 0x3FFD
PORT_1FFD   equ 0x1FFD
PORT_ULA    equ 0xFE

PAGING_M2   equ 0x0D          ; Special mode 2 + motor on

; DPB values (standard +3 format)
DPB_OFF     equ 1             ; 1 reserved track
DPB_SPT     equ 36            ; 36 records/track (9 sectors × 4 records)
DPB_BSH     equ 3             ; Block shift (1K blocks)
DPB_DRM     equ 63            ; 63 = 64 directory entries - 1

BIOS_ADDR   equ 0xC000        ; Where to load the system file

; System file name: "CPM3    SYS" (8+3, space padded)
SYS_NAME:   db "CPM3    SYS"

; ==========================================================================
; Entry point
; ==========================================================================

    ; We're in mode 2 (4,5,6,3), executing from bank 4 at 0000.
    ; Motor should still be on from boot sector.

    ; Yellow border = loading system
    ld a, 6
    out (PORT_ULA), a

    ; Keep the loader stack below the CPM3.SYS load range. A 16K system image
    ; reads a padded final sector at FE00h, which would overwrite the boot
    ; sector's FE00h stack before the jump to BIOS.
    ld sp, BIOS_ADDR

    ; Ensure motor on
    ld bc, PORT_1FFD
    ld a, PAGING_M2
    out (c), a

    ; Seek to directory track (track 1 = OFF)
    ld a, DPB_OFF
    call fdc_seek

    ; Scan directory for CPM3.SYS
    ; Directory occupies first 4 sectors of track 1 (sectors 1-4)
    ; Each 512-byte sector = 16 directory entries (32 bytes each)
    ld b, 4                    ; 4 sectors to scan
    ld c, 1                    ; Starting sector ID
    ld hl, dir_buffer          ; Buffer for one sector

.dir_sector:
    push bc
    push hl

    ; Read one directory sector
    ld a, c                    ; Sector ID
    call fdc_read_single       ; Read 512 bytes to dir_buffer
    jp nz, load_error

    ; Scan 16 entries in this sector
    pop hl
    push hl
    ld a, 16                   ; 16 entries per sector
    ld (entry_count), a

.dir_entry:
    ; Check user number: we want user 0 entries
    ld a, (hl)
    cp 0xE5                    ; Deleted?
    jr z, .next_entry
    or a                       ; User 0?
    jr nz, .next_entry

    ; Compare filename (bytes 1-11) with SYS_NAME
    push hl
    push de                                         ; lint: ignore — only D matters
    inc hl                     ; Point to name field
    ld de, SYS_NAME
    ld b, 11
.cmp_name:
    ld a, (de)
    ld c, a
    ld a, (hl)
    and 0x7F                   ; Mask attribute bits
    cp c
    jr nz, .name_mismatch
    inc hl
    inc de
    djnz .cmp_name
    ; Match found!
    pop de
    pop hl                     ; HL = directory entry
    jr .found_sys

.name_mismatch:
    pop de
    pop hl

.next_entry:
    ld de, 32
    add hl, de                 ; Next entry
    ld a, (entry_count)
    dec a
    ld (entry_count), a
    jr nz, .dir_entry

    ; Next sector
    pop hl                     ; Restore buffer pointer
    pop bc
    inc c                      ; Next sector ID
    djnz .dir_sector

    ; Not found — error
    ld a, 2                    ; Red border = file not found
    out (PORT_ULA), a
    jr $                       ; Hang

; ==========================================================================
; Found CPM3.SYS — load it to C000h
;   HL = pointer to matching directory entry
; ==========================================================================

.found_sys:
    pop af                     ; Clean stack (was push hl from .dir_sector)
    pop af                     ; Clean stack (was push bc from .dir_sector)

    ; Green border = loading system file
    ld a, 4
    out (PORT_ULA), a

    ; The directory entry's allocation map (bytes 16-31) lists the blocks.
    ; Each block is 1K (2 physical sectors). Block N starts at:
    ;   track = (N * 2) / 9 + OFF
    ;   sector = (N * 2) % 9 + 1
    ; (Each block = 2 sectors of 512 bytes)

    push hl
    pop ix                     ; IX = directory entry

    ld hl, BIOS_ADDR           ; HL = load destination
    ld (load_dest), hl
    ld a, 16                   ; Up to 16 block pointers
    ld (block_count), a

.load_block:
    ; Get block number from allocation map
    ld a, (ix + 16)
    or a
    jr z, load_done           ; Block 0 = end of file

    ; Block N → 2 absolute sectors: N*2 and N*2+1
    ; For each sector: track = sector/9 + OFF, ID = sector%9 + 1
    ld l, a
    ld h, 0
    add hl, hl                 ; HL = block * 2 (first absolute sector)

    ; Read first sector of block
    ld a, l
    call read_one_sector
    jp nz, load_error

    ; Read second sector of block (block*2 + 1)
    ld a, (ix + 16)
    ld l, a
    ld h, 0
    add hl, hl
    inc hl
    ld a, l
    call read_one_sector
    jp nz, load_error

    ; Next block pointer
    inc ix
    ld a, (block_count)
    dec a
    ld (block_count), a
    jr nz, .load_block

load_done:
    ; Cyan border = done, jumping to BIOS
    ld a, 5
    out (PORT_ULA), a
    jp BIOS_ADDR

; Helper: read one 512-byte sector to (load_dest), advance load_dest
;   In: A = absolute sector number in data area
;   Out: Z = success
;   Clobbers: AF, BC, DE, HL
read_one_sector:
    ld c, 9
    call div_a_c               ; A = track offset, C = sector within track
    add a, DPB_OFF             ; A = physical track
    push bc                    ; Save C (sector) — fdc_seek clobbers BC  ; lint: ignore
    call fdc_seek
    pop bc
    ld a, c
    inc a                      ; Sector ID (1-based)
    ld de, (load_dest)
    call fdc_read_to_de
    ret nz                     ; Error
    ; Advance load_dest by 512
    ld hl, (load_dest)
    ld de, 512
    add hl, de
    ld (load_dest), hl
    xor a                      ; Z = success
    ret

load_dest:    dw 0
block_count:  db 0
entry_count:  db 0

load_error:
    ld a, 2                    ; Red border
    out (PORT_ULA), a
    jr $


; ==========================================================================
; div_a_c — Divide A by C
;   In:  A = dividend, C = divisor
;   Out: A = quotient, C = remainder
;   Clobbers: B
; ==========================================================================
div_a_c:
    ld b, 0
.div_loop:
    cp c
    jr c, .div_done
    sub c
    inc b
    jr .div_loop
.div_done:
    ld c, a                    ; C = remainder
    ld a, b                    ; A = quotient
    ret


; ==========================================================================
; FDC routines (minimal, for loader use only)
; ==========================================================================

; fdc_seek — Seek to track A
;   In: A = track
;   Clobbers: AF, BC
fdc_seek:
    ld (current_track), a      ; Cache track for READ commands
    push af
    ld a, 0x0F                 ; SEEK
    call fdc_send
    xor a                      ; HD=0, US=0
    call fdc_send
    pop af
    call fdc_send              ; NCN = track
    ; Wait for seek complete
.sense:
    ld a, 0x08                 ; SENSE INTERRUPT STATUS
    call fdc_send
    call fdc_recv              ; ST0
    push af                    ; Save ST0 (fdc_recv clobbers BC)
    call fdc_recv              ; PCN (discard)
    pop af                     ; A = ST0
    bit 5, a                   ; Seek End?
    jr z, .sense
    ret


; fdc_read_single — Read one 512-byte sector into dir_buffer
;   In: A = sector ID
;   Out: Z = success, NZ = error
;   Clobbers: AF, BC, DE, HL
fdc_read_single:
    ld hl, dir_buffer
    jr fdc_read_common

; fdc_read_to_de — Read one 512-byte sector to address in DE
;   In: A = sector ID, DE = destination
;   Out: Z = success, NZ = error
;   Clobbers: AF, BC, DE, HL
fdc_read_to_de:
    ex de, hl                  ; HL = destination
    ; Fall through

fdc_read_common:
    push hl                    ; Save destination
    push af                    ; Save sector ID

    ld a, 0x46                 ; READ DATA (MFM)
    call fdc_send
    xor a                      ; HD=0, US=0
    call fdc_send
    ld a, (current_track)
    call fdc_send              ; C = current track
    xor a
    call fdc_send              ; H = 0
    pop af                     ; Sector ID
    push af
    call fdc_send              ; R = sector ID
    ld a, 2
    call fdc_send              ; N = 512
    pop af
    call fdc_send              ; EOT = same sector
    ld a, 0x2A
    call fdc_send              ; GPL
    ld a, 0xFF
    call fdc_send              ; DTL

    ; Read 512 bytes (2 pages of 256)
    pop hl                     ; Destination
    ld bc, PORT_FDC_ST
    ld d, 2
.page:
    ld e, 0
.byte:
    in a, (c)
    jp p, .byte
    ld b, high PORT_FDC_DT
    in a, (c)
    ld (hl), a
    inc hl
    ld b, high PORT_FDC_ST
    dec e
    jr nz, .byte
    dec d
    jr nz, .page

    ; Read 7 result bytes — save ST0/ST1 before fdc_recv clobbers BC
    call fdc_recv              ; ST0
    push af
    call fdc_recv              ; ST1
    push af
    call fdc_recv              ; ST2
    call fdc_recv              ; C
    call fdc_recv              ; H
    call fdc_recv              ; R
    call fdc_recv              ; N
    pop bc                     ; B = ST1
    pop af                     ; A = ST0
    and 0xC0
    cp 0x80
    jr nc, .read_err
    ld a, b                    ; ST1
    and 0x37
    ret                        ; Z = no errors
.read_err:
    or 1                       ; NZ = error
    ret


; fdc_send — Send byte in A to FDC
;   Clobbers: AF, BC
fdc_send:
    push af
    ld bc, PORT_FDC_ST
.wait:
    in a, (c)
    jp p, .wait
    pop af
    ld bc, PORT_FDC_DT
    out (c), a
    ret

; fdc_recv — Read byte from FDC
;   Out: A = byte
;   Clobbers: BC
fdc_recv:
    ld bc, PORT_FDC_ST
.wait:
    in a, (c)
    jp p, .wait
    ld bc, PORT_FDC_DT
    in a, (c)
    ret


; Variables
current_track: db 0xFF         ; Cached track position

; 512-byte buffer for directory sector reads
dir_buffer: ds 512
