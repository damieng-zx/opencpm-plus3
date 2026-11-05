; M80TEST.COM - 24x80 mode regression
;
; Enters 24x80, checks TE_ASK reports an 80-column viewport, moves the
; cursor past the visible page (auto-flip), checks the logical cursor, then
; leaves 24x80 and checks the width is back to 51.  Prints M80..OK/FAIL.
;
; Build: sjasmplus --raw=build/m80test.com src/test/m80test.asm

    org 0x100

BDOS    equ 0x0005
TE_ASK  equ 0x00BF

start:
    ; USERF (BIOS fn 30) entry from the warm-boot vector
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    ld de, 90
    add hl, de
    ld (userf_call + 1), hl

    ; Page mode off so the test output cannot pause
    ld de, 0
    ld c, 109
    call BDOS

    ; ESC x: enter 24x80
    ld a, 0x1B
    call put
    ld a, 'x'
    call put

    ; TE_ASK: width - 1 = 79
    ld hl, TE_ASK
    call xcall
    ld a, e
    cp 79
    jp nz, fail

    ; ESC Y 0 70: beyond the first 51-column page
    ld a, 0x1B
    call put
    ld a, 'Y'
    call put
    ld a, 32
    call put
    ld a, 70 + 32
    call put

    ; TE_ASK: logical cursor column = 71 (auto-flip does not move it)
    ld hl, TE_ASK
    call xcall
    ld a, l
    cp 70
    jp nz, fail

    ; ESC y: leave 24x80 and restore 51 columns
    ld a, 0x1B
    call put
    ld a, 'y'
    call put

    ld hl, TE_ASK
    call xcall
    ld a, e
    cp 50
    jp nz, fail
    ld de, msg_ok
    jr print

fail:
    ld de, msg_fail
print:
    push de
    ld a, 0x1B                 ; harmless if already back in 51-column mode
    call put
    ld a, 'y'
    call put
    pop de
    ld c, 9
    call BDOS
    rst 0

xcall:
    ld (userf_dw), hl
userf_call:
    call 0
userf_dw:
    dw 0
    ret

put:
    ld e, a
    ld c, 2
    call BDOS
    ret

msg_ok:   db "M80..OK", 0x0D, 0x0A, "$"
msg_fail: db "M80..FAIL", 0x0D, 0x0A, "$"
