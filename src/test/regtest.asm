; REGTEST.COM — BDOS register preservation test
;
; CP/M 3 programs may rely on BC, DE, IX and IY surviving a BDOS call
; (only A, HL and the flags are documented as return values).  This
; program plants magic values in BC/DE/IX/IY, makes a BDOS call, and
; reports per register whether the value survived:
;
;   F12: B+ D+ X+ Y+      '+' = preserved, '-' = CLOBBERED,
;                         '.' = not checked (register is a call input)
;
; C and E always carry call inputs (function number, char), so only the
; high bytes B and D are checked for BC/DE.  IX and IY are checked in
; full.  Functions exercised: F12 (core), F2 (console/screen path), F25
; (disk status), F13 (disk reset), F15 OPEN (file path, FCB shadow).
;
; Build: sjasmplus --raw=build/regtest.com src/test/regtest.asm

    ORG 0100h

BDOS        EQU 0005h

; ============================================================
; Entry
; ============================================================
start:
    ld de, msg_header
    ld c, 9
    call BDOS

    ; --- F12 VERSION: no register inputs, core BDOS path ---
    call set_magic
    ld c, 12
    call BDOS
    call report_f12

    ; --- F2 CONOUT: E is input; exercises console/screen path ---
    call set_magic
    ld e, '*'
    ld c, 2
    call BDOS
    call report_f2

    ; --- F25 CURDSK: no register inputs; disk subsystem ---
    call set_magic
    ld c, 25
    call BDOS
    call report_f25

    ; --- F13 DISK RESET: no register inputs ---
    call set_magic
    ld c, 13
    call BDOS
    call report_f13

    ; --- F15 OPEN: DE is input (FCB); file path with FCB shadow ---
    call prep_fcb
    call set_magic
    ld de, 0x005C
    ld c, 15
    call BDOS
    call report_f15
    ld de, 0x005C               ; close it again
    ld c, 16
    call BDOS

    ld de, msg_done
    ld c, 9
    call BDOS
    rst 0                       ; warm boot back to CCP

; ============================================================
; Helpers
; ============================================================

; set_magic: plant the magic values in BC, DE, IX, IY
set_magic:
    ld bc, 0x1234
    ld de, 0x5678
    ld ix, 0xBEEF
    ld iy, 0xCAFE
    ret

; Comparators: A = '+' if the register still holds its magic, '-' if not.
; Only the non-input bytes are checked: B for BC (C = function number)
; and D for DE (E carries call inputs on some functions).
ck_bc:
    ld a, b
    cp 0x12
    jr nz, ck_no
    jr ck_yes
ck_de:
    ld a, d
    cp 0x56
    jr nz, ck_no
    jr ck_yes
ck_ix:
    ld a, ixh
    cp 0xBE
    jr nz, ck_no
    ld a, ixl
    cp 0xEF
    jr nz, ck_no
    jr ck_yes
ck_iy:
    ld a, iyh
    cp 0xCA
    jr nz, ck_no
    ld a, iyl
    cp 0xFE
    jr nz, ck_no
ck_yes:
    ld a, '+'
    ret
ck_no:
    ld a, '-'
    ret

; Report builders: patch the template, print via F9.
; Template layout: "F12: B. D. X. Y." — codes at offsets 6, 9, 12, 15.
report_f12:
    call ck_bc
    ld (out_f12 + 6), a
    call ck_de
    ld (out_f12 + 9), a
    call ck_ix
    ld (out_f12 + 12), a
    call ck_iy
    ld (out_f12 + 15), a
    ld de, out_f12
    ld c, 9
    jp BDOS

report_f2:                      ; DE is an input — not checked
    call ck_bc
    ld (out_f2 + 6), a
    call ck_ix
    ld (out_f2 + 12), a
    call ck_iy
    ld (out_f2 + 15), a
    ld de, out_f2
    ld c, 9
    jp BDOS

report_f25:
    call ck_bc
    ld (out_f25 + 6), a
    call ck_de
    ld (out_f25 + 9), a
    call ck_ix
    ld (out_f25 + 12), a
    call ck_iy
    ld (out_f25 + 15), a
    ld de, out_f25
    ld c, 9
    jp BDOS

report_f13:
    call ck_bc
    ld (out_f13 + 6), a
    call ck_de
    ld (out_f13 + 9), a
    call ck_ix
    ld (out_f13 + 12), a
    call ck_iy
    ld (out_f13 + 15), a
    ld de, out_f13
    ld c, 9
    jp BDOS

report_f15:                     ; DE is an input — not checked
    call ck_bc
    ld (out_f15 + 6), a
    call ck_ix
    ld (out_f15 + 12), a
    call ck_iy
    ld (out_f15 + 15), a
    ld de, out_f15
    ld c, 9
    jp BDOS

; prep_fcb: zero the default FCB at 005Ch, set name CPM3    SYS,
; point DMA at 0080h.
prep_fcb:
    ld hl, 0x005C
    ld b, 36
.clr:
    ld (hl), 0
    inc hl
    djnz .clr
    ld hl, fn_cpm3sys
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x0080
    ld c, 26                    ; F26 SETDMA
    jp BDOS

; ============================================================
; Data
; ============================================================

msg_header:
    DB 0Dh, 0Ah
    DB "REGTEST: BDOS register preservation", 0Dh, 0Ah
    DB "(+ = preserved, - = CLOBBERED, . = input)", 0Dh, 0Ah
    DB '$'

out_f12: DB "F12: B. D. X. Y.", 0Dh, 0Ah, '$'
out_f2:  DB "F02: B. D. X. Y.", 0Dh, 0Ah, '$'
out_f25: DB "F25: B. D. X. Y.", 0Dh, 0Ah, '$'
out_f13: DB "F13: B. D. X. Y.", 0Dh, 0Ah, '$'
out_f15: DB "F15: B. D. X. Y.", 0Dh, 0Ah, '$'

fn_cpm3sys: DB "CPM3    SYS"

msg_done:
    DB 0Dh, 0Ah, "REGTEST DONE", 0Dh, 0Ah, '$'
