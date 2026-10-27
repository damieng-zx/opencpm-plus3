; ==========================================================================
; TABTEST.COM — verify console TAB expands to the next 8-column stop
; ==========================================================================
; Prints "A", TAB, "B".  A correct console driver leaves "A" in column 0
; and "B" in column 8 (seven spaces between them).  If TAB is ignored the
; output is "AB".
; ==========================================================================

    org 0x0100

BDOS equ 0x0005

start:
    ld e, 'A'
    ld c, 2
    call BDOS

    ld e, 9                    ; TAB
    ld c, 2
    call BDOS

    ld e, 'B'
    ld c, 2
    call BDOS

    ld e, 13
    ld c, 2
    call BDOS
    ld e, 10
    ld c, 2
    call BDOS

    jp 0                       ; warm boot back to the CCP
