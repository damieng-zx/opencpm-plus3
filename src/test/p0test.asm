; ==========================================================================
; P0TEST.COM — verify page-zero compatibility bytes 0003/0004
; ==========================================================================
; F8 (IOBYTE) must update 0003; F32 (user) and F14 (drive) must update
; 0004 as (user << 4) | drive.  Restores user 0 / IOBYTE 0 before exit.
; ==========================================================================

    org 0x0100

BDOS equ 0x0005

start:
    ; F8: set IOBYTE = 0x5A
    ld e, 0x5A
    ld c, 8
    call BDOS

    ; F32: set user 3
    ld e, 3
    ld c, 32
    call BDOS

    ; F14: select drive A
    ld e, 0
    ld c, 14
    call BDOS

    ld a, (0x0003)
    cp 0x5A
    jr nz, .bad
    ld a, (0x0004)
    cp 0x30
    jr nz, .bad

    xor a
    ld e, a
    ld c, 32
    call BDOS                   ; user 0
    ld e, a
    ld c, 8
    call BDOS                   ; IOBYTE 0

    ld de, msg_ok
    ld c, 9
    call BDOS
    jp 0

.bad:
    xor a
    ld e, a
    ld c, 32
    call BDOS                   ; user 0
    ld e, a
    ld c, 8
    call BDOS                   ; IOBYTE 0
    ld de, msg_bad
    ld c, 9
    call BDOS
    jp 0

msg_ok:  db 'P0 PASS', 13, 10, '$'
msg_bad: db 'P0 BAD', 13, 10, '$'
