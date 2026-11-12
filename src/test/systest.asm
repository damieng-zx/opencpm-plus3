; ==========================================================================
; SYSTEST.COM — combined system/console regression checks
; ==========================================================================
; Runs on this system and on Locomotive's CP/M Plus.  Run it from the disc
; it is on; it changes nothing on disc.
;
; Runs:
;   1. TPA stack top / bios_visible path / deep stack
;   2. BIOS MOVE direction (XMOVE TPA->TPA)
;   3. Clock ticking in TPA mode without BDOS calls
;   4. Page-zero IOBYTE (0003h) and user/drive (0004h) -- this system only
;   5. Console TAB expansion (visual: "A       B")
;   6. F110 output delimiter / F9 termination
;
; Prints STACK OK/BAD, MOVE OK/BAD, CLOCK OK/BAD, P0 PASS/BAD, a TAB
; line, and DELIM PASS/BAD.  A stack failure stops the run (continuing
; with a broken stack would be unsafe); other failures continue.
; ==========================================================================

    org 0x0100

BDOS        equ 0x0005
BIOS_CONOUT equ 4
F_ORDER     equ 120           ; our private SETDEF order byte: 0-3 here, 0xFF on
                              ; any other CP/M 3 (Locomotive's answers it as an
                              ; unknown function)

start:
    ; lint-exempt: stack  ; the deep-stack test deliberately changes SP
    ld (entry_sp), sp

    ; --- 1. Initial SP: the CCP enters a transient with 0000h (warm boot)
    ;        pushed on the stack, so a program can exit with RET.  The stack
    ;        starts just under the BDOS: the TPA top is the high byte of the
    ;        BDOS entry at 0006h (F600h here, F400h on Locomotive's CP/M
    ;        Plus), and SP = top - 2. -------------------------------------
    ld hl, (0x0006)
    ld l, 0
    ld (tpa_top), hl
    dec hl
    dec hl
    ex de, hl                     ; DE = TPA top - 2
    ld hl, (entry_sp)
    or a
    sbc hl, de
    jr nz, .sp_bad
    ld hl, (entry_sp)             ; and the pushed word must be 0000h
    ld a, (hl)
    inc hl
    or (hl)
    jr z, .sp_ok
.sp_bad:
    ld de, msg_stack_bad
    jp fail

.sp_ok:
    ; Is this our CP/M 3?  (See F_ORDER above.)  Three things below are about
    ; this system only, or differ between the two.
    ld e, 0
    ld c, F_ORDER
    call BDOS
    cp 4
    ld a, 0
    jr nc, .foreign
    inc a
.foreign:
    ld (ours), a

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

    ld sp, (tpa_top)              ; discard the deep stack
    call bios_conout_y

    ld de, msg_stack_ok
    call print

    ; --- 4. BIOS MOVE (fn 25): HL=dst, DE=src, BC=count -----------------
    ; MOVE works in the bank selected by XMOVE (fn 29).  Select TPA->TPA
    ; so the source and destination addresses below COMMON_BASE resolve
    ; to our own memory rather than the system bank.
    ; Our BIOS numbers the TPA 0 and the system bank 1 (its bank_sel); CP/M 3
    ; makes bank 1 the TPA, which is what Locomotive's BIOS expects.
    ld a, 29
    call compute_bios_entry
    ld bc, 0x0101                 ; B = dest bank 1 (TPA), C = src bank 1
    ld a, (ours)
    or a
    jr z, .xm_bank
    ld bc, 0x0000                 ; ours: bank 0 is the TPA
.xm_bank:
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

    ; --- 5. Clock ticks in TPA mode without any BDOS calls ---------------
    ; This guards our banked ISR, and it reads our SCB straight out of common
    ; memory, so it only means something on this system.
    ld a, (ours)
    or a
    jr nz, .clock_here
    ld de, msg_clock_skip
    call print
    jp p0_test
.clock_here:
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
    jp p0_test

fail:
    ld de, msg_stack_bad
    call print
    jp sys_exit

; ==========================================================================
; P0: page-zero IOBYTE / user-drive bytes
; ==========================================================================
p0_test:
    ; F8 (set IOBYTE) and the user/drive byte at 0004h are CP/M 2.2 behaviour
    ; that this system keeps; CP/M 3 does not support F7/F8 and its BDOS
    ; leaves 0004h to the CCP, so Locomotive's fails both.
    ld a, (ours)
    or a
    jr nz, .p0_here
    ld de, msg_p0_skip
    call print
    jp tab_test
.p0_here:
    ld e, 0x5A
    ld c, 8
    call BDOS                     ; F8: IOBYTE = 0x5A

    ld e, 3
    ld c, 32
    call BDOS                     ; F32: user 3

    ld e, 0
    ld c, 14
    call BDOS                     ; F14: drive A

    ld a, (0x0003)
    cp 0x5A
    jr nz, .p0_bad
    ld a, (0x0004)
    cp 0x30
    jr nz, .p0_bad

    xor a
    ld e, a
    ld c, 32
    call BDOS                     ; user 0
    ld e, a
    ld c, 8
    call BDOS                     ; IOBYTE 0
    ld de, msg_p0_ok
    jr .p0_print
.p0_bad:
    xor a
    ld e, a
    ld c, 32
    call BDOS
    ld e, a
    ld c, 8
    call BDOS
    ld de, msg_p0_bad
.p0_print:
    call print

; ==========================================================================
; TAB: visual check — A at column 0, B at column 8
; ==========================================================================
tab_test:
    ld de, msg_tab
    call print
    ld e, 'A'
    ld c, 2
    call BDOS
    ld e, 9
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

; ==========================================================================
; F110: output delimiter / F9 termination
; ==========================================================================
delim_test:
    ld e, '#'
    ld c, 110
    call BDOS                     ; set delimiter '#'
    ld de, 0xFFFF
    ld c, 110
    call BDOS                     ; get it back
    cp '#'
    jr nz, .delim_bad

    ld de, msg_delim_pass       ; "DELIM PASS\r\n#" — prints only the text
    ld c, 9
    call BDOS

    ld e, '$'
    ld c, 110
    call BDOS                     ; restore '$' before returning
    jp sys_exit

.delim_bad:
    ld e, '$'
    ld c, 110
    call BDOS
    ld de, msg_delim_bad
    ld c, 9
    call BDOS
    jp sys_exit

sys_exit:
    jp 0                          ; warm boot

; ==========================================================================
; Helpers
; ==========================================================================
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
    ; lint-exempt: stack  ; indirect jump to the visible BIOS entry
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
    ; lint-exempt: stack  ; indirect jump to the visible BIOS entry
    ld hl, (0x0001)               ; WBOOT entry = bios_visible + 3
    dec hl
    dec hl
    dec hl                        ; HL = bios_visible (BIOS base)
    ld de, BIOS_CONOUT * 3
    add hl, de
    jp (hl)                       ; BIOS CONOUT returns to our caller

; ==========================================================================
; Data
; ==========================================================================
entry_sp:      dw 0
tpa_top:       dw 0
ours:          db 0           ; 1 = this is our CP/M 3
bios_ent:      dw 0
src_txt:       db 'MOVE1234'
src_buf:       ds 8
dst_buf:       ds 8

msg_stack_ok:  db 13, 10, 'STACK OK', 13, 10, '$'
msg_stack_bad: db 13, 10, 'STACK BAD', 13, 10, '$'
msg_move_ok:   db 13, 10, 'MOVE OK', 13, 10, '$'
msg_move_bad:  db 13, 10, 'MOVE BAD', 13, 10, '$'
msg_clock_ok:  db 13, 10, 'CLOCK OK', 13, 10, '$'
msg_clock_bad: db 13, 10, 'CLOCK BAD', 13, 10, '$'
msg_clock_skip: db 13, 10, 'CLOCK SKIP (not this system)', 13, 10, '$'
msg_p0_ok:     db 13, 10, 'P0 PASS', 13, 10, '$'
msg_p0_bad:    db 13, 10, 'P0 BAD', 13, 10, '$'
msg_p0_skip:   db 13, 10, 'P0 SKIP (not this system)', 13, 10, '$'
msg_tab:       db 13, 10, 'TAB:', 13, 10, '$'
msg_delim_pass: db 13, 10, 'DELIM PASS', 13, 10, '#'
msg_delim_bad: db 13, 10, 'DELIM BAD', 13, 10, '$'
