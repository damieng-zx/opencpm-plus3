; XTE-TEST.COM — XBIOS Terminal Emulator function tester
;
; Tests XBIOS TE functions via USERF (BIOS function 30).
;
; Build: sjasmplus --raw=build/xtetest.com src/test/xtetest.asm

    ORG 0100h

BDOS        EQU 0005h

; XBIOS extended jumpblock entries (bank 0, per the +3 CP/M Plus manual).
; USERF takes the entry address inline; our dispatcher uses its low byte.
TE_ASK          EQU 0x00BF
TE_RESET        EQU 0x00C2
TE_STL_ASK      EQU 0x00C5
TE_STL_ON_OFF   EQU 0x00C8
TE_SET_INK      EQU 0x00CB
TE_SET_BORDER   EQU 0x00CE
TE_SET_SPEED    EQU 0x00D1
SCR_RUN_ROUTINE EQU 0x00E9

; Phase-1 XBIOS disc entries
DD_INIT         EQU 0x0080
DD_SEL_FORMAT   EQU 0x0095
DD_READ_ID      EQU 0x009B
DD_L_ON_MOTOR   EQU 0x00A4
DD_L_T_OFF_MOTOR EQU 0x00A7
DD_OFF_MOTOR    EQU 0x00AA
DD_L_SEEK       EQU 0x00B3

; ============================================================
; Entry
; ============================================================
start:
    ; Compute USERF address from page zero
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl                      ; HL = BIOS base (bios_visible)
    ld de, 90
    add hl, de                  ; HL = USERF entry
    ld (userf_trampoline + 1), hl  ; Patch CALL in trampoline

    ; === Test 0: TE_RESET (run first — clears screen) ===
    ld hl, TE_RESET
    ld (userf_dw), hl
    call userf_trampoline

    ; --- Banner (after reset so it's visible) ---
    ld de, msg_header
    ld c, 9
    call BDOS

    ; === Test 1: TE_SET_BORDER (red) ===
    ld de, msg_t1
    ld c, 9
    call BDOS

    ld hl, TE_SET_BORDER
    ld (userf_dw), hl
    ld b, 0x0C                  ; Red: GG=00 RR=11 BB=00
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 2: TE_ASK ===
    ld de, msg_t2
    ld c, 9
    call BDOS

    ld hl, TE_ASK
    ld (userf_dw), hl
    call userf_trampoline
    ; B=top, C=left, D=height-1, E=width-1, H=row, L=col

    ; Save results before BDOS clobbers everything
    ld a, e
    inc a                       ; width = width-1 + 1
    ld (res_w), a
    ld a, d
    inc a
    ld (res_h), a
    ld a, h
    ld (res_r), a
    ld a, l
    ld (res_c), a

    ld a, (res_w)
    call print_dec
    ld e, 'x'
    ld c, 2
    call BDOS
    ld a, (res_h)
    call print_dec
    ld e, ' '
    ld c, 2
    call BDOS
    ld a, (res_r)
    call print_dec
    ld e, ','
    ld c, 2
    call BDOS
    ld a, (res_c)
    call print_dec

    ld de, msg_crlf
    ld c, 9
    call BDOS

    ; === Test 3: TE_SET_INK (yellow ink on black paper) ===
    ld de, msg_t3
    ld c, 9
    call BDOS

    ; Set paper to black
    ld hl, TE_SET_INK
    ld (userf_dw), hl
    ld a, 0                     ; paper
    ld b, 0x00                  ; black
    ld c, 0x00
    call userf_trampoline

    ; Set ink to yellow
    ld hl, TE_SET_INK
    ld (userf_dw), hl
    ld a, 1                     ; ink
    ld b, 0x3C                  ; yellow: GG=11 RR=11 BB=00
    ld c, 0x3C
    call userf_trampoline

    ld de, msg_yellow
    ld c, 9
    call BDOS

    ; --- Test 3b: both inks to a different flash colour ---
    ; Black paper with a yellow flash value, then yellow ink with a black
    ; flash value.  Both cells must carry the FLASH attribute (0x86).
    ld hl, TE_SET_INK
    ld (userf_dw), hl
    ld a, 0                     ; paper
    ld b, 0x00                  ; black
    ld c, 0x3C                  ; different => flashing
    call userf_trampoline

    ld hl, TE_SET_INK
    ld (userf_dw), hl
    ld a, 1                     ; ink
    ld b, 0x3C                  ; yellow
    ld c, 0x00                  ; different => flashing
    call userf_trampoline

    ld de, msg_flash
    ld c, 9
    call BDOS

    ; === Test 4: TE_STL_ASK ===
    ld de, msg_t4
    ld c, 9
    call BDOS

    ld hl, TE_STL_ASK
    ld (userf_dw), hl
    call userf_trampoline
    ; A=0 (disabled), Z set

    push af
    pop bc                      ; B=A, C=F
    ld a, b
    call print_hex
    ld e, ' '
    ld c, 2
    call BDOS
    ; Check Z flag
    bit 6, c                    ; Z flag is bit 6 of F
    jr nz, .stl_z
    ld de, msg_nz
    jr .stl_print
.stl_z:
    ld de, msg_zf
.stl_print:
    ld c, 9
    call BDOS

    ; === Test 5: Restore border (blue) ===
    ld de, msg_t5
    ld c, 9
    call BDOS

    ld hl, TE_SET_BORDER
    ld (userf_dw), hl
    ld b, 0x01                  ; Blue: GG=00 RR=00 BB=01
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 5b: TE_SET_SPEED (accepted and ignored on +3) ===
    ld de, msg_t5b
    ld c, 9
    call BDOS

    ld hl, TE_SET_SPEED
    ld (userf_dw), hl
    ld hl, 0x0A0A               ; H = main delay, L = alternate delay
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 6: TE_RESET (restore defaults after colour changes) ===
    ld de, msg_t6
    ld c, 9
    call BDOS

    ld hl, TE_RESET
    ld (userf_dw), hl
    call userf_trampoline

    ; Print after reset to confirm colours restored
    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 7: SCR_RUN_ROUTINE ===
    ; Copy the test routine into common memory (C000-F5FF), then run it
    ; with the screen paged in.  The routine checks DE/HL/IX/IY pass-through
    ; and writes 5Ah to the bottom-right attribute cell (bank 5, 5AFFh).
    ld de, msg_t7
    ld c, 9
    call BDOS

    ld hl, srr_code
    ld de, 0xD000
    ld bc, srr_code_end - srr_code
    ldir

    ld hl, SCR_RUN_ROUTINE
    ld (userf_dw), hl
    ld bc, 0xD000
    ld de, 0x1111
    ld hl, 0x2222
    ld ix, 0x3333
    ld iy, 0x4444
    call userf_trampoline

    ; DE = 1234h, HL = 5678h, IX = 9ABCh, IY = DEF0h
    ld a, d
    cp 0x12
    jr nz, .t7_fail
    ld a, e
    cp 0x34
    jr nz, .t7_fail
    ld a, h
    cp 0x56
    jr nz, .t7_fail
    ld a, l
    cp 0x78
    jr nz, .t7_fail
    push ix
    pop bc
    ld a, b
    cp 0x9A
    jr nz, .t7_fail
    ld a, c
    cp 0xBC
    jr nz, .t7_fail
    push iy
    pop bc
    ld a, b
    cp 0xDE
    jr nz, .t7_fail
    ld a, c
    cp 0xF0
    jr nz, .t7_fail
    ld a, (0xD100)              ; routine's input pass-through flag
    cp 1
    jr nz, .t7_fail
    ld de, msg_ok
    jr .t7_print
.t7_fail:
    ld de, msg_fail
.t7_print:
    ld c, 9
    call BDOS

    ; === Test 8: phase-1 XBIOS disc calls ===
    ld de, msg_t8
    ld c, 9
    call BDOS

    xor a
    ld (t8_ok), a

    ; DD_INIT
    ld hl, DD_INIT
    ld (userf_dw), hl
    call userf_trampoline

    ; DD_SEL_FORMAT: format 0 (+3/PCW SS), XDPB at D200h
    ld hl, DD_SEL_FORMAT
    ld (userf_dw), hl
    xor a
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t8_done

    ; SPT=36, BSH=3, BLM=7 at D200h..D203h
    ld a, (0xD200)
    cp 36
    jp nz, .t8_done
    ld a, (0xD201)
    or a
    jp nz, .t8_done
    ld a, (0xD202)
    cp 3
    jp nz, .t8_done
    ld a, (0xD203)
    cp 7
    jp nz, .t8_done

    ; DD_L_ON_MOTOR must preserve AF/BC/DE/HL
    ld hl, DD_L_ON_MOTOR
    ld (userf_dw), hl
    ld bc, 0x1234
    ld de, 0x5678
    ld hl, 0x9ABC
    ld a, 0x5A
    scf
    call userf_trampoline
    jp nc, .t8_done
    cp 0x5A
    jp nz, .t8_done
    ld a, b
    cp 0x12
    jp nz, .t8_done
    ld a, d
    cp 0x56
    jp nz, .t8_done
    ld a, h
    cp 0x9A
    jp nz, .t8_done

    ; DD_L_SEEK: unit 0, head 0, track 0
    ld hl, DD_L_SEEK
    ld (userf_dw), hl
    ld bc, 0
    ld d, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t8_done

    ; DD_READ_ID: unit 0, logical track 0
    ld hl, DD_READ_ID
    ld (userf_dw), hl
    ld bc, 0
    ld d, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t8_done
    cp 1                        ; READ ID returns the first sector found
    jp c, .t8_done
    cp 10                       ; +3 sectors are numbered 1-9
    jp nc, .t8_done
    ld a, (hl)                  ; result count
    cp 7
    jp nz, .t8_done
    ld de, 6
    add hl, de
    ld a, (hl)                  ; R
    cp 1
    jp c, .t8_done
    cp 10
    jp nc, .t8_done

    ; DD_L_T_OFF_MOTOR must preserve AF/BC/DE/HL
    ld hl, DD_L_T_OFF_MOTOR
    ld (userf_dw), hl
    ld bc, 0x1234
    ld de, 0x5678
    ld hl, 0x9ABC
    ld a, 0x5A
    scf
    call userf_trampoline
    jp nc, .t8_done
    cp 0x5A
    jp nz, .t8_done
    ld a, b
    cp 0x12
    jp nz, .t8_done
    ld a, d
    cp 0x56
    jp nz, .t8_done
    ld a, h
    cp 0x9A
    jp nz, .t8_done

    ld a, 1
    ld (t8_ok), a

.t8_done:
    ; Always stop the motor, even after a failure.
    ld hl, DD_L_T_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline

    ld a, (t8_ok)
    or a
    ld de, msg_fail
    jr z, .t8_print
    ld de, msg_ok
.t8_print:
    ld c, 9
    call BDOS

    ; === Done ===
    ld de, msg_done
    ld c, 9
    call BDOS

    rst 0


; ============================================================
; USERF trampoline — self-modifying code
; ============================================================
userf_trampoline:
    call 0                      ; Patched to USERF address (3 bytes)
userf_dw:
    dw 0                        ; Target address patched per call
    ret


; ============================================================
; srr_code — copied to D000h and run by SCR_RUN_ROUTINE
;   In:  DE=1111h, HL=2222h, IX=3333h, IY=4444h
;   Out: DE=1234h, HL=5678h, IX=9ABCh, IY=DEF0h
;   Writes 5Ah to the screen attribute at 5AFFh (bank 5) and 1 to
;   D100h when every input matched.  Only relative jumps are used, so
;   the block is position-independent.
; ============================================================
srr_code:
    ld a, e
    cp 0x11
    jr nz, .srr_ret
    ld a, d
    cp 0x11
    jr nz, .srr_ret
    ld a, l
    cp 0x22
    jr nz, .srr_ret
    ld a, h
    cp 0x22
    jr nz, .srr_ret
    push ix
    pop bc
    ld a, b
    cp 0x33
    jr nz, .srr_ret
    ld a, c
    cp 0x33
    jr nz, .srr_ret
    push iy
    pop bc
    ld a, b
    cp 0x44
    jr nz, .srr_ret
    ld a, c
    cp 0x44
    jr nz, .srr_ret
    ld a, 0x5A
    ld (0x5AFF), a             ; bottom-right attribute (bank 5)
    ld a, 1
    ld (0xD100), a
.srr_ret:
    ld de, 0x1234
    ld hl, 0x5678
    ld ix, 0x9ABC
    ld iy, 0xDEF0
    ret
srr_code_end:


; ============================================================
; print_dec — Print A as 2-digit decimal (0-99)
;   In:  A = value
;   Clobbers: AF, BC, DE
; ============================================================
print_dec:
    ld b, 0
.tens:
    cp 10
    jr c, .units
    sub 10
    inc b
    jr .tens
.units:
    push af
    ld a, b
    add a, '0'
    ld e, a
    ld c, 2
    call BDOS
    pop af
    add a, '0'
    ld e, a
    ld c, 2
    call BDOS
    ret


; ============================================================
; print_hex — Print A as 2-digit hex
;   In:  A = value
;   Clobbers: AF, BC, DE
; ============================================================
print_hex:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nib
    pop af
    call .nib
    ret
.nib:
    and 0x0F
    add a, '0'
    cp '9' + 1
    jr c, .dig
    add a, 7                    ; A-F
.dig:
    ld e, a
    ld c, 2
    call BDOS
    ret


; ============================================================
; Result storage
; ============================================================
res_w: db 0
res_h: db 0
res_r: db 0
res_c: db 0
t8_ok: db 0


; ============================================================
; Messages
; ============================================================
msg_header: db "XTE-TEST", 0x0D, 0x0A, '$'
msg_t1:     db "1.BORDER red..", '$'
msg_t2:     db "2.TE_ASK:", '$'
msg_t3:     db "3.INK..", '$'
msg_t4:     db "4.STL_ASK:", '$'
msg_t5:     db 0x0D, 0x0A, "5.BORDER blue..", '$'
msg_t5b:    db "5b.SPEED..", '$'
msg_t6:     db "6.RESET..", '$'
msg_t7:     db "7.RUN..", '$'
msg_t8:     db 0x0D, 0x0A, "8.DISK..", '$'
msg_fail:   db "FAIL", 0x0D, 0x0A, '$'
msg_t6ok:   db "6.RESET OK", 0x0D, 0x0A, '$'
msg_ok:     db "OK", 0x0D, 0x0A, '$'
msg_yellow: db "YELLOW TEXT", 0x0D, 0x0A, '$'
msg_flash:  db "FLASH TEXT", 0x0D, 0x0A, '$'
msg_nz:     db "NZ", 0x0D, 0x0A, '$'
msg_zf:     db "Z", 0x0D, 0x0A, '$'
msg_crlf:   db 0x0D, 0x0A, '$'
msg_done:   db "DONE", 0x0D, 0x0A, '$'
