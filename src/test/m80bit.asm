; M80BIT.COM - 24x80 page-flip bitmap regression
;
; Puts 'W' at logical column 29, then moves to column 51.  The move leaves
; the first 51-column page, so the fast flip shifts the bitmap and then
; renders the newly exposed columns from the logical buffer.  'Q' at column
; 51 is the first exposed cell.  The smoke runner compares the visible
; bitmap with a reference render of LG_BUF, which catches a wrong shift
; direction or a bad source address in the re-render.
;
; Build: sjasmplus --raw=build/m80bit.com src/test/m80bit.asm

    org 0x100

BDOS    equ 0x0005
F_COUT  equ 2
F_PSTR  equ 9
F_TAIL  equ 109

start:
    ; Page mode off so the output cannot pause.
    ld de, 0
    ld c, F_TAIL
    call BDOS

    ; ESC x: enter 24x80.
    ld a, 0x1B
    call put
    ld a, 'x'
    call put

    ; ESC Y 0 29, then 'W'.
    call ypos
    db 0
    db 29
    ld a, 'W'
    call put

    ; ESC Y 0 51 - this leaves the first page and flips to 29.
    call ypos
    db 0
    db 51
    ld a, 'Q'
    call put

    ; Marker, then block on the keyboard.
    ld de, msg
    ld c, F_PSTR
    call BDOS
    ld c, 1
    call BDOS

    ; Leave 24x80 again so the caller returns to a 51-column prompt.
    ld a, 0x1B
    call put
    ld a, 'y'
    call put
    rst 0

; ypos - send ESC Y r c, with r/c taken from the inline bytes after the call.
ypos:
    pop hl
    ld a, (hl)
    ld (rowp), a
    inc hl
    ld a, (hl)
    ld (colp), a
    inc hl
    push hl
    ld a, 0x1B
    call put
    ld a, 'Y'
    call put
    ld a, (rowp)
    add a, 32
    call put
    ld a, (colp)
    add a, 32
    call put
    pop hl
    jp (hl)

put:
    ld e, a
    ld c, F_COUT
    call BDOS
    ret

rowp: db 0
colp: db 0
msg:  db "M80BIT..OK", '$'
