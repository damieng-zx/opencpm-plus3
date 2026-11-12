; FONTTEST.COM - interactive proof sheet for the CP/M Plus character set
;
; The +3 CP/M 3 console has three screen fonts: FONT32 (8-pixel, 32
; columns), FONT51 (5-pixel, 51 columns) and FONT64 (4-pixel, 64 columns).
; This program draws the same set of themed pages in whichever mode is
; current, so the glyphs and the cell seams can be compared side by side.
;
; Pages:
;   0  about / key help
;   1  ASCII 20-7F            every printable ASCII code
;   2  line drawing 80-9F     single/double frames, T pieces, stubs
;   3  accents C0-FF          every accented letter plus real words
;   4  symbols A0-BF          currency, fractions, legal marks, bullets
;   5  maths DC-DF, FC-FF     the reachable maths symbols
;   6  controls 00-1F         the control codes and why their glyphs
;                             cannot be printed
;
; Keys: N/SPACE next, P previous, 1-6 jump, W cycle 32/51/64, R redraw,
;       Q/ESC quit.
;
; All three fonts (32, 51 and 64 columns) carry the full 256-code set, so
; every page draws the same glyphs in every width: ASCII 20-7F on page 1,
; all of 80-9F on page 2 (the frame and both junction tables included),
; A0-BF on page 4 and C0-FF on page 3.  Only the control codes 00-1F cannot
; be printed, because the console acts on them; page 6 lists them by name.
;
; Build: sjasmplus --raw=build/fonttest.com src/test/fonttest.asm

    org 0x0100

BDOS        equ 0x0005
F_CONOUT    equ 2
F_CONIO     equ 6
F_SCB       equ 49
F_BIOS      equ 50

ESC         equ 0x1B

; --------------------------------------------------------------------------
; start - set up the screen state, then enter the page loop
; --------------------------------------------------------------------------
start:
    call no_wrap
    call stl_off
    call read_width
    call set_layout
    xor a
    ld (page), a

.main:
    call draw_page
    call wait_key
    cp 'q'
    jp z, quit
    cp 'Q'
    jp z, quit
    cp ESC
    jp z, quit
    cp 'n'
    jr z, .next
    cp 'N'
    jr z, .next
    cp ' '
    jr z, .next
    cp 'p'
    jr z, .prev
    cp 'P'
    jr z, .prev
    cp 'w'
    jr z, .width
    cp 'W'
    jr z, .width
    cp 'r'
    jr z, .main
    cp 'R'
    jr z, .main
    cp '0'
    jr c, .main
    cp '6' + 1
    jr nc, .main
    sub '0'
    ld (page), a
    jr .main

.next:
    ld a, (page)
    inc a
    cp 7
    jr c, .store_page
    xor a
.store_page:
    ld (page), a
    jr .main

.prev:
    ld a, (page)
    or a
    jr nz, .prev_ok
    ld a, 7
.prev_ok:
    dec a
    ld (page), a
    jr .main

.width:
    call cycle_width
    jr .main

quit:
    call clear_screen
    call wrap_on
    rst 0

; --------------------------------------------------------------------------
; wait_key - block until a key is pressed, without echoing it
;   Out: A = character
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
wait_key:
    ld c, F_CONIO
    ld e, 0xFF
    call BDOS
    or a
    jr z, wait_key
    ret

; --------------------------------------------------------------------------
; read_width - read the current console width from SCB offset 0x1A
;   Out: cols = 32, 51 or 64 (80 and anything else lay out as 51)
;        actual_cols = what the BIOS reported
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
read_width:
    ld de, scb_pb
    ld c, F_SCB
    call BDOS
    inc a                       ; conwidth + 1 = columns
    ld (actual_cols), a
    cp 32
    jr z, .store
    cp 51
    jr z, .store
    cp 64
    jr z, .store
    ld a, 51                    ; 24x80 and unknown modes use 51 layout
.store:
    ld (cols), a
    ret

; --------------------------------------------------------------------------
; set_layout - derive the table geometry and the frame characters
;   Clobbers: AF, HL
; --------------------------------------------------------------------------
set_layout:
    ld a, (cols)
    cp 32
    jr z, .w32
    cp 64
    jr z, .w64

    ; 51 columns
    ld a, 9
    ld (cells), a
    ld a, 6
    ld (ctl_cells), a
    ld a, 3
    ld (grid_left), a
    ld a, 1
    ld (ctl_left), a
    ld hl, box_single
    ld (frame_set), hl
    ret

.w32:
    ld a, 6
    ld (cells), a
    ld a, 3
    ld (ctl_cells), a
    ld a, 1
    ld (grid_left), a
    ld a, 4
    ld (ctl_left), a
    ld hl, box_single
    ld (frame_set), hl
    ret

.w64:
    ld a, 12
    ld (cells), a
    ld a, 7
    ld (ctl_cells), a
    ld a, 2
    ld (grid_left), a
    ld a, 4
    ld (ctl_left), a
    ld hl, box_single
    ld (frame_set), hl
    ret

; --------------------------------------------------------------------------
; cycle_width - 32 -> 51 -> 64 -> 32, then redraw the same page
; --------------------------------------------------------------------------
cycle_width:
    ld a, (actual_cols)
    cp 32
    jr z, .to51
    cp 51
    jr z, .to64
    ld a, 32
    jr .set
.to51:
    ld a, 51
    jr .set
.to64:
    ld a, 64
.set:
    ld (bios_pb + 1), a
    ld de, bios_pb
    ld c, F_BIOS
    call BDOS
    call no_wrap
    call stl_off
    call read_width
    jp set_layout

; --------------------------------------------------------------------------
; draw_page - clear, frame, header, current page, help line
; --------------------------------------------------------------------------
draw_page:
    call clear_screen
    ld a, 3
    ld (line_row), a
    call draw_frame
    call print_header
    call dispatch_page
    jp print_help

dispatch_page:
    ; lint-exempt: stack  ; indirect jump through the page table
    ld a, (page)
    add a, a
    ld e, a
    ld d, 0
    ld hl, page_table
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    jp (hl)

; --------------------------------------------------------------------------
; print_header - page number and width, then the page theme
; --------------------------------------------------------------------------
print_header:
    ld b, 1
    ld c, 2
    call goto
    ld de, s_header
    call puts
    ld a, (page)
    call print_dec
    ld de, s_slash
    call puts
    ld a, (cols)
    call print_dec
    ld de, s_col
    call puts

    ld b, 2
    ld c, 2
    call goto
    ld a, (page)
    add a, a
    ld e, a
    ld d, 0
    ld hl, theme_table
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    jp puts

; --------------------------------------------------------------------------
; print_help - the key line above the bottom frame
; --------------------------------------------------------------------------
print_help:
    ld b, 22
    ld c, 2
    call goto
    ld a, (cols)
    cp 51
    jr c, .short
    ld de, s_help_long
    jp puts
.short:
    ld de, s_help_short
    jp puts

; --------------------------------------------------------------------------
; draw_frame - a box around the whole screen
;   The frame is the first alignment test: every horizontal run crosses
;   every cell seam and both vertical sides cross every row seam.
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
draw_frame:
    ld hl, (frame_set)
    ld (jset), hl

    ; top row
    ld b, 0
    ld c, 0
    call goto
    xor a
    call jchar
    call putc
    ld a, (cols)
    sub 2
    ld b, a
    call repeat_h
    ld a, 1
    call jchar
    call putc

    ; bottom row
    ld b, 23
    ld c, 0
    call goto
    ld a, 2
    call jchar
    call putc
    ld a, (cols)
    sub 2
    ld b, a
    call repeat_h
    ld a, 3
    call jchar
    call putc

    ; left and right sides, rows 1-22
    ld b, 1
.side:
    ld c, 0
    call goto
    ld a, 5
    call jchar
    call putc
    ld a, (cols)
    dec a
    ld c, a
    call goto
    ld a, 5
    call jchar
    call putc
    inc b
    ld a, b
    cp 23
    jr nz, .side
    ret

; --------------------------------------------------------------------------
; draw_jbox - a three-column, two-row junction table
;   It exercises the four corners, the four T pieces, the cross and both
;   the horizontal and vertical runs at every seam.
;   In:  B = top row, HL = 11-byte character set
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
draw_jbox:
    ld a, b
    ld (jrow), a
    ld (jset), hl

    ld a, (cols)
    sub 3
    ld (jright), a
    ld b, a
    ld a, 2
    ld (jleft), a
    ld a, b
    sub 2
    srl a
    add a, 2
    ld (jmid), a

    ; top: TL, run, TT, run, TR
    ld a, (jrow)
    ld b, a
    ld c, 2
    call goto
    xor a
    call jchar
    call putc
    ld a, (jmid)
    sub 3
    ld b, a
    call repeat_h
    ld a, 6
    call jchar
    call putc
    call .right_run
    ld a, 1
    call jchar
    call putc

    ; verticals
    ld a, (jrow)
    inc a
    ld b, a
    call jvert_row

    ; middle: LT, run, X, run, RT
    ld a, (jrow)
    add a, 2
    ld b, a
    ld c, 2
    call goto
    ld a, 8
    call jchar
    call putc
    ld a, (jmid)
    sub 3
    ld b, a
    call repeat_h
    ld a, 10
    call jchar
    call putc
    call .right_run
    ld a, 9
    call jchar
    call putc

    ; verticals
    ld a, (jrow)
    add a, 3
    ld b, a
    call jvert_row

    ; bottom: BL, run, BT, run, BR
    ld a, (jrow)
    add a, 4
    ld b, a
    ld c, 2
    call goto
    ld a, 2
    call jchar
    call putc
    ld a, (jmid)
    sub 3
    ld b, a
    call repeat_h
    ld a, 7
    call jchar
    call putc
    call .right_run
    ld a, 3
    call jchar
    jp putc

.right_run:
    ld a, (jright)
    ld b, a
    ld a, (jmid)
    ld c, a
    ld a, b
    sub c
    dec a
    ld b, a
    jp repeat_h

; --------------------------------------------------------------------------
; jvert_row - the three vertical pieces of one junction-table row
;   In:  B = row
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
jvert_row:
    ld c, 2
    call goto
    ld a, 5
    call jchar
    call putc
    ld a, (jmid)
    ld c, a
    call goto
    ld a, 5
    call jchar
    call putc
    ld a, (jright)
    ld c, a
    call goto
    ld a, 5
    call jchar
    jp putc

; --------------------------------------------------------------------------
; repeat_h - B copies of the set's horizontal piece
; --------------------------------------------------------------------------
repeat_h:
    ld a, b
    or a
    ret z
.loop:
    push bc
    ld a, 4
    call jchar
    call putc
    pop bc
    djnz .loop
    ret

; --------------------------------------------------------------------------
; jchar - character A from the current junction set
;   In:  A = index 0-10, jset = table
;   Out: A = character
;   Clobbers: AF, DE, HL
; --------------------------------------------------------------------------
jchar:
    push hl
    push de
    ld e, a
    ld d, 0
    ld hl, (jset)
    add hl, de
    ld a, (hl)
    pop de
    pop hl
    ret

; --------------------------------------------------------------------------
; print_line_table - print NUL-terminated lines until the table runs out
;                    or the content area is full
;   In:  HL = table of word pointers, B = count
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
print_line_table:
    ld a, (line_row)
    cp 22
    ret nc
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    push hl
    push bc
    call line
    pop bc
    pop hl
    djnz print_line_table
    ret

; --------------------------------------------------------------------------
; line - print one line at the current content row, column 2
;   In:  DE = NUL-terminated string
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
line:
    push de
    ld a, (line_row)
    ld b, a
    ld c, 2
    call goto
    pop de
    ld a, (cols)
    sub 3
    ld b, a
    call puts_n
    ld hl, line_row
    inc (hl)
    ret

; --------------------------------------------------------------------------
; print_grid_glyphs / print_grid_names - draw a tabled range of bytes
;   Entry: HL = bytes, B = count, C = cells per row
;   The caller's cell width is fixed at 5 (glyph) or 8 (control name).
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
print_grid_glyphs:
    ld a, (grid_left)
    ld (grid_x), a
    xor a
    ld (grid_mode), a
    jp print_grid

print_grid_names:
    ld a, (ctl_left)
    ld (grid_x), a
    ld a, 1
    ld (grid_mode), a
    jp print_grid

print_grid:
    ld (grid_ptr), hl
    ld a, b
    ld (grid_remain), a
    ld a, c
    ld (grid_cells), a
    ld a, (line_row)
    ld (grid_row), a
.row:
    ld a, (grid_remain)
    or a
    ret z
    ld a, (grid_row)
    ld b, a
    ld a, (grid_x)
    ld c, a
    call goto
    ld a, (grid_cells)
    ld (grid_inrow), a
.cell:
    ld hl, (grid_ptr)
    ld a, (hl)
    inc hl
    ld (grid_ptr), hl
    ld (grid_byte), a
    ld a, (grid_mode)
    or a
    jr nz, .name
    ld a, (grid_byte)
    call print_cell
    jr .next
.name:
    ld a, (grid_byte)
    call print_ctl_cell
.next:
    ld hl, grid_remain
    dec (hl)
    jr z, .done
    ld hl, grid_inrow
    dec (hl)
    jr nz, .cell
    ld hl, grid_row
    inc (hl)
    jr .row
.done:
    ld a, (grid_row)
    inc a
    ld (line_row), a
    ret

; --------------------------------------------------------------------------
; print_cell - "XX c " for one byte
;   In:  A = byte
;   Clobbers: AF, DE, HL
; --------------------------------------------------------------------------
print_cell:
    push af
    call print_hex
    ld a, ' '
    call putc
    pop af
    cp 0x20
    jr c, .dot
    call putc
    jr .pad
.dot:
    ld a, '.'
    call putc
.pad:
    ld a, ' '
    jp putc

; --------------------------------------------------------------------------
; print_ctl_cell - "XX NNN  " for one control code
;   In:  A = 0-31
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
print_ctl_cell:
    push af
    call print_hex
    ld a, ' '
    call putc
    pop af
    ld l, a
    ld h, 0
    add hl, hl                  ; 2A
    ld e, a
    ld d, 0
    add hl, de                  ; 3A
    ld de, ctl_names
    add hl, de
    ld b, 3
.loop:
    ld a, (hl)
    call putc
    inc hl
    djnz .loop
    ld a, ' '
    call putc
    ld a, ' '
    jp putc

; --------------------------------------------------------------------------
; fill_range / append_range - write a run of increasing byte values
;   In:  A = first value, B = count (append_range also takes HL = dest)
; --------------------------------------------------------------------------
fill_range:
    ld hl, chr_buf
append_range:
    ld (hl), a
    inc hl
    inc a
    djnz append_range
    ret

; ==========================================================================
; Page handlers
; ==========================================================================

; --------------------------------------------------------------------------
; 0 - about
; --------------------------------------------------------------------------
page_about:
    ld hl, lines_about
    ld b, 18
    jp print_line_table

; --------------------------------------------------------------------------
; 1 - ASCII 20-7F
; --------------------------------------------------------------------------
page_ascii:
    ld de, s_p1_1
    call line
    ld a, 0x20
    ld b, 96
    call fill_range
    ld hl, chr_buf
    ld b, 96
    ld a, (cells)
    ld c, a
    call print_grid_glyphs
    ld a, (cols)
    cp 32
    jr nz, .wide
    ld de, s_p1_note
    jp line
.wide:
    ld de, s_p1_pangram
    call line
    ld de, s_p1_pangram2
    jp line

; --------------------------------------------------------------------------
; 2 - line drawing 80-9F
; --------------------------------------------------------------------------
page_boxes:
    ld de, s_p2_1
    call line
    ld hl, (frame_set)
    ld a, (line_row)
    ld b, a
    call draw_jbox
    ld a, (line_row)
    add a, 5
    ld (line_row), a

    ld de, s_p2_2
    call line
    ld hl, box_double
    ld a, (line_row)
    ld b, a
    call draw_jbox
    ld a, (line_row)
    add a, 5
    ld (line_row), a

    ld de, s_p2_tpieces
    call line
    ld a, (line_row)
    ld b, a
    ld c, 2
    call goto
    ld hl, tpiece_bytes
    ld b, 4
.tpiece:
    push bc
    push hl
    ld a, (hl)
    call print_cell
    pop hl
    inc hl
    pop bc
    djnz .tpiece
    ld hl, line_row
    inc (hl)

    ld de, s_p2_stubs
    call line
    ld a, (line_row)
    ld b, a
    ld c, 2
    call goto
    ld hl, stub_bytes
    ld b, 6
.stub:
    ld a, (hl)
    call putc
    inc hl
    ld a, ' '
    call putc
    djnz .stub
    ld hl, line_row
    inc (hl)

    ld de, s_p2_codes
    call line
    ld de, s_p2_seams
    jp line

; --------------------------------------------------------------------------
; 3 - accents C0-FF
; --------------------------------------------------------------------------
page_accents:
    ld de, s_p3_1
    call line
    ld a, 0xC0
    ld b, 64
    call fill_range
    ld hl, chr_buf
    ld b, 64
    ld a, (cells)
    ld c, a
    call print_grid_glyphs
    ld hl, accent_lines
    ld b, 13
    jp print_line_table

; --------------------------------------------------------------------------
; 4 - symbols A0-BF
; --------------------------------------------------------------------------
page_symbols:
    ld de, s_p4_1
    call line
    ld hl, symbol_lines
    ld b, 14
    jp print_line_table

; --------------------------------------------------------------------------
; 5 - maths in context
; --------------------------------------------------------------------------
page_maths:
    ld de, s_p5_1
    call line
    ld hl, math_lines
    ld b, 13
    jp print_line_table

; --------------------------------------------------------------------------
; 6 - control codes 00-1F
; --------------------------------------------------------------------------
page_controls:
    ld de, s_p6_1
    call line
    xor a
    ld b, 32
    call fill_range
    ld hl, chr_buf
    ld b, 32
    ld a, (ctl_cells)
    ld c, a
    call print_grid_names
    ld hl, control_lines
    ld b, 7
    jp print_line_table

; ==========================================================================
; Console helpers
; ==========================================================================

; --------------------------------------------------------------------------
; putc - output A through BDOS function 2, preserving all registers
; --------------------------------------------------------------------------
putc:
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

; --------------------------------------------------------------------------
; puts - output a NUL-terminated string
;   In: DE = string
; --------------------------------------------------------------------------
puts:
    ld a, (de)
    or a
    ret z
    call putc
    inc de
    jr puts

; --------------------------------------------------------------------------
; puts_n - output at most B characters of a NUL-terminated string
;   In: DE = string, B = maximum
; --------------------------------------------------------------------------
puts_n:
    ld a, (de)
    or a
    ret z
    ld a, b
    or a
    ret z
    ld a, (de)
    call putc
    inc de
    dec b
    jr puts_n

; --------------------------------------------------------------------------
; goto - position the cursor with ESC Y (row+32, col+32)
;   In: B = row 0-23, C = column
; --------------------------------------------------------------------------
goto:
    push bc
    ld a, ESC
    call putc
    ld a, 'Y'
    call putc
    pop bc
    push bc
    ld a, b
    add a, 32
    call putc
    pop bc
    ld a, c
    add a, 32
    jp putc

; --------------------------------------------------------------------------
; print_hex - two uppercase hex digits for A
; --------------------------------------------------------------------------
print_hex:
    push af
    rrca
    rrca
    rrca
    rrca
    call print_nibble
    pop af
print_nibble:
    and 0x0F
    add a, '0'
    cp '9' + 1
    jr c, .out
    add a, 7
.out:
    jp putc

; --------------------------------------------------------------------------
; print_dec - decimal 0-99 for A
; --------------------------------------------------------------------------
print_dec:
    ld b, 0
.loop:
    cp 10
    jr c, .units
    sub 10
    inc b
    jr .loop
.units:
    ld c, a
    ld a, b
    or a
    jr z, .last
    add a, '0'
    call putc
.last:
    ld a, c
    add a, '0'
    jp putc

; --------------------------------------------------------------------------
; clear_screen - ANSI ED2 + home
; --------------------------------------------------------------------------
clear_screen:
    ld de, s_clear
    jp puts

; --------------------------------------------------------------------------
; no_wrap / wrap_on / stl_off - terminal state
; --------------------------------------------------------------------------
no_wrap:
    ld a, ESC
    call putc
    ld a, 'w'
    jp putc
wrap_on:
    ld a, ESC
    call putc
    ld a, 'v'
    jp putc
stl_off:
    ld a, ESC
    call putc
    ld a, '0'
    jp putc

; ==========================================================================
; Data
; ==========================================================================

page_table:
    dw page_about, page_ascii, page_boxes, page_accents
    dw page_symbols, page_maths, page_controls

theme_table:
    dw th_about, th_ascii, th_boxes, th_accents
    dw th_symbols, th_maths, th_controls

lines_about:
    dw s_p0_1, s_p0_2, s_p0_3, s_blank
    dw s_p0_4, s_p0_5, s_p0_6, s_p0_7, s_p0_8, s_p0_9
    dw s_blank, s_p0_10
    dw s_p0_11, s_p0_12, s_p0_13, s_p0_14, s_p0_15, s_p0_16

accent_lines:
    dw s_p3_w1, s_p3_w2, s_p3_w3, s_p3_w11, s_p3_w4, s_p3_w5
    dw s_p3_w6, s_p3_w7, s_p3_w8, s_p3_w9, s_p3_w10, s_p3_w12
    dw s_p3_w13

symbol_lines:
    dw s_p4_l1, s_p4_l2, s_p4_l3, s_p4_l4, s_p4_l5
    dw s_p4_l6, s_p4_l7, s_p4_l8, s_p4_l9, s_p4_l10
    dw s_p4_l11, s_p4_l12, s_p4_l13, s_p4_l14

math_lines:
    dw s_p5_l1, s_p5_l2, s_p5_l3, s_p5_l4, s_p5_l5
    dw s_p5_l6, s_p5_l7, s_p5_l8, s_p5_l9, s_p5_l10
    dw s_p5_l11, s_p5_l12, s_p5_l13

control_lines:
    dw s_p6_l1, s_p6_l2, s_p6_l3, s_p6_l4
    dw s_p6_l5, s_p6_l6, s_p6_l7

; Junction sets: TL, TR, BL, BR, H, V, TT, BT, LT, RT, X
box_single:
    db 0x96, 0x9C, 0x93, 0x99, 0x9A, 0x95
    db 0x9E, 0x9B, 0x97, 0x9D, 0x9F
box_double:
    db 0x86, 0x8C, 0x83, 0x89, 0x8A, 0x85
    db 0x8E, 0x8B, 0x87, 0x8D, 0x8F

tpiece_bytes:
    db 0x81, 0x82, 0x84, 0x88
stub_bytes:
    db 0x91, 0x92, 0x94, 0x98, 0x90, 0x80

ctl_names:
    db 'NUL','SOH','STX','ETX','EOT','ENQ','ACK','BEL'
    db 'BS ','TAB','LF ','VT ','FF ','CR ','SO ','SI '
    db 'DLE','DC1','DC2','DC3','DC4','NAK','SYN','ETB'
    db 'CAN','EM ','SUB','ESC','FS ','GS ','RS ','US '

th_about:    db 'About FONTTEST', 0
th_ascii:    db 'Printable ASCII', 0
th_boxes:    db 'Line drawing 80-9F', 0
th_accents:  db 'Accented words', 0
th_symbols:  db 'Symbols in use', 0
th_maths:    db 'Maths in use', 0
th_controls: db 'Controls & limits', 0

s_clear:       db ESC, '[2J', ESC, '[H', 0

; --------------------------------------------------------------------------
; Text (generated from the Amstrad CP/M Plus Language 0 code page)
;
; The db bytes are code-page values, not UTF-8.  To change a word, edit the
; hex pairs (and the comment beside them); typing an accented character
; directly into a db string would store its UTF-8 encoding instead.
; --------------------------------------------------------------------------
s_p0_1:
    db 'CP/M Plus character set test',0  ; CP/M Plus character set test
s_p0_2:
    db 'Fonts: 8px, 5px and 4px wide',0  ; Fonts: 8px, 5px and 4px wide
s_p0_3:
    db '0: about this program',0  ; 0: about this program
s_blank:
    db 0  ; (blank)
s_p0_4:
    db 'N/SPACE  next page',0  ; N/SPACE  next page
s_p0_5:
    db 'P        previous page',0  ; P        previous page
s_p0_6:
    db '1-6      jump to page',0  ; 1-6      jump to page
s_p0_7:
    db 'W        cycle 32/51/64',0  ; W        cycle 32/51/64
s_p0_8:
    db 'R        redraw',0  ; R        redraw
s_p0_9:
    db 'Q/ESC    quit',0  ; Q/ESC    quit
s_p0_10:
    db 'Pages:',0  ; Pages:
s_p0_11:
    db '1  ASCII 20-7F',0  ; 1  ASCII 20-7F
s_p0_12:
    db '2  line drawing 80-9F',0  ; 2  line drawing 80-9F
s_p0_13:
    db '3  accents C0-FF',0  ; 3  accents C0-FF
s_p0_14:
    db '4  symbols in use',0  ; 4  symbols in use
s_p0_15:
    db '5  maths in equations',0  ; 5  maths in equations
s_p0_16:
    db '6  controls 00-1F',0  ; 6  controls 00-1F
s_p1_1:
    db 'ASCII 0x20-0x7F (96 codes)',0  ; ASCII 0x20-0x7F (96 codes)
s_p1_note:
    db 'Hex code and glyph per cell.',0  ; Hex code and glyph per cell.
s_p1_pangram:
    db 'The quick brown fox jumps over the lazy dog.',0  ; The quick brown fox jumps over the lazy dog.
s_p1_pangram2:
    db 'Pack my box with five dozen liquor jugs.',0  ; Pack my box with five dozen liquor jugs.
s_p2_1:
    db 'Single-line box junctions:',0  ; Single-line box junctions:
s_p2_2:
    db 'Double-line box junctions:',0  ; Double-line box junctions:
s_p2_tpieces:
    db 'T pieces:',0  ; T pieces:
s_p2_stubs:
    db 'Stubs and centre dot:',0  ; Stubs and centre dot:
s_p2_codes:
    db 'All 32 codes 80-9F are here',0  ; All 32 codes 80-9F are here
s_p2_seams:
    db 'Check every cell seam.',0  ; Check every cell seam.
s_p3_1:
    db 'Accented letters C0-FF',0  ; Accented letters C0-FF
s_p3_w1:
    db 'FR: ',0xE6,'tre, o',0xEE,', d',0xE1,'j',0xEA,', ',0xE1,'l',0xEB,'ve',0  ; FR: être, où, déjà, élève
s_p3_w2:
    db 'ES: ma',0xF9,'ana, d',0xE2,'a, men',0xE4,0  ; ES: mañana, día, menú
s_p3_w3:
    db 'DE: sch',0xF3,'n, Gr',0xF3,0xBA,'e, ',0xF4,'ber',0  ; DE: schön, Größe, über
s_p3_w4:
    db 'SV: bl',0xF7,'b',0xF0,'r, ',0xD7,'land, ',0xF3,'l',0  ; SV: blåbär, Åland, öl
s_p3_w5:
    db 'DK: r',0xF8,'dgr',0xF8,'d, ',0xF6,'ble, ',0xF8,'l',0  ; DK: rødgrød, æble, øl
s_p3_w6:
    db 'IT: perch',0xE1,', citt',0xEA,', pi',0xEE,0  ; IT: perché, città, più
s_p3_w7:
    db 'PT: cora',0xF5,0xFA,'o, n',0xFA,'o, lim',0xFB,'es',0  ; PT: coração, não, limões
s_p3_w8:
    db 'FR: gar',0xF5,'on, h',0xE8,'tel, No',0xF1,'l',0  ; FR: garçon, hôtel, Noël
s_p3_w9:
    db 'FR: ch',0xE5,'teau, d',0xE7,'ner, s',0xE9,'r',0  ; FR: château, dîner, sûr
s_p3_w10:
    db 'FR: A',0xEF,', na',0xF2,'ve, ma',0xF2,'s',0  ; FR: Aÿ, naïve, maïs
s_p3_w11:
    db 'ES: ',0xAE,'qu',0xE1,'? ',0xAF,'s',0xE2,'! ni',0xF9,'o',0  ; ES: ¿qué? ¡sí! niño
s_p3_w12:
    db 'DE: M',0xF0,'dchen, sp',0xF0,'t',0  ; DE: Mädchen, spät
s_p3_w13:
    db 'PT: irm',0xFA,'os, a',0xF5,0xFA,'o',0  ; PT: irmãos, ação
s_p4_1:
    db 'Every symbol in context',0  ; Every symbol in context
s_p4_l1:
    db 'Money: ',0xA3,'12.99  ',0xB1,'50  ',0xBD,'500',0  ; Money: £12.99  ¢50  ¥500
s_p4_l2:
    db 'Peseta: ',0xAD,'1.500  Florin: ',0xB0,'10',0  ; Peseta: ₧1.500  Florin: ƒ10
s_p4_l3:
    db 'Degrees: 20',0xA2,'C  98.6',0xA2,'F',0  ; Degrees: 20°C  98.6°F
s_p4_l4:
    db 'Fractions: ',0xA8,' ',0xA9,' ',0xAA,' ',0xB6,' ',0xB7,' ',0xB8,' ',0xB9,0  ; Fractions: ¼ ½ ¾ ⅛ ⅜ ⅝ ⅞
s_p4_l5:
    db 'Recipe: 1',0xA9,' cups, ',0xB7,' tsp, ',0xB9,' lb',0  ; Recipe: 1½ cups, ⅜ tsp, ⅞ lb
s_p4_l6:
    db 'Legal: ',0xA4,' 2026 Acme',0xBE,' Widget',0xBF,0  ; Legal: © 2026 Acme® Widget™
s_p4_l7:
    db 'Clauses: ',0xA6,'4.2 and ',0xA5,'3 apply',0xA7,0  ; Clauses: §4.2 and ¶3 apply†
s_p4_l8:
    db 'Ordinals: 1',0xA1,' 2',0xA1,' 3',0xA1,'  1',0xA0,' 2',0xA0,' 3',0xA0,0  ; Ordinals: 1º 2º 3º  1ª 2ª 3ª
s_p4_l9:
    db 'Quotes: ',0xAB,'oui',0xAC,' ',0xAB,'s',0xE2,0xAC,' ',0xAB,'ja',0xAC,0  ; Quotes: «oui» «sí» «ja»
s_p4_l10:
    db 'Spanish: ',0xAE,'Qu',0xE1,'? ',0xAF,'S',0xE2,'!',0  ; Spanish: ¿Qué? ¡Sí!
s_p4_l11:
    db 'German: Stra',0xBA,'e, gro',0xBA,', Ma',0xBA,0  ; German: Straße, groß, Maß
s_p4_l12:
    db 'Bullets: ',0xBC,' one ',0xBB,' two ',0xBC,' three',0  ; Bullets: • one ○ two • three
s_p4_l13:
    db 'Spacing accents: ',0xB2,' ',0xB3,' ',0xB4,0  ; Spacing accents: ¨ ´ ˆ
s_p4_l14:
    db 'Per mille: 50',0xB5,' rise',0  ; Per mille: 50‰ rise
s_p5_1:
    db 'Maths in equations',0  ; Maths in equations
s_p5_l1:
    db '3x ',0xDC,' 12  ',0xFC,'  x ',0xDC,' 4',0  ; 3x ≥ 12  ⇒  x ≥ 4
s_p5_l2:
    db '0 ',0xDD,' x ',0xDD,' 10,  x ',0xDE,' 5',0  ; 0 ≤ x ≤ 10,  x ≠ 5
s_p5_l3:
    db 'a ',0xDD,' b, b ',0xDD,' c ',0xFC,' a ',0xDD,' c',0  ; a ≤ b, b ≤ c ⇒ a ≤ c
s_p5_l4:
    db 'a ',0xDF,' 3.14159',0  ; a ≃ 3.14159
s_p5_l5:
    db 'x + 1 ',0xFF,' 3 (mod 2)',0  ; x + 1 ≡ 3 (mod 2)
s_p5_l6:
    db 'p ',0xFC,' q     q ',0xFD,' p',0  ; p ⇒ q     q ⇐ p
s_p5_l7:
    db 'p ',0xFE,' q   (p iff q)',0  ; p ⇔ q   (p iff q)
s_p5_l8:
    db 'not p ',0xFC,' not q',0  ; not p ⇒ not q
s_p5_l9:
    db 0xA9,' of ',0xAA,' = ',0xB7,0  ; ½ of ¾ = ⅜
s_p5_l10:
    db '1',0xA8,' + 1',0xA9,' = 2',0xAA,0  ; 1¼ + 1½ = 2¾
s_p5_l11:
    db 0xDF,' approx   ',0xFF,' identical',0  ; ≃ approx   ≡ identical
s_p5_l12:
    db 'Times, div, pm at 05 06 0D',0  ; Times, div, pm at 05 06 0D
s_p5_l13:
    db 'Greek glyphs are 00-1F',0  ; Greek glyphs are 00-1F
s_p6_1:
    db 'Control codes 00-1F',0  ; Control codes 00-1F
s_p6_l1:
    db 'BEL BS TAB LF CR ESC act.',0  ; BEL BS TAB LF CR ESC act.
s_p6_l2:
    db 'Other codes are ignored, so',0  ; Other codes are ignored, so
s_p6_l3:
    db 'their Greek/maths glyphs can',0  ; their Greek/maths glyphs can
s_p6_l4:
    db 'not be printed.',0  ; not be printed.
s_p6_l5:
    db 'x=05 /=06 +/-=0D controls.',0  ; x=05 /=06 +/-=0D controls.
s_p6_l6:
    db '0x7F is the second zero.',0  ; 0x7F is the second zero.
s_p6_l7:
    db '80 square, 90 centre dot.',0  ; 80 square, 90 centre dot.
s_header:
    db 'FONTTEST ',0  ; FONTTEST 
s_slash:
    db '/6  ',0  ; /6  
s_col:
    db ' COL',0  ;  COL
s_help_short:
    db 'N/P page  W width  Q quit',0  ; N/P page  W width  Q quit
s_help_long:
    db 'N/P page  1-6 jump  W width  Q quit',0  ; N/P page  1-6 jump  W width  Q quit

; --------------------------------------------------------------------------
; Variables
; --------------------------------------------------------------------------
page:        db 0
cols:        db 51
actual_cols: db 51
cells:       db 9
ctl_cells:   db 6
grid_left:   db 3
ctl_left:    db 1
line_row:    db 3
frame_set:   dw box_single

jset:        dw box_single
jrow:        db 0
jleft:       db 0
jmid:        db 0
jright:      db 0

grid_ptr:    dw 0
grid_remain: db 0
grid_cells:  db 0
grid_row:    db 0
grid_inrow:  db 0
grid_x:      db 0
grid_mode:   db 0
grid_byte:   db 0

scb_pb:      db 0x1A, 0, 0, 0
bios_pb:     db 32, 0, 0, 0, 0, 0, 0, 0

chr_buf:     ds 96
