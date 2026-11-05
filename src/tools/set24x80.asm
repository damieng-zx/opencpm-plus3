; SET24X80.COM - enter or leave the virtual 24x80 screen
;   SET24X80        enter 24x80 (the +3 and this implementation default to
;                   24x51, so the 80-column screen is shown in pages)
;   SET24X80 ON     same as no argument
;   SET24X80 OFF    leave 24x80 and restore the previous physical width
;
; The command simply sends ESC x / ESC y to the terminal emulator; the BIOS
; does the mode switch, clears the screen and draws the status-line markers.
;
; Build: sjasmplus --raw=build/set24x80.com src/tools/set24x80.asm

    org 0x0100

BDOS    equ 0x0005
F_COUT  equ 2
F_PSTR  equ 9
TAIL    equ 0x0080

start:
    ld hl, TAIL + 1
.skip:
    ld a, (hl)
    cp ' '
    jr z, .next
    or a
    jr z, on
    cp 0x0D
    jr z, on
    and 0xDF                   ; case-insensitive ON/OFF
    cp 'O'
    jp nz, usage
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'N'
    jr z, .on
    cp 'F'
    jp nz, usage
    inc hl
    ld a, (hl)
    and 0xDF
    cp 'F'
    jp nz, usage
    inc hl
    call end_ok
    jp nz, usage
    jr off
.on:
    inc hl
    call end_ok
    jp nz, usage
    jr on
.next:
    inc hl
    jr .skip

on:
    ld a, 0x1B
    call cout
    ld a, 'x'
    call cout
    rst 0

off:
    ld a, 0x1B
    call cout
    ld a, 'y'
    call cout
    rst 0

usage:
    ld de, msg
    ld c, F_PSTR
    call BDOS
    rst 0

; Z set when the tail ends here (space, NUL or CR)
end_ok:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    ret

cout:
    ld e, a
    ld c, F_COUT
    jp BDOS

msg: db "SET24X80 [ON|OFF]", 0x0D, 0x0A, "$"
