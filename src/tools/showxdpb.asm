; SHOWXDPB.COM — Display each drive's XDPB with interpreted values
;
; For A: and B:, selects the drive (BDOS 14), fetches the DPB pointer
; (BDOS 31), and prints every field of the 27-byte XDPB. BDOS 31 returns
; the DPH's DPB pointer — in this BIOS that points at our 27-byte XDPB,
; so we can print the Amstrad extension fields too (bytes 17-26).
;
; Build: sjasmplus --raw=build/showxdpb.com src/tools/showxdpb.asm

    ORG 0x0100

BDOS         equ 0x0005

F_CONOUT     equ 2
F_PRINT      equ 9
F_SELDRV     equ 14
F_CURDRV     equ 25
F_GETDPB     equ 31
F_ERRMODE    equ 45

; XDPB field offsets
X_SPT   equ 0
X_BSH   equ 2
X_BLM   equ 3
X_EXM   equ 4
X_DSM   equ 5
X_DRM   equ 7
X_AL0   equ 9
X_AL1   equ 10
X_CKS   equ 11
X_OFF   equ 13
X_PSH   equ 15
X_PHM   equ 16
X_SIDES equ 17
X_TRKS  equ 18
X_SECTS equ 19
X_FIRST equ 20
X_SSZ   equ 21
X_GAP1  equ 23
X_GAP2  equ 24
X_FLAGS equ 25
X_FRZ   equ 26


start:
    ; Quiet error mode so a missing drive returns instead of panicking.
    ld e, 0xFF
    ld c, F_ERRMODE
    call BDOS

    ; Remember current drive so we can restore it on exit.
    ld c, F_CURDRV
    call BDOS
    ld (save_drv), a

    ld de, msg_hdr
    ld c, F_PRINT
    call BDOS

    xor a
    call show_drive               ; A:
    ld a, 1
    call show_drive               ; B:

    ; Restore drive and exit.
    ld a, (save_drv)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    rst 0

save_drv: db 0


; ===========================================================================
; show_drive — select a drive, fetch its DPB, print the XDPB.
;   In:  A = drive (0=A, 1=B, ...)
; ===========================================================================
show_drive:
    ld (cur_drv), a

    ; Print "X: " header.
    add a, 'A'
    ld e, a
    ld c, F_CONOUT
    call BDOS
    ld de, msg_colon_sp
    ld c, F_PRINT
    call BDOS

    ld a, (cur_drv)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    cp 0xFF
    jp z, .missing                ; BDOS returns 0xFF if drive not present

    ld c, F_GETDPB
    call BDOS                     ; HL = DPB/XDPB address
    ld (xdpb), hl

    ld de, msg_xdpb_at
    ld c, F_PRINT
    call BDOS
    ld hl, (xdpb)
    call print_hex16
    ld e, 'h'
    ld c, F_CONOUT
    call BDOS

    ; Summary: "  SS 40T 9x512 sectors (175K)"
    ld de, s_spaces2
    ld c, F_PRINT     : call BDOS
    ld a, X_SIDES     : call xdpb_byte
    call print_sides_name
    ld e, ' '         : ld c, F_CONOUT : call BDOS
    ld a, X_TRKS      : call xdpb_byte_dec
    ld e, 'T'         : ld c, F_CONOUT : call BDOS
    ld e, ' '         : ld c, F_CONOUT : call BDOS
    ld a, X_SECTS     : call xdpb_byte_dec
    ld e, 'x'         : ld c, F_CONOUT : call BDOS
    ld a, X_SSZ       : call xdpb_word_dec
    ld de, s_sectors
    ld c, F_PRINT     : call BDOS
    ld de, s_lparen
    ld c, F_PRINT     : call BDOS
    call print_total_kb
    ld de, s_k_rparen
    ld c, F_PRINT     : call BDOS
    call crlf

    ; ---- SPT BSH BLM EXM ----
    call indent
    ld de, s_spt      : call print_str
    ld a, X_SPT       : call xdpb_word_dec
    ld de, s_bsh      : call print_str
    ld a, X_BSH       : call xdpb_byte_dec
    ld de, s_lparen_bs
    ld c, F_PRINT     : call BDOS
    ld a, X_BSH       : call xdpb_byte
    call print_block_size
    ld e, ')'         : ld c, F_CONOUT : call BDOS
    ld de, s_blm      : call print_str
    ld a, X_BLM       : call xdpb_byte_dec
    ld de, s_exm      : call print_str
    ld a, X_EXM       : call xdpb_byte_dec
    call crlf

    ; ---- DSM (with size) DRM (with entries) ----
    call indent
    ld de, s_dsm      : call print_str
    ld a, X_DSM       : call xdpb_word_dec
    ld de, s_lparen
    ld c, F_PRINT     : call BDOS
    call print_total_kb
    ld de, s_k_rparen
    ld c, F_PRINT     : call BDOS
    ld de, s_drm      : call print_str
    ld a, X_DRM       : call xdpb_word_dec
    ld de, s_lparen
    ld c, F_PRINT     : call BDOS
    call print_dir_entries
    ld de, s_ent_rparen
    ld c, F_PRINT     : call BDOS
    call crlf

    ; ---- AL0 AL1 (dir blocks) CKS OFF ----
    call indent
    ld de, s_al0      : call print_str
    ld a, X_AL0       : call xdpb_byte_hex
    ld de, s_al1      : call print_str
    ld a, X_AL1       : call xdpb_byte_hex
    ld de, s_lparen
    ld c, F_PRINT     : call BDOS
    call print_dir_blocks
    ld de, s_db_rparen
    ld c, F_PRINT     : call BDOS
    ld de, s_cks      : call print_str
    ld a, X_CKS       : call xdpb_word_dec
    ld de, s_off      : call print_str
    ld a, X_OFF       : call xdpb_word_dec
    call crlf

    ; ---- PSH (sector size) PHM ----
    call indent
    ld de, s_psh      : call print_str
    ld a, X_PSH       : call xdpb_byte_dec
    ld de, s_lparen_bs
    ld c, F_PRINT     : call BDOS
    ld a, X_PSH       : call xdpb_byte
    call print_block_size
    ld e, ')'         : ld c, F_CONOUT : call BDOS
    ld de, s_phm      : call print_str
    ld a, X_PHM       : call xdpb_byte_dec
    call crlf

    ; ---- First Gap1 Gap2 ----
    call indent
    ld de, s_first_nopad : call print_str
    ld a, X_FIRST     : call xdpb_byte_hex
    ld de, s_gap1     : call print_str
    ld a, X_GAP1      : call xdpb_byte_hex
    ld de, s_gap2     : call print_str
    ld a, X_GAP2      : call xdpb_byte_hex
    call crlf

    ; ---- Flags Freeze (named) ----
    call indent
    ld de, s_flags    : call print_str
    ld a, X_FLAGS     : call xdpb_byte_hex
    ld de, s_freeze   : call print_str
    ld a, X_FRZ       : call xdpb_byte_hex
    ld e, '('         : ld c, F_CONOUT : call BDOS
    ld a, X_FRZ       : call xdpb_byte
    call print_freeze_name
    ld e, ')'         : ld c, F_CONOUT : call BDOS
    call crlf
    call crlf
    ret

.missing:
    ld de, msg_missing
    ld c, F_PRINT
    call BDOS
    ret


; ===========================================================================
; XDPB accessors — read field at offset A from the saved XDPB pointer.
; ===========================================================================

; xdpb_byte: In A=offset; Out A=byte, preserves HL/BC.
;   Clobbers: AF, DE (DE is scratch in the offset math)
xdpb_byte:
    push hl
    ld hl, (xdpb)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    pop hl
    ret

; xdpb_word: In A=offset; Out HL=word, preserves BC.
;   Clobbers: AF, DE (DE is scratch in the offset math)
xdpb_word:
    push de
    ld hl, (xdpb)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    pop de
    ret

xdpb_byte_dec:
    call xdpb_byte
    jp print_dec8

xdpb_byte_hex:
    call xdpb_byte
    call print_hex8
    ld e, 'h'
    ld c, F_CONOUT
    jp BDOS

xdpb_word_dec:
    call xdpb_word
    jp print_dec16


; ===========================================================================
; Interpretation helpers
; ===========================================================================

; print_block_size — Given A = shift (BSH or PSH), print decimal (128<<A).
;   Clobbers: AF, BC, DE, HL
print_block_size:
    ld h, 0
    ld l, 128
    or a
    jr z, .done
.loop:
    add hl, hl
    dec a
    jr nz, .loop
.done:
    jp print_dec16

; print_total_kb — Print (DSM+1)<<(BSH-3) as decimal (total KB usable).
;   Assumes BSH >= 3 (our formats all use 1K+ blocks). Clobbers all.
print_total_kb:
    ld a, X_DSM
    call xdpb_word                ; HL = DSM
    inc hl                         ; HL = DSM+1
    push hl
    ld a, X_BSH
    call xdpb_byte                 ; A = BSH
    pop hl
    sub 3
    jr z, .emit
    jr c, .emit                    ; BSH < 3 — skip shifts
.shift:
    add hl, hl
    dec a
    jr nz, .shift
.emit:
    jp print_dec16

; print_dir_entries — Print (DRM+1) in decimal.
print_dir_entries:
    ld a, X_DRM
    call xdpb_word
    inc hl
    jp print_dec16

; print_dir_blocks — Print popcount(AL0:AL1) in decimal.
print_dir_blocks:
    ld a, X_AL0
    call xdpb_byte
    call popcount8
    ld c, a
    ld a, X_AL1
    call xdpb_byte
    call popcount8
    add a, c
    jp print_dec8

; popcount8 — In A; Out A = number of 1-bits. Preserves BC (via swap).
popcount8:
    push bc
    ld b, 0
    ld c, 8
.loop:
    rrca
    jr nc, .skip
    inc b
.skip:
    dec c
    jr nz, .loop
    ld a, b
    pop bc
    ret

; print_sides_name — In A = sidedness byte; print "SS"/"alt-DS"/"succ-DS"/"?".
print_sides_name:
    cp 0 : jr z, .ss
    cp 1 : jr z, .alt
    cp 2 : jr z, .succ
    ld de, s_unknown
    jr .out
.ss:   ld de, s_ss   : jr .out
.alt:  ld de, s_alt  : jr .out
.succ: ld de, s_succ
.out:
    ld c, F_PRINT
    jp BDOS

; print_freeze_name — 00h = "auto", FFh = "frozen", else "?".
print_freeze_name:
    cp 0 : jr z, .auto
    cp 0xFF : jr z, .frozen
    ld de, s_unknown
    jr .out
.auto:   ld de, s_auto   : jr .out
.frozen: ld de, s_frozen
.out:
    ld c, F_PRINT
    jp BDOS


; ===========================================================================
; String and formatting primitives
; ===========================================================================

print_str:
    ld c, F_PRINT
    jp BDOS

indent:
    ld de, s_indent
    ld c, F_PRINT
    jp BDOS

crlf:
    ld de, s_crlf
    ld c, F_PRINT
    jp BDOS

; print_hex8 — A as 2 uppercase hex digits
print_hex8:
    push af
    rrca : rrca : rrca : rrca
    call _hex_nib
    pop af
    ; fall-through
_hex_nib:
    and 0x0F
    add a, '0'
    cp ':'
    jr c, .ok
    add a, 7
.ok:
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; print_hex16 — HL as 4 uppercase hex digits
print_hex16:
    ld a, h
    call print_hex8
    ld a, l
    jp print_hex8

; print_dec8 — A as decimal
print_dec8:
    ld h, 0
    ld l, a
    ; fall through

; print_dec16 — HL as decimal, no leading zeros
print_dec16:
    xor a
    ld (pd_lead), a
    ld de, 10000 : call pd_place
    ld de, 1000  : call pd_place
    ld de, 100   : call pd_place
    ld de, 10    : call pd_place
    ld a, l
    add a, '0'
    ld e, a
    ld c, F_CONOUT
    jp BDOS

pd_lead: db 0

pd_place:
    ld a, 0
    or a
.sub:
    sbc hl, de
    jr c, .under
    inc a
    jr .sub
.under:
    add hl, de
    or a
    jr nz, .nonzero
    ld a, (pd_lead)
    or a
    ret z
    xor a
    jr .emit
.nonzero:
    push af
    ld a, 1
    ld (pd_lead), a
    pop af
.emit:
    add a, '0'
    push bc
    push de
    push hl
    ld e, a
    ld c, F_CONOUT
    call BDOS
    pop hl
    pop de
    pop bc
    ret


; ===========================================================================
; State
; ===========================================================================
cur_drv: db 0
xdpb:    dw 0


; ===========================================================================
; Strings
; ===========================================================================
msg_hdr:      db "SHOWXDPB", 13, 10, 13, 10, "$"
msg_colon_sp: db ": $"
msg_xdpb_at:  db "XDPB @ $"
msg_missing:  db "not present", 13, 10, 13, 10, "$"

s_indent: db "  $"
s_crlf:   db 13, 10, "$"

s_spaces2:    db "  $"
s_sectors:    db " sectors$"
s_first_nopad: db "First=$"

s_spt:    db "SPT=$"
s_bsh:    db " BSH=$"
s_blm:    db " BLM=$"
s_exm:    db " EXM=$"
s_dsm:    db "DSM=$"
s_drm:    db " DRM=$"
s_al0:    db "AL0=$"
s_al1:    db " AL1=$"
s_cks:    db " CKS=$"
s_off:    db " OFF=$"
s_psh:    db "PSH=$"
s_phm:    db " PHM=$"
s_gap1:   db " Gap1=$"
s_gap2:   db " Gap2=$"
s_flags:  db "Flags=$"
s_freeze: db " Freeze=$"

s_lparen:      db " ($"
s_lparen_bs:   db "($"
s_k_rparen:    db "K) $"
s_ent_rparen:  db " ent)$"
s_db_rparen:   db " dir blk)$"

s_ss:      db "SS$"
s_alt:     db "alt-DS$"
s_succ:    db "succ-DS$"
s_auto:    db "auto$"
s_frozen:  db "frozen$"
s_unknown: db "?$"
