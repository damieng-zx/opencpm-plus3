; TERMTEST.COM - self-checking screen-driver regression
;
; Covers the BIOS terminal-emulation escapes and the screen modes:
;
;   * cursor:   ESC Y, ESC H, ESC A/B/C/D (with clamping), ESC j/k
;   * geometry: ESC 3 0/1/2 widths, ESC 3 cancels page mode, ESC 4
;   * status:   ESC 0/1 (TE_STL_ASK + the 23-row viewport) and the
;               23-row scroll path
;   * wrapping: ESC v/w
;   * control:  BS (non-destructive cursor motion)
;   * erasing:  ESC E/J/K/d/l/o
;   * editing:  ESC L/M/N and ESC I (reverse index)
;   * 24x80:    ESC x/y, TE_ASK width 80, LG_BUF writes, auto-flip and the
;               visible-window mapping
;
; Screen *contents* are read back through SCR_RUN_ROUTINE (XBIOS 0x00E9),
; which runs a small position-independent reader with banks 5 and 6 paged
; in; that is what lets the program check the character buffer itself
; instead of asking a human to look at the screen.
;
; The three glyph-rendering phases (32 columns/8px, 51 columns/5px and the
; 24x80 page flip) print a marker and wait for a key; tools/zx84_smoke.py
; renders the reference from the character buffer and compares the visible
; bitmap.  A failure prints "TERMTEST..FAIL <name>" and warm boots.
;
; Exits with "TERMTEST..OK" on screen (24x80 flip phase) and leaves 51
; columns when a key is pressed.
;
; Build: sjasmplus --raw=build/termtest.com src/test/termtest.asm

    org 0x0100

BDOS            equ 0x0005
F_CONIN         equ 1
F_CONOUT        equ 2
F_PRINT         equ 9
F_CONMODE       equ 109

TE_ASK          equ 0x00BF
TE_STL_ASK      equ 0x00C5
TE_STL_ON_OFF   equ 0x00C8
SCR_RUN_ROUTINE equ 0x00E9

ESC             equ 0x1B
CR              equ 0x0D
LF              equ 0x0A

CHK_BASE        equ 0xD000      ; common-memory window the checker is copied to

; --------------------------------------------------------------------------
start:
    ; Compute the USERF (BIOS function 30) entry from the warm-boot vector.
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl                      ; HL = BIOS base
    ld de, 90
    add hl, de                  ; HL = USERF entry
    ld (userf_call + 1), hl

    ; The character-buffer reader must be in common memory so it stays
    ; visible while the screen banks are paged in.
    ld hl, checker_start
    ld de, CHK_BASE
    ld bc, checker_end - checker_start
    ldir

    ; Known state: page mode off, status line off, 51 columns, auto-flip on.
    ; ESC 5 0 turns auto-flip ON (the +3 manual's polarity), 1 turns it off.
    ld a, '4'
    ld b, '0'
    call esc_1p
    ld a, '0'
    call esc_cmd
    ld a, '3'
    ld b, '1'
    call esc_1p
    ld a, '5'
    ld b, '0'
    call esc_1p

    call t_cursor_y
    call t_cursor_home
    call t_cursor_rel
    call t_cursor_save
    call t_widths
    call t_page_mode
    call t_status_line
    call t_wrap
    call t_backspace
    call t_clear
    call t_erase_j
    call t_erase_k
    call t_erase_d
    call t_erase_l
    call t_erase_o
    call t_insert_line
    call t_delete_line
    call t_delete_char
    call t_reverse_index
    call t_scroll23
    call t_m80

    ; ---- visual phases (checked by the smoke runner) ----
    call phase_32
    call phase_51
    call phase_flip

    ; phase_flip never returns here (it waits, then warm boots).

; --------------------------------------------------------------------------
; Tests
; --------------------------------------------------------------------------

; ---- ESC Y: absolute cursor position ----
t_cursor_y:
    ld de, n_y
    ld (v_name), de
    call clear_screen
    ld d, 5
    ld e, 7
    call set_cur
    ld d, 5
    ld e, 7
    call expect_cur
    ld d, 23
    ld e, 50
    call set_cur
    ld d, 23
    ld e, 50
    call expect_cur
    ld de, n_y
    jp pass_

; ---- ESC H: home ----
t_cursor_home:
    ld de, n_h
    ld (v_name), de
    call clear_screen
    ld d, 9
    ld e, 33
    call set_cur
    ld a, 'H'
    call esc_cmd
    ld d, 0
    ld e, 0
    call expect_cur
    ld de, n_h
    jp pass_

; ---- ESC A/B/C/D: relative moves and clamping ----
t_cursor_rel:
    ld de, n_rel
    ld (v_name), de
    call clear_screen
    ld d, 5
    ld e, 5
    call set_cur
    ld a, 'A'
    call esc_cmd
    ld d, 4
    ld e, 5
    call expect_cur
    ld a, 'B'
    call esc_cmd
    ld d, 5
    ld e, 5
    call expect_cur
    ld a, 'C'
    call esc_cmd
    ld d, 5
    ld e, 6
    call expect_cur
    ld a, 'D'
    call esc_cmd
    ld d, 5
    ld e, 5
    call expect_cur
    ; clamping at the top-left and bottom-right
    ld d, 0
    ld e, 0
    call set_cur
    ld a, 'A'
    call esc_cmd
    ld d, 0
    ld e, 0
    call expect_cur
    ld a, 'D'
    call esc_cmd
    ld d, 0
    ld e, 0
    call expect_cur
    ld d, 23
    ld e, 50
    call set_cur
    ld a, 'B'
    call esc_cmd
    ld d, 23
    ld e, 50
    call expect_cur
    ld a, 'C'
    call esc_cmd
    ld d, 23
    ld e, 50
    call expect_cur
    ld de, n_rel
    jp pass_

; ---- ESC j / ESC k: save and restore ----
t_cursor_save:
    ld de, n_save
    ld (v_name), de
    call clear_screen
    ld d, 6
    ld e, 9
    call set_cur
    ld a, 'j'
    call esc_cmd
    ld d, 2
    ld e, 3
    call set_cur
    ld a, 'k'
    call esc_cmd
    ld d, 6
    ld e, 9
    call expect_cur
    ld de, n_save
    jp pass_

; ---- ESC 3 n: widths 32/51/80, and leaving 24x80 ----
t_widths:
    ld de, n_width
    ld (v_name), de
    ld a, '3'
    ld b, '0'
    call esc_1p
    ld a, 32
    call expect_w
    xor a
    call expect_mode
    ld a, '3'
    ld b, '1'
    call esc_1p
    ld a, 51
    call expect_w
    ld a, '3'
    ld b, '2'
    call esc_1p
    ld a, 80
    call expect_w
    ld a, 1
    call expect_mode
    ld a, 0
    call expect_off
    ld a, 'y'
    call esc_cmd
    ld a, 51
    call expect_w
    xor a
    call expect_mode
    ld de, n_width
    jp pass_

; ---- ESC 4 n: page mode, and ESC 3 cancels it ----
t_page_mode:
    ld de, n_page
    ld (v_name), de
    ld a, '4'
    ld b, '1'
    call esc_1p
    call expect_page_on
    ld a, '4'
    ld b, '0'
    call esc_1p
    call expect_page_off
    ld a, '4'
    ld b, '1'
    call esc_1p
    call expect_page_on
    ld a, '3'
    ld b, '1'
    call esc_1p
    call expect_page_off
    ld de, n_page
    jp pass_

; ---- ESC 0 / ESC 1: status line and the 23-row viewport ----
t_status_line:
    ld de, n_stl
    ld (v_name), de
    call clear_screen
    ld a, '1'
    call esc_cmd
    ld a, 0xFF
    call expect_stl
    ld a, 23
    call expect_h
    ld a, '0'
    call esc_cmd
    xor a
    call expect_stl
    ld a, 24
    call expect_h
    ld de, n_stl
    jp pass_

; ---- ESC v / ESC w: wrapping at the right edge ----
t_wrap:
    ld de, n_wrap
    ld (v_name), de
    ld a, '3'
    ld b, '0'
    call esc_1p
    ld a, 'w'
    call esc_cmd
    ld a, 'H'
    call esc_cmd
    ld b, 40
    ld a, 'X'
    call put_repeat
    ld d, 0
    ld e, 31
    call expect_cur
    call clear_screen
    ld a, 'v'
    call esc_cmd
    ld a, 'H'
    call esc_cmd
    ld b, 40
    ld a, 'X'
    call put_repeat
    ld d, 1
    ld e, 8
    call expect_cur
    ld a, '3'
    ld b, '1'
    call esc_1p
    ld de, n_wrap
    jp pass_

; ---- BS: cursor motion only, it must not erase ----
;
; CP/M Plus BS is a pure cursor move.  DISCKIT draws box edges right to
; left as "corner, BS, BS, dash, BS, BS, dash" and a destructive BS eats the
; glyphs it just wrote; that is what truncated the DISCKIT menu's boxes.
t_backspace:
    ld de, n_bs
    ld (v_name), de
    call clear_screen

    ; 1. "ABCDE" then two backspaces leaves ABCDE in the buffer.
    ld d, 3
    ld e, 5
    call set_cur
    ld de, s_abcde
    call pstr
    call bs
    call bs
    ld d, 3
    ld e, 5
    ld c, 'A'
    call expect_cell
    ld d, 3
    ld e, 6
    ld c, 'B'
    call expect_cell
    ld d, 3
    ld e, 7
    ld c, 'C'
    call expect_cell
    ld d, 3
    ld e, 8
    ld c, 'D'
    call expect_cell
    ld d, 3
    ld e, 9
    ld c, 'E'
    call expect_cell
    ; ...and the cursor did move back two columns (5 chars from col 5 leave
    ; the cursor at col 10; two backspaces put it at col 8).
    ld d, 3
    ld e, 8
    call expect_cur

    ; 2. Overwriting after the backspaces still works (the classic
    ;    "BS BS XY" case): the two characters are replaced in place.
    ld d, 6
    ld e, 5
    call set_cur
    ld de, s_abcde
    call pstr
    call bs
    call bs
    ld de, s_xy
    call pstr
    ld d, 6
    ld e, 5
    ld c, 'A'
    call expect_cell
    ld d, 6
    ld e, 6
    ld c, 'B'
    call expect_cell
    ld d, 6
    ld e, 7
    ld c, 'C'
    call expect_cell
    ld d, 6
    ld e, 8
    ld c, 'X'
    call expect_cell
    ld d, 6
    ld e, 9
    ld c, 'Y'
    call expect_cell
    ld de, n_bs
    jp pass_

; ---- ESC E: clear the viewport, cursor unchanged ----
t_clear:
    ld de, n_clr
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 2
    call set_cur
    ld a, 'E'
    call esc_cmd
    ld d, 2
    ld e, 2
    call expect_cur
    ld d, 0
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 5
    ld e, 10
    ld c, ' '
    call expect_cell
    ld de, n_clr
    jp pass_

; ---- ESC J: erase from cursor to the end of the viewport ----
t_erase_j:
    ld de, n_eraj
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 2
    call set_cur
    ld a, 'J'
    call esc_cmd
    ld d, 2
    ld e, 2
    call expect_cur
    ld d, 1
    ld e, 0
    ld c, '1'
    call expect_cell
    ld d, 2
    ld e, 1
    ld c, '2'
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 50
    ld c, ' '
    call expect_cell
    ld d, 3
    ld e, 0
    ld c, ' '
    call expect_cell
    ld de, n_eraj
    jp pass_

; ---- ESC K: erase from cursor to end of line ----
t_erase_k:
    ld de, n_erak
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 2
    call set_cur
    ld a, 'K'
    call esc_cmd
    ld d, 2
    ld e, 2
    call expect_cur
    ld d, 2
    ld e, 1
    ld c, '2'
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 50
    ld c, ' '
    call expect_cell
    ld d, 3
    ld e, 0
    ld c, '3'
    call expect_cell
    ld de, n_erak
    jp pass_

; ---- ESC d: erase from top of the viewport to the cursor ----
t_erase_d:
    ld de, n_erad
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 2
    call set_cur
    ld a, 'd'
    call esc_cmd
    ld d, 2
    ld e, 2
    call expect_cur
    ld d, 0
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 1
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 1
    ld e, 50
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 3
    ld c, '2'
    call expect_cell
    ld d, 2
    ld e, 10
    ld c, 'C'
    call expect_cell
    ld de, n_erad
    jp pass_

; ---- ESC l: erase the whole line ----
t_erase_l:
    ld de, n_eral
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 5
    call set_cur
    ld a, 'l'
    call esc_cmd
    ld d, 2
    ld e, 5
    call expect_cur
    ld d, 2
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 10
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 50
    ld c, ' '
    call expect_cell
    ld d, 3
    ld e, 0
    ld c, '3'
    call expect_cell
    ld de, n_eral
    jp pass_

; ---- ESC o: erase start of line to the cursor ----
t_erase_o:
    ld de, n_erao
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 2
    call set_cur
    ld a, 'o'
    call esc_cmd
    ld d, 2
    ld e, 2
    call expect_cur
    ld d, 2
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 3
    ld c, '2'
    call expect_cell
    ld d, 1
    ld e, 0
    ld c, '1'
    call expect_cell
    ld de, n_erao
    jp pass_

; ---- ESC L: insert a line at the cursor ----
t_insert_line:
    ld de, n_insl
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 0
    call set_cur
    ld a, 'L'
    call esc_cmd
    ld d, 2
    ld e, 0
    call expect_cur
    ld d, 1
    ld e, 0
    ld c, '1'
    call expect_cell
    ld d, 2
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 10
    ld c, ' '
    call expect_cell
    ld d, 3
    ld e, 0
    ld c, '2'
    call expect_cell
    ld d, 4
    ld e, 0
    ld c, '3'
    call expect_cell
    ld d, 5
    ld e, 0
    ld c, '4'
    call expect_cell
    ld d, 6
    ld e, 0
    ld c, '5'
    call expect_cell
    ld de, n_insl
    jp pass_

; ---- ESC M: delete the cursor line ----
t_delete_line:
    ld de, n_dell
    ld (v_name), de
    call setup_pattern
    ld d, 2
    ld e, 0
    call set_cur
    ld a, 'M'
    call esc_cmd
    ld d, 2
    ld e, 0
    call expect_cur
    ld d, 1
    ld e, 0
    ld c, '1'
    call expect_cell
    ld d, 2
    ld e, 0
    ld c, '3'
    call expect_cell
    ld d, 3
    ld e, 0
    ld c, '4'
    call expect_cell
    ld d, 4
    ld e, 0
    ld c, '5'
    call expect_cell
    ld d, 23
    ld e, 0
    ld c, ' '
    call expect_cell
    ld de, n_dell
    jp pass_

; ---- ESC N: delete the character under the cursor ----
t_delete_char:
    ld de, n_delc
    ld (v_name), de
    call clear_screen
    ld d, 2
    ld e, 0
    call set_cur
    ld de, s_abc
    call pstr
    ld d, 2
    ld e, 1
    call set_cur
    ld a, 'N'
    call esc_cmd
    ld d, 2
    ld e, 1
    call expect_cur
    ld d, 2
    ld e, 0
    ld c, 'A'
    call expect_cell
    ld d, 2
    ld e, 1
    ld c, 'C'
    call expect_cell
    ld d, 2
    ld e, 2
    ld c, ' '
    call expect_cell
    ld d, 2
    ld e, 50
    ld c, ' '
    call expect_cell
    ld de, n_delc
    jp pass_

; ---- ESC I: reverse index at the top scrolls down ----
t_reverse_index:
    ld de, n_rev
    ld (v_name), de
    call setup_pattern
    ld d, 0
    ld e, 0
    call set_cur
    ld a, 'I'
    call esc_cmd
    ld d, 0
    ld e, 0
    call expect_cur
    ld d, 0
    ld e, 0
    ld c, ' '
    call expect_cell
    ld d, 1
    ld e, 0
    ld c, '0'
    call expect_cell
    ld d, 2
    ld e, 0
    ld c, '1'
    call expect_cell
    ld de, n_rev
    jp pass_

; ---- status line: 30 lines through the 23-row viewport ----
t_scroll23:
    ld de, n_scroll
    ld (v_name), de
    call clear_screen
    ld a, '1'
    call esc_cmd
    ld a, 0xFF
    call expect_stl
    ld a, 23
    call expect_h
    ld de, s_lines
    call pstr
    ; lines 08..29 are on rows 0..21; row 22 is blank after the last LF.
    ld d, 0
    ld e, 0
    ld c, '0'
    call expect_cell
    ld d, 0
    ld e, 1
    ld c, '8'
    call expect_cell
    ld d, 21
    ld e, 0
    ld c, '2'
    call expect_cell
    ld d, 21
    ld e, 1
    ld c, '9'
    call expect_cell
    ld d, 22
    ld e, 0
    ld c, ' '
    call expect_cell
    ; the status row itself stays blank in 51-column mode
    ld d, 23
    ld e, 0
    ld c, ' '
    call expect_cell
    ld a, '0'
    call esc_cmd
    xor a
    call expect_stl
    ld a, 24
    call expect_h
    ld de, n_scroll
    jp pass_

; ---- 24x80: TE_ASK, logical buffer, auto-flip, window mapping ----
t_m80:
    ld de, n_m80
    ld (v_name), de
    call clear_screen
    ld a, 'x'
    call esc_cmd
    ld a, 80
    call expect_w
    ld a, 1
    call expect_mode
    ld a, 0
    call expect_off
    ld d, 0
    ld e, 0
    call set_cur
    ld a, 'A'
    call cout
    ld d, 0
    ld e, 0
    ld c, 'A'
    call expect_lg
    ld d, 0
    ld e, 0
    ld c, 'A'
    call expect_cell
    ; Moving past the physical window flips to page 29.
    ld d, 0
    ld e, 51
    call set_cur
    ld a, 29
    call expect_off
    ld a, 'B'
    call cout
    ld d, 0
    ld e, 51
    ld c, 'B'
    call expect_lg
    ld d, 0
    ld e, 22
    ld c, 'B'
    call expect_cell
    ; ...and moving back flips to page 0.
    ld d, 0
    ld e, 0
    call set_cur
    ld a, 0
    call expect_off
    ld d, 0
    ld e, 0
    call expect_cur
    ; ESC 5 1 disables auto-flip (the +3 manual's polarity, shared with
    ; Locomotive).  The window is on page 0 here; with paging off, moving the
    ; cursor out to column 60 must leave it there.
    ld a, '5'
    ld b, '1'
    call esc_1p
    ld a, 0
    call expect_off
    ld d, 0
    ld e, 60
    call set_cur
    ld a, 0
    call expect_off
    ; ESC 5 0 enables it again; the next out-of-window move must page right.
    ld a, '5'
    ld b, '0'
    call esc_1p
    ld d, 0
    ld e, 60
    call set_cur
    ld a, 29
    call expect_off
    ld d, 0
    ld e, 0
    call set_cur
    ld a, 0
    call expect_off
    ld a, 'y'
    call esc_cmd
    ld a, 51
    call expect_w
    xor a
    call expect_mode
    ld de, n_m80
    jp pass_

; --------------------------------------------------------------------------
; Visual phases
; --------------------------------------------------------------------------

phase_32:
    ld a, '3'
    ld b, '0'
    call esc_1p
    ld a, '0'
    call esc_cmd
    call clear_screen
    ld d, 0
    ld e, 0
    call set_cur
    ld de, s_pat32
    call pstr
    ld d, 2
    ld e, 0
    call set_cur
    ld de, s_vis32
    call pstr
    call wait_key
    ret

phase_51:
    ld a, '3'
    ld b, '1'
    call esc_1p
    ld a, '0'
    call esc_cmd
    call clear_screen
    ld d, 0
    ld e, 0
    call set_cur
    ld de, s_pat51
    call pstr
    ld d, 2
    ld e, 0
    call set_cur
    ld de, s_vis51
    call pstr
    call wait_key
    ret

phase_flip:
    ld a, 'x'
    call esc_cmd
    ld d, 0
    ld e, 29
    call set_cur
    ld a, 'W'
    call cout
    ld d, 0
    ld e, 51
    call set_cur
    ld a, 'Q'
    call cout
    ld de, s_ok
    call pstr
    call wait_key
    ; Back to a sane prompt after the runner's flip-back checks.
    jp restore

; --------------------------------------------------------------------------
; Helpers
; --------------------------------------------------------------------------

; cout - write A via BDOS CONOUT (preserves all registers)
cout:
    push af
    push bc
    push de
    push hl
    ld e, a
    ld c, F_CONOUT
    call BDOS
    pop hl
    pop de
    pop bc
    pop af
    ret

; pstr - print a $-terminated string at DE
pstr:
    push bc
    push de
    push hl
    ld c, F_PRINT
    call BDOS
    pop hl
    pop de
    pop bc
    ret

; wait_key - block on a keystroke
wait_key:
    push af
    push bc
    push de
    push hl
    ld c, F_CONIN
    call BDOS
    pop hl
    pop de
    pop bc
    pop af
    ret

; set_cur - ESC Y row/col (D = row, E = col)
set_cur:
    ld a, ESC
    call cout
    ld a, 'Y'
    call cout
    ld a, d
    add a, 0x20
    call cout
    ld a, e
    add a, 0x20
    jp cout

; bs - send a backspace via BDOS CONOUT
bs:
    ld a, 0x08
    jp cout

; esc_cmd - send ESC followed by the command in A
esc_cmd:
    push af
    ld a, ESC
    call cout
    pop af
    jp cout

; esc_1p - send ESC + command (A) + parameter (B)
esc_1p:
    call esc_cmd
    ld a, b
    jp cout

; clear_screen - ESC E then ESC H
clear_screen:
    ld a, 'E'
    call esc_cmd
    ld a, 'H'
    jp esc_cmd

; put_repeat - write A, B times
put_repeat:
    ld c, a
.pr_loop:
    ld a, c
    push bc
    call cout
    pop bc
    djnz .pr_loop
    ret

; ask - TE_ASK into v_top/v_left/v_h/v_w/v_r/v_c
ask:
    ld hl, TE_ASK
    call xcall
    ld a, b
    ld (v_top), a
    ld a, c
    ld (v_left), a
    ld a, d
    ld (v_h), a
    ld a, e
    ld (v_w), a
    ld a, h
    ld (v_r), a
    ld a, l
    ld (v_c), a
    ret

; xcall - call an XBIOS entry (HL) through USERF
xcall:
    ld (userf_dw), hl
userf_call:
    call 0
userf_dw:
    dw 0
    ret

; chk - run a checker routine (HL = offset) with D/E arguments
chk:
    ld b, h
    ld c, l
    ld hl, CHK_BASE
    add hl, bc
    ld b, h
    ld c, l
    ld hl, SCR_RUN_ROUTINE
    ld (userf_dw), hl
    jp userf_call

; cell_get - A = visible char at (D,E)
cell_get:
    ld hl, rd_cell - checker_start
    jp chk

; lg_get - A = logical (80-column) char at (D,E)
lg_get:
    ld hl, rd_lg - checker_start
    jp chk

; mode_get - A = mode80
mode_get:
    ld hl, rd_mode - checker_start
    jp chk

; off_get - A = lg_off
off_get:
    ld hl, rd_off - checker_start
    jp chk

; expect_cur - D/E must equal TE_ASK's cursor
expect_cur:
    ld a, d
    ld (v_exp), a
    ld a, e
    ld (v_exp2), a
    call ask
    ld a, (v_r)
    ld b, a
    ld a, (v_exp)
    cp b
    jr nz, .ec_fail
    ld a, (v_c)
    ld b, a
    ld a, (v_exp2)
    cp b
    ret z
.ec_fail:
    ld de, (v_name)
    jp fail

; expect_w - A = expected width (TE_ASK E+1)
expect_w:
    ld (v_exp), a
    call ask
    ld a, (v_w)
    inc a
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_h - A = expected height (TE_ASK D+1)
expect_h:
    ld (v_exp), a
    call ask
    ld a, (v_h)
    inc a
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_mode - A = expected mode80
expect_mode:
    ld (v_exp), a
    call mode_get
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_off - A = expected lg_off
expect_off:
    ld (v_exp), a
    call off_get
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_cell - D/E cell must contain C
expect_cell:
    ld a, c
    ld (v_exp), a
    call cell_get
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_lg - D/E logical cell must contain C
expect_lg:
    ld a, c
    ld (v_exp), a
    call lg_get
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_stl - TE_STL_ASK must report A
expect_stl:
    ld (v_exp), a
    ld hl, TE_STL_ASK
    call xcall
    ld b, a
    ld a, (v_exp)
    cp b
    ret z
    ld de, (v_name)
    jp fail

; expect_page_on / expect_page_off - F109 bit 0
expect_page_on:
    call f109_get
    bit 0, l
    ret nz
    ld de, (v_name)
    jp fail

expect_page_off:
    call f109_get
    bit 0, l
    ret z
    ld de, (v_name)
    jp fail

; f109_get - HL = console mode word
f109_get:
    ld de, 0xFFFF
    ld c, F_CONMODE
    jp BDOS

; setup_pattern - rows 0..5: five row digits at col 0, a letter at col 10
setup_pattern:
    call clear_screen
    xor a
    ld (v_row), a
.sp_loop:
    ld a, (v_row)
    cp 6
    ret z
    ld d, a
    xor a
    ld e, a
    call set_cur
    ld a, '0'
    ld hl, v_row
    add a, (hl)
    ld b, 5
    call put_repeat
    ld a, (v_row)
    ld d, a
    ld e, 10
    call set_cur
    ld a, 'A'
    ld hl, v_row
    add a, (hl)
    call cout
    ld a, (v_row)
    inc a
    ld (v_row), a
    jr .sp_loop

; pass_ - print "<name>..OK" and return
pass_:
    call pstr
    ld de, s_ok_line
    jp pstr

; fail - print "<name>..FAIL", wait for a key, then warm boot
fail:
    call pstr
    ld de, s_fail_line
    call pstr
    call wait_key
; restore - leave 24x80 at 51 columns, status line off and auto-flip back
; at its cold-boot default (off; t_m80 turns it on), then warm boot
restore:
    ld a, 'y'
    call esc_cmd
    ld a, '3'
    ld b, '1'
    call esc_1p
    ld a, '0'
    call esc_cmd
    ld a, '5'
    ld b, '1'
    call esc_1p
warm:
    jp 0x0000

; --------------------------------------------------------------------------
; Character-buffer reader, copied to CHK_BASE (common memory).
;
; It runs with the screen banks paged in (4,5,6,3) and may not call BIOS or
; BDOS.  Only relative jumps are used, so the copied block is position
; independent.  Bank 6 is at 8000h (0xA000 is char_buffer, 0xA8C1 mode80,
; 0xA8C2 lg_off); bank 5 is at 4000h (0x5B00 is LG_BUF).
; --------------------------------------------------------------------------
checker_start:
rd_cell:
    ld a, e
    ld (0xD1F1), a
    ld hl, 0xA000               ; char_buffer
    ld a, d
    or a
    jr z, .rc_col
    ld b, a
    ld de, 51
.rc_row:
    add hl, de
    djnz .rc_row
.rc_col:
    ld a, (0xD1F1)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    ret

rd_lg:
    ld a, e
    ld (0xD1F1), a
    ld hl, 0x5B00               ; LG_BUF
    ld a, d
    or a
    jr z, .rl_col
    ld b, a
    ld de, 80
.rl_row:
    add hl, de
    djnz .rl_row
.rl_col:
    ld a, (0xD1F1)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    ret

rd_mode:
    ld a, (0xA8C1)
    ret

rd_off:
    ld a, (0xA8C2)
    ret
checker_end:

; --------------------------------------------------------------------------
; Data
; --------------------------------------------------------------------------
v_name:     dw 0
v_exp:      db 0
v_exp2:     db 0
v_row:      db 0
v_top:      db 0
v_left:     db 0
v_h:        db 0
v_w:        db 0
v_r:        db 0
v_c:        db 0

n_y:        db "Y", 0
n_h:        db "H", 0
n_rel:      db "ABCD", 0
n_save:     db "JK", 0
n_width:    db "WIDTH", 0
n_page:     db "PAGE", 0
n_stl:      db "STL", 0
n_wrap:     db "WRAP", 0
n_bs:       db "BS", 0
n_clr:      db "CLR", 0
n_eraj:     db "ERAJ", 0
n_erak:     db "ERAK", 0
n_erad:     db "ERAd", 0
n_eral:     db "ERAl", 0
n_erao:     db "ERAo", 0
n_insl:     db "INSL", 0
n_dell:     db "DELL", 0
n_delc:     db "DELC", 0
n_rev:      db "REVIDX", 0
n_scroll:   db "SCROLL23", 0
n_m80:      db "24x80", 0

s_ok_line:   db "..OK", CR, LF, "$"
s_fail_line: db "..FAIL", CR, LF, "$"
s_abc:       db "ABC$"
s_abcde:     db "ABCDE$"
s_xy:        db "XY$"
s_vis32:     db "VIS32", CR, LF, "$"
s_vis51:     db "VIS51", CR, LF, "$"
s_ok:        db "TERMTEST..OK", '$'

; 32 characters for the byte-aligned 8px font
s_pat32:     db "0123456789ABCDEFGHIJKLMNOPQRSTUV$"
; 51 characters for the 5px font (exactly fills the row)
s_pat51:     db "The quick brown fox jumps over the lazy dog 0123456$"

; 30 numbered lines for the 23-row scroll check
s_lines:
    db "00", CR, LF, "01", CR, LF, "02", CR, LF, "03", CR, LF
    db "04", CR, LF, "05", CR, LF, "06", CR, LF, "07", CR, LF
    db "08", CR, LF, "09", CR, LF, "10", CR, LF, "11", CR, LF
    db "12", CR, LF, "13", CR, LF, "14", CR, LF, "15", CR, LF
    db "16", CR, LF, "17", CR, LF, "18", CR, LF, "19", CR, LF
    db "20", CR, LF, "21", CR, LF, "22", CR, LF, "23", CR, LF
    db "24", CR, LF, "25", CR, LF, "26", CR, LF, "27", CR, LF
    db "28", CR, LF, "29", CR, LF, "$"
