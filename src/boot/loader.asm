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

; ==========================================================================
; Entry point
; ==========================================================================

    ; We're in mode 2 (4,5,6,3), executing from bank 4 at 0000.
    ; Motor should still be on from boot sector.

    ; Yellow border = loading system
    ld a, 6
    out (PORT_ULA), a

    ; Keep the loader stack clear of both the CPM3.SYS load range
    ; (C000-FFFF), the bank-6 font/CCP staging (8000-BFFF) and the
    ; loader's own variables/dir_buffer.  0800 is free bank-4 RAM and is
    ; overwritten only when init copies the system image down.
    ld sp, 0x0800
    ; lint-exempt: 1ffd  ; no shadow exists yet - CPM3.SYS is not loaded

    ; Ensure motor on
    ld bc, PORT_1FFD
    ld a, PAGING_M2
    out (c), a

    ; No fonts/CCP/FID found yet.  These flags live in bank 6 at A860 so
    ; they survive the system-image copy into bank 4.
    xor a
    ld (LF_FLAGS), a
    ld (LF_CCP_LEN), a
    ld (LF_CCP_LEN + 1), a

    ; --- Fonts → bank 6 ---
    ld ix, font_table
    ld b, FONT_COUNT
.font_loop:
    push bc
    push ix
    ld l, (ix + 0)
    ld h, (ix + 1)
    ld e, (ix + 2)
    ld d, (ix + 3)
    ld b, 2                    ; at most 2 × 1K blocks
    call load_file
    pop ix
    jr nz, .font_next
    ld a, (LF_FLAGS)
    or (ix + 4)
    ld (LF_FLAGS), a
.font_next:
    ld bc, 5
    add ix, bc
    pop bc
    djnz .font_loop

    ; --- CCP.COM → bank 6 at B000 ---
    ld hl, NAME_CCP
    ld de, 0xB000
    ld b, 4
    call load_file
    jr nz, .no_ccp
    ; DE = first byte past the staged image
    ex de, hl
    ld bc, 0 - 0xB000
    add hl, bc
    ld (LF_CCP_LEN), hl
    ld a, (LF_FLAGS)
    or 0x08
    ld (LF_FLAGS), a
.no_ccp:

    ; --- RAMDISK.FID first block → bank 6 at 9000 ---
    ld hl, NAME_FID
    ld de, 0x9000
    ld b, 1
    call load_file
    jr nz, .no_fid
    ld a, (LF_FLAGS)
    or 0x04
    ld (LF_FLAGS), a
.no_fid:

    ; --- CPM3.SYS → C000 ---
    ; Green border = loading system file
    ld a, 4
    out (PORT_ULA), a
    ld hl, NAME_SYS
    ld de, BIOS_ADDR
    ld b, 16
    call load_file
    jp nz, load_error

    ; Cyan border = done, jumping to BIOS
    ld a, 5
    out (PORT_ULA), a
    jp BIOS_ADDR


; ==========================================================================
; find_file — find a directory entry by name
;   In:  HL = 11-byte name
;   Out: HL = 32-byte entry in dir_buffer, Z = found; NZ = not found
;   Clobbers: AF, BC, DE, HL
; ==========================================================================
find_file:
    ld (name_ptr), hl
    ld a, DPB_OFF
    call fdc_seek
    ld b, 4                    ; 4 directory sectors
    ld c, 1
.ff_sector:
    push bc                    ; preserve sector counter across the read
    ld a, c
    call fdc_read_single       ; clobbers BC
    jp nz, load_error
    ld hl, dir_buffer
    ld a, 16
    ld (entry_count), a
.ff_entry:
    ld a, (hl)
    cp 0xE5
    jr z, .ff_next
    or a                       ; user 0 only
    jr nz, .ff_next
    push hl
    inc hl
    ld de, (name_ptr)
    ld b, 11
.ff_cmp:
    ld a, (de)
    ld c, a
    ld a, (hl)
    and 0x7F
    cp c
    jr nz, .ff_mismatch
    inc hl
    inc de
    djnz .ff_cmp
    pop hl
    pop bc                     ; discard the saved sector counter
    xor a                      ; Z = found
    ret
.ff_mismatch:
    pop hl
.ff_next:
    ld de, 32
    add hl, de
    ld a, (entry_count)
    dec a
    ld (entry_count), a
    jr nz, .ff_entry
    pop bc                     ; restore the sector counter
    inc c
    djnz .ff_sector
    or 1                       ; NZ = not found
    ret


; ==========================================================================
; load_file — find a file and load its 1K blocks
;   In:  HL = 11-byte name, DE = destination, B = max blocks
;   Out: Z + DE = first byte past the loaded data; NZ = not found
;   Clobbers: AF, BC, DE, HL, IX
; ==========================================================================
load_file:
    ld (name_ptr), hl
    ld (load_dest), de
    push bc
    call find_file
    pop bc
    jr nz, .lf_missing
    push hl
    pop ix                     ; IX = directory entry
    ld a, b
    ld (block_count), a

.lf_block:
    ld a, (ix + 16)            ; allocation map entry
    or a
    jr z, .lf_done             ; block 0 = end of file
    ld l, a
    ld h, 0
    add hl, hl                 ; block * 2 = first absolute sector
    ld a, l
    call read_one_sector
    jp nz, load_error
    ld a, (ix + 16)
    ld l, a
    ld h, 0
    add hl, hl
    inc hl                     ; second sector of the block
    ld a, l
    call read_one_sector
    jp nz, load_error
    inc ix
    ld a, (block_count)
    dec a
    ld (block_count), a
    jr nz, .lf_block

.lf_done:
    ld de, (load_dest)
    xor a                      ; Z = found
    ret
.lf_missing:
    or 1                       ; NZ = not found
    ret


NAME_SYS:   db "CPM3    SYS"
NAME_CCP:   db "CCP     COM"
NAME_FID:   db "RAMDISK FID"
NAME_51:    db "FONT51  BIN"
NAME_32:    db "FONT32  BIN"
NAME_64:    db "FONT64  BIN"

FONT_COUNT  equ 3
font_table:
    dw NAME_51, 0x8000
    db 0x01
    dw NAME_32, 0x8800
    db 0x02
    dw NAME_64, 0x9400
    db 0x10

; Hand-off block for the OS: bank 6, outside the image.
LF_FLAGS    equ 0xA860         ; bit 0=font51, 1=font32, 2=fid, 3=ccp, 4=font64
LF_CCP_LEN  equ 0xA861         ; word: bytes staged at B000 (0 = no CCP)

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
name_ptr:     dw 0
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
    bit 5, a                   ; EXM = 0 → command left execution phase
    jr z, .read_done
    ld b, high PORT_FDC_DT
    in a, (c)
    ld (hl), a
    inc hl
    ld b, high PORT_FDC_ST
    dec e
    jr nz, .byte
    dec d
    jr nz, .page

.read_done:
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
