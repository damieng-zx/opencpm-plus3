; ==========================================================================
; CKBENCH.COM - checksum algorithm timing benchmark
; ==========================================================================
;
; Answers "which checksum suits a 3.5 MHz Z80" with measured cycles instead
; of folklore.  Same technique as src/test/screenbm.asm: nothing is timed in
; the guest.  Each phase stores its number to MARKER, and tools/ckbench.py
; times the T-states between marker changes, so the figures are real Z80
; cycles and cannot drift with a guest clock.
;
; Every phase hashes the same 16K - four passes over a 4K buffer - so
; "T-states per byte" is phase time / 16384 and the phases are directly
; comparable.
;
; Tables are built before the first marker: only the hot loop is timed.  That
; is the honest measure, because a checksum tool pays the loop once per byte
; and the table once per run.
;
; Every phase is written the way a real tool would write it.  Where the state
; fits in registers it is kept there; where it does not (CRC-32) it lives in
; memory, which is what actual Z80 implementations do.
;
; Build: sjasmplus --raw=build/ckbench.com src/test/ckbench.asm

    org 0x0100

MARKER      equ 0x3F00
BUFFER      equ 0x2000
BUFLEN      equ 4096
PASSES      equ 4

BDOS        equ 0x0005

; Byte-count layout for the table-driven phases: an outer byte of 16 and an
; inner `djnz` of 256 gives 4096 bytes with B free for the inner counter.
OUTER       equ BUFLEN / 256

; --------------------------------------------------------------------------
; Entry
; --------------------------------------------------------------------------
start:
    call fill_buffer
    call build_tables

; ==========================================================================
; 1: 8-bit additive sum
; ==========================================================================
    ld a, 1
    call phase_open
    ld a, PASSES
    ld (passes), a
    ld e, 0
.p1_pass:
    ld hl, BUFFER
    ld bc, BUFLEN
.p1:
    ld a, (hl)
    add a, e
    ld e, a
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .p1
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p1_pass

; ==========================================================================

    ld a, 1
    call phase_close
; 2: 16-bit additive sum
; ==========================================================================
    ld a, 2
    call phase_open
    ld a, PASSES
    ld (passes), a
    ld de, 0
.p2_pass:
    ld hl, BUFFER
    ld bc, BUFLEN
.p2:
    ld a, (hl)
    add a, e
    ld e, a
    ld a, d
    adc a, 0
    ld d, a
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .p2
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p2_pass

; ==========================================================================

    ld a, 2
    call phase_close
; 3: 8-bit XOR
; ==========================================================================
    ld a, 3
    call phase_open
    ld a, PASSES
    ld (passes), a
    ld e, 0
.p3_pass:
    ld hl, BUFFER
    ld bc, BUFLEN
.p3:
    ld a, (hl)
    xor e
    ld e, a
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .p3
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p3_pass

; ==========================================================================

    ld a, 3
    call phase_close
; 4: Fletcher-16, mod 255
;   sum1 += byte; sum2 += sum1; both fold with end-around carry, which is
;   the mod-255 reduction and what makes it position-sensitive.
; ==========================================================================
    ld a, 4
    call phase_open
    ld a, PASSES
    ld (passes), a
    xor a
    ld (f1), a
    ld (f2), a
.p4_pass:
    ld hl, BUFFER
    ld bc, BUFLEN
.p4:
    ld a, (hl)
    ld e, a
    ld a, (f1)
    add a, e
    jr nc, .p4_c1
    inc a
.p4_c1:
    ld (f1), a
    ld e, a
    ld a, (f2)
    add a, e
    jr nc, .p4_c2
    inc a
.p4_c2:
    ld (f2), a
    inc hl
    dec bc
    ld a, b
    or c
    jr nz, .p4
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p4_pass

; ==========================================================================

    ld a, 4
    call phase_close
; 5: CRC-16-CCITT, bit at a time (poly 1021h, init FFFFh)
;   State in BC.
; ==========================================================================
    ld a, 5
    call phase_open
    ld a, PASSES
    ld (passes), a
    ld bc, 0xFFFF
.p5_pass:
    ld hl, BUFFER
    ld de, BUFLEN
.p5:
    ld a, (hl)
    xor b
    ld b, a
    ld a, 8
    ld (bits), a
.p5_bit:
    sla c
    rl b
    jr nc, .p5_no
    ld a, b
    xor 0x10
    ld b, a
    ld a, c
    xor 0x21
    ld c, a
.p5_no:
    ld a, (bits)
    dec a
    ld (bits), a
    jr nz, .p5_bit
    inc hl
    dec de
    ld a, d
    or e
    jr nz, .p5
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p5_pass

; ==========================================================================

    ld a, 5
    call phase_close
; 6: CRC-16-CCITT, byte table
;   crc = (crc << 8) xor table[(crc >> 8) xor byte]
; The table is split into two 256-byte pages, so the lookup is `ld l,index /
; ld h,page / ld a,(hl)` with no 16-bit arithmetic.  CRC in memory, buffer
; pointer in DE, B free for `djnz`.
; ==========================================================================
    ld a, 6
    call phase_open
    ld a, PASSES
    ld (passes), a
    ld a, 0xFF
    ld (c16h), a
    ld (c16l), a
.p6_pass:
    ld de, BUFFER
    ld a, OUTER
    ld (outer), a
.p6_outer:
    ld b, 0
.p6:
    ld a, (de)
    ld c, a
    ld a, (c16h)
    xor c                         ; index
    ld l, a
    ld h, CHI_PAGE
    ld c, (hl)                    ; table high half
    ld a, (c16l)
    xor c                         ; new high = table_hi ^ old low
    ld (c16h), a
    ld a, l                       ; L still holds the index
    ld h, CLO_PAGE
    ld a, (hl)                    ; new low
    ld (c16l), a
    inc de
    djnz .p6
    ld a, (outer)
    dec a
    ld (outer), a
    jr nz, .p6_outer
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p6_pass

; ==========================================================================

    ld a, 6
    call phase_close
; 7: CRC-32, nibble table (16 entries x 4 bytes)
;   The classic small-table compromise: half the table of the byte version,
;   twice the iterations.
; ==========================================================================
    ld a, 7
    call phase_open
    ld a, PASSES
    ld (passes), a
    call crc32_reset
.p7_pass:
    ld de, BUFFER
    ld a, OUTER
    ld (outer), a
.p7_outer:
    ld b, 0
.p7:
    ; Two nibbles per byte: high nibble first.
    ld a, (de)
    rra
    rra
    rra
    rra
    and 0x0F
    call crc32_nibble_step
    ld a, (de)
    and 0x0F
    call crc32_nibble_step
    inc de
    djnz .p7
    ld a, (outer)
    dec a
    ld (outer), a
    jr nz, .p7_outer
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p7_pass

; ==========================================================================

    ld a, 7
    call phase_close
; 8: CRC-32, byte table (256 entries x 4 bytes)
;   crc = (crc >> 8) xor table[(crc xor byte) & 0FFh]
; ==========================================================================
    ld a, 8
    call phase_open
    ld a, PASSES
    ld (passes), a
    call crc32_reset
.p8_pass:
    ld de, BUFFER
    ld a, OUTER
    ld (outer), a
.p8_outer:
    ld b, 0
.p8:
    ld a, (de)
    ld c, a
    ld a, (c32 + 0)
    xor c                         ; index
    add a, a
    add a, a                      ; * 4
    ld l, a
    ld h, C32_PAGE
    ; crc >>= 8 then xor the 4-byte table entry
    ld a, (c32 + 1)
    ld (c32 + 0), a
    ld a, (c32 + 2)
    ld (c32 + 1), a
    ld a, (c32 + 3)
    ld (c32 + 2), a
    ld a, (hl)
    ld (c32 + 3), a
    inc hl
    ld a, (c32 + 0)
    xor (hl)
    ld (c32 + 0), a
    inc hl
    ld a, (c32 + 1)
    xor (hl)
    ld (c32 + 1), a
    inc hl
    ld a, (c32 + 2)
    xor (hl)
    ld (c32 + 2), a
    inc de
    djnz .p8
    ld a, (outer)
    dec a
    ld (outer), a
    jr nz, .p8_outer
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p8_pass

; ==========================================================================

    ld a, 8
    call phase_close
; 9: CRC-32, byte table, tabulated shift
;   Same table, but the four "shift down by a byte" moves are avoided by
;   keeping the index and adding the table base once; this is the form to use
;   when the tool hashes many small files and the loop dominates.
; ==========================================================================
    ld a, 9
    call phase_open
    ld a, PASSES
    ld (passes), a
    call crc32_reset
.p9_pass:
    ld de, BUFFER
    ld a, OUTER
    ld (outer), a
.p9_outer:
    ld b, 0
.p9:
    ld a, (de)
    ld c, a
    ld a, (c32 + 0)
    xor c
    add a, a
    add a, a                      ; * 4
    ld l, a
    ld h, C32_PAGE
    ; Load the entry into registers first, then shift-and-xor in one pass,
    ; so the state is read and written once instead of twice.
    ld a, (hl)
    ld (t0), a
    inc hl
    ld a, (hl)
    ld (t1), a
    inc hl
    ld a, (hl)
    ld (t2), a
    inc hl
    ld a, (hl)
    ld (t3), a
    ld a, (c32 + 1)
    xor (t0 + 0)
    ld (c32 + 0), a
    ld a, (c32 + 2)
    xor (t1 + 0)
    ld (c32 + 1), a
    ld a, (c32 + 3)
    xor (t2 + 0)
    ld (c32 + 2), a
    ld a, (t3 + 0)
    ld (c32 + 3), a
    inc de
    djnz .p9
    ld a, (outer)
    dec a
    ld (outer), a
    jr nz, .p9_outer
    ld a, (passes)
    dec a
    ld (passes), a
    jr nz, .p9_pass

; ==========================================================================

    ld a, 9
    call phase_close

; --------------------------------------------------------------------------
; Done
; --------------------------------------------------------------------------
    ld a, 0xFF
    ld (MARKER), a
    rst 0

; ==========================================================================
; CRC-32 helpers
; ==========================================================================
; crc32_reset - crc = FFFFFFFF
;   Clobbers: AF
crc32_reset:
    ld a, 0xFF
    ld (c32 + 0), a
    ld (c32 + 1), a
    ld (c32 + 2), a
    ld (c32 + 3), a
    ret

; crc32_nibble_step - fold one nibble (0-15 in A) into the CRC
;   In:       A = nibble
;   Clobbers: AF, HL, BC
crc32_nibble_step:
    ld c, a
    ld a, (c32 + 0)
    xor c
    and 0x0F
    add a, a
    add a, a                      ; * 4
    ld l, a
    ld h, CNIB_PAGE
    ; crc >>= 4, then xor the 4-byte entry
    ld a, (c32 + 0)
    rrca
    rrca
    rrca
    rrca
    ld c, a                       ; C = old low >> 4 (the nibble shifted in
                                  ; from c32+1 must be merged first)
    ld a, (c32 + 1)
    and 0x0F
    rlca
    rlca
    rlca
    rlca                          ; low nibble of c32+1 moved to high
    or c
    ld (c32 + 0), a
    ld a, (c32 + 1)
    rrca
    rrca
    rrca
    rrca
    ld c, a
    ld a, (c32 + 2)
    and 0x0F
    rlca
    rlca
    rlca
    rlca
    or c
    ld (c32 + 1), a
    ld a, (c32 + 2)
    rrca
    rrca
    rrca
    rrca
    ld c, a
    ld a, (c32 + 3)
    and 0x0F
    rlca
    rlca
    rlca
    rlca
    or c
    ld (c32 + 2), a
    ld a, (c32 + 3)
    rrca
    rrca
    rrca
    rrca
    ld (c32 + 3), a
    ; xor the table entry
    ld a, (c32 + 0)
    xor (hl)
    ld (c32 + 0), a
    inc hl
    ld a, (c32 + 1)
    xor (hl)
    ld (c32 + 1), a
    inc hl
    ld a, (c32 + 2)
    xor (hl)
    ld (c32 + 2), a
    inc hl
    ld a, (c32 + 3)
    xor (hl)
    ld (c32 + 3), a
    ret


fill_buffer:
    ld hl, BUFFER
    ld bc, BUFLEN
    ld a, 0x5A
.fill:
    ld d, a
    add a, a
    add a, a
    add a, d
    inc a
    ld (hl), a
    inc hl
    dec bc
    jr nz, .fill
    ret

next_phase:
    ld a, (MARKER)
    inc a
    ld (MARKER), a
    ret

; phase_open - write 0x10 + N, opening a measured region
;   In:       A = phase number (1..N)
;   Clobbers: AF
;   The 0x10/0x20 pairing is the convention tools/ckbench.py looks for: a
;   region opens at 0x10+n and closes at 0x20+n, so the T-states at the two
;   writes differ by exactly the work between them.  Markers 1..9 are also
;   written for readability, but the timing comes from the pairs.
phase_open:
    add a, 0x10
    ld (MARKER), a
    ret

; phase_close - write 0x20 + N, closing a measured region
;   In:       A = phase number (1..N)
;   Clobbers: AF
phase_close:
    add a, 0x20
    ld (MARKER), a
    ret

; build_tables - CRC-16 and CRC-32 tables, untimed
;   Clobbers: everything
build_tables:
    call build_crc16
    call build_crc32_nibble
    call build_crc32_byte
    ret

; build_crc16 - two 256-byte pages for the CRC-16-CCITT byte table
;   Clobbers: everything
build_crc16:
    ld hl, crc16_hi
    ld e, 0
.next:
    ; CRC-16 of the single byte E, starting from E << 8.
    ld b, e
    ld c, 0
    ld d, 8
.bit:
    sla c
    rl b
    jr nc, .no
    ld a, b
    xor 0x10
    ld b, a
    ld a, c
    xor 0x21
    ld c, a
.no:
    dec d
    jr nz, .bit
    ld (hl), b                    ; high page
    push hl
    ld a, e
    add a, low(crc16_lo)
    ld l, a
    ld h, high(crc16_lo)
    ld (hl), c                    ; low page
    pop hl
    inc hl
    inc e
    jr nz, .next
    ret

; build_crc32_nibble - 16 entries of 4 bytes
;   Clobbers: everything
build_crc32_nibble:
    ld de, crc32_nib
    ld b, 0                       ; B = nibble 0..15
.nib:
    ; crc = nibble; eight shifts
    ld a, b
    ld (c32 + 0), a
    xor a
    ld (c32 + 1), a
    ld (c32 + 2), a
    ld (c32 + 3), a
    ld c, 8
.shift:
    ; crc >>= 1, and if the bit shifted out was 1, xor the polynomial
    ld a, (c32 + 0)
    and 1
    ld (t_bit), a
    call crc32_shr1
    ld a, (t_bit)
    or a
    jr z, .next_bit
    ld a, (c32 + 0)
    xor 0x20                      ; EDB88320h low byte
    ld (c32 + 0), a
    ld a, (c32 + 1)
    xor 0x83
    ld (c32 + 1), a
    ld a, (c32 + 2)
    xor 0xB8
    ld (c32 + 2), a
    ld a, (c32 + 3)
    xor 0xED
    ld (c32 + 3), a
.next_bit:
    dec c
    jr nz, .shift
    ; Store the 4 bytes little-endian.
    ld a, (c32 + 0)
    ld (de), a
    inc de
    ld a, (c32 + 1)
    ld (de), a
    inc de
    ld a, (c32 + 2)
    ld (de), a
    inc de
    ld a, (c32 + 3)
    ld (de), a
    inc de
    inc b
    ld a, b
    cp 16
    jr nz, .nib
    ret

; build_crc32_byte - 256 entries of 4 bytes, from the nibble table
;   Clobbers: everything
build_crc32_byte:
    ld hl, crc32_tab
    ld b, 0
.byte:
    ; entry[b] = crc32 of byte b = nibble[b >> 4] then nibble[b & 15]
    ; Computed the slow way once; this is outside the timed region.
    ld a, b
    ld (c32 + 0), a
    xor a
    ld (c32 + 1), a
    ld (c32 + 2), a
    ld (c32 + 3), a
    ld c, 8
.shift:
    ld a, (c32 + 0)
    and 1
    ld (t_bit), a
    call crc32_shr1
    ld a, (t_bit)
    or a
    jr z, .nb
    ld a, (c32 + 0)
    xor 0x20
    ld (c32 + 0), a
    ld a, (c32 + 1)
    xor 0x83
    ld (c32 + 1), a
    ld a, (c32 + 2)
    xor 0xB8
    ld (c32 + 2), a
    ld a, (c32 + 3)
    xor 0xED
    ld (c32 + 3), a
.nb:
    dec c
    jr nz, .shift
    ld a, (c32 + 0)
    ld (hl), a
    inc hl
    ld a, (c32 + 1)
    ld (hl), a
    inc hl
    ld a, (c32 + 2)
    ld (hl), a
    inc hl
    ld a, (c32 + 3)
    ld (hl), a
    inc hl
    inc b
    jr nz, .byte
    ret

; crc32_shr1 - shift the 32-bit CRC right by one bit
;   Clobbers: AF, HL
crc32_shr1:
    ld a, (c32 + 3)
    srl a
    ld (c32 + 3), a
    ld a, (c32 + 2)
    rr a
    ld (c32 + 2), a
    ld a, (c32 + 1)
    rr a
    ld (c32 + 1), a
    ld a, (c32 + 0)
    rr a
    ld (c32 + 0), a
    ret

; ==========================================================================
; Data
; ==========================================================================
passes:     db 0
bits:       db 0
outer:      db 0
t_bit:      db 0
f1:         db 0
f2:         db 0
t0:         db 0
t1:         db 0
t2:         db 0
t3:         db 0
f_tmp:      db 0
f_tmp2:     db 0
r_carry:    db 0
m_ptr:      dw 0
m_a:        ds 4
m_b:        ds 4
m_c:        ds 4
m_d:        ds 4
m_x:        ds 4
m_t:        ds 4
c16h:       db 0
c16l:       db 0
c32:        ds 4

; Tables are 256-aligned so `ld h, page` addresses them.
CHI_PAGE    equ crc16_hi / 256
CLO_PAGE    equ crc16_lo / 256
C32_PAGE    equ crc32_tab / 256
CNIB_PAGE   equ crc32_nib / 256

    align 256
crc16_hi:   ds 256
    align 256
crc16_lo:   ds 256
    align 256
crc32_nib:  ds 64
    align 256
crc32_tab:  ds 1024
