; STLTEST.COM - Status line / TE_STL test
;
; Enables the status line, checks the 23-row viewport, scrolls 30 lines
; through it, disables it again and checks that 24 rows come back.  Prints
; "STL..OK" (or "STL..FAIL") so the smoke runner can see the result after
; the program exits; XTETEST's test 4 runs the same checks too early in its
; burst to survive the runner's frame sampling.
;
; Build: sjasmplus --raw=build/stltest.com src/test/stltest.asm

    org 0x100

BDOS            equ 0x0005
TE_ASK          equ 0x00BF
TE_STL_ASK      equ 0x00C5
TE_STL_ON_OFF   equ 0x00C8

start:
    ; Compute the USERF (BIOS fn 30) entry from the warm-boot vector.
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl                      ; HL = BIOS base (bios_visible)
    ld de, 90
    add hl, de                  ; HL = USERF entry
    ld (userf_call + 1), hl

    ; Start from a known state: disable the status line.
    xor a
    ld hl, TE_STL_ON_OFF
    call xcall
    or a
    jr nz, fail

    ; ASK must now agree: A = 00h, Zero set.
    ld hl, TE_STL_ASK
    call xcall
    or a
    jr nz, fail

    ; Enable: A = FFh, Zero clear.
    ld a, 0xFF
    ld hl, TE_STL_ON_OFF
    call xcall
    push af
    pop bc                      ; B = A, C = F
    ld a, b
    cp 0xFF
    jr nz, fail
    bit 6, c
    jr nz, fail

    ; The viewport loses a row: TE_ASK reports D = 22.
    ld hl, TE_ASK
    call xcall
    ld a, d
    cp 22
    jr nz, fail

    ; Turn page mode off so 30 lines do not stop at "Press any key".
    ld de, 0
    ld c, 109
    call BDOS

    ; Scroll 30 lines through the 23-row viewport.  A broken fast scroll
    ; (wrong height, attribute row, or status-row damage) hangs or corrupts
    ; the display, so this is also a smoke check of the 23-row path.
    ld de, lines
    ld c, 9
    call BDOS

    ; Disable again: A = 00h, Zero set.
    xor a
    ld hl, TE_STL_ON_OFF
    call xcall
    or a
    jr nz, fail

    ; TE_ASK is back to 24 rows: D = 23.
    ld hl, TE_ASK
    call xcall
    ld a, d
    cp 23
    jr nz, fail

    ; ASK: A = 00h, Zero set.
    ld hl, TE_STL_ASK
    call xcall
    push af
    pop bc
    ld a, b
    or a
    jr nz, fail
    bit 6, c
    jr z, fail
    ld de, msg_ok
    jr print

fail:
    ld de, msg_fail
print:
    ld c, 9
    call BDOS
    rst 0

; Call an XBIOS entry through USERF, preserving A (the parameter).
;   In: HL = jumpblock entry, A = parameter
xcall:
    ld (userf_dw), hl
userf_call:
    call 0                      ; patched to USERF
userf_dw:
    dw 0
    ret

msg_ok:   db "STL..OK", 0x0D, 0x0A, "$"
msg_fail: db "STL..FAIL", 0x0D, 0x0A, "$"

lines:
    db "00", 0x0D, 0x0A, "01", 0x0D, 0x0A, "02", 0x0D, 0x0A, "03", 0x0D, 0x0A
    db "04", 0x0D, 0x0A, "05", 0x0D, 0x0A, "06", 0x0D, 0x0A, "07", 0x0D, 0x0A
    db "08", 0x0D, 0x0A, "09", 0x0D, 0x0A, "10", 0x0D, 0x0A, "11", 0x0D, 0x0A
    db "12", 0x0D, 0x0A, "13", 0x0D, 0x0A, "14", 0x0D, 0x0A, "15", 0x0D, 0x0A
    db "16", 0x0D, 0x0A, "17", 0x0D, 0x0A, "18", 0x0D, 0x0A, "19", 0x0D, 0x0A
    db "20", 0x0D, 0x0A, "21", 0x0D, 0x0A, "22", 0x0D, 0x0A, "23", 0x0D, 0x0A
    db "24", 0x0D, 0x0A, "25", 0x0D, 0x0A, "26", 0x0D, 0x0A, "27", 0x0D, 0x0A
    db "28", 0x0D, 0x0A, "29", 0x0D, 0x0A, "$"
