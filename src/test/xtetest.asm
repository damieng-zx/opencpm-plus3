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
DD_SETUP        EQU 0x0083
DD_SEL_FORMAT   EQU 0x0095
DD_READ_ID      EQU 0x009B
DD_L_ON_MOTOR   EQU 0x00A4
DD_L_T_OFF_MOTOR EQU 0x00A7
DD_OFF_MOTOR    EQU 0x00AA
DD_L_SEEK       EQU 0x00B3
DD_READ_SECTOR  EQU 0x0086
DD_WRITE        EQU 0x0089
DD_CHECK_SECTOR EQU 0x008C
DD_FORMAT       EQU 0x008F
DD_LOGIN        EQU 0x0092
DD_L_DPB        EQU 0x009E
DD_L_XDPB       EQU 0x00A1
DD_L_READ       EQU 0x00AD
DD_L_WRITE      EQU 0x00B0
KM_SET_EXPAND   EQU 0x00D4
KM_SET_KEY      EQU 0x00D7
KM_KT_GET       EQU 0x00DA
KM_KT_PUT       EQU 0x00DD
KM_SET_SPEED    EQU 0x00E0
CD_VERSION      EQU 0x00E3
CD_INFO         EQU 0x00E6
DD_DRIVE_STATUS EQU 0x0098

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

    ; TE_STL_ON_OFF is accepted and ignored; it must return with Z set.
    ld hl, TE_STL_ON_OFF
    ld (userf_dw), hl
    call userf_trampoline
    jr z, .stl_ask
    ld de, msg_nz
    jr .stl_print
.stl_ask:
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

    ; === Test 9: phase-2 disc calls ===
    ld de, msg_t9
    ld c, 9
    call BDOS

    xor a
    ld (t9_ok), a

    ; DD_LOGIN: unit 0, XDPB at D200h
    ld hl, DD_LOGIN
    ld (userf_dw), hl
    ld bc, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t9_fail_restore
    cp 0
    jp nz, .t9_fail_restore
    ld a, d
    cp 0
    jp nz, .t9_fail_restore
    ld a, e
    cp 45                       ; floor(174/4)+2
    jp nz, .t9_fail_restore
    ld a, h
    cp 1                        ; 4*(63+1) = 256
    jp nz, .t9_fail_restore
    ld a, l
    cp 0
    jp nz, .t9_fail_restore

    ; DD_READ_SECTOR: logical track 0, sector 0 into D300h
    ld hl, DD_READ_SECTOR
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0
    ld hl, 0xD300
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t9_fail_restore

    ; Boot-sector disc spec: 00 00 28 09 02 01 03 02 2A 52
    ld a, (0xD300)
    or a
    jp nz, .t9_fail_restore
    ld a, (0xD301)
    or a
    jp nz, .t9_fail_restore
    ld a, (0xD302)
    cp 0x28
    jp nz, .t9_fail_restore
    ld a, (0xD303)
    cp 9
    jp nz, .t9_fail_restore
    ld a, (0xD304)
    cp 2
    jp nz, .t9_fail_restore
    ld a, (0xD305)
    cp 1
    jp nz, .t9_fail_restore
    ld a, (0xD306)
    cp 3
    jp nz, .t9_fail_restore
    ld a, (0xD307)
    cp 2
    jp nz, .t9_fail_restore
    ld a, (0xD308)
    cp 0x2A
    jp nz, .t9_fail_restore
    ld a, (0xD309)
    cp 0x52
    jp nz, .t9_fail_restore

    ; DD_WRITE: write the same sector back unchanged
    ld hl, DD_WRITE
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0
    ld hl, 0xD300
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t9_fail_restore

    ; DD_CHECK_SECTOR: equal buffer
    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0
    ld hl, 0xD300
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t9_fail_restore
    jp nz, .t9_fail_restore

    ; DD_CHECK_SECTOR: one byte different
    ld a, 1
    ld (0xD300), a
    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0
    ld hl, 0xD300
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t9_fail_restore
    jr z, .t9_fail_restore
    xor a
    ld (0xD300), a

    ; DD_FORMAT: an unsupported bank must fail without formatting
    ld hl, DD_FORMAT
    ld (userf_dw), hl
    ld bc, 0
    ld de, 0
    ld hl, 0xD400
    ld ix, 0xD200
    call userf_trampoline
    jr c, .t9_fail_restore
    cp 9
    jp nz, .t9_fail_restore

    ld a, 1
    ld (t9_ok), a
    jr .t9_done

.t9_fail_restore:
    xor a
    ld (0xD300), a
.t9_done:
    ld a, (t9_ok)
    or a
    ld de, msg_fail
    jr z, .t9_print
    ld de, msg_ok
.t9_print:
    ld c, 9
    call BDOS

    ; === Test 10: optional destructive DD_FORMAT test ===
    ; Only runs when the harness has set the DC00h magic byte, so the
    ; normal boot-disk self-test never formats anything.
    ld a, (0xDC00)
    cp 0xA5
    jr nz, .t10_skip
    ld de, msg_t10
    ld c, 9
    call BDOS

    ; Header table at D500h: track 39, head 0, sectors 1-9, N=2.
    ld hl, 0xD500
    ld b, 1
.t10_hdr:
    ld a, 39
    ld (hl), a
    inc hl
    xor a
    ld (hl), a
    inc hl
    ld a, b
    ld (hl), a
    inc hl
    ld a, 2
    ld (hl), a
    inc hl
    inc b
    ld a, b
    cp 10
    jr nz, .t10_hdr

    ; DD_FORMAT: B=1, C=0, D=39, E=0xE5, HL=D500h, IX=D200h
    ld hl, DD_FORMAT
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0x27E5
    ld hl, 0xD500
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t10_fail

    ; Read track 39 sector 0 back into D300h.
    ld hl, DD_READ_SECTOR
    ld (userf_dw), hl
    ld bc, 0x0100
    ld de, 0x2700
    ld hl, 0xD300
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t10_fail

    ; The formatted data area is filled with 0xE5.
    ld hl, 0xD300
    ld b, 32
.t10_check:
    ld a, (hl)
    cp 0xE5
    jr nz, .t10_fail
    inc hl
    djnz .t10_check
    ld de, msg_ok
    jr .t10_print
.t10_fail:
    ld de, msg_fail
.t10_print:
    ld c, 9
    call BDOS
.t10_skip:

    ; === Test 11: DD_SETUP ===
    ld de, msg_t11
    ld c, 9
    call BDOS

    ; Default +3 parameter block at D600h
    ld hl, dd_setup_defaults
    ld de, 0xD600
    ld bc, 7
    ldir

    ld hl, DD_SETUP
    ld (userf_dw), hl
    ld hl, 0xD600
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 12: DD_L_DPB ===
    ld de, msg_t12
    ld c, 9
    call BDOS

    ld hl, dd_l_spec
    ld de, 0xD700
    ld bc, 10
    ldir

    ld hl, DD_L_DPB
    ld (userf_dw), hl
    ld hl, 0xD700
    ld ix, 0xD800
    call userf_trampoline
    jp nc, .t12_fail
    cp 0
    jp nz, .t12_fail

    ; Standard +3 DPB: SPT=36 BSH=3 BLM=7 EXM=0 DSM=174 DRM=63
    ; AL0=C0 AL1=00 CKS=16 OFF=1 PSH=2 PHM=3
    ld a, (0xD800)
    cp 36
    jp nz, .t12_fail
    ld a, (0xD801)
    or a
    jp nz, .t12_fail
    ld a, (0xD802)
    cp 3
    jp nz, .t12_fail
    ld a, (0xD803)
    cp 7
    jp nz, .t12_fail
    ld a, (0xD804)
    or a
    jp nz, .t12_fail
    ld a, (0xD805)
    cp 174
    jp nz, .t12_fail
    ld a, (0xD806)
    or a
    jp nz, .t12_fail
    ld a, (0xD807)
    cp 63
    jp nz, .t12_fail
    ld a, (0xD808)
    or a
    jp nz, .t12_fail
    ld a, (0xD809)
    cp 0xC0
    jp nz, .t12_fail
    ld a, (0xD80A)
    or a
    jp nz, .t12_fail
    ld a, (0xD80B)
    cp 16
    jp nz, .t12_fail
    ld a, (0xD80C)
    or a
    jp nz, .t12_fail
    ld a, (0xD80D)
    cp 1
    jp nz, .t12_fail
    ld a, (0xD80E)
    or a
    jp nz, .t12_fail
    ld a, (0xD80F)
    cp 2
    jp nz, .t12_fail
    ld a, (0xD810)
    cp 3
    jp nz, .t12_fail
    ld de, msg_ok
    jr .t12_print
.t12_fail:
    ld de, msg_fail
.t12_print:
    ld c, 9
    call BDOS

    ; === Test 13: DD_L_XDPB ===
    ld de, msg_t13
    ld c, 9
    call BDOS

    ld hl, DD_L_XDPB
    ld (userf_dw), hl
    ld hl, 0xD700
    ld ix, 0xD820
    call userf_trampoline
    jp nc, .t13_fail
    cp 0
    jp nz, .t13_fail

    ; DPB prefix
    ld a, (0xD820)
    cp 36
    jp nz, .t13_fail
    ld a, (0xD822)
    cp 3
    jp nz, .t13_fail
    ld a, (0xD825)
    cp 174
    jp nz, .t13_fail
    ld a, (0xD827)
    cp 63
    jp nz, .t13_fail

    ; Extension: sides, tracks, sectors, first, size, gap1, gap2,
    ; flags, freeze
    ld a, (0xD831)
    or a
    jp nz, .t13_fail
    ld a, (0xD832)
    cp 40
    jp nz, .t13_fail
    ld a, (0xD833)
    cp 9
    jp nz, .t13_fail
    ld a, (0xD834)
    cp 1
    jp nz, .t13_fail
    ld a, (0xD835)
    or a
    jp nz, .t13_fail
    ld a, (0xD836)
    cp 2
    jp nz, .t13_fail
    ld a, (0xD837)
    cp 0x2A
    jp nz, .t13_fail
    ld a, (0xD838)
    cp 0x52
    jp nz, .t13_fail
    ld a, (0xD839)
    cp 0x40
    jp nz, .t13_fail
    ld a, (0xD83A)
    cp 0xFF
    jp nz, .t13_fail
    ld de, msg_ok
    jr .t13_print
.t13_fail:
    ld de, msg_fail
.t13_print:
    ld c, 9
    call BDOS

    ; === Test 14: DD_L_READ ===
    ld de, msg_t14
    ld c, 9
    call BDOS

    xor a
    ld (t14_ok), a

    ; Motor on and seek track 0.
    ld hl, DD_L_ON_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_L_SEEK
    ld (userf_dw), hl
    ld bc, 0
    ld d, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t14_motor_off

    ; READ ID via DD_L_READ: command 4Ah, unit/head 00h, count 0.
    ld hl, lread_id_pb
    ld de, 0xD900
    ld bc, 8
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)                  ; result count
    cp 7
    jp nz, .t14_motor_off
    inc hl
    ld a, (hl)                  ; ST0
    and 0xC0
    cp 0x80
    jp nc, .t14_motor_off
    inc hl
    ld a, (hl)                  ; ST1
    and 0x3B
    jp nz, .t14_motor_off
    ld de, 4                    ; HL + 4 = R (ST0 ST1 ST2 C H R)
    add hl, de
    ld a, (hl)
    cp 1
    jp c, .t14_motor_off
    cp 10
    jp nc, .t14_motor_off

    ; READ DATA sector 1: command 46h, unit/head 0, C=0, H=0, R=1,
    ; N=2, EOT=1, GPL=2Ah, DTL=FFh, count=512, buffer=D300h.
    ld hl, lread_data_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t14_motor_off
    inc hl
    inc hl
    ld a, (hl)                  ; ST1
    and 0x3B
    jp nz, .t14_motor_off

    ; Boot-sector disc spec: 00 00 28 09 02 01 03 02 2A 52
    ld a, (0xD300)
    or a
    jp nz, .t14_motor_off
    ld a, (0xD301)
    or a
    jp nz, .t14_motor_off
    ld a, (0xD302)
    cp 0x28
    jp nz, .t14_motor_off
    ld a, (0xD303)
    cp 9
    jp nz, .t14_motor_off
    ld a, (0xD304)
    cp 2
    jp nz, .t14_motor_off
    ld a, (0xD308)
    cp 0x2A
    jp nz, .t14_motor_off
    ld a, (0xD309)
    cp 0x52
    jp nz, .t14_motor_off

    ld a, 1
    ld (t14_ok), a

.t14_motor_off:
    ld hl, DD_L_T_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline

    ld a, (t14_ok)
    or a
    ld de, msg_fail
    jr z, .t14_print
    ld de, msg_ok
.t14_print:
    ld c, 9
    call BDOS

    ; === Test 15: DD_L_WRITE ===
    ld de, msg_t15
    ld c, 9
    call BDOS

    xor a
    ld (t15_ok), a

    ld hl, DD_L_ON_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_L_SEEK
    ld (userf_dw), hl
    ld bc, 0
    ld d, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t15_motor_off

    ; Read sector 1 into D300h with DD_L_READ.
    ld hl, lread_data_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t15_motor_off

    ; Write the same sector back with DD_L_WRITE (0x45 = WRITE DATA).
    ld hl, lwrite_data_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_WRITE
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t15_motor_off
    inc hl
    inc hl
    ld a, (hl)                  ; ST1
    and 0x7B                    ; WP, DE, OR, ND, NW, MA
    jp nz, .t15_motor_off

    ; Read it back and verify the boot-sector prefix.
    ld hl, lread_data_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t15_motor_off
    ld a, (0xD300)
    or a
    jp nz, .t15_motor_off
    ld a, (0xD302)
    cp 0x28
    jp nz, .t15_motor_off
    ld a, (0xD303)
    cp 9
    jp nz, .t15_motor_off
    ld a, (0xD308)
    cp 0x2A
    jp nz, .t15_motor_off
    ld a, (0xD309)
    cp 0x52
    jp nz, .t15_motor_off

    ld a, 1
    ld (t15_ok), a

.t15_motor_off:
    ld hl, DD_L_T_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline

    ld a, (t15_ok)
    or a
    ld de, msg_fail
    jr z, .t15_print
    ld de, msg_ok
.t15_print:
    ld c, 9
    call BDOS

    ; === Test 16: KM_SET_SPEED ===
    ld de, msg_t16
    ld c, 9
    call BDOS

    ld hl, KM_SET_SPEED
    ld (userf_dw), hl
    ld hl, 0x0A05               ; H = 10 scans delay, L = 5 scans rate
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 17: KM_KT_PUT ===
    ld de, msg_t17
    ld c, 9
    call BDOS

    ; Put two tokens and check the registers survive.
    ld hl, KM_KT_PUT
    ld (userf_dw), hl
    ld bc, 0x082B               ; caps-lock shift, key 2Bh
    call userf_trampoline
    ld a, b
    cp 0x08
    jp nz, .t17_fail
    ld a, c
    cp 0x2B
    jp nz, .t17_fail

    ld bc, 0x001F               ; no shift, key 1Fh
    call userf_trampoline

    ld de, msg_ok
    jr .t17_print
.t17_fail:
    ld de, msg_fail
.t17_print:
    ld c, 9
    call BDOS

    ; === Test 18: KM_KT_GET ===
    ld de, msg_t18
    ld c, 9
    call BDOS

    ld hl, KM_KT_GET
    ld (userf_dw), hl
    call userf_trampoline
    jp nc, .t18_fail
    ld a, b
    cp 0x08                     ; caps-lock shift state
    jp nz, .t18_fail
    ld a, c
    cp 0x2B
    jp nz, .t18_fail

    call userf_trampoline
    jp nc, .t18_fail
    ld a, b
    or a
    jp nz, .t18_fail
    ld a, c
    cp 0x1F
    jp nz, .t18_fail

    ; Empty queue: carry clear, B = last lock state (0), C undefined.
    call userf_trampoline
    jp c, .t18_fail
    ld a, b
    or a
    jp nz, .t18_fail

    ; DE and HL must survive the call.
    ld de, 0x1234
    ld hl, 0x5678
    call userf_trampoline
    jp c, .t18_fail
    ld a, d
    cp 0x12
    jp nz, .t18_fail
    ld a, e
    cp 0x34
    jp nz, .t18_fail
    ld a, h
    cp 0x56
    jp nz, .t18_fail
    ld a, l
    cp 0x78
    jp nz, .t18_fail

    ld de, msg_ok
    jr .t18_print
.t18_fail:
    ld de, msg_fail
.t18_print:
    ld c, 9
    call BDOS

    ; === Test 19: KM_SET_KEY ===
    ; Remap Z (raw key 1) in the normal table to 'Q', then wait for the
    ; harness to press Z and check the translated character.
    ld de, msg_t19
    ld c, 9
    call BDOS

    ld hl, KM_SET_KEY
    ld (userf_dw), hl
    ld bc, 0x5101               ; B = 'Q', C = key 1 (Z)
    ld de, 0x0100               ; D = normal table, E = unchanged
    call userf_trampoline
    ld a, c
    cp 1
    jp nz, .t19_fail
    ld a, b
    cp 0x51
    jp nz, .t19_fail
    ld a, d
    cp 0x01
    jp nz, .t19_fail

.t19_wait:
    ld c, 6                     ; direct console input, no echo
    ld e, 0xFF
    call BDOS
    or a
    jr z, .t19_wait
    cp 0x51                     ; 'Q'
    jp nz, .t19_fail

    ; Restore the built-in translation for key 1.
    ld hl, KM_SET_KEY
    ld (userf_dw), hl
    ld bc, 0xFF01
    ld de, 0x0100
    call userf_trampoline

    ld de, msg_ok
    jr .t19_print
.t19_fail:
    ld de, msg_fail
.t19_print:
    ld c, 9
    call BDOS

    ; === Test 20: KM_SET_EXPAND ===
    ld de, msg_t20
    ld c, 9
    call BDOS

    ; String at DD00h (common memory).
    ld hl, exp_string
    ld de, 0xDD00
    ld bc, 5
    ldir

    ld hl, KM_SET_EXPAND
    ld (userf_dw), hl
    ld hl, 0xDD00
    ld bc, 0x8505               ; B = token 85h, C = 5 characters
    call userf_trampoline
    jp nc, .t20_fail

    ; Token 7Fh is not an expansion token.
    ld hl, 0xDD00
    ld bc, 0x7F05
    call userf_trampoline
    jp c, .t20_fail

    ; 32 characters is too long.
    ld hl, 0xDD00
    ld bc, 0x8520
    call userf_trampoline
    jp c, .t20_fail

    ld de, msg_ok
    jr .t20_print
.t20_fail:
    ld de, msg_fail
.t20_print:
    ld c, 9
    call BDOS

    ; === Test 21: CD_VERSION ===
    ld de, msg_t21
    ld c, 9
    call BDOS

    ld hl, CD_VERSION
    ld (userf_dw), hl
    call userf_trampoline
    cp 3                        ; machine type 3 (+3)
    jp nz, .t21_fail
    ld a, b
    cp 1                        ; major version 1
    jp nz, .t21_fail
    ld a, c
    or a                        ; minor version 0
    jp nz, .t21_fail

    ld de, msg_ok
    jr .t21_print
.t21_fail:
    ld de, msg_fail
.t21_print:
    ld c, 9
    call BDOS

    ; === Test 22: CD_INFO ===
    ld de, msg_t22
    ld c, 9
    call BDOS

    ld hl, CD_INFO
    ld (userf_dw), hl
    call userf_trampoline
    or a                        ; A = 0 (one drive)
    jp nz, .t22_fail
    ld a, b
    cp 8                        ; 128K = 8 x 16K banks
    jp nz, .t22_fail
    ld a, c
    or a                        ; no serial
    jp nz, .t22_fail
    ld a, d
    or a                        ; no B: drive
    jp nz, .t22_fail
    ld a, e
    cp 0x15                     ; SS 40-track 3-inch
    jp nz, .t22_fail

    ; HL must point into common memory and hold the 0xFF terminator.
    ld a, h
    cp 0xC0
    jp c, .t22_fail
    ld a, (hl)
    inc a                       ; 0xFF + 1 = 0
    jp nz, .t22_fail

    ld de, msg_ok
    jr .t22_print
.t22_fail:
    ld de, msg_fail
.t22_print:
    ld c, 9
    call BDOS

    ; === Test 23: DD_DRIVE_STATUS ===
    ld de, msg_t23
    ld c, 9
    call BDOS

    ; Drive A, head 0: Ready + Track0, and B/DE must survive.
    ld hl, DD_DRIVE_STATUS
    ld (userf_dw), hl
    ld bc, 0x1200               ; B = 12h, C = unit 0 head 0
    ld de, 0x3456
    call userf_trampoline
    cp 0x30
    jp nz, .t23_fail
    ld a, b
    cp 0x12
    jp nz, .t23_fail
    ld a, d
    cp 0x34
    jp nz, .t23_fail
    ld a, e
    cp 0x56
    jp nz, .t23_fail

    ; Drive A, head 1: ST3 bit 2 mirrors the requested head.
    ld bc, 0x1204
    ld de, 0x3456
    call userf_trampoline
    cp 0x34
    jp nz, .t23_fail

    ; Unit 1: not fitted, unit bit set, Ready/WP clear.
    ld bc, 0x1201
    ld de, 0x3456
    call userf_trampoline
    cp 0x01
    jp nz, .t23_fail

    ld de, msg_ok
    jr .t23_print
.t23_fail:
    ld de, msg_fail
.t23_print:
    ld c, 9
    call BDOS

    ; === Test 24: KM_KT queue overflow and wrap ===
    ld de, msg_t24
    ld c, 9
    call BDOS

    ; Put 17 tokens: the queue is 16 deep, so the last one is dropped.
    ld hl, KM_KT_PUT
    ld (userf_dw), hl
    ld ix, 17
    ld c, 0x40
.t24_fill:
    ld b, 0
    call userf_trampoline
    inc c
    dec ix
    ld a, ixh
    or ixl
    jr nz, .t24_fill

    ; Drain 16 in order and check the 17th (0x50) was discarded.
    ld hl, KM_KT_GET
    ld (userf_dw), hl
    ld ix, 16
    ld e, 0x40
.t24_drain:
    call userf_trampoline
    jp nc, .t24_fail
    ld a, c
    cp e
    jp nz, .t24_fail
    inc e
    dec ix
    ld a, ixh
    or ixl
    jr nz, .t24_drain

    ; Queue must be empty now (the 17th put was dropped).
    call userf_trampoline
    jp c, .t24_fail

    ; 20 put/get cycles exercise head/tail wrap past 16.
    ld ix, 20
    ld e, 0x60
.t24_wrap:
    ld hl, KM_KT_PUT
    ld (userf_dw), hl
    ld b, 0
    ld c, e
    call userf_trampoline
    ld hl, KM_KT_GET
    ld (userf_dw), hl
    call userf_trampoline
    jp nc, .t24_fail
    ld a, c
    cp e
    jp nz, .t24_fail
    inc e
    dec ix
    ld a, ixh
    or ixl
    jr nz, .t24_wrap

    ld de, msg_ok
    jr .t24_print
.t24_fail:
    ld de, msg_fail
.t24_print:
    ld c, 9
    call BDOS

    ; === Test 25: KM_SET_KEY masks and bounds ===
    ; The smoke runner reads the table back from bank 6; these calls just
    ; set entries in the non-normal tables plus the no-op cases, so later
    ; smoke commands are not affected by remapped letters.
    ld de, msg_t25
    ld c, 9
    call BDOS

    ld hl, KM_SET_KEY
    ld (userf_dw), hl

    ; Key 2 (X) -> 'A' in CAPS only.
    ld bc, 0x4102
    ld de, 0x0200
    call userf_trampoline

    ; Key 3 (C) -> 'B' in SYMB only.
    ld bc, 0x4203
    ld de, 0x0400
    call userf_trampoline

    ; Key 4 (V) -> 'C' in EXTEND only.
    ld bc, 0x4304
    ld de, 0x0800
    call userf_trampoline

    ; Key 5 (A) -> 'F' in CAPS, SYMB and EXTEND (combined mask, no normal).
    ld bc, 0x4605
    ld de, 0x0E00
    call userf_trampoline

    ; Key 6 (S) -> 'G' in CAPS...
    ld bc, 0x4706
    ld de, 0x0200
    call userf_trampoline
    ; ...then an invalid key number (40) and a zero mask must not change it.
    ld bc, 0x4828
    ld de, 0x0200
    call userf_trampoline
    ld bc, 0x4906
    ld de, 0x0000
    call userf_trampoline

    ; Boundary key 39 (B) -> 'J' in CAPS.
    ld bc, 0x4A27
    ld de, 0x0200
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 26: KM_SET_EXPAND boundaries ===
    ld de, msg_t26
    ld c, 9
    call BDOS

    ; 31-byte string in common memory.
    ld hl, exp31
    ld de, 0xDD20
    ld bc, 31
    ldir

    ld hl, KM_SET_EXPAND
    ld (userf_dw), hl

    ; Token 80h, length 0 (empty string).
    ld hl, 0xDD20
    ld bc, 0x8000
    call userf_trampoline
    jp nc, .t26_fail

    ; Token 80h, length 32: too long, slot must stay empty.
    ld hl, 0xDD20
    ld bc, 0x8020
    call userf_trampoline
    jp c, .t26_fail

    ; Token 9Eh, length 31 (maximum).
    ld hl, 0xDD20
    ld bc, 0x9E1F
    call userf_trampoline
    jp nc, .t26_fail

    ; Token 9Fh is not an expansion token.
    ld hl, 0xDD20
    ld bc, 0x9F01
    call userf_trampoline
    jp c, .t26_fail

    ld de, msg_ok
    jr .t26_print
.t26_fail:
    ld de, msg_fail
.t26_print:
    ld c, 9
    call BDOS

    ; === Test 27: KM_SET_SPEED 0 means 256 ===
    ; Leave 0/0 in place; the smoke runner reads the stored words.
    ld de, msg_t27
    ld c, 9
    call BDOS

    ld hl, KM_SET_SPEED
    ld (userf_dw), hl
    ld hl, 0x0000
    call userf_trampoline

    ld de, msg_ok
    ld c, 9
    call BDOS

    ; === Test 28: DD_L_READ depth ===
    ld de, msg_t28
    ld c, 9
    call BDOS

    xor a
    ld (t28_ok), a

    ; Motor on, seek track 0.
    ld hl, DD_L_ON_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_L_SEEK
    ld (userf_dw), hl
    ld bc, 0
    ld d, 0
    ld ix, 0xD200
    call userf_trampoline
    jp nc, .t28_off

    ; Multi-sector READ DATA: sectors 1-2 into D400h (1024 bytes).
    ld hl, lread_multi_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t28_off
    inc hl
    inc hl
    ld a, (hl)
    and 0x3B
    jp nz, .t28_off

    ; Single-sector READ DATA for sector 2 into E000h.
    ld hl, lread_one_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t28_off
    inc hl
    inc hl
    ld a, (hl)
    and 0x3B
    jp nz, .t28_off

    ; The second half of the multi-sector read must match sector 2.
    ld hl, 0xD600
    ld de, 0xE000
    ld bc, 512
.t28_cmp:
    ld a, (de)
    cp (hl)
    jp nz, .t28_off
    inc hl
    inc de
    dec bc
    ld a, b
    or c
    jr nz, .t28_cmp

    ; Bank != 1 is rejected without transferring data.
    ld hl, lread_bank0_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    or a
    jp nz, .t28_off

    ; Missing sector: the result phase must still come back (ND/MA set).
    ld hl, lread_bad_pb
    ld de, 0xD900
    ld bc, 15
    ldir
    ld hl, DD_L_READ
    ld (userf_dw), hl
    ld hl, 0xD900
    call userf_trampoline
    ld a, (hl)
    cp 7
    jp nz, .t28_off
    inc hl
    inc hl
    ld a, (hl)                  ; ST1
    and 0x05                    ; ND or MA
    jp z, .t28_off

    ld a, 1
    ld (t28_ok), a

.t28_off:
    ld hl, DD_L_T_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline
    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_trampoline

    ld a, (t28_ok)
    or a
    ld de, msg_fail
    jr z, .t28_print
    ld de, msg_ok
.t28_print:
    ld c, 9
    call BDOS

    ; === Test 29: invalid DPB/XDPB specs ===
    ld de, msg_t29
    ld c, 9
    call BDOS

    ld ix, bad_specs
    ld b, 8
.t29_loop:
    push bc
    push ix
    push ix
    pop hl
    ld de, 0xD700
    ld bc, 10
    ldir
    ld hl, DD_L_XDPB
    ld (userf_dw), hl
    ld hl, 0xD700
    ld ix, 0xD800
    call userf_trampoline
    pop ix
    pop bc
    jp c, .t29_fail
    cp 6
    jp nz, .t29_fail
    ld de, 10
    add ix, de
    djnz .t29_loop

    ; DD_L_DPB must reject the same way (type 4 for a single check).
    ld hl, bad_specs
    ld de, 0xD700
    ld bc, 10
    ldir
    ld hl, DD_L_DPB
    ld (userf_dw), hl
    ld hl, 0xD700
    ld ix, 0xD800
    call userf_trampoline
    jp c, .t29_fail
    cp 6
    jp nz, .t29_fail

    ; DD_SEL_FORMAT rejects format 4.
    ld hl, DD_SEL_FORMAT
    ld (userf_dw), hl
    ld a, 4
    ld ix, 0xD800
    call userf_trampoline
    jp c, .t29_fail
    cp 6
    jp nz, .t29_fail

    ld de, msg_ok
    jr .t29_print
.t29_fail:
    ld de, msg_fail
.t29_print:
    ld c, 9
    call BDOS

    ; === Test 30: DD_SETUP edge values ===
    ; Motor-off 0 (never), step rate 0 (clamped to 16 ms), HUT 15,
    ; head-load 0x7F with non-DMA set.  Left in place for the smoke to read.
    ld de, msg_t30
    ld c, 9
    call BDOS

    ld hl, setup_pb_edge
    ld de, 0xD600
    ld bc, 7
    ldir
    ld hl, DD_SETUP
    ld (userf_dw), hl
    ld hl, 0xD600
    call userf_trampoline

    ld de, msg_ok
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
t9_ok: db 0
t14_ok: db 0
t15_ok: db 0
t28_ok: db 0
dd_setup_defaults: db 10, 50, 175, 30, 12, 15, 3
dd_l_spec: db 0, 0, 40, 9, 2, 1, 3, 2, 42, 82

lread_id_pb:
    db 1
    dw 0xD300
    dw 0
    db 2
    db 0x4A, 0x00
lread_data_pb:
    db 1
    dw 0xD300
    dw 512
    db 9
    db 0x46, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x2A, 0xFF
setup_pb_edge: db 10, 0, 175, 30, 0, 15, 0xFF
bad_specs:
    db 4, 0, 40, 9, 2, 1, 3, 2, 42, 82    ; bad disc type
    db 0, 3, 40, 9, 2, 1, 3, 2, 42, 82    ; bad arrangement
    db 0, 0, 0, 9, 2, 1, 3, 2, 42, 82     ; zero tracks
    db 0, 0, 40, 0, 2, 1, 3, 2, 42, 82    ; zero sectors
    db 0, 0, 40, 9, 3, 1, 3, 2, 42, 82    ; bad sector size
    db 0, 0, 40, 9, 2, 1, 8, 2, 42, 82    ; bad block size
    db 0, 0, 40, 9, 2, 1, 3, 0, 42, 82    ; zero directory blocks
    db 0, 0, 40, 9, 2, 1, 3, 17, 42, 82   ; too many directory blocks
lread_multi_pb:
    db 1
    dw 0xD400
    dw 1024
    db 9
    db 0x46, 0x00, 0x00, 0x00, 0x01, 0x02, 0x02, 0x2A, 0xFF
lread_one_pb:
    db 1
    dw 0xE000
    dw 512
    db 9
    db 0x46, 0x00, 0x00, 0x00, 0x02, 0x02, 0x02, 0x2A, 0xFF
lread_bank0_pb:
    db 0
    dw 0xD400
    dw 1024
    db 9
    db 0x46, 0x00, 0x00, 0x00, 0x01, 0x02, 0x02, 0x2A, 0xFF
lread_bad_pb:
    db 1
    dw 0xD400
    dw 0
    db 9
    db 0x46, 0x00, 0x00, 0x00, 0x14, 0x02, 0x14, 0x2A, 0xFF
lwrite_data_pb:
    db 1
    dw 0xD300
    dw 512
    db 9
    db 0x45, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x2A, 0xFF


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
msg_t9:     db 0x0D, 0x0A, "9.RW..", '$'
msg_t10:    db 0x0D, 0x0A, "10.FMT..", '$'
msg_t11:    db 0x0D, 0x0A, "11.SETUP..", '$'
msg_t12:    db 0x0D, 0x0A, "12.DPB..", '$'
msg_t13:    db 0x0D, 0x0A, "13.XDPB..", '$'
msg_t14:    db 0x0D, 0x0A, "14.LREAD..", '$'
msg_t15:    db 0x0D, 0x0A, "15.LWRITE..", '$'
msg_t16:    db 0x0D, 0x0A, "16.KMSPD..", '$'
msg_t17:    db 0x0D, 0x0A, "17.KTPUT..", '$'
msg_t18:    db 0x0D, 0x0A, "18.KTGET..", '$'
msg_t19:    db 0x0D, 0x0A, "19.KTAB..", '$'
msg_t20:    db 0x0D, 0x0A, "20.EXP..", '$'
msg_t21:    db 0x0D, 0x0A, "21.CDVER..", '$'
msg_t22:    db 0x0D, 0x0A, "22.CDINFO..", '$'
msg_t23:    db 0x0D, 0x0A, "23.DRIVESTAT..", '$'
msg_t24:    db 0x0D, 0x0A, "24.KTWRAP..", '$'
msg_t25:    db 0x0D, 0x0A, "25.SETKEY..", '$'
msg_t26:    db 0x0D, 0x0A, "26.EXPMAX..", '$'
msg_t27:    db 0x0D, 0x0A, "27.KMZERO..", '$'
msg_t28:    db 0x0D, 0x0A, "28.LREADX..", '$'
msg_t29:    db 0x0D, 0x0A, "29.BADSPEC..", '$'
msg_t30:    db 0x0D, 0x0A, "30.SETUPX..", '$'
exp_string: db "HELLO"
exp31:      db "0123456789ABCDEFGHIJKLMNOPQRSTU"
msg_fail:   db "FAIL", 0x0D, 0x0A, '$'
msg_t6ok:   db "6.RESET OK", 0x0D, 0x0A, '$'
msg_ok:     db "OK", 0x0D, 0x0A, '$'
msg_yellow: db "YELLOW TEXT", 0x0D, 0x0A, '$'
msg_flash:  db "FLASH TEXT", 0x0D, 0x0A, '$'
msg_nz:     db "NZ", 0x0D, 0x0A, '$'
msg_zf:     db "Z", 0x0D, 0x0A, '$'
msg_crlf:   db 0x0D, 0x0A, '$'
msg_done:   db "DONE", 0x0D, 0x0A, '$'
