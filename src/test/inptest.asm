; INPTEST.COM - read a console line and print it back
;
; Exercises submit-file program input: a .SUB file can put '<' lines after
; this program's command and the CCP queues them as console input, so the
; program reads them with plain BDOS console calls (F10 here).
;
;   A>SUBMIT SCRIPT        (SCRIPT.SUB: "INPTEST" then "<HELLO FROM SUBMIT")
;   INPUT? HELLO FROM SUBMIT
;   GOT: HELLO FROM SUBMIT
;
; Build: sjasmplus --raw=build/inptest.com src/test/inptest.asm

    ORG 0100h

BDOS        EQU 0005h
F_CONOUT    EQU 2
F_PSTR      EQU 9
F_READBUF   EQU 10

start:
    ld de, msg_prompt
    ld c, F_PSTR
    call BDOS

    ld de, buf
    ld c, F_READBUF
    call BDOS                   ; line into buf, echoed by the BDOS

    ld de, msg_got
    ld c, F_PSTR
    call BDOS

    ld a, (buf + 1)             ; character count
    ld b, a
    ld hl, buf + 2
    or a
    jr z, .done
.echo:
    ld e, (hl)
    push hl
    push bc
    ld c, F_CONOUT
    call BDOS
    pop bc
    pop hl
    inc hl
    djnz .echo
.done:
    ld de, msg_crlf
    ld c, F_PSTR
    call BDOS
    rst 0

msg_prompt: db "INPUT? ", '$'
msg_got:    db "GOT: ", '$'
msg_crlf:   db 0x0D, 0x0A, '$'

buf:        db 126
            ds 127
