; ==========================================================================
; DELIMTEST.COM — verify F110 output delimiter and F9 termination
; ==========================================================================
; Sets the delimiter to '#', reads it back, then prints "OK#" with F9.
; A correct implementation prints only "OK" for that string, then
; "DELIM PASS".  If F9 still terminates on '$', it will run past the '#'
; terminator and the output will be visibly wrong.
; ==========================================================================

    org 0x0100

BDOS equ 0x0005

start:
    ; Set output delimiter to '#'
    ld e, '#'
    ld c, 110
    call BDOS

    ; Get it back
    ld de, 0xFFFF
    ld c, 110
    call BDOS
    cp '#'
    jr nz, .bad

    ; F9 must stop at '#'
    ld de, msg_ok
    ld c, 9
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    jp 0

.bad:
    ; Restore '$' so the diagnostic string terminates normally
    ld e, '$'
    ld c, 110
    call BDOS
    ld de, msg_bad
    ld c, 9
    call BDOS
    jp 0

msg_ok:   db 'OK#'
msg_pass: db 13, 10, 'DELIM PASS', 13, 10, '#'
msg_bad:  db 13, 10, 'DELIM BAD', 13, 10, '$'
