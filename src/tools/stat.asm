; STAT.COM - drive space, file sizes/attributes, and attribute setting
;
;   STAT                 free space on each drive
;   STAT filespec        list matching files with size and attributes
;   STAT filespec $R/O   set read-only      ($R/W clears it)
;   STAT filespec $SYS   set the system attribute
;
; Free space comes from BDOS F46 (free 128-byte records), capacity from the
; drive's DPB (F31), sizes by summing the record count of every directory
; extent of the name, and attributes from the directory entry and F30.
;
; Build: sjasmplus --raw=build/stat.com src/tools/stat.asm

    org 0x0100

BDOS            equ 0x0005
F_CONOUT        equ 2
F_PSTR          equ 9
F_SELDRV        equ 14
F_SEARCH_FIRST  equ 17
F_SEARCH_NEXT   equ 18
F_CURDRV        equ 25
F_SETDMA        equ 26
F_SETATTR       equ 30
F_GETDPB        equ 31
F_FREE          equ 46

TAIL            equ 0x0080
FCB1            equ 0x005C

; ==========================================================================
; Entry
; ==========================================================================
start:
    ld c, F_CURDRV
    call BDOS
    ld (saved_drive), a

    ; An empty tail means the drive summary.
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, drive_summary
    inc hl
    call skip_spaces
    ld a, (hl)
    or a
    jp z, drive_summary
    cp 0x0D
    jp z, drive_summary

    ; A "$option" turns the command into an attribute change.
    call find_dollar
    jp nc, list_files
    call parse_option
    call set_attribute
    jp finish

; ==========================================================================
; Drive summary
; ==========================================================================
drive_summary:
    ld de, freebuf
    ld c, F_SETDMA
    call BDOS

    ld hl, 0
    ld (found_any), hl
    xor a
    ld (drv), a
.drive_loop:
    ; Select the drive, then fetch its DPB (F31 uses the current disk).
    ld a, (drv)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    ld c, F_GETDPB
    call BDOS
    ld a, h
    or l
    jr z, .next                  ; drive not present
    ld (dpb_ptr), hl

    ; "X: "
    ld a, (drv)
    add a, 'A'
    call cout
    ld a, ':'
    call cout
    ld a, ' '
    call cout

    ; Free space: F46 leaves three bytes at the DMA (128-byte records).
    ld a, (drv)
    ld e, a
    ld c, F_FREE
    call BDOS
    cp 0xFF
    jr z, .next
    ld a, (freebuf)
    ld e, a
    ld a, (freebuf + 1)
    ld d, a
    call de_div8                 ; DE = free K
    call print_de16
    ld de, msg_free
    call pstr

    ; Capacity: (DSM + 1) << (BSH - 3)
    ld hl, (dpb_ptr)
    inc hl
    inc hl
    ld a, (hl)                   ; BSH
    ld (bsh), a
    ld hl, (dpb_ptr)
    ld de, 5
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)                   ; DE = DSM
    inc de
    ld a, (bsh)
    cp 3
    jr z, .have_k
    jr c, .shift_right
    sub 3
    ld b, a
.shift_left:
    sla e
    rl d
    djnz .shift_left
    jr .have_k
.shift_right:
    ld b, a
    ld a, 3
    sub b
    ld b, a
.shift_right_loop:
    srl d
    rr e
    djnz .shift_right_loop
.have_k:
    call print_de16
    ld de, msg_capacity
    call pstr
    ld hl, 1
    ld (found_any), hl

.next:
    ld a, (drv)
    inc a
    ld (drv), a
    cp 3
    jp nz, .drive_loop

    ld hl, (found_any)
    ld a, h
    or l
    jp nz, finish
    ld de, msg_no_drives
    call pstr
    jp finish

; ==========================================================================
; File listing
; ==========================================================================
list_files:
    ld de, dma_buf
    ld c, F_SETDMA
    call BDOS
    xor a
    ld (have_prev), a
    ld hl, 0
    ld (total_recs), hl
    ld (file_count), hl

    ld de, FCB1
    ld c, F_SEARCH_FIRST
    call BDOS
.next:
    cp 0xFF
    jp z, .done

    ; A = index of the entry within the 128-byte dir sector.
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, dma_buf
    add hl, de
    ld (entry_ptr), hl

    ld a, (have_prev)
    or a
    jr z, .is_new

    ; Same name as the previous entry?  Then it is another extent.
    ld hl, (entry_ptr)
    inc hl
    ld de, prev
    ld b, 11
.cmp:
    ld a, (hl)
    and 0x7F
    ld c, a
    ld a, (de)
    cp c
    jr nz, .is_new
    inc hl
    inc de
    djnz .cmp
    ld hl, (entry_ptr)
    ld de, 15
    add hl, de
    ld a, (hl)
    ld l, a
    ld h, 0
    ex de, hl
    ld hl, (cur_recs)
    add hl, de
    ld (cur_recs), hl
    jr .advance

.is_new:
    ld a, (have_prev)
    or a
    call nz, flush_file
    ; Remember the name, size and attributes of this file.
    ld hl, (entry_ptr)
    inc hl
    ld de, prev
    ld bc, 11
    ldir
    ld a, 1
    ld (have_prev), a
    ld hl, (entry_ptr)
    ld de, 15
    add hl, de
    ld a, (hl)
    ld l, a
    ld h, 0
    ld (cur_recs), hl
    ld hl, (entry_ptr)
    ld de, 9
    add hl, de
    ld a, (hl)
    and 0x80
    ld (cur_ro), a
    ld hl, (entry_ptr)
    ld de, 10
    add hl, de
    ld a, (hl)
    and 0x80
    ld (cur_sys), a
    ld hl, (file_count)
    inc hl
    ld (file_count), hl

.advance:
    ld de, FCB1
    ld c, F_SEARCH_NEXT
    call BDOS
    jp .next

.done:
    ld a, (have_prev)
    or a
    call nz, flush_file

    ld hl, (file_count)
    ld a, h
    or l
    jr nz, .totals
    ld de, msg_no_files
    call pstr
    jp finish

.totals:
    ld hl, (file_count)
    ex de, hl
    call print_de16
    ld de, msg_files
    call pstr
    ld hl, (total_recs)
    call recs_to_k
    ex de, hl
    call print_de16
    ld de, msg_k
    call pstr
    jp finish

; flush_file - print the accumulated file and add it to the totals
;   In:       prev, cur_recs, cur_ro, cur_sys
;   Clobbers: everything
flush_file:
    ld de, prev
    call print_name11
    call col_to14
    ld hl, (cur_recs)
    call recs_to_k
    ex de, hl
    call print_de16
    ld a, 'K'
    call pc
    ld a, (cur_ro)
    or a
    jr z, .no_ro
    ld de, msg_ro
    call pstr
.no_ro:
    ld a, (cur_sys)
    or a
    jr z, .no_sys
    ld de, msg_sys
    call pstr
.no_sys:
    call crlf

    ld hl, (total_recs)
    ld de, (cur_recs)
    add hl, de
    ld (total_recs), hl
    xor a
    ld (have_prev), a
    ret

; ==========================================================================
; Attribute setting
; ==========================================================================
set_attribute:
    ; F30 matches exact names only (no wildcards), so say so up front.
    ld hl, FCB1 + 1
    ld b, 11
.check_wild:
    ld a, (hl)
    cp '?'
    jr z, .wild
    inc hl
    djnz .check_wild

    ; Build a fresh FCB from FCB1 (name only) and set/clear the bit.
    ld hl, fcb
    ld b, 36
.zero:
    ld (hl), 0
    inc hl
    djnz .zero
    ld hl, FCB1
    ld de, fcb
    ld bc, 12
    ldir

    ld a, (attr_op)
    cp 2
    jr z, .sys
    ld a, (fcb + 9)              ; T1 carries the R/O bit
    and 0x7F
    ld b, a
    ld a, (attr_op)
    or a
    jr nz, .clear_ro             ; R/W: leave the bit clear
    ld a, b
    or 0x80                      ; R/O: set it
    jr .store9
.clear_ro:
    ld a, b
.store9:
    ld (fcb + 9), a
    jr .call
.sys:
    ld a, (fcb + 10)             ; T2 carries SYS
    or 0x80
    ld (fcb + 10), a
    jr .call
.wild:
    ld de, msg_wild
    jp pstr

.call:
    ld de, fcb
    ld c, F_SETATTR
    call BDOS
    cp 0xFF
    jr z, .not_found

    ld de, FCB1 + 1
    call print_name11
    ld de, (attr_msg)
    jp pstr
.not_found:
    ld de, FCB1 + 1
    call print_name11
    ld de, msg_not_found
    jp pstr

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

; find_dollar - locate a "$option" in the tail
;   Out:      carry set + HL = '$' when found
;   Clobbers: AF, HL
find_dollar:
    ld hl, TAIL + 1
.loop:
    ld a, (hl)
    or a
    jr z, .none
    cp 0x0D
    jr z, .none
    cp '$'
    jr z, .found
    inc hl
    jr .loop
.none:
    or a
    ret
.found:
    scf
    ret

; parse_option - read the "$..." option after HL
;   In:       HL = '$'
;   Out:      attr_op (0 = R/O, 1 = R/W, 2 = SYS), attr_msg
;   Clobbers: AF, DE, HL
parse_option:
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'R'
    jr z, .r
    cp 'S'
    jp nz, usage
    ; "SYS"
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'Y'
    jp nz, usage
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'S'
    jp nz, usage
    ld a, 2
    ld (attr_op), a
    ld de, msg_set_sys
    ld (attr_msg), de
    jr .end
.r:
    inc hl
    ld a, (hl)
    cp '/'
    jp nz, usage
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'O'
    jr z, .ro
    cp 'W'
    jp nz, usage
    ld a, 1
    ld (attr_op), a
    ld de, msg_set_rw
    ld (attr_msg), de
    jr .end
.ro:
    xor a
    ld (attr_op), a
    ld de, msg_set_ro
    ld (attr_msg), de
.end:
    inc hl
.space_loop:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    jp nz, usage
    inc hl
    jr .space_loop

; recs_to_k - HL records -> HL kilobytes (rounded up)
;   Out:      HL = kilobytes
;   Clobbers: F, DE, HL
recs_to_k:
    ld de, 7
    add hl, de
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ret

; de_div8 - DE = DE / 8
;   Out:      DE = bytes / 8
;   Clobbers: F, DE
de_div8:
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    ret

; print_name11 - print an 11-byte CP/M name ("NAME.EXT"), trailing spaces cut
;   In:       DE = 11 bytes
;   Clobbers: everything
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
    call pc
    pop hl
    inc hl
    ld a, (name_left)
    dec a
    ld (name_left), a
    jr nz, .name
.dot:
    ld a, '.'
    call pc
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
    call pc
    pop hl
    inc hl
    ld a, (name_left)
    dec a
    ld (name_left), a
    jr nz, .ext
.done:
    ret

; col_to14 - pad the line with spaces up to column 14
;   Clobbers: AF, BC, DE ; lint: ignore - via pc
col_to14:
.loop:
    ld a, (col)
    cp 14
    ret nc
    ld a, ' '
    call pc
    jr .loop

; pc - print A and count the column
;   In:       A = character
;   Clobbers: AF, BC, DE ; lint: ignore
pc:
    push af
    ld a, (col)
    inc a
    ld (col), a
    pop af
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; cout - print A (no column bookkeeping; used for short fixed text)
;   In:       A = character
;   Clobbers: AF, BC, DE ; lint: ignore
cout:
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; pstr - print a '$'-terminated string
;   In:       DE = string
;   Clobbers: AF, BC, DE ; lint: ignore
pstr:
    ld c, F_PSTR
    jp BDOS

; crlf - end the line and reset the column counter
;   Clobbers: AF, BC, DE ; lint: ignore
crlf:
    xor a
    ld (col), a
    ld de, msg_crlf
    jp pstr

; print_de16 - print DE as decimal, no leading zeros
;   In:       DE = value
;   Clobbers: everything
print_de16:
    xor a
    ld (lead), a
    ld hl, 10000
    call .place
    ld hl, 1000
    call .place
    ld hl, 100
    call .place
    ld hl, 10
    call .place
    ld a, e
    add a, '0'
    jp pc
.place:
    ld b, 0
.sub:
    ld a, e
    sub l
    ld c, a
    ld a, d
    sbc a, h
    jr c, .under
    ld d, a
    ld e, c
    inc b
    jr .sub
.under:
    ld a, (lead)
    or a
    jr nz, .print
    ld a, b
    or a
    ret z
.print:
    ld a, 1
    ld (lead), a
    ld a, b
    add a, '0'
    push de                      ; pc (BDOS) clobbers DE: keep the remainder
    call pc
    pop de
    ret

; ==========================================================================
; Usage
; ==========================================================================
usage:
    ld de, msg_usage
    call pstr

finish:
    ; restore the default drive
    ld a, (saved_drive)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    rst 0

; ==========================================================================
; Data
; ==========================================================================
saved_drive:   db 0
drv:           db 0
bsh:           db 0
attr_op:       db 0
attr_msg:      dw 0
have_prev:     db 0
cur_ro:        db 0
cur_sys:       db 0
col:           db 0
lead:          db 0
digit:         db 0, 0
cur_recs:      dw 0
total_recs:    dw 0
file_count:    dw 0
found_any:     dw 0
dpb_ptr:       dw 0
entry_ptr:     dw 0
name_ptr:      dw 0
name_left:     db 0
prev:          ds 11
fcb:           ds 36
freebuf:       ds 4
dma_buf:       ds 128

msg_crlf:      db 0x0D, 0x0A, '$'
msg_free:      db "K free of ", '$'
msg_capacity:  db "K", 0x0D, 0x0A, '$'
msg_files:     db " file(s), ", '$'
msg_k:         db "K", 0x0D, 0x0A, '$'
msg_no_files:  db "No files", 0x0D, 0x0A, '$'
msg_no_drives: db "No drives", 0x0D, 0x0A, '$'
msg_ro:        db " R/O", '$'
msg_sys:       db " SYS", '$'
msg_not_found: db " not found", 0x0D, 0x0A, '$'
msg_set_ro:    db " set to R/O", 0x0D, 0x0A, '$'
msg_set_rw:    db " set to R/W", 0x0D, 0x0A, '$'
msg_set_sys:   db " set to SYS", 0x0D, 0x0A, '$'
msg_usage:
    db "STAT                 free space per drive", 0x0D, 0x0A
    db "STAT filespec        sizes and attributes", 0x0D, 0x0A
    db "STAT filespec $R/O   set read-only ($R/W clears)", 0x0D, 0x0A
    db "STAT filespec $SYS   set the system attribute", 0x0D, 0x0A, '$'
msg_wild:      db "Attribute changes need a specific file name.", 0x0D, 0x0A, '$'
