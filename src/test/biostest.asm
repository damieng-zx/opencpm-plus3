; ==========================================================================
; BIOSTEST.COM - direct BIOS jump-table checks
; ==========================================================================
; Calls the visible BIOS entries through the common-memory wrappers instead
; of going through the BDOS, so the jump-table order and the bank-4 entry
; points are covered directly.  BOOT/WBOOT, CONIN (blocking), BNKSEL (it
; would leave the TPA) and the XBIOS USERF entry (XTETEST) are skipped.
;
; The disc checks read the boot-track record, write it back unchanged and
; read it into a second buffer, so the running system disc is not altered.
;
; Build: sjasmplus --raw=build/biostest.com src/test/biostest.asm

    ORG 0100h

BDOS        equ 0005h
F_PSTR      equ 9
F_CONOUT    equ 2

; BIOS entries we call
B_CONST     equ 2
B_CONOUT    equ 4
B_LIST      equ 5
B_AUXOUT    equ 6
B_AUXIN     equ 7
B_HOME      equ 8
B_SELDSK    equ 9
B_SETTRK    equ 10
B_SETSEC    equ 11
B_SETDMA    equ 12
B_READ      equ 13
B_WRITE     equ 14
B_LISTST    equ 15
B_SECTRN    equ 16
B_CONOST    equ 17
B_AUXIST    equ 18
B_AUXOST    equ 19
B_DEVTBL    equ 20
B_DEVINIT   equ 21
B_DRVTBL    equ 22
B_MULTIO    equ 23
B_FLUSH     equ 24
B_MOVE      equ 25
B_TIME      equ 26
B_SETBNK    equ 28
B_XMOVE     equ 29

start:
    ld de, msg_header
    call print

    call t_b02
    call t_b04
    call t_b05
    call t_b06
    call t_b07
    call t_b08
    call t_b09
    call t_b10
    call t_b11
    call t_b12
    call t_b13
    call t_b14
    call t_b15
    call t_b16
    call t_b17
    call t_b18
    call t_b19
    call t_b20
    call t_b21
    call t_b22
    call t_b23
    call t_b24
    call t_b29                  ; XMOVE: TPA->TPA for the MOVE below
    call t_b25
    call t_b26
    call t_b28

    ld de, msg_done
    call print
    rst 0

; --------------------------------------------------------------------------
; B02 CONST - A = 00h (no key) or FFh (key ready)
; --------------------------------------------------------------------------
t_b02:
    ld de, lbl_02
    call print
    ld a, B_CONST
    call compute_bios_entry
    call call_bios_ent
    or a
    jp z, bpass
    cp 0FFh
    jp nz, bfail
    jp bpass

; --------------------------------------------------------------------------
; B04 CONOUT - print a marker character
; --------------------------------------------------------------------------
t_b04:
    ld de, lbl_04
    call print
    ld a, B_CONOUT
    call compute_bios_entry
    ld c, '.'
    call call_bios_ent
    jp bpass

; --------------------------------------------------------------------------
; B05 LIST, B06 AUXOUT - both are write-only stubs
; --------------------------------------------------------------------------
t_b05:
    ld de, lbl_05
    call print
    ld a, B_LIST
    call compute_bios_entry
    ld c, 'X'
    call call_bios_ent
    jp bpass

t_b06:
    ld de, lbl_06
    call print
    ld a, B_AUXOUT
    call compute_bios_entry
    ld c, 'X'
    call call_bios_ent
    jp bpass

; --------------------------------------------------------------------------
; B07 AUXIN - no serial device, so returns EOF (1Ah)
; --------------------------------------------------------------------------
t_b07:
    ld de, lbl_07
    call print
    ld a, B_AUXIN
    call compute_bios_entry
    call call_bios_ent
    cp 1Ah
    jp nz, bfail
    jp bpass

; --------------------------------------------------------------------------
; B08-B12 HOME, SELDSK, SETTRK, SETSEC, SETDMA - set up a boot-record read
; --------------------------------------------------------------------------
t_b08:
    ld de, lbl_08
    call print
    ld a, B_HOME
    call compute_bios_entry
    call call_bios_ent
    jp bpass

t_b09:
    ld de, lbl_09
    call print
    ld a, B_SELDSK
    call compute_bios_entry
    ld c, 0                    ; A:
    ld e, 0                    ; first select: probe the format
    call call_bios_ent
    ld a, h
    or l
    jp z, bfail
    jp bpass

t_b10:
    ld de, lbl_10
    call print
    ld a, B_SETTRK
    call compute_bios_entry
    ld bc, 0                   ; boot track
    call call_bios_ent
    jp bpass

t_b11:
    ld de, lbl_11
    call print
    ld a, B_SETSEC
    call compute_bios_entry
    ld bc, 0                   ; first 128-byte record
    call call_bios_ent
    jp bpass

t_b12:
    ld de, lbl_12
    call print
    ld a, B_SETDMA
    call compute_bios_entry
    ld bc, disk_buf
    call call_bios_ent
    jp bpass

; --------------------------------------------------------------------------
; B13 READ - read the boot-track record into disk_buf
; --------------------------------------------------------------------------
t_b13:
    ld de, lbl_13
    call print
    ld a, B_READ
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail
    jp bpass

; --------------------------------------------------------------------------
; B14 WRITE - write the same record back, then read it into disk_buf2 and
; compare.  The buffer already holds the bytes the READ returned, so the
; disc contents do not change.
; --------------------------------------------------------------------------
t_b14:
    ld de, lbl_14
    call print
    ld a, B_WRITE
    call compute_bios_entry
    xor a                      ; write type 0 (normal)
    ld c, a
    call call_bios_ent
    or a
    jp nz, bfail

    ; Read it back into a second buffer.
    ld a, B_SETDMA
    call compute_bios_entry
    ld bc, disk_buf2
    call call_bios_ent
    ld a, B_READ
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail

    ld hl, disk_buf
    ld de, disk_buf2
    ld b, 8
.cmp:
    ld a, (de)
    cp (hl)
    jp nz, bfail
    inc hl
    inc de
    djnz .cmp
    jp bpass

; --------------------------------------------------------------------------
; B15-B19 status stubs
; --------------------------------------------------------------------------
t_b15:
    ld de, lbl_15
    call print
    ld a, B_LISTST
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail
    jp bpass

t_b16:
    ld de, lbl_16
    call print
    ld a, B_SECTRN
    call compute_bios_entry
    ld bc, 5                   ; sector
    ld de, 0                   ; no translation table
    call call_bios_ent
    ld a, h
    or a
    jp nz, bfail
    ld a, l
    cp 5
    jp nz, bfail
    jp bpass

t_b17:
    ld de, lbl_17
    call print
    ld a, B_CONOST
    call compute_bios_entry
    call call_bios_ent
    cp 0FFh
    jp nz, bfail
    jp bpass

t_b18:
    ld de, lbl_18
    call print
    ld a, B_AUXIST
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail
    jp bpass

t_b19:
    ld de, lbl_19
    call print
    ld a, B_AUXOST
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail
    jp bpass

; --------------------------------------------------------------------------
; B20 DEVTBL, B22 DRVTBL - return table addresses
; --------------------------------------------------------------------------
t_b20:
    ld de, lbl_20
    call print
    ld a, B_DEVTBL
    call compute_bios_entry
    call call_bios_ent
    ld a, h
    or l
    jp z, bfail
    jp bpass

t_b21:
    ld de, lbl_21
    call print
    ld a, B_DEVINIT
    call compute_bios_entry
    call call_bios_ent
    jp bpass

t_b22:
    ld de, lbl_22
    call print
    ld a, B_DRVTBL
    call compute_bios_entry
    call call_bios_ent
    ld a, h
    or l
    jp z, bfail
    jp bpass

; --------------------------------------------------------------------------
; B23 MULTIO, B24 FLUSH
; --------------------------------------------------------------------------
t_b23:
    ld de, lbl_23
    call print
    ld a, B_MULTIO
    call compute_bios_entry
    ld a, 1
    call call_bios_ent
    jp bpass

t_b24:
    ld de, lbl_24
    call print
    ld a, B_FLUSH
    call compute_bios_entry
    call call_bios_ent
    or a
    jp nz, bfail
    jp bpass

; --------------------------------------------------------------------------
; B29 XMOVE (TPA -> TPA), then B25 MOVE
; --------------------------------------------------------------------------
t_b29:
    ld de, lbl_29
    call print
    ld a, B_XMOVE
    call compute_bios_entry
    ld b, 0                    ; destination bank: TPA
    ld c, 0                    ; source bank: TPA
    call call_bios_ent
    jp bpass

t_b25:
    ld de, lbl_25
    call print
    ld hl, move_junk
    ld de, move_dst
    ld bc, 8
    ldir                       ; seed the destination with junk first
    ld a, B_MOVE
    call compute_bios_entry
    ld hl, move_dst
    ld de, move_src
    ld bc, 8
    call call_bios_ent
    ld hl, move_src
    ld de, move_dst
    ld b, 8
.cmp:
    ld a, (de)
    cp (hl)
    jp nz, bfail
    inc hl
    inc de
    djnz .cmp
    jp bpass

; --------------------------------------------------------------------------
; B26 TIME, B28 SETBNK - stubs with no observable result
; --------------------------------------------------------------------------
t_b26:
    ld de, lbl_26
    call print
    ld a, B_TIME
    call compute_bios_entry
    ld c, 0
    call call_bios_ent
    jp bpass

t_b28:
    ld de, lbl_28
    call print
    ld a, B_SETBNK
    call compute_bios_entry
    xor a                      ; DMA bank 0 (TPA)
    call call_bios_ent
    jp bpass

; --------------------------------------------------------------------------
; Helpers
; --------------------------------------------------------------------------

; compute_bios_entry - A = function number; store its bank-4 entry
;   BIOS base = word at 0001h - 3 (0001h points at WBOOT, entry 1).
compute_bios_entry:
    ld l, a
    ld h, 0
    ld e, l
    ld d, h
    add hl, hl
    add hl, de                 ; HL = 3 * function
    ex de, hl
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    add hl, de
    ld (bios_ent), hl
    ret

; call_bios_ent - call the visible BIOS entry with the current registers.
call_bios_ent:
    ; lint-exempt: stack  ; indirect jump to the visible BIOS entry
    ld iy, (bios_ent)
    call .jp_iy
    ret
.jp_iy:
    jp (iy)

print:
    ld c, F_PSTR
    call BDOS
    ret

print_crlf:
    ld de, crlf
    ld c, F_PSTR
    jp BDOS

bpass:
    ld de, msg_pass
    ld c, F_PSTR
    call BDOS
    jp print_crlf

bfail:
    ld de, msg_fail
    ld c, F_PSTR
    call BDOS
    jp print_crlf

; --------------------------------------------------------------------------
; Data
; --------------------------------------------------------------------------
msg_header: db 0Dh, 0Ah, "BIOS jump table", 0Dh, 0Ah, '$'
msg_done:   db 0Dh, 0Ah, "BIOS DONE", 0Dh, 0Ah, '$'
msg_pass:   db "PASS$"
msg_fail:   db "FAIL$"
crlf:       db 0Dh, 0Ah, '$'

lbl_02:  db "B02 CONST   : $"
lbl_04:  db "B04 CONOUT  : $"
lbl_05:  db "B05 LIST    : $"
lbl_06:  db "B06 AUXOUT  : $"
lbl_07:  db "B07 AUXIN   : $"
lbl_08:  db "B08 HOME    : $"
lbl_09:  db "B09 SELDSK  : $"
lbl_10:  db "B10 SETTRK  : $"
lbl_11:  db "B11 SETSEC  : $"
lbl_12:  db "B12 SETDMA  : $"
lbl_13:  db "B13 READ    : $"
lbl_14:  db "B14 WRITE   : $"
lbl_15:  db "B15 LISTST  : $"
lbl_16:  db "B16 SECTRN  : $"
lbl_17:  db "B17 CONOST  : $"
lbl_18:  db "B18 AUXIST  : $"
lbl_19:  db "B19 AUXOST  : $"
lbl_20:  db "B20 DEVTBL  : $"
lbl_21:  db "B21 DEVINIT : $"
lbl_22:  db "B22 DRVTBL  : $"
lbl_23:  db "B23 MULTIO  : $"
lbl_24:  db "B24 FLUSH   : $"
lbl_25:  db "B25 MOVE    : $"
lbl_26:  db "B26 TIME    : $"
lbl_28:  db "B28 SETBNK  : $"
lbl_29:  db "B29 XMOVE   : $"

move_src:   db "BIOSMOVE"
move_junk:  db "XXXXXXXX"
move_dst:   ds 8

bios_ent:   dw 0
disk_buf:   ds 128
disk_buf2:  ds 128
