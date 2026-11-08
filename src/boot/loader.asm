; ==========================================================================
; CP/M 3.1 Stage 2 Loader — File-based system loader
; ==========================================================================
; Loaded by boot sector to 0x0000 (bank 4) in mode 2 (4,5,6,3).
; Reads the CP/M directory from disk, finds CPM3.SYS, and loads
; it to C000h (common memory, bank 3).
;
; The system file is a regular CP/M file on the disk containing
; the complete BIOS+BDOS+CCP. This removes the system track size
; limit — the OS can be as large as needed.
;
; Two disc layouts are supported from this one source.  Both keep the
; +3 sector IDs 1-9 and one reserved track, so only the block map, the
; directory size and the head selection differ:
;
;   +3 180K (default)  40 tracks, 1 side, 9 sectors, 1K blocks,
;                      8-bit block numbers, 64 directory entries.
;   720K PCW DS/DD     80 tracks, 2 sides, 9 sectors, 2K blocks,
;                      16-bit block numbers, 128 directory entries.
;
; Assemble with -DDS720 for the 720K variant.
; ==========================================================================

    device zxspectrum128
    org 0x0000

PORT_FDC_ST equ 0x2FFD
PORT_FDC_DT equ 0x3FFD
PORT_1FFD   equ 0x1FFD
PORT_ULA    equ 0xFE

PAGING_M2   equ 0x0D          ; Special mode 2 + motor on

; DPB values
DPB_OFF     equ 1             ; 1 reserved track
DPB_SPT     equ 9             ; physical sectors per track

BIOS_ADDR   equ 0xC000        ; Where to load the system file

    IFDEF DS720
BLK_SECTORS equ 4             ; 512-byte sectors per 2K block
DIR_SECTORS equ 8             ; 128 directory entries
BLK16       equ 1             ; 16-bit big-endian block numbers
SIDED       equ 1             ; alternating sides
    ELSE
BLK_SECTORS equ 2             ; 512-byte sectors per 1K block
DIR_SECTORS equ 4             ; 64 directory entries
BLK16       equ 0             ; 8-bit block numbers
SIDED       equ 0             ; single sided
    ENDIF

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
    ld (cur_head), a

    ; --- Screen row-address table → bank 6 at A890 ---
    ; Pure data, so it lives here instead of in the 16K CPM3.SYS window.
    ld hl, row_scr_tbl_data
    ld de, 0xA890
    ld bc, 48
    ldir

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
    ld c, (ix + 4)
    ld b, (ix + 5)             ; BC = byte budget (font size)
    call load_file
    pop ix
    jr nz, .font_next
    ld a, (LF_FLAGS)
    or (ix + 6)
    ld (LF_FLAGS), a
.font_next:
    ld bc, 7
    add ix, bc
    pop bc
    djnz .font_loop

    ; --- CCP.COM → bank 6 at B000 ---
    ld hl, NAME_CCP
    ld de, 0xB000
    ld bc, 4096
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

    ; --- CPM3C.SYS → bank 5 at 62C0 ---
    ; The bank-5 screen code and the common stub are a separate file so
    ; CPM3.SYS (loaded at C000) can use the whole bank-3 window.  The screen
    ; code stays where it lands; init copies the common stub to F600.
    ld hl, NAME_SYS2
    ld de, SYS2_STAGE
    ld bc, SYS2_BYTES
    call load_file
    jp nz, load_error

    ; --- RAMDISK.FID first block → bank 6 at 9000 ---
    ld hl, NAME_FID
    ld de, 0x9000
    ld bc, 1024
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
    ld bc, 0x4000
    call load_file
    jp nz, load_error

    ; Cyan border = done, jumping to BIOS
    ld a, 5
    out (PORT_ULA), a
    jp BIOS_ADDR


; ==========================================================================
; find_extent — find the directory entry for one extent of a file
;   In:  (name_ptr) = 11-byte name, (want_ext) / (want_s2) = extent
;   Out: HL = 32-byte entry in dir_buffer, Z = found; NZ = no more
;   Clobbers: AF, BC, DE, HL
;
; A file bigger than one extent's block map (16 slots on the 180K
; layout, 8 on the 720K one) continues in further directory entries with
; EX/S2 incremented, so the loader walks them in turn.
; ==========================================================================
find_extent:
    ld a, DPB_OFF
    call seek_logical          ; the directory starts on the first data track
    ld a, DIR_SECTORS
    ld (dir_left), a
    ld a, 1
    ld (dir_sector), a
.fe_sector:
    ld a, (dir_sector)
    call fdc_read_single       ; clobbers BC
    jp nz, load_error
    ld hl, dir_buffer
    ld a, 16
    ld (entry_count), a
.fe_entry:
    ld (entry_ptr), hl
    ld a, (hl)
    cp 0xE5
    jr z, .fe_next
    or a                       ; user 0 only
    jr nz, .fe_next
    ; name match
    inc hl
    ld de, (name_ptr)
    ld b, 11
.fe_cmp:
    ld a, (de)
    ld c, a
    ld a, (hl)
    and 0x7F
    cp c
    jr nz, .fe_next
    inc hl
    inc de
    djnz .fe_cmp
    ; extent match: EX holds the low five bits of the logical extent and
    ; S2 the rest (mkdsk writes extent & 0x1F / extent >> 5).
    ld a, (want_ext)
    and 0x1F
    cp (hl)
    jr nz, .fe_next
    inc hl
    inc hl
    ld a, (hl)                 ; S2
    and 0x3F
    ld c, a
    ld a, (want_ext)
    rrca
    rrca
    rrca
    rrca
    rrca
    and 0x3F
    cp c
    jr nz, .fe_next
    ld hl, (entry_ptr)
    xor a                      ; Z = found
    ret
.fe_next:
    ld hl, (entry_ptr)
    ld de, 32
    add hl, de
    ld a, (entry_count)
    dec a
    ld (entry_count), a
    jr nz, .fe_entry
    ld a, (dir_sector)
    inc a
    ld (dir_sector), a
    ld a, (dir_left)
    dec a
    ld (dir_left), a
    jr nz, .fe_sector
    or 1                       ; NZ = no more extents
    ret


; ==========================================================================
; load_file — find a file and load up to BC bytes of it
;   In:  HL = 11-byte name, DE = destination, BC = byte budget
;   Out: Z + DE = first byte past the loaded data; NZ = not found
;   Clobbers: AF, BC, DE, HL, IX
;
; The block map ends at the first zero slot and the file ends after its
; last extent, so a short file stops early.  The budget caps the transfer
; where a staging area is smaller than a whole block (a font, or the
; top of bank 5 for CPM3C.SYS); it is truncated down to whole 512-byte sectors so a
; partial sector is never read past the target.
; ==========================================================================
load_file:
    ld (name_ptr), hl
    ld (load_dest), de
    ; Byte budget, rounded down to whole 512-byte sectors: clearing the low
    ; byte and bit 0 of the high byte drops the low nine bits of BC, so a
    ; partial sector is never read past the staging area it was given.
    ld a, b
    and 0xFE
    ld b, a
    ld c, 0
    ld (budget), bc
    xor a
    ld (want_ext), a

    call find_extent
    jr nz, .lf_missing
    push hl
    pop ix                     ; IX = directory entry

.lf_block:
    ld hl, (budget)
    ld a, h
    or l
    jr z, .lf_done             ; budget exhausted
    call block_number          ; DE = block number (0 = end of file)
    ld a, d
    or e
    jr z, .lf_next_extent      ; end of this extent's map
    ; DE * BLK_SECTORS = first absolute data-area sector of the block
    ex de, hl
    add hl, hl
    IF BLK_SECTORS == 4
    add hl, hl
    ENDIF
    ld (sector_num), hl
    ld a, BLK_SECTORS
    ld (sect_left), a

.lf_sector:
    ld hl, (sector_num)
    call read_one_sector
    jp nz, load_error
    ld hl, (sector_num)
    inc hl
    ld (sector_num), hl

    ; 512 bytes of the budget used up
    ld hl, (budget)
    ld de, 0 - 512
    add hl, de
    ld (budget), hl
    ld a, h
    or l
    jr z, .lf_done

    ld a, (sect_left)
    dec a
    ld (sect_left), a
    jr nz, .lf_sector

    ; advance to the next block-number slot
    IF BLK16
    ld bc, 2
    ELSE
    ld bc, 1
    ENDIF
    add ix, bc
    jr .lf_block

.lf_next_extent:
    ; The map ran out of blocks.  Those blocks must hold every record the
    ; extent's RC claims, or the map was cut short and the file is
    ; truncated: report it as missing rather than boot on a partial CCP or
    ; common stub.  Each map byte is 8 records on both layouts (one 1K
    ; block, or half of a 16-bit 2K block number).
    push ix
    pop hl
    ld de, (entry_ptr)
    or a
    sbc hl, de                 ; L = map bytes used (at most 16)
    ld a, l
    add a, a
    add a, a
    add a, a                   ; A = records the map covers (at most 128)
    ex de, hl
    ld de, 15
    add hl, de                 ; HL -> RC
    cp (hl)
    jr c, .lf_missing          ; fewer records than RC: truncated
    ; The file continues in the next extent, unless that entry does not
    ; exist (then the file simply ended here).
    ld a, (want_ext)
    inc a
    ld (want_ext), a
    call find_extent
    jr nz, .lf_done
    push hl
    pop ix
    jr .lf_block

.lf_done:
    ld de, (load_dest)
    xor a                      ; Z = found
    ret
.lf_missing:
    or 1                       ; NZ = not found
    ret


; ==========================================================================
; block_number — read the block number in the current directory slot
;   In:  IX = directory entry with the slot pointer in +16
;   Out: DE = block number (0 = end of file)
;   Clobbers: AF, DE
; ==========================================================================
block_number:
    IF BLK16
    ld d, (ix + 16)
    ld e, (ix + 17)            ; 16-bit block numbers are high byte first
    ELSE
    ld e, (ix + 16)
    ld d, 0
    ENDIF
    ret


NAME_SYS:   db "CPM3    SYS"
NAME_SYS2:  db "CPM3C   SYS"
NAME_CCP:   db "CCP     COM"
NAME_FID:   db "RAMDISK FID"
NAME_51:    db "FONT51  BIN"
NAME_32:    db "FONT32  BIN"
NAME_64:    db "FONT64  BIN"

; Staged to bank 6 at A890 (see screen.zpa _row_scr_tbl).
row_scr_tbl_data:
    dw 0x4000, 0x4020, 0x4040, 0x4060, 0x4080, 0x40A0, 0x40C0, 0x40E0
    dw 0x4800, 0x4820, 0x4840, 0x4860, 0x4880, 0x48A0, 0x48C0, 0x48E0
    dw 0x5000, 0x5020, 0x5040, 0x5060, 0x5080, 0x50A0, 0x50C0, 0x50E0

FONT_COUNT  equ 3
font_table:
    dw NAME_51, 0x8000
    db 2048 & 0xFF, 2048 >> 8, 0x01
    dw NAME_32, 0x8800
    db 2048 & 0xFF, 2048 >> 8, 0x02
    dw NAME_64, 0x9400
    db 2048 & 0xFF, 2048 >> 8, 0x10

; Hand-off block for the OS: bank 6, outside the image.
LF_FLAGS    equ 0xA860         ; bit 0=font51, 1=font32, 2=fid, 3=ccp, 4=font64
LF_CCP_LEN  equ 0xA861         ; word: bytes staged at B000 (0 = no CCP)
; Bank-5 staging for CPM3C.SYS (the bank-5 screen code, then the common
; stub).  Must match SYS2_STAGE in bios.zpa: the screen code runs where it
; lands, just above the 24x80 buffer (5B00-62BF), and the budget runs to
; the top of bank 5 (mapped at 4000-7FFF in this mode).
SYS2_STAGE  equ 0x62C0
SYS2_BYTES  equ 0x8000 - SYS2_STAGE


; ==========================================================================
; seek_logical — seek to a logical track, selecting the head
;   In:  A = logical track
;   Out: nothing
;   Clobbers: AF, BC
; ==========================================================================
seek_logical:
    IF SIDED
    ld b, a
    and 1
    ld (cur_head), a           ; alternating sides: head = track & 1
    ld a, b
    srl a                      ; cylinder = track / 2
    ENDIF
    jp fdc_seek


; ==========================================================================
; div_hl_c — divide HL by C
;   In:  HL = dividend, C = divisor
;   Out: A = quotient, C = remainder
;   Clobbers: AF, B, HL
; ==========================================================================
div_hl_c:
    ld b, 0
.dh_loop:
    ld a, h
    or a
    jr nz, .dh_sub             ; more than 255 left: definitely >= C
    ld a, l
    cp c
    jr c, .dh_done
.dh_sub:
    ld a, l
    sub c
    ld l, a
    jr nc, .dh_no_borrow
    dec h
.dh_no_borrow:
    inc b
    jr .dh_loop
.dh_done:
    ld c, l                    ; C = remainder
    ld a, b                    ; A = quotient
    ret


; Helper: read one 512-byte sector to (load_dest), advance load_dest
;   In: HL = absolute sector number in the data area
;   Out: Z = success
;   Clobbers: AF, BC, DE, HL
read_one_sector:
    ld c, DPB_SPT
    call div_hl_c              ; A = track offset, C = sector within track
    add a, DPB_OFF             ; A = logical track
    push bc                    ; Save C (sector) — fdc_seek clobbers BC  ; lint: ignore
    call seek_logical
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
budget:       dw 0
sector_num:   dw 0
name_ptr:     dw 0
entry_ptr:    dw 0
sect_left:    db 0
entry_count:  db 0
dir_sector:   db 0
dir_left:     db 0
want_ext:     db 0
cur_head:     db 0

load_error:
    ld a, 2                    ; Red border
    out (PORT_ULA), a
    jr $


; ==========================================================================
; FDC routines (minimal, for loader use only)
; ==========================================================================

; fdc_seek — Seek to cylinder A, keeping the selected head
;   In: A = cylinder
;   Clobbers: AF, BC
fdc_seek:
    ld (cur_track), a          ; Cache cylinder for READ commands
    push af
    ld a, 0x0F                 ; SEEK
    call fdc_send
    ld a, (cur_head)
    rlca
    rlca                       ; HD in bit 2, US=0
    call fdc_send
    pop af
    call fdc_send              ; NCN = cylinder
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
    ld a, (cur_head)
    rlca
    rlca                       ; HD in bit 2, US=0
    call fdc_send
    ld a, (cur_track)
    call fdc_send              ; C = cylinder
    ld a, (cur_head)
    call fdc_send              ; H = head
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
cur_track: db 0xFF             ; Cached cylinder position

; 512-byte buffer for directory sector reads
dir_buffer: ds 512
