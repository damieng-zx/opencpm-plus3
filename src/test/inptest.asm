; INPTEST.COM - read console lines and print them back
;
; Normal mode (no argument) exercises submit-file program input: a .SUB file
; can put '<' lines after this program's command and the CCP queues them as
; console input, so the program reads them with plain BDOS console calls
; (F10 here).
;
;   A>SUBMIT SCRIPT        (SCRIPT.SUB: "INPTEST" then "<HELLO FROM SUBMIT")
;   INPUT? HELLO FROM SUBMIT
;   GOT: HELLO FROM SUBMIT
;
; "INPTEST EDIT" runs the F10 line editor checks: a backspace edit and a
; buffer-full truncation.  The smoke runner drives the keys.
;
; Build: sjasmplus --raw=build/inptest.com src/test/inptest.asm

    ORG 0100h

BDOS        EQU 0005h
F_CONOUT    EQU 2
F_PSTR      EQU 9
F_READBUF   EQU 10

start:
    ld a, (0080h)              ; command tail length
    or a
    jr nz, edit_mode

    ld de, msg_prompt
    ld c, F_PSTR
    call BDOS

    ld de, buf
    ld c, F_READBUF
    call BDOS                   ; line into buf, echoed by the BDOS

    ld de, msg_got
    ld c, F_PSTR
    call BDOS

    ld hl, buf
    call print_line

    ld de, msg_crlf
    ld c, F_PSTR
    call BDOS
    rst 0

; ------------------------------------------------------------------
; edit_mode - F10 line-editor checks
;   1. "ABC" + backspace + "D" must come back as "ABD".
;   2. A 5-character buffer must accept "ABCDEFGH" as "ABCDE".
; ------------------------------------------------------------------
edit_mode:
    ld de, msg_edit1
    ld c, F_PSTR
    call BDOS
    ld de, buf1
    ld c, F_READBUF
    call BDOS

    ld de, msg_got1
    ld c, F_PSTR
    call BDOS
    ld hl, buf1
    call print_line

    ld de, msg_edit2
    ld c, F_PSTR
    call BDOS
    ld de, buf2
    ld c, F_READBUF
    call BDOS

    ld de, msg_got2
    ld c, F_PSTR
    call BDOS
    ld hl, buf2
    call print_line

    ld de, msg_edit_done
    ld c, F_PSTR
    call BDOS
    rst 0

; ------------------------------------------------------------------
; print_line - print the characters of an F10 buffer
;   In:      HL = buffer address (count at +1, chars at +2)
;   Out:     nothing
;   Clobbers: AF, BC, DE, HL
; ------------------------------------------------------------------
print_line:
    inc hl
    ld b, (hl)
    inc hl
.loop:
    ld a, b
    or a
    ret z
    ld e, (hl)
    push hl
    push bc
    ld c, F_CONOUT
    call BDOS
    pop bc
    pop hl
    inc hl
    dec b
    jr .loop

msg_prompt:     db "INPUT? ", '$'
msg_got:        db "GOT: ", '$'
msg_edit1:      db "EDIT1? ", '$'
msg_got1:       db "GOT1: ", '$'
msg_edit2:      db 0x0D, 0x0A, "EDIT2? ", '$'
msg_got2:       db 0x0D, 0x0A, "GOT2: ", '$'
msg_edit_done:  db 0x0D, 0x0A, "EDIT DONE", 0x0D, 0x0A, '$'
msg_crlf:       db 0x0D, 0x0A, '$'

buf:        db 126
            ds 127
buf1:       db 20
            ds 21
buf2:       db 5
            ds 6
