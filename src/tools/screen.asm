; SCREEN.COM — show or set the screen width
;   SCREEN          show the current mode
;   SCREEN n        set 24x32, 24x51 or 24x64 (BIOS function 32)
;
; 64 columns is our extension: the +3 manual's ESC 3 only defines 32, 51
; and 80.  At the prompt the mode can also be changed with BREAK (ESC) 3 0
; or 3 1, which the screen driver handles directly.
;
; This lives outside the CCP: changing the screen width is a once-a-session
; operation, so it does not deserve resident bytes next to DIR/TYPE/ERA.
;
; Build: sjasmplus --raw=build/screen.com src/tools/screen.asm

    org 0x0100

BDOS    equ 0x0005
F_COUT  equ 2
F_PSTR  equ 9
F_SCB   equ 49
F_BIOS  equ 50
TAIL    equ 0x0080

; ==========================================================================
; start — parse the optional argument, then set or query the mode
; @proc start
; @clobbers af,bc,de,hl
; @end
start:
    ld hl, TAIL + 1
.skip:
    ld a, (hl)
    cp ' '
    jr z, .next
    or a
    jr z, .query
    cp 0x0D
    jr z, .query
    jr .parse
.next:
    inc hl
    jr .skip

.parse:
    cp '3'
    jr z, .tens3
    cp '5'
    jr z, .tens5
    cp '6'
    jr z, .tens6
    jr usage
.tens3:
    inc hl
    ld a, (hl)
    cp '2'
    jr nz, usage
    ld a, 32
    jr .set
.tens5:
    inc hl
    ld a, (hl)
    cp '1'
    jr nz, usage
    ld a, 51
    jr .set
.tens6:
    inc hl
    ld a, (hl)
    cp '4'
    jr nz, usage
    ld a, 64
.set:
    ld (bios_pb + 1), a
    ld de, bios_pb
    ld c, F_BIOS
    jp BDOS                    ; fn 32 clears the screen and returns

.query:
    ld de, query_pb
    ld c, F_SCB
    call BDOS
    inc a                      ; conwidth + 1 = columns
    push af
    ld de, str_mode
    ld c, F_PSTR
    call BDOS
    pop af
    call print_decimal_a
    ld de, str_cols
    ld c, F_PSTR
    jp BDOS

; ==========================================================================
; print_decimal_a — print A (0-255) as decimal
; @proc print_decimal_a
; @param %value:u8 a
; @clobbers af,bc,de
; @end
print_decimal_a:
    ld b, 0
.div:
    cp 10
    jr c, .units
    sub 10
    inc b
    jr .div
.units:
    ld c, a
    ld a, b
    or a
    jr z, .last
    add a, '0'
    ld e, a
    push bc
    ld c, F_COUT
    call BDOS
    pop bc
.last:
    ld a, c
    add a, '0'
    ld e, a
    ld c, F_COUT
    jp BDOS

; @proc usage
; @clobbers af,de
; @end
usage:
    ld de, msg_usage
    ld c, F_PSTR
    jp BDOS

; --- Data ---
bios_pb:    db 32, 0, 0, 0, 0, 0, 0, 0  ; BIOS fn 32, A = columns (patched)
query_pb:   db 0x1A, 0, 0, 0            ; SCB offset 0x1A (conwidth), get
str_mode:   db "Mode: $"
str_cols:   db " columns", 0x0D, 0x0A, '$'
msg_usage:  db "Usage: SCREEN 32|51|64", 0x0D, 0x0A, '$'
