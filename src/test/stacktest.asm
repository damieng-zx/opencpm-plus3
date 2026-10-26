; ==========================================================================
; STKTEST.COM — regression test for the TPA stack top / bv_shim path
; ==========================================================================
; Checks:
;   1. The initial SP is TPA_TOP (0xF600), not the BDOS entry (bdos_stub).
;   2. A direct BIOS call through bios_visible works after BDOS calls.
;   3. A deep TPA stack does not overwrite the common stub.
; Prints "STACK OK" or "STACK BAD".
;
; Build: sjasmplus --raw=build/stktest.com src/test/stacktest.asm
; ==========================================================================

    org 0x0100

BDOS        equ 0x0005
TPA_TOP     equ 0xF600
BIOS_CONOUT equ 4

start:
    ld (entry_sp), sp

    ; --- 1. Initial SP must be TPA_TOP -----------------------------------
    ld hl, (entry_sp)
    ld de, TPA_TOP
    or a
    sbc hl, de
    jr z, .sp_ok
    ld de, msg_bad
    jp fail

.sp_ok:
    ; --- 2. BDOS calls first (this is what used to corrupt bv_shim) ------
    ld e, 'A'
    ld c, 2
    call BDOS
    ld e, 'B'
    ld c, 2
    call BDOS

    ; Direct BIOS CONOUT via the visible table: BIOS base = (0001h) - 3.
    call bios_conout_x

    ; --- 3. Deep stack, then another direct BIOS call --------------------
    ld bc, 0x0200                 ; 512 words = 1K
.deep:
    push bc
    dec bc
    ld a, b
    or c
    jr nz, .deep

    ld sp, TPA_TOP                ; discard the deep stack
    call bios_conout_y

    ld de, msg_ok
    call print

    ; --- 4. BIOS MOVE (fn 25): HL=dst, DE=src, BC=count ----------------
    ; MOVE works in the bank selected by XMOVE (fn 29).  Select TPA->TPA
    ; so the source and destination addresses below COMMON_BASE resolve
    ; to our own memory rather than the system bank.
    ld a, 29
    call compute_bios_entry
    ld bc, 0                      ; B = dest bank 0 (TPA), C = src bank 0
    call call_bios_ent

    ld hl, src_txt
    ld de, src_buf
    ld bc, 8
    ldir                          ; initialise the source

    ld a, 25
    call compute_bios_entry
    ld hl, dst_buf                ; HL = destination
    ld de, src_buf                ; DE = source
    ld bc, 8
    call call_bios_ent

    ld hl, src_buf
    ld de, dst_buf
    ld b, 8
.cmp_move:
    ld a, (de)
    cp (hl)
    jr nz, .move_bad
    inc hl
    inc de
    djnz .cmp_move
    ld de, msg_move_ok
    jr .print_move
.move_bad:
    ld de, msg_move_bad
.print_move:
    call print

    ; --- 5. Clock ticks in TPA mode without any BDOS calls --------------
    ld hl, (0xF63A)               ; SCB base (patched by cold_boot)
    ld de, 0x5C
    add hl, de                    ; HL = &scb_sec
    ld a, (hl)
    ld c, a                       ; initial seconds
    ld b, 4                       ; ~2s timeout (4 x 65535 inner loops)
.clock_outer:
    ld de, 0xFFFF
.clock_inner:
    ld a, (hl)
    cp c
    jr nz, .clock_ok
    dec de
    ld a, d
    or e
    jr nz, .clock_inner
    dec b
    jr nz, .clock_outer
    ld de, msg_clock_bad
    jr .print_clock
.clock_ok:
    ld de, msg_clock_ok
.print_clock:
    call print
    jp 0                          ; warm boot

fail:
    ld de, msg_bad
    call print
    jp 0                          ; warm boot

print:
    ld c, 9
    call BDOS
    ret

; compute_bios_entry — A = function number; store its bank-4 entry in
; (bios_ent).  BIOS base = word at 0001h - 3.
compute_bios_entry:
    ld l, a
    ld h, 0
    ld e, l
    ld d, h
    add hl, hl                    ; 2*fn
    add hl, de                    ; 3*fn
    ex de, hl
    ld hl, (0x0001)               ; WBOOT entry = bios_visible + 3
    dec hl
    dec hl
    dec hl                        ; HL = bios_visible (BIOS base)
    add hl, de
    ld (bios_ent), hl
    ret

; call_bios_ent — call (bios_ent) with HL/DE/BC as arguments.
call_bios_ent:
    ld iy, (bios_ent)
    call .jp_iy
    ret
.jp_iy:
    jp (iy)

; Call BIOS CONOUT with C='X'/'Y'.  Uses the visible jump table; if bv_shim
; was corrupted by the first BDOS call this will jump somewhere else.
bios_conout_x:
    ld c, 'X'
    jr bios_conout

bios_conout_y:
    ld c, 'Y'
bios_conout:
    ld hl, (0x0001)               ; WBOOT entry = bios_visible + 3
    dec hl
    dec hl
    dec hl                        ; HL = bios_visible (BIOS base)
    ld de, BIOS_CONOUT * 3
    add hl, de
    jp (hl)                       ; BIOS CONOUT returns to our caller

entry_sp:     dw 0
bios_ent:     dw 0
src_txt:      db 'MOVE1234'
src_buf:      ds 8
dst_buf:      ds 8
msg_ok:       db 0x0D, 0x0A, 'STACK OK', 0x0D, 0x0A, '$'
msg_bad:      db 0x0D, 0x0A, 'STACK BAD', 0x0D, 0x0A, '$'
msg_move_ok:  db 0x0D, 0x0A, 'MOVE OK', 0x0D, 0x0A, '$'
msg_move_bad: db 0x0D, 0x0A, 'MOVE BAD', 0x0D, 0x0A, '$'
msg_clock_ok: db 0x0D, 0x0A, 'CLOCK OK', 0x0D, 0x0A, '$'
msg_clock_bad: db 0x0D, 0x0A, 'CLOCK BAD', 0x0D, 0x0A, '$'
