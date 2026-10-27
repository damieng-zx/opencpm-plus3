; DUMP.COM — Hex/ASCII file viewer
; Usage: DUMP filename.ext
; Displays file contents as hex bytes and ASCII.
; Bytes per line adapts to screen width: (width-8)/4
; Paging is handled system-wide by BDOS when SETDEF [PAGE] is on.
;
; Build: sjasmplus --raw=build/dump.com src/tools/dump.asm

    ORG 0100h

BDOS    equ 0005h

; BDOS functions
F_CONIN   equ 1
F_CONOUT  equ 2
F_PRINT   equ 9
F_READBUF equ 10
F_CONST   equ 11
F_OPEN    equ 15
F_CLOSE   equ 16
F_READ    equ 20
F_SETDMA  equ 26
F_GETSCB  equ 49

start:
    ld a, (080h)
    or a
    jp z, usage
    ld de, 05Ch
    ld c, F_OPEN
    call BDOS
    cp 0FFh
    jp z, nofile

    ld de, scb_pb
    ld c, F_GETSCB
    call BDOS
    inc a
    sub 8
    srl a
    srl a
    ld (bpl), a

    ld de, dmbuf
    ld c, F_SETDMA
    call BDOS

    xor a
    ld hl, 0
    ld (foff), hl
    ld (brem), a

doline:
    ld hl, lnbuf
    ld a, (bpl)
    ld b, a
    ld c, 0
.fill:
    push bc
    push hl
    call getbyte
    pop hl
    pop bc
    jr c, .filled
    ld (hl), a
    inc hl
    inc c
    djnz .fill
.filled:
    ld a, c
    or a
    jp z, xit
    ld (chnk), a

    ld de, (foff)
    call phex4
    ld e, ':'
    call cout
    ld e, ' '
    call cout

    ld hl, lnbuf
    ld a, (chnk)
    ld b, a
hexlp:
    ld a, (hl)
    inc hl
    push hl
    push bc
    call phexsp
    pop bc
    pop hl
    djnz hexlp

    ld a, (bpl)
    ld b, a
    ld a, (chnk)
    cp b
    jp nc, .no_pad
    sub b
    neg
    ld b, a
.padlp:
    push bc
    ld e, ' '
    call cout
    ld e, ' '
    call cout
    ld e, ' '
    call cout
    pop bc
    djnz .padlp
.no_pad:

    ld e, ' '
    call cout

    ld hl, lnbuf
    ld a, (chnk)
    ld b, a
asclp:
    ld a, (hl)
    inc hl
    push hl
    push bc
    call toasc
    ld e, a
    call cout
    pop bc
    pop hl
    djnz asclp

    call crlf

    ld a, (chnk)
    ld e, a
    ld d, 0
    ld hl, (foff)
    add hl, de
    ld (foff), hl
    jp doline

xit:
    ld de, 05Ch
    ld c, F_CLOSE
    call BDOS
    rst 0

usage:
    ld de, msg_usage
    ld c, F_PRINT
    call BDOS
    rst 0

nofile:
    ld de, msg_nofile
    ld c, F_PRINT
    call BDOS
    rst 0


; getbyte — read next byte from file across record boundaries
;   In:  nothing
;   Out: A = byte (carry clear), or carry set on EOF
;   Clobbers: AF, HL
getbyte:
    ld a, (brem)
    or a
    jr nz, .have
    push bc
    push de
    ld de, 05Ch
    ld c, F_READ
    call BDOS
    pop de
    pop bc
    or a
    scf
    ret nz
    ld a, 128
    ld (brem), a
    ld hl, dmbuf
    ld (bptr), hl
.have:
    ld hl, (bptr)
    ld a, (hl)
    inc hl
    ld (bptr), hl
    ld hl, brem
    dec (hl)
    or a
    ret


; cout — output character
;   In:  E = character
;   Out: nothing
;   Clobbers: AF
cout:
    push bc
    push de
    push hl
    ld c, F_CONOUT
    call BDOS
    pop hl
    pop de
    pop bc
    ret

; crlf — output CR+LF
;   In:  nothing
;   Out: nothing
;   Clobbers: AF, E
crlf:
    ld e, 0Dh
    call cout
    ld e, 0Ah
    jp cout

; phex4 — print 16-bit value as 4 hex digits
;   In:  DE = value
;   Out: nothing
;   Clobbers: AF, DE, HL
phex4:
    push de
    ld a, d
    call phex2
    pop de
    ld a, e
    jp phex2

; phex2 — print byte as 2 hex digits
;   In:  A = byte
;   Out: nothing
;   Clobbers: AF, DE, HL
phex2:
    push af
    rrca
    rrca
    rrca
    rrca
    call phex1
    pop af
    jp phex1

; phex1 — print low nibble as hex digit
;   In:  A = byte (low nibble used)
;   Out: nothing
;   Clobbers: AF, DE, HL
phex1:
    and 0Fh
    ld e, a
    ld d, 0
    ld hl, hextab
    add hl, de
    ld e, (hl)
    jp cout

; phexsp — print byte as hex + space
;   In:  A = byte
;   Out: nothing
;   Clobbers: AF, DE, HL
phexsp:
    call phex2
    ld e, ' '
    jp cout

; toasc — convert byte to printable ASCII or '.'
;   In:  A = byte
;   Out: A = char or '.'
;   Clobbers: F
toasc:
    cp 20h
    jr c, dot
    cp 7Fh
    jr nc, dot
    ret
dot:
    ld a, '.'
    ret

hextab:
    db '0123456789ABCDEF'

scb_pb:
    db 1Ah, 00h, 00h, 00h

msg_usage:
    db 'Usage: DUMP filename.ext', 0Dh, 0Ah, '$'
msg_nofile:
    db 'File not found', 0Dh, 0Ah, '$'

bpl:    db 0
foff:   dw 0
brem:   db 0
chnk:   db 0
bptr:   dw 0

lnbuf:  ds 16
dmbuf:  ds 128
