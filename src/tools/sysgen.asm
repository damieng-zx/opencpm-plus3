; SYSGEN.COM - make a formatted disc bootable
;
; Usage:  SYSGEN B:      (or A:)
;
; The system is read from A: - track 0 (boot sector + stage-2 loader) and
; the three files the loader needs: CPM3.SYS, CPM3C.SYS and CCP.COM.  All of
; it is buffered in memory, so the target can be the same drive: after the
; read the user is asked to swap discs.  The target's layout is checked
; against the source's before anything is written.  Only the boot track and
; the system files are written, so other files on the target are kept, and
; every written file is read back and compared with the buffered copy.
;
; Build: sjasmplus --raw=build/sysgen.com src/tools/sysgen.asm

    org 0x0100

BDOS            equ 0x0005
F_CONOUT        equ 2
F_DIRECT        equ 6
F_PSTR          equ 9
F_SELDRV        equ 14
F_OPEN          equ 15
F_CLOSE         equ 16
F_DELETE        equ 19
F_READ          equ 20
F_WRITE         equ 21
F_MAKE          equ 22
F_CURDRV        equ 25
F_SETDMA        equ 26

TAIL            equ 0x0080
FCB             equ 0x005C
USERF_OFFSET    equ 90

DD_INIT         equ 0x0080
DD_READ_SECTOR  equ 0x0086
DD_WRITE        equ 0x0089
DD_LOGIN        equ 0x0092

; Buffers in the TPA: the boot track (up to 32 sectors; our layouts use
; 8-10, so 16K is plenty) and the three system files, which are at most
; 16K + 4K + 4K.  XDPB_SRC/XDPB_TGT are in bank 3, which is the same memory
; in TPA and system mode, so the XBIOS calls can see them.
BOOTBUF         equ 0x1000               ; 16K: the boot track
SYSBUF          equ 0x5000               ; 32K: the three system files
SYSBUF_LEN      equ 0x8000
CMPBUF          equ 0xD400               ; one record, for read-back checks
XDPB_SRC        equ 0xD200
XDPB_TGT        equ 0xD240

XDPB_PSH        equ 15
XDPB_SIDES      equ 17
XDPB_TRACKS     equ 18
XDPB_SECTS      equ 19

; ==========================================================================
; Entry
; ==========================================================================
start:
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    ld de, USERF_OFFSET
    add hl, de
    ld (userf_call + 1), hl

    ld c, F_CURDRV
    call BDOS
    ld (saved_drive), a

    ; One argument: the target unit.
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, usage
    inc hl
    call skip_spaces
    call parse_unit
    jp c, usage
    ld (tgt_unit), a
    call tail_end_ok
    jp nz, usage                  ; lint: ignore - Z flag is the result

    ; Banner and confirmation.
    ld de, msg_title
    call pstr
    ld a, (tgt_unit)
    call print_unit
    ld de, msg_title2
    call pstr
    ld de, msg_about
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled

    ; ---- Read the system from A: ----
    ld de, msg_reading
    call pstr

    ; Detect the source layout (unit 0) into XDPB_SRC.
    ld hl, DD_LOGIN
    ld (userf_dw), hl
    ld c, 0
    ld ix, XDPB_SRC
    call userf_call
    jp nc, no_source

    ; "Source: SS, 40 tracks, 9 sectors."
    ld de, msg_source
    call pstr
    ld hl, XDPB_SRC + XDPB_SIDES
    ld a, (hl)
    or a
    ld de, msg_ss
    jr z, .sides
    ld de, msg_ds
.sides:
    call pstr
    ld a, (XDPB_SRC + XDPB_TRACKS)
    call print_dec
    ld de, msg_tracks
    call pstr
    ld a, (XDPB_SRC + XDPB_SECTS)
    call print_dec
    ld de, msg_sectors
    call pstr

    ; ---- Read the three files ----
    xor a
    ld (file_idx), a
    ld hl, 0
    ld (off_next), hl
.file_loop:
    call build_fcb
    ld a, 1                       ; FCB drive code 1 = A:
    ld (FCB), a
    ld de, FCB
    ld c, F_OPEN
    call BDOS
    inc a
    jp z, missing_file

    ; DMA = SYSBUF + off_next
    ld hl, SYSBUF
    ld de, (off_next)
    add hl, de
    call set_dma

    ; Records left in the buffer.
    ld hl, SYSBUF_LEN
    ld de, (off_next)
    xor a                         ; clear carry for the subtraction
    sbc hl, de
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ld (recs_left), hl

    ld hl, 0
.read_rec:
    ; Would another record fit?
    ld de, (recs_left)
    push hl
    or a
    sbc hl, de
    pop hl
    jr z, .no_memory

    push hl
    ld de, FCB
    ld c, F_READ
    call BDOS
    pop hl
    or a
    jr nz, .read_done
    inc hl
    push hl
    call advance_dma              ; the BDOS does not move the DMA itself
    pop hl
    jr .read_rec

.no_memory:
    ld de, FCB + 1
    call print_name11
    ld de, msg_no_memory
    call pstr
    jp fail

.read_done:
    ld a, (file_idx)
    call store_recs
    ld de, FCB
    ld c, F_CLOSE
    call BDOS

    call store_off               ; offs[file_idx] = off_next
    ; off_next += records * 128
    ld a, (file_idx)
    call load_recs
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, (off_next)
    add hl, de
    ld (off_next), hl

    ld a, (file_idx)
    inc a
    ld (file_idx), a
    cp 3
    jp nz, .file_loop

    ; ---- Read the boot track (after the file reads: a raw sector read
    ; invalidates the deblock cache the BDOS search relies on) ----
    call read_boot_track

    ; ---- The target ----
    ld a, (tgt_unit)
    or a
    jr nz, .two_drives
    ld de, msg_swap
    call pstr
    ld a, (tgt_unit)
    call print_unit
    ld de, msg_swap2
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled
.two_drives:
    call disk_changed

    ; ---- Check the target's layout ----
    ld hl, DD_LOGIN
    ld (userf_dw), hl
    ld a, (tgt_unit)
    ld c, a
    ld ix, XDPB_TGT
    call userf_call
    jp nc, target_geometry
    ld hl, XDPB_SRC + XDPB_PSH
    ld de, XDPB_TGT + XDPB_PSH
    ld b, 8                       ; PSH, PHM, sides, tracks, sectors,
.cmp:                             ; first ID, sector size (16-bit)
    ld a, (hl)
    ld c, a
    ld a, (de)
    cp c
    jp nz, target_geometry
    inc hl
    inc de
    djnz .cmp
    jp write_all

; ==========================================================================
; Boot track
; ==========================================================================
; read_boot_track - read logical track 0 of A: into BOOTBUF
;   Clobbers: everything ; lint: ignore
read_boot_track:
    ld a, (XDPB_SRC + XDPB_SECTS)
    cp 32 + 1                     ; BOOTBUF holds 32 sectors
    jr c, .have_count
    ld a, 32
.have_count:
    ld (boot_sectors), a
    xor a
    ld (boot_sec), a
.sec_loop:
    call boot_dma
    ld hl, DD_READ_SECTOR
    ld (userf_dw), hl
    call sec_to_e
    ld e, a
    ld d, 0
    xor a                         ; unit 0 = A:
    ld c, a
    ld b, 1                       ; CP/M bank 1 (TPA)
    ld hl, (boot_ptr)
    ld ix, XDPB_SRC
    call userf_call
    jp nc, source_read_error
    ld a, (boot_sec)
    inc a
    ld (boot_sec), a
    ld b, a
    ld a, (boot_sectors)
    cp b
    jp nz, .sec_loop
    ret

; write_boot_track - write BOOTBUF to logical track 0 of the target
;   Clobbers: everything ; lint: ignore
write_boot_track:
    xor a
    ld (boot_sec), a
.sec_loop:
    call boot_dma
    ld hl, DD_WRITE
    ld (userf_dw), hl
    call sec_to_e
    ld e, a
    ld d, 0
    ld a, (tgt_unit)
    ld c, a
    ld b, 1
    ld hl, (boot_ptr)
    ld ix, XDPB_SRC
    call userf_call
    jp nc, target_write_error
    ld a, (boot_sec)
    inc a
    ld (boot_sec), a
    ld b, a
    ld a, (boot_sectors)
    cp b
    jp nz, .sec_loop
    ret

; boot_dma - boot_ptr = BOOTBUF + boot_sec * 512
;   Clobbers: AF, DE, HL
boot_dma:
    ld a, (boot_sec)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                    ; *512
    ld de, BOOTBUF
    add hl, de
    ld (boot_ptr), hl
    ret

; sec_to_e - A = boot_sec << PSH (the XBIOS record number)
;   Out:      A = record number
;   Clobbers: B, F
sec_to_e:
    ld a, (XDPB_SRC + XDPB_PSH)
    ld b, a
    ld a, (boot_sec)
    inc b
.loop:
    dec b
    ret z
    sla a
    jr .loop

; ==========================================================================
; Files
; ==========================================================================
; build_fcb - FCB from names[file_idx]
;   Clobbers: everything ; lint: ignore
build_fcb:
    ld hl, FCB
    ld b, 36
.zero:
    ld (hl), 0
    inc hl
    djnz .zero

    ld a, (file_idx)
    add a, a
    ld e, a
    ld d, 0
    ld hl, name_ptrs
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld hl, FCB + 1
    ex de, hl
    ld bc, 11
    ldir
    ret

; load_recs - HL = recs[file_idx]
;   In:       A = file_idx
;   Out:      HL = records
;   Clobbers: AF, DE, HL
load_recs:
    add a, a
    ld e, a
    ld d, 0
    ld hl, recs
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ret

; store_recs - recs[file_idx] = HL
;   In:       A = file_idx, HL = records
;   Clobbers: AF, DE, HL
store_recs:
    ld (tmp_recs), hl
    add a, a
    ld e, a
    ld d, 0
    ld hl, recs
    add hl, de
    ld de, (tmp_recs)
    ld (hl), e
    inc hl
    ld (hl), d
    ret

; load_off - HL = offs[file_idx]
;   In:       A = file_idx
;   Out:      HL = byte offset of the file within SYSBUF
;   Clobbers: AF, DE, HL
load_off:
    add a, a
    ld e, a
    ld d, 0
    ld hl, offs
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ret

; store_off - offs[file_idx] = off_next
;   Clobbers: AF, DE, HL
store_off:
    ld a, (file_idx)
    add a, a
    ld e, a
    ld d, 0
    ld hl, offs
    add hl, de
    ld de, (off_next)
    ld (hl), e
    inc hl
    ld (hl), d
    ret

; set_dma - point the BDOS DMA at HL
;   In:       HL = buffer
;   Clobbers: AF, BC, DE, HL ; lint: ignore
set_dma:
    ld (dma_ptr), hl
    ex de, hl
    ld c, F_SETDMA
    jp BDOS

; advance_dma - point the BDOS DMA at the next 128-byte record
;   Clobbers: AF, BC, DE, HL ; lint: ignore
advance_dma:
    ld hl, (dma_ptr)
    ld de, 128
    add hl, de
    jp set_dma

; verify_file - read the target file back and compare it with SYSBUF
;   In:       A = file_idx
;   Out:      carry set OK; carry clear on a read error or a mismatch
;   Clobbers: everything ; lint: ignore
verify_file:
    ld (file_idx), a
    call build_fcb
    ld a, (tgt_unit)
    inc a
    ld (FCB), a
    ld de, FCB
    ld c, F_OPEN
    call BDOS
    inc a
    jr z, .bad

    ld a, (file_idx)
    call load_off
    ld de, SYSBUF
    add hl, de
    ld (cmp_src), hl
    ld a, (file_idx)
    call load_recs
    ld (tmp_recs), hl

.loop:
    ld hl, (tmp_recs)
    ld a, h
    or l
    jr z, .done
    ld hl, CMPBUF                ; every record lands in the same buffer
    call set_dma
    ld de, FCB
    ld c, F_READ
    call BDOS
    or a
    jr nz, .bad                  ; short file or read error
    call cmp_record
    jr nz, .bad
    ld hl, (cmp_src)
    ld de, 128
    add hl, de
    ld (cmp_src), hl
    ld hl, (tmp_recs)
    dec hl
    ld (tmp_recs), hl
    jr .loop

.done:
    ; There must be no record after the last one.
    ld hl, CMPBUF
    call set_dma
    ld de, FCB
    ld c, F_READ
    call BDOS
    cp 1                         ; 1 = end of file
    jr nz, .bad
    ld de, FCB
    ld c, F_CLOSE
    call BDOS
    scf
    ret
.bad:
    ld de, FCB
    ld c, F_CLOSE
    call BDOS
    or a                         ; clear carry
    ret

; cmp_record - compare 128 bytes at CMPBUF with the buffer copy
;   In:       cmp_src = buffer pointer
;   Out:      Z = equal, NZ = different
;   Clobbers: AF, B, DE, HL
cmp_record:
    ld hl, (cmp_src)
    ld de, CMPBUF
    ld b, 128
.loop:
    ld a, (de)
    cp (hl)
    jr nz, .diff
    inc hl
    inc de
    djnz .loop
    xor a
    ret
.diff:
    or 1
    ret

; ==========================================================================
; Writing the system files
; ==========================================================================
write_all:
    ld de, msg_boot
    call pstr
    call write_boot_track

    xor a
    ld (file_idx), a
.write_loop:
    call build_fcb
    ld a, (tgt_unit)
    inc a                         ; FCB drive code: 1 = A:
    ld (FCB), a
    ld de, FCB
    ld c, F_DELETE
    call BDOS                     ; best effort
    ld de, FCB
    ld c, F_MAKE
    call BDOS
    inc a
    jp z, target_write_error

    ; DMA = SYSBUF + offs[file_idx]
    ld a, (file_idx)
    call load_off
    ld de, SYSBUF
    add hl, de
    call set_dma

    ld a, (file_idx)
    call load_recs
    ld (tmp_recs), hl
    ld de, msg_writing
    call pstr
    ld de, FCB + 1
    call print_name11

.rec_loop:
    ld hl, (tmp_recs)
    ld a, h
    or l
    jr z, .closed
    ld de, FCB
    ld c, F_WRITE
    call BDOS
    or a
    jp nz, target_write_error
    call advance_dma
    ld hl, (tmp_recs)
    dec hl
    ld (tmp_recs), hl
    jr .rec_loop

.closed:
    ld de, FCB
    ld c, F_CLOSE
    call BDOS
    inc a
    jp z, target_write_error
    ld de, msg_ok
    call pstr

    ; Read it back and compare it with the copy still in the buffer.
    ld de, msg_checking
    call pstr
    ld de, FCB + 1
    call print_name11
    ld a, (file_idx)
    call verify_file
    jp nc, target_verify_error
    ld de, msg_ok
    call pstr

    ld a, (file_idx)
    inc a
    ld (file_idx), a
    cp 3
    jp nz, .write_loop

    ld de, msg_done
    call pstr
    jp finish

; ==========================================================================
; Helpers
; ==========================================================================
; skip_spaces - advance HL past spaces
;   Out:      HL = first non-space
;   Clobbers: AF
skip_spaces:
    ld a, (hl)
    cp ' '
    ret nz
    inc hl
    jr skip_spaces

; parse_unit - read "A:" / "B:"
;   In:       HL = pointer
;   Out:      A = 0/1, HL advanced; carry set on a bad unit
;   Clobbers: AF, B, HL
parse_unit:
    ld a, (hl)
    or a
    jr z, .bad
    cp 0x0D
    jr z, .bad
    and 0xDF
    cp 'A'
    jr c, .bad
    cp 'B' + 1
    jr nc, .bad
    sub 'A'
    ld b, a
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .done
    inc hl
.done:
    ld a, b
    and a
    ret
.bad:
    scf
    ret

; tail_end_ok - Z set when only spaces remain
;   Clobbers: AF, HL
tail_end_ok:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    jr nz, .junk
    inc hl
    jr tail_end_ok
.junk:
    or a
    ret

; wait_key - wait for one keypress, without echo
;   Out:      A = character
;   Clobbers: AF, BC, DE ; lint: ignore
wait_key:
    ld e, 0xFF
    ld c, F_DIRECT
    call BDOS
    or a
    jr z, wait_key
    ret

; disk_changed - reset the disc driver after a swap
;   Clobbers: AF, BC, DE, HL, IX, IY ; lint: ignore - tail call
disk_changed:
    ld hl, DD_INIT
    ld (userf_dw), hl
    jp userf_call

; ==========================================================================
; Console and numbers
; ==========================================================================
; cout - write A to the console
;   Clobbers: AF, BC, DE ; lint: ignore
cout:
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; pstr - print a '$'-terminated string
;   Clobbers: AF, BC, DE ; lint: ignore
pstr:
    ld c, F_PSTR
    jp BDOS

; crlf - end the line
;   Clobbers: AF, BC, DE ; lint: ignore
crlf:
    ld de, msg_crlf
    jp pstr

; print_unit - print A as "X:"
;   Clobbers: AF, BC, DE ; lint: ignore
print_unit:
    add a, 'A'
    call cout
    ld a, ':'
    jp cout

; print_dec - print A as decimal
;   In:       A = 0-255
;   Clobbers: AF, BC ; lint: ignore
print_dec:
    ld b, 0
.hundreds:
    cp 100
    jr c, .tens
    sub 100
    inc b
    jr .hundreds
.tens:
    ld c, 0
.tens_loop:
    cp 10
    jr c, .units
    sub 10
    inc c
    jr .tens_loop
.units:
    ld (pd_u), a
    ld a, c
    ld (pd_t), a
    ld a, b
    ld (pd_h), a
    or a
    jr nz, .three
    ld a, (pd_t)
    or a
    jr z, .last
    add a, '0'
    call cout
    jr .last
.three:
    add a, '0'
    call cout
    ld a, (pd_t)
    add a, '0'
    call cout
.last:
    ld a, (pd_u)
    add a, '0'
    jp cout

; print_name11 - print an 11-byte CP/M name
;   In:       DE = name
;   Clobbers: everything ; lint: ignore
print_name11:
    ld (name_ptr), de
    ld a, 8
    ld (name_left), a
    ld hl, (name_ptr)
.name:
    ld a, (hl)
    and 0x7F
    cp ' '
    jr z, .dot
    push hl
    call cout
    pop hl
    inc hl
    ld a, (name_left)
    dec a
    ld (name_left), a
    jr nz, .name
.dot:
    ld a, '.'
    call cout
    ld hl, (name_ptr)
    ld de, 8
    add hl, de
    ld a, 3
    ld (name_left), a
.ext:
    ld a, (hl)
    and 0x7F
    cp ' '
    jr z, .done
    push hl
    call cout
    pop hl
    inc hl
    ld a, (name_left)
    dec a
    ld (name_left), a
    jr nz, .ext
.done:
    ret

; ==========================================================================
; Failures and exit
; ==========================================================================
missing_file:
    ld de, FCB + 1
    call print_name11
    ld de, msg_missing
    call pstr
    jr fail

no_source:
    ld de, msg_no_source
    call pstr
    jr fail

source_read_error:
    ld de, msg_source_error
    call pstr
    jr fail

target_geometry:
    ld de, msg_bad_target
    call pstr
    jr fail

target_write_error:
    ld de, msg_write_error
    call pstr
    jr fail

target_verify_error:
    ld de, msg_verify_error
    call pstr
    jr fail

fail:
    jp finish

cancelled:
    call crlf
    ld de, msg_cancelled
    call pstr
    jp finish

usage:
    ld de, msg_usage
    call pstr
    jp finish

finish:
    ld a, (saved_drive)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    rst 0

; ==========================================================================
; USERF trampoline (patched at start)
; ==========================================================================
userf_call:
    call 0
userf_dw:
    dw 0
    ret

; ==========================================================================
; Data
; ==========================================================================
saved_drive:   db 0
tgt_unit:      db 0
file_idx:      db 0
boot_sec:      db 0
boot_sectors:  db 0
boot_ptr:      dw 0
off_next:      dw 0
recs_left:     dw 0
tmp_recs:      dw 0
name_ptr:      dw 0
name_left:     db 0
pd_h:          db 0
pd_t:          db 0
pd_u:          db 0
offs:          dw 0, 0, 0
recs:          dw 0, 0, 0
cmp_src:       dw 0
dma_ptr:       dw 0

name_ptrs:     dw name1, name2, name3
name1:         db "CPM3    SYS"
name2:         db "CPM3C   SYS"
name3:         db "CCP     COM"

msg_crlf:      db 0x0D, 0x0A, '$'
msg_title:     db 0x0D, 0x0A, "Make ", '$'
msg_title2:    db " bootable.", 0x0D, 0x0A, '$'
msg_about:
    db "The disc must be formatted; existing", 0x0D, 0x0A
    db "files are kept.", 0x0D, 0x0A
    db "Press any key (ESC cancels)", 0x0D, 0x0A, '$'
msg_reading:   db 0x0D, 0x0A, "Reading the system from A:...", 0x0D, 0x0A, '$'
msg_source:    db "Source: ", '$'
msg_ss:        db "SS, ", '$'
msg_ds:        db "DS, ", '$'
msg_tracks:    db " tracks, ", '$'
msg_sectors:   db " sectors.", 0x0D, 0x0A, '$'
msg_swap:
    db 0x0D, 0x0A, "Remove the system disc and put the", 0x0D, 0x0A
    db "TARGET disc in ", '$'
msg_swap2:     db ".", 0x0D, 0x0A, "Then press any key.", '$'
msg_boot:      db 0x0D, 0x0A, "Writing the boot track...", 0x0D, 0x0A, '$'
msg_writing:   db 0x0D, 0x0A, "Writing ", '$'
msg_checking:  db 0x0D, 0x0A, "Checking ", '$'
msg_ok:        db "... ok", 0x0D, 0x0A, '$'
msg_done:
    db 0x0D, 0x0A, "Done - the target disc is bootable.", 0x0D, 0x0A, '$'
msg_missing:   db " is not on A: - not a system disc?", 0x0D, 0x0A, '$'
msg_no_source: db "Cannot read the system disc in A:.", 0x0D, 0x0A, '$'
msg_source_error:
    db "Read error on the system disc.", 0x0D, 0x0A, '$'
msg_bad_target:
    db "The TARGET disc is not formatted like the system disc.", 0x0D, 0x0A, '$'
msg_write_error:
    db "Write error on the TARGET disc", 0x0D, 0x0A
    db "(write-protected, full or damaged).", 0x0D, 0x0A, '$'
msg_verify_error:
    db "Read-back error: the copy on the TARGET", 0x0D, 0x0A
    db "disc does not match the system files.", 0x0D, 0x0A, '$'
msg_no_memory: db " is too large for the buffer.", 0x0D, 0x0A, '$'
msg_cancelled: db "Cancelled.", 0x0D, 0x0A, '$'
msg_usage:
    db "SYSGEN target:", 0x0D, 0x0A
    db "  e.g. SYSGEN B:   (the system is read from A:)", 0x0D, 0x0A
    db "  The target must be formatted with the same layout.", 0x0D, 0x0A, '$'
