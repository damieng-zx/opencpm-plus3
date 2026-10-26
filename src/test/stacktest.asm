; ==========================================================================
; STACKTEST.COM — regression test for the TPA stack top / bv_shim path
; ==========================================================================
; Checks:
;   1. The initial SP is TPA_TOP (0xF600), not the BDOS entry (bdos_stub).
;   2. A direct BIOS call through bios_visible works after BDOS calls.
;   3. A deep TPA stack does not overwrite the common stub.
; Prints "STACK OK" or "STACK BAD".
;
; Build: sjasmplus --raw=build/stacktest.com src/test/stacktest.asm
; ==========================================================================

    org 0x0100

BDOS        equ 0x0005
TPA_TOP     equ 0xF600
BIOS_CONOUT equ 4

start:
    ld (entry_sp), sp

    ; --- 1. Initial SP must be TPA_TOP -----------------------------------
    ld hl, (entry_sp)
    ld de, TPA_TOP
    or a
    sbc hl, de
    jr z, .sp_ok
    ld de, msg_bad
    jp fail

.sp_ok:
    ; --- 2. BDOS calls first (this is what used to corrupt bv_shim) ------
    ld e, 'A'
    ld c, 2
    call BDOS
    ld e, 'B'
    ld c, 2
    call BDOS

    ; Direct BIOS CONOUT via the visible table: BIOS base = (0001h) - 3.
    call bios_conout_x

    ; --- 3. Deep stack, then another direct BIOS call --------------------
    ld bc, 0x0200                 ; 512 words = 1K
.deep:
    push bc
    dec bc
    ld a, b
    or c
    jr nz, .deep

    ld sp, TPA_TOP                ; discard the deep stack
    call bios_conout_y

    ld de, msg_ok
    jp print

fail:
print:
    ld c, 9
    call BDOS
    jp 0                          ; warm boot

; Call BIOS CONOUT with C='X'.  Uses the visible jump table; if bv_shim was
; corrupted by the first BDOS call this will jump somewhere else.
bios_conout_x:
    ld c, 'X'
    jr bios_conout

bios_conout_y:
    ld c, 'Y'
bios_conout:
    ld hl, (0x0001)               ; WBOOT entry = bios_visible + 3
    dec hl
    dec hl
    dec hl                        ; HL = bios_visible (BIOS base)
    ld de, BIOS_CONOUT * 3
    add hl, de
    jp (hl)                       ; BIOS CONOUT returns to our caller

entry_sp:   dw 0
msg_ok:     db 0x0D, 0x0A, 'STACK OK', 0x0D, 0x0A, '$'
msg_bad:    db 0x0D, 0x0A, 'STACK BAD', 0x0D, 0x0A, '$'
