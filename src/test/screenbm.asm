; ==========================================================================
; SCREENBM.COM — screen timing benchmark for CP/M 3 on the ZX Spectrum +3
; ==========================================================================
;
; One binary runs unchanged on this system and on Locomotive's CP/M Plus, so
; the two can be compared on identical work.  It uses only BDOS function 2
; (console output) and the terminal sequences both systems document in the
; +3 CP/M manual (Appendix III): ESC 0, ESC 3, ESC 5, ESC E, ESC H, ESC K,
; ESC Y, ESC x and ESC y.  No BIOS calls, no private entry points, nothing
; that only one of the two has.
;
; HOW THE WORK IS MEASURED
; ========================
; The program does not time anything itself: a program clock is one more
; thing the two systems could disagree about.  Each phase announces itself by
; storing a marker byte to MARKER and brackets its work with two of them:
;
;   marker code   meaning
;   0x10 + n      phase n starts here (first timed instruction is next)
;   0x20 + n      phase n ends here
;
; tools/screen_bench.py arms a memory-write watchpoint on MARKER, and reads
; the Z80 T-states at each stop.  A PC breakpoint would be ambiguous: the
; CCP and the BDOS also execute in the 0100-page, so a breakpoint there can
; fire before the program has even started.  Only this program writes MARKER,
; so the watchpoint cannot be fooled.
;
; MARKER lives at 3F00h, inside the TPA and clear of this program.
;
; TERMINAL NORMALISATION
; ======================
; Every phase first sends ESC 0 (status line off, so the viewport is the
; full 24 rows) and ESC 3 1 (24 x 51, viewport reset and cleared).  The two
; systems ship with different defaults - Locomotive switches the status line
; on at boot and spends a row on it - so without this the same workload
; would not be doing the same work.  Normalisation is outside the timed
; regions.
;
;   A>SCREENBM 0    all phases in sequence (what the harness runs)
;   A>SCREENBM 1    glyphs   8 pages of 23 x 51 characters, no CR/LF
;   A>SCREENBM 2    scroll   640 line feeds from the bottom row
;   A>SCREENBM 3    clear    40 x ESC E (the documented clear-viewport)
;   A>SCREENBM 4    cursor   2000 x ESC Y (row 20, column 5)
;   A>SCREENBM 5    page     4 pages of full-screen text, CR/LF per row
;   A>SCREENBM 6    call     2000 x BDOS function 2 with 01h, which both
;                           systems document as an ignored control code --
;                           the per-call cost with no rendering at all
;   A>SCREENBM 7    noflip   25 x (ESC 3 2; ESC 5 1; 51 characters) -- the
;                           51st character lands in the last visible column
;                           and advances the cursor to 51, but with paging
;                           off nothing pages
;   A>SCREENBM 8    flip     the same, with paging ON and one more
;                           character written at column 51, which is what
;                           makes both systems page the display right
;   A>SCREENBM 9    erase    1000 x ESC K (erase to end of line) from
;                           column 0, i.e. a whole row of cells
;
; The extra character in phase 8 matters: Locomotive pages when a character
; is written past the window, not when the cursor merely arrives there, and
; this system behaves the same way once the write happens.
;
; Phases 7 and 8 differ only in whether the page flips, so their difference
; is the cost of 25 flips.  ESC 3 2 re-enters 24x80 between iterations so
; every iteration starts from the same state on both systems.
;
; Both systems start in 24x51 (CP/M Plus's standard width on the +3), so the
; row width is a constant.  The program ends with "BM DONE" and a warm boot.
;
; Build:
;   sjasmplus --raw=build/screenbm.com --lst=build/screenbm.lst \
;             src/test/screenbm.asm
; ==========================================================================

    org 0x0100

BDOS        equ 0x0005
F_CONOUT    equ 2
F_PSTR      equ 9
ESC         equ 27

MARKER      equ 0x3F00              ; the harness watches this byte

COLS        equ 51
ROWS        equ 23                  ; one row short, so a page never scrolls

CHARS_PAGES equ 8
PAGE_REPS   equ 4
LF_REPS     equ 640
CLR_REPS    equ 40
CUP_REPS    equ 2000
CALL_REPS   equ 2000
FLIP_REPS   equ 25                  ; each repetition flips out and back
ERASE_REPS  equ 1000

; ==========================================================================
; Entry — the phase number comes from the command tail
; ==========================================================================
start:
    xor a
    ld (running_all), a
    ld a, (0x0080)                  ; command-tail length
    or a
    jr z, usage
    ld hl, 0x0081
    ld b, a
.skip_space:
    ld a, (hl)
    cp ' '
    jr nz, .got_phase
    inc hl
    djnz .skip_space
    jr usage
.got_phase:
    cp '0'
    jr nz, .one
    ld a, 1
    ld (running_all), a
    jp run_all
.one:
    sub '0'
    dec a
    cp 9
    jr nc, usage
    add a, a                        ; two bytes per table entry
    ld e, a
    ld d, 0
    ld hl, phase_table
    add hl, de
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld (phase_entry), hl
    call normalise
    ld hl, (phase_entry)
    jp (hl)

usage:
    ld de, msg_usage
    call print
    jp exit

; ==========================================================================
; Run all five phases back to back, so the harness can time them from one
; program launch and never has to round-trip through the CCP.
; ==========================================================================
run_all:
    call phase_glyphs
    call phase_scroll
    call phase_clear
    call phase_cursor
    call phase_page
    call phase_call
    call phase_noflip
    call phase_flip
    call phase_erase
    jp exit

; ==========================================================================
; Normalise the terminal: ESC 0 (status line off) and ESC 3 1 (24 x 51,
; viewport reset and cleared).  Both are outside the timed regions.
; ==========================================================================
normalise:
    ld e, ESC
    call cout
    ld e, '0'
    call cout
    ld e, ESC
    call cout
    ld e, '3'
    call cout
    ld e, '1'
    jp cout

; begin_n / end_n — the marker writes that bracket a timed region
begin_1: ld a, 0x11
         ld (MARKER), a
         ret
end_1:   ld a, 0x21
         ld (MARKER), a
         ret
begin_2: ld a, 0x12
         ld (MARKER), a
         ret
end_2:   ld a, 0x22
         ld (MARKER), a
         ret
begin_3: ld a, 0x13
         ld (MARKER), a
         ret
end_3:   ld a, 0x23
         ld (MARKER), a
         ret
begin_4: ld a, 0x14
         ld (MARKER), a
         ret
end_4:   ld a, 0x24
         ld (MARKER), a
         ret
begin_5: ld a, 0x15
         ld (MARKER), a
         ret
end_5:   ld a, 0x25
         ld (MARKER), a
         ret
begin_6: ld a, 0x16
         ld (MARKER), a
         ret
end_6:   ld a, 0x26
         ld (MARKER), a
         ret
begin_7: ld a, 0x17
         ld (MARKER), a
         ret
end_7:   ld a, 0x27
         ld (MARKER), a
         ret
begin_8: ld a, 0x18
         ld (MARKER), a
         ret
end_8:   ld a, 0x28
         ld (MARKER), a
         ret
begin_9: ld a, 0x19
         ld (MARKER), a
         ret
end_9:   ld a, 0x29
         ld (MARKER), a
         ret

; ==========================================================================
; 1. Glyphs — 8 pages of 23 x 51 characters, re-homed between pages so the
;    cursor never reaches the bottom row and nothing scrolls.
; ==========================================================================
phase_glyphs:
    call normalise
    ld de, msg_glyphs
    call print
    ld hl, CHARS_PAGES
    ld (pages), hl
    call begin_1
.page:
    call home
    ld a, ROWS
    ld (rows), a
.row:
    ld hl, COLS
    ld (cols), hl
.col:
    ld e, 'A'
    call cout
    ld hl, (cols)
    dec hl
    ld (cols), hl
    ld a, h
    or l
    jr nz, .col
    ld a, (rows)
    dec a
    ld (rows), a
    jr nz, .row
    ld hl, (pages)
    dec hl
    ld (pages), hl
    ld a, h
    or l
    jr nz, .page
    call end_1
    jp phase_finished

; ==========================================================================
; 2. Scroll — walk to the bottom row, then 640 line feeds
; ==========================================================================
phase_scroll:
    call normalise
    ld de, msg_scroll
    call print
    call home
    ld a, ROWS                      ; ROWS newlines put us on the last row
    ld (rows), a
.down:
    call newline
    ld a, (rows)
    dec a
    ld (rows), a
    jr nz, .down
    ld hl, LF_REPS
    ld (reps), hl
    call begin_2
.loop:
    call newline
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_2
    jp phase_finished

; ==========================================================================
; 3. Clear — ESC E, "clears the viewport, cursor position unaffected"
; ==========================================================================
phase_clear:
    call normalise
    ld de, msg_clear
    call print
    ld hl, CLR_REPS
    ld (reps), hl
    call begin_3
.loop:
    call viewport_clear
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_3
    jp phase_finished

; ==========================================================================
; 4. Cursor — ESC Y to row 20, column 5, 2000 times
; ==========================================================================
phase_cursor:
    call normalise
    ld de, msg_cursor
    call print
    ld hl, CUP_REPS
    ld (reps), hl
    call begin_4
.loop:
    call cursor_20_5
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_4
    jp phase_finished

; ==========================================================================
; 5. Page — full-screen paint: home, then 23 rows of 51 characters.  No
;    explicit CR/LF: the 51st character wraps to the next row, exactly as a
;    full screen wraps.  After 23 rows the cursor is on row 23, so nothing
;    scrolls.
; ==========================================================================
phase_page:
    call normalise
    ld de, msg_page
    call print
    ld hl, PAGE_REPS
    ld (pages), hl
    call begin_5
.page:
    call home
    ld a, ROWS
    ld (rows), a
.row:
    ld hl, COLS
    ld (cols), hl
.col:
    ld e, 'A'
    call cout
    ld hl, (cols)
    dec hl
    ld (cols), hl
    ld a, h
    or l
    jr nz, .col
    ld a, (rows)
    dec a
    ld (rows), a
    jr nz, .row
    ld hl, (pages)
    dec hl
    ld (pages), hl
    ld a, h
    or l
    jr nz, .page
    call end_5
    jp phase_finished

; ==========================================================================
; 6. Call — 2000 BDOS console calls with no rendering, to isolate the
;    per-call cost from the per-glyph cost.  01h is a control code both
;    systems document as ignored, so neither draws anything.
; ==========================================================================
phase_call:
    call normalise
    ld de, msg_call
    call print
    ld hl, CALL_REPS
    ld (reps), hl
    call begin_6
.loop:
    ld e, 1
    call cout
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_6
    jp phase_finished

; ==========================================================================
; 7. Noflip — 25 iterations of: re-enter 24x80, turn auto-paging OFF, and
;    write 51 characters.  The cursor reaches column 51 of the 80-column
;    logical screen, but with paging off the window stays at columns 0..50.
;    This is the baseline for phase 8.
; ==========================================================================
phase_noflip:
    call normalise
    ld de, msg_noflip
    call print
    ld hl, FLIP_REPS
    ld (reps), hl
    call begin_7
.loop:
    call enter80
    call paging_off
    ld a, COLS
    ld (rows), a
.col:
    ld e, 'A'
    call cout
    ld a, (rows)
    dec a
    ld (rows), a
    jr nz, .col
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_7
    ld e, ESC
    call cout
    ld e, 'y'
    call cout
    jp phase_finished

; ==========================================================================
; 8. Flip — the same work with auto-paging ON, plus one more character at
;    column 51.  That write is what pages the display right.
; ==========================================================================
phase_flip:
    call normalise
    ld de, msg_flip
    call print
    ld hl, FLIP_REPS
    ld (reps), hl
    call begin_8
.loop:
    call enter80
    call paging_on
    ld a, COLS
    ld (rows), a
.col:
    ld e, 'A'
    call cout
    ld a, (rows)
    dec a
    ld (rows), a
    jr nz, .col
    ld e, 'A'
    call cout                      ; the character that leaves the window
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_8
    ld e, ESC
    call cout
    ld e, 'y'
    call cout
    jp phase_finished

; enter80 — ESC 3 2, 24x80 at the current physical width, window at column 0
enter80:
    ld e, ESC
    call cout
    ld e, '3'
    call cout
    ld e, '2'
    jp cout

; paging_off / paging_on — ESC 5 1 / ESC 5 0 (the +3 manual's polarity)
paging_off:
    ld e, ESC
    call cout
    ld e, '5'
    call cout
    ld e, '1'
    jp cout

paging_on:
    ld e, ESC
    call cout
    ld e, '5'
    call cout
    ld e, '0'
    jp cout

; ==========================================================================
; 8. Erase — ESC K from column 0, so a whole 51-cell row is cleared
; ==========================================================================
phase_erase:
    call normalise
    ld de, msg_erase
    call print
    ld hl, ERASE_REPS
    ld (reps), hl
    call begin_9
.loop:
    call home
    call erase_eol                  ; ESC K
    ld hl, (reps)
    dec hl
    ld (reps), hl
    ld a, h
    or l
    jr nz, .loop
    call end_9
    jp phase_finished

; phase_finished — return to run_all, or leave after a single phase
phase_finished:
    ld a, (running_all)
    or a
    ret nz
    jp exit

; ==========================================================================
; Helpers — every piece of loop state lives in memory, so it does not
; matter which registers a system's BDOS chooses to clobber.
; ==========================================================================

cout:
    push de
    ld c, F_CONOUT
    call BDOS
    pop de
    ret

print:
    ld c, F_PSTR
    jp BDOS

newline:
    ld e, 13
    call cout
    ld e, 10
    jp cout

home:                               ; ESC H
    ld e, ESC
    call cout
    ld e, 'H'
    jp cout

viewport_clear:                     ; ESC E
    ld e, ESC
    call cout
    ld e, 'E'
    jp cout

cursor_20_5:                        ; ESC Y, row+32, column+32
    ld e, ESC
    call cout
    ld e, 'Y'
    call cout
    ld e, 20 + 32
    call cout
    ld e, 5 + 32
    jp cout

cup_0_79:                           ; ESC Y, row 0, column 79
    ld e, ESC
    call cout
    ld e, 'Y'
    call cout
    ld e, 0 + 32
    call cout
    ld e, 79 + 32
    jp cout

cup_0_0:                            ; ESC Y, row 0, column 0
    ld e, ESC
    call cout
    ld e, 'Y'
    call cout
    ld e, 0 + 32
    call cout
    ld e, 0 + 32
    jp cout

cup_0_60:                           ; ESC Y, row 0, column 60
    ld e, ESC
    call cout
    ld e, 'Y'
    call cout
    ld e, 0 + 32
    call cout
    ld e, 60 + 32
    jp cout

erase_eol:                          ; ESC K
    ld e, ESC
    call cout
    ld e, 'K'
    jp cout

exit:
    ld de, msg_done
    call print
    xor a
    ld (MARKER), a                  ; done: the harness stops here
    jp 0                            ; warm boot

; ==========================================================================
; Data
; ==========================================================================
phase_table:
    dw phase_glyphs
    dw phase_scroll
    dw phase_clear
    dw phase_cursor
    dw phase_page
    dw phase_call
    dw phase_noflip
    dw phase_flip
    dw phase_erase

running_all:  db 0
phase_entry:  dw 0
pages:        dw 0
reps:         dw 0
cols:         dw 0
rows:         db 0
rowarg:       db 0
rowidx:       db 0

msg_usage:  db 13, 10, 'SCREENBM <0-5>', 13, 10, '$'
msg_glyphs: db 13, 10, 'BM GLYPHS 1', 13, 10, '$'
msg_scroll: db 13, 10, 'BM SCROLL 2', 13, 10, '$'
msg_clear:  db 13, 10, 'BM CLEAR 3', 13, 10, '$'
msg_cursor: db 13, 10, 'BM CURSOR 4', 13, 10, '$'
msg_page:   db 13, 10, 'BM PAGE 5', 13, 10, '$'
msg_call:   db 13, 10, 'BM CALL 6', 13, 10, '$'
msg_noflip: db 13, 10, 'BM NOFLIP 7', 13, 10, '$'
msg_flip:   db 13, 10, 'BM FLIP 8', 13, 10, '$'
msg_erase:  db 13, 10, 'BM ERASE 9', 13, 10, '$'
msg_done:   db 13, 10, 'BM DONE', 13, 10, '$'
