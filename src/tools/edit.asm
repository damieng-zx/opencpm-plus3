; EDIT.COM - full-screen text editor for CP/M 3 on the ZX Spectrum +3
;
; 23 text rows plus one inverted status row.  EXTEND (Caps+Symbol) is the
; command prefix:
;   O open   S save   N new    Q quit   F find   R replace
;   V spaces W wrap   I ins    Z undo   D delete L redraw  H help
; Holding EXTEND alone for about a second opens the help panel.
;
; Keys are read as raw tokens with KM_KT_GET (XBIOS 0xDA), so EXTEND+letter
; and the physical cursor keys (Caps+5/6/7/8) stay distinguishable.
;
; Build: sjasmplus --raw=build/edit.com src/tools/edit.asm

    org 0x0100

BDOS        equ 0x0005
F_CONOUT    equ 2
F_OPEN      equ 15
F_CLOSE     equ 16
F_DELETE    equ 19
F_READ      equ 20
F_WRITE     equ 21
F_MAKE      equ 22
F_RENAME    equ 23
F_CURDSK    equ 25
F_SETDMA    equ 26
F_SCB       equ 49

ESC         equ 0x1B
CR          equ 0x0D
LF          equ 0x0A
TAB         equ 0x09
EOF_Z       equ 0x1A

BUF_START   equ 0x3000
BUF_END     equ 0xF000
ISR_TICK    equ 0xF774          ; common-memory 50 Hz frame counter

TEXT_ROWS   equ 23
STATUS_ROW  equ 23

UNDO_NONE   equ 0
UNDO_INS    equ 1
UNDO_DEL    equ 2
UNDO_NL     equ 3
UNDO_REPL   equ 4
UNDO_DNL    equ 5

; ==========================================================================
; Start
; ==========================================================================
start:
    ; USERF entry: BIOS base + 30*3.
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    ld de, 30 * 3
    add hl, de
    ld (userf_trampoline + 1), hl

    ; Status line off, autowrap off.
    ld a, ESC
    call putc
    ld a, '0'
    call putc
    ld a, ESC
    call putc
    ld a, 'w'
    call putc

    call read_width
    call clear_buffer

    ; Take the CCP's default FCB if it holds a name.
    ld hl, 0x005C
    ld de, file_fcb
    ld bc, 36
    ldir
    ld a, (file_fcb + 1)
    cp ' '
    jr z, .noname
    or a
    jr z, .noname
    ld a, 1
    ld (have_name), a
    call build_file_disp
    ld hl, file_fcb
    ld de, work_fcb
    ld bc, 36
    ldir
    ld a, 1
    ld (allow_new), a
    call open_work_fcb
    jr .ready
.noname:
    call clear_buffer
.ready:
    call draw_all
    jp main_loop

; ==========================================================================
; Main loop
; ==========================================================================
main_loop:
    call get_key
    or a
    jr z, main_loop
    call insert_char
    call after_edit
    jr main_loop

; ==========================================================================
; Key input
; ==========================================================================
get_key:
.loop:
    ld hl, 0x00DA
    ld (userf_dw), hl
    call userf_trampoline
    jr c, .token
    call poll_extend_hold
    jr .loop
.token:
    ld a, b
    and 3
    ld (key_shift), a
    ld a, c
    ld (key_raw), a
    call clear_message
    jp process_key
    ret

; get_raw - non-blocking raw key token.  Carry set + key_shift/key_raw.
get_raw:
    ld hl, 0x00DA
    ld (userf_dw), hl
    call userf_trampoline
    jr c, .got
    ret
.got:
    ld a, b
    and 3
    ld (key_shift), a
    ld a, c
    ld (key_raw), a
    scf
    ret

; process_key - A = character to insert, or 0 if handled here
process_key:
    ld a, (key_shift)
    cp 3
    jp z, process_extend
    cp 1
    jp z, process_caps
    ; normal or symbol shift
    ld e, a
    ld a, (key_raw)
    call map_key
    or a
    ret z
    cp CR
    jr z, .enter
    cp TAB
    ret z
    cp 0x20
    jr c, .none
    cp 0x7F
    jr nc, .none
    ret
.enter:
    call do_newline
    call after_edit
    xor a
    ret
.none:
    xor a
    ret

process_caps:
    ld a, (key_raw)
    cp 19
    jr z, .left
    cp 24
    jr z, .down
    cp 23
    jr z, .up
    cp 22
    jr z, .right
    cp 20
    jr z, .back
    cp 18
    jr z, .tab
    cp 35
    jr z, .none
    cp 30
    jr z, .enter
    ; Caps+letter etc.
    ld e, 1
    ld a, (key_raw)
    call map_key
    or a
    ret z
    cp 0x20
    jr c, .none
    cp 0x7F
    jr nc, .none
    ret
.left:
    call move_left
    call after_move
    xor a
    ret
.right:
    call move_right
    call after_move
    xor a
    ret
.up:
    call move_up
    call after_move
    xor a
    ret
.down:
    call move_down
    call after_move
    xor a
    ret
.back:
    call do_backspace
    call after_edit
    xor a
    ret
.tab:
    ld a, TAB
    ret
.enter:
    call do_newline
    call after_edit
    xor a
    ret
.none:
    xor a
    ret

process_extend:
    ld a, (key_raw)
    call extend_command
    or a
    jr nz, .cmd
    ; EXTEND+A/G/U/Y produce symbols; everything else is ignored.
    ld a, (key_raw)
    cp 5
    jr c, .none
    cp 10
    jr c, .symbol
    cp 28
    jr c, .none
    cp 30
    jr nc, .none
.symbol:
    call wait_extend_release
    ld a, (key_raw)
    cp 5
    jr c, .none
    cp 10
    jr c, .sym_ok
    cp 28
    jr c, .none
    cp 30
    jr nc, .none
.sym_ok:
    ld e, 3
    ld a, (key_raw)
    call map_key
    or a
    ret z
    cp 0x20
    ret c
    cp 0x7F
    jr nc, .none
    ret
.cmd:
    push af
    call wait_extend_release
    pop af
    call do_command
    xor a
    ret
.none:
    xor a
    ret

extend_command:
    cp 40
    ret nc
    ld hl, extend_table
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    ret

do_command:
    cp 1
    jp z, cmd_open
    cp 2
    jp z, cmd_save
    cp 3
    jp z, cmd_new
    cp 4
    jp z, cmd_quit
    cp 5
    jp z, cmd_find
    cp 6
    jp z, cmd_replace
    cp 7
    jp z, cmd_whitespace
    cp 8
    jp z, cmd_wrap
    cp 9
    jp z, cmd_ins
    cp 10
    jp z, cmd_redraw
    cp 11
    jp z, cmd_help
    cp 12
    jp z, cmd_undo
    cp 13
    jp z, cmd_delete
    ret

; ==========================================================================
; Commands
; ==========================================================================
cmd_ins:
    ld a, (mode_ins)
    xor 1
    ld (mode_ins), a
    jp draw_status
    ret

cmd_whitespace:
    ld a, (show_ws)
    xor 1
    ld (show_ws), a
    jp draw_all
    ret

cmd_wrap:
    ld a, (wrap_mode)
    xor 1
    ld (wrap_mode), a
    or a
    jr z, .off
    xor a
    ld (left_col), a
    ld (left_col + 1), a
    jr .redraw
.off:
    xor a
    ld (top_seg), a
.redraw:
    call ensure_visible
    ld a, 1
    ld (structural), a
    call draw_all
    xor a
    ld (structural), a
    ret

cmd_redraw:
    jp draw_all
    ret

cmd_help:
    jp show_help
    ret

cmd_delete:
    call do_delete
    jp after_edit
    ret

cmd_undo:
    call do_undo
    jp after_edit
    ret

cmd_open:
    call confirm_save
    ret nc
    ld hl, msg_open
    ld (prompt_ptr), hl
    xor a
    ld (prompt_alt), a
    ld (prompt_alt + 1), a
    ld hl, name_buf
    ld (prompt_buf_ptr), hl
    ld a, 80
    ld (prompt_max), a
    call prompt_string
    ret nc
    ld hl, name_buf
    call parse_filename
    ret nc
    xor a
    ld (allow_new), a
    call open_work_fcb
    ret nc
    jp draw_all
    ret

cmd_save:
    jp save_file
    ret

cmd_new:
    call confirm_save
    ret nc
    call clear_buffer
    jp draw_all
    ret

cmd_quit:
    call confirm_save
    ret nc
    call restore_terminal
    jp 0

; ==========================================================================
; Buffer: gap buffer at BUF_START..BUF_END
; ==========================================================================
clear_buffer:
    call reset_buffer_only
    xor a
    ld (have_name), a
    ld (modified), a
    ld (eof_z), a
    ld (undo_type), a
    ld (structural), a
    ld hl, str_noname
    ld de, file_disp
    jp strcpy
    ret

reset_buffer_only:
    ld hl, BUF_START
    ld (gap_start), hl
    ld hl, BUF_END
    ld (gap_end), hl
    xor a
    ld (top_pos), a
    ld (top_pos + 1), a
    ld (draw_pos), a
    ld (draw_pos + 1), a
    ld (len), a
    ld (len + 1), a
    ld (cur_pos), a
    ld (cur_pos + 1), a
    ld (cur_line), a
    ld (cur_line + 1), a
    ld (line_start), a
    ld (line_start + 1), a
    ld (cur_col), a
    ld (cur_col + 1), a
    ld (top_line), a
    ld (top_line + 1), a
    ld (left_col), a
    ld (left_col + 1), a
    ld (top_seg), a
    ld (modified), a
    ld (eof_z), a
    ld (undo_type), a
    ld (structural), a
    ret

; addr_from_pos - HL = logical pos -> HL = memory address
addr_from_pos:
    push hl
    ld hl, (gap_start)
    ld de, BUF_START
    or a
    sbc hl, de                  ; gap logical position
    pop de                      ; DE = pos
    push hl
    ex de, hl
    call cmp16
    ex de, hl
    pop hl
    jr c, .before
    ex de, hl
    xor a
    sbc hl, de
    ld de, (gap_end)
    add hl, de
    ret
.before:
    ex de, hl
    ld de, BUF_START
    add hl, de
    ret

; move_gap - move gap to logical position HL
move_gap:
    ld (move_target), hl
.loop:
    ld hl, (gap_start)
    ld de, BUF_START
    or a
    sbc hl, de
    ld de, (move_target)
    call cmp16
    jr z, .done
    jr c, .forward
    ; gap > target: move one byte left
    ld hl, (gap_start)
    dec hl
    ld de, (gap_end)
    dec de
    ld a, (hl)
    ld (de), a
    ld (gap_start), hl
    ld (gap_end), de
    jr .loop
.forward:
    ; gap < target: move one byte right
    ld hl, (gap_end)
    ld de, (gap_start)
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    ld (gap_start), de
    ld (gap_end), hl
    jr .loop
.done:
    ret

; peek - HL = pos (pos < len), A = byte.  HL preserved.
peek:
    push hl
    call addr_from_pos
    ld a, (hl)
    pop hl
    ret

; append_byte - A = byte, append at gap_start.  Carry set if full.
append_byte:
    push af
    ld hl, (gap_start)
    ld de, (gap_end)
    or a
    sbc hl, de
    jr z, .full
    ld hl, (gap_start)
    pop af
    ld (hl), a
    inc hl
    ld (gap_start), hl
    ld hl, (len)
    inc hl
    ld (len), hl
    or a
    ret
.full:
    pop af
    scf
    ret

; buffer_insert - A = byte at cur_pos.  Carry set if full.
buffer_insert:
    ld (edit_char), a
    ld hl, (cur_pos)
    call move_gap
    ld hl, (gap_start)
    ld de, (gap_end)
    or a
    sbc hl, de
    jr z, .full
    ld a, (edit_char)
    ld hl, (gap_start)
    ld (hl), a
    inc hl
    ld (gap_start), hl
    ld hl, (len)
    inc hl
    ld (len), hl
    or a
    ret
.full:
    scf
    ret

; buffer_delete - delete byte at cur_pos.  A = byte, carry set if none.
buffer_delete:
    ld hl, (cur_pos)
    ld de, (len)
    ex de, hl
    call cmp16
    ex de, hl
    jr c, .none
    jr z, .none
    ld hl, (cur_pos)
    call move_gap
    ld hl, (gap_end)
    ld a, (hl)
    inc hl
    ld (gap_end), hl
    ld hl, (len)
    dec hl
    ld (len), hl
    or a
    ret
.none:
    xor a
    scf
    ret

; ==========================================================================
; Editing
; ==========================================================================
insert_char:
    ld (edit_char), a
    ld a, (mode_ins)
    or a
    jr nz, .insert
    ; overwrite: at end of line, insert instead
    ld hl, (cur_pos)
    ld de, (len)
    call cmp16
    jr nc, .insert
    ld hl, (cur_pos)
    call peek
    cp CR
    jr z, .insert
    cp LF
    jr z, .insert
    ; replace the character at the cursor
    ld a, UNDO_REPL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    ld a, (edit_char)
    ld (undo_char), a
    call peek
    ld (undo_old), a
    ld hl, (cur_pos)
    call buffer_delete
    ld a, (edit_char)
    call buffer_insert
    jr c, .full
    ld a, (edit_char)
    cp TAB
    jr z, .tab
    call inc_col
    jr .done
.tab:
    call tab_col
.done:
    ld a, 1
    ld (modified), a
    ret
.insert:
    ld a, UNDO_INS
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    ld a, (edit_char)
    ld (undo_char), a
    call buffer_insert
    jr c, .full
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld a, (edit_char)
    cp TAB
    jr z, .tab2
    call inc_col
    jr .done2
.tab2:
    call tab_col
.done2:
    ld a, 1
    ld (modified), a
    ret
.full:
    xor a
    ld (undo_type), a
    ld de, msg_full
    jp show_error
    ret

do_newline:
    ld a, UNDO_NL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    ld a, CR
    call buffer_insert
    jr c, .full
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld a, LF
    call buffer_insert
    jr c, .full
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld (line_start), hl
    ld hl, (cur_line)
    inc hl
    ld (cur_line), hl
    xor a
    ld (cur_col), a
    ld (cur_col + 1), a
    ld a, 1
    ld (modified), a
    ld (structural), a
    ret
.full:
    xor a
    ld (undo_type), a
    ld de, msg_full
    jp show_error
    ret

do_backspace:
    ld hl, (cur_pos)
    ld a, h
    or l
    ret z
    ; look at the byte before the cursor
    ld hl, (cur_pos)
    dec hl
    ld (del_pos), hl
    call peek
    cp LF
    jr z, .maybe_crlf
    cp CR
    jr z, .break_join
    ; normal character
    ld hl, (del_pos)
    ld (cur_pos), hl
    ld a, UNDO_DEL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    call buffer_delete
    ld (undo_char), a
    cp TAB
    jr z, .recompute
    ld hl, (cur_col)
    dec hl
    ld (cur_col), hl
    jr .done
.recompute:
    call recompute_col
.done:
    ld a, 1
    ld (modified), a
    ret
.maybe_crlf:
    ld hl, (del_pos)
    ld a, h
    or l
    jr z, .break_join
    dec hl
    call peek
    cp CR
    jr nz, .break_join
    ; CR LF join: cur_pos points at the CR
    ld hl, (del_pos)
    dec hl
    ld (cur_pos), hl
    jr .join
.break_join:
    ld hl, (del_pos)
    ld (cur_pos), hl
.join:
    ld hl, (line_start)
    ld (join_old_start), hl
    ; record the break bytes
    ld hl, (cur_pos)
    call peek
    ld (undo_char), a
    xor a
    ld (undo_old), a
    ld a, (undo_char)
    cp CR
    jr nz, .one_break
    ; CR: check for LF
    ld hl, (cur_pos)
    inc hl
    ld de, (len)
    call cmp16
    jr nc, .one_break
    call peek
    cp LF
    jr nz, .one_break
    ld a, 1
    ld (undo_old), a
    ld a, UNDO_DNL
    ld (undo_type), a
    ld hl, (cur_pos)
    call buffer_delete
    call buffer_delete
    jr .joined
.one_break:
    ld a, UNDO_DNL
    ld (undo_type), a
    ld hl, (cur_pos)
    call buffer_delete
.joined:
    ld hl, (join_old_start)
    call prev_line_start
    ld (line_start), hl
    ld hl, (cur_line)
    dec hl
    ld (cur_line), hl
    call recompute_col
    ld a, 1
    ld (modified), a
    ld a, 1
    ld (structural), a
    ret

do_delete:
    ld hl, (cur_pos)
    ld de, (len)
    call cmp16
    jp nc, .none
    ld hl, (cur_pos)
    call peek
    cp CR
    jr z, .maybe_crlf
    cp LF
    jr z, .one_break
    ; normal character
    ld a, UNDO_DEL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    call buffer_delete
    ld (undo_char), a
    ld a, 1
    ld (modified), a
    ret
.maybe_crlf:
    ld hl, (cur_pos)
    inc hl
    ld de, (len)
    call cmp16
    jr nc, .one_break
    call peek
    cp LF
    jr nz, .one_break
    ld a, UNDO_DNL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    ld a, CR
    ld (undo_char), a
    ld a, 1
    ld (undo_old), a
    ld hl, (cur_pos)
    call buffer_delete
    call buffer_delete
    jr .joined
.one_break:
    ld a, UNDO_DNL
    ld (undo_type), a
    ld hl, (cur_pos)
    ld (undo_pos), hl
    call peek
    ld (undo_char), a
    xor a
    ld (undo_old), a
    ld hl, (cur_pos)
    call buffer_delete
.joined:
    ld a, 1
    ld (modified), a
    ld a, 1
    ld (structural), a
    ret
.none:
    ret

do_undo:
    ld a, (undo_type)
    or a
    ret z
    cp UNDO_INS
    jr z, .ins
    cp UNDO_DEL
    jr z, .del
    cp UNDO_NL
    jr z, .nl
    cp UNDO_REPL
    jr z, .repl
    cp UNDO_DNL
    jr z, .dnl
    ret
.ins:
    ld hl, (undo_pos)
    ld (cur_pos), hl
    call buffer_delete
    jr .done
.del:
    ld hl, (undo_pos)
    ld (cur_pos), hl
    ld a, (undo_char)
    call buffer_insert
    jr .done
.nl:
    ld hl, (undo_pos)
    ld (cur_pos), hl
    call buffer_delete
    call buffer_delete
    jr .done
.repl:
    ld hl, (undo_pos)
    ld (cur_pos), hl
    call buffer_delete
    ld a, (undo_old)
    call buffer_insert
    jr .done
.dnl:
    ld hl, (undo_pos)
    ld (cur_pos), hl
    ld a, (undo_char)
    call buffer_insert
    ld a, (undo_old)
    or a
    jr z, .done
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld a, LF
    call buffer_insert
.done:
    xor a
    ld (undo_type), a
    ld a, 1
    ld (modified), a
    ld a, 1
    ld (structural), a
    ld hl, (undo_pos)
    jp sync_from_pos
    ret

; ==========================================================================
; Cursor and line helpers
; ==========================================================================
inc_col:
    ld hl, (cur_col)
    inc hl
    ld (cur_col), hl
    ret

tab_col:
    ld hl, (cur_col)
    ld a, l
    and 0xF8
    ld l, a
    ld de, 8
    add hl, de
    ld (cur_col), hl
    ret

recompute_col:
    ld de, (line_start)
    ld hl, (cur_pos)
    call col_from
    ld (cur_col), hl
    ret

; col_from - DE = start, HL = end, returns HL = display width
col_from:
    ld (cf_end), hl
    ld (cf_pos), de
    ld hl, 0
    ld (cf_col), hl
.loop:
    ld hl, (cf_pos)
    ld de, (cf_end)
    call cmp16
    jr nc, .done
    call peek
    cp TAB
    jr z, .tab
    ld hl, (cf_col)
    inc hl
    ld (cf_col), hl
    jr .next
.tab:
    ld hl, (cf_col)
    ld a, l
    and 0xF8
    ld l, a
    ld de, 8
    add hl, de
    ld (cf_col), hl
.next:
    ld hl, (cf_pos)
    inc hl
    ld (cf_pos), hl
    jr .loop
.done:
    ld hl, (cf_col)
    ret

line_end:
    ld (le_pos), hl
.loop:
    ld hl, (le_pos)
    ld de, (len)
    call cmp16
    jr nc, .done
    call peek
    cp CR
    jr z, .done
    cp LF
    jr z, .done
    ld hl, (le_pos)
    inc hl
    ld (le_pos), hl
    jr .loop
.done:
    ld hl, (le_pos)
    ret

next_line:
    call line_end
    ld de, (len)
    call cmp16
    jr nc, .at_end
    call peek
    cp CR
    jr z, .cr
    cp LF
    jr z, .lf
    ret
.cr:
    inc hl
    ld de, (len)
    call cmp16
    jr nc, .done
    call peek
    cp LF
    jr nz, .done
    inc hl
.done:
    ret
.lf:
    inc hl
    ret
.at_end:
    ld hl, (len)
    ret

; prev_line_start - HL = current line start -> HL = previous line start
prev_line_start:
    ld a, h
    or l
    ret z
    dec hl
    ld (pls_p), hl
    call peek
    cp LF
    jr nz, .maybe_cr
    ld hl, (pls_p)
    ld a, h
    or l
    jr z, .walk
    dec hl
    call peek
    cp CR
    jr nz, .walk
    ld hl, (pls_p)
    dec hl
    dec hl
    ld (pls_p), hl
    jr .walk
.maybe_cr:
    cp CR
    jr nz, .walk
    ld hl, (pls_p)
    dec hl
    ld (pls_p), hl
.walk:
    ld hl, (pls_p)
    ld a, h
    or l
    jr z, .done
    dec hl
    call peek
    cp CR
    jr z, .done
    cp LF
    jr z, .done
    ld hl, (pls_p)
    dec hl
    ld (pls_p), hl
    jr .walk
.done:
    ld hl, (pls_p)
    ret

; cmp16 - compare HL with DE.  Carry set if HL < DE, Z set if HL == DE.
;   Preserves HL and DE; clobbers A and flags.
cmp16:
    ld a, h
    cp d
    ret nz
    ld a, l
    cp e
    ret

; div16 - HL / DE (8-bit divisor in E) -> HL = quotient, A = remainder
div16:
    ld b, 16
    ld c, 0
.loop:
    add hl, hl
    rl c
    ld a, c
    cp e
    jr c, .next
    sub e
    ld c, a
    inc l
.next:
    djnz .loop
    ld a, c
    ret

; line_segments - HL = line start -> A = display segments
line_segments:
    ld a, (wrap_mode)
    or a
    jr nz, .wrap
    ld a, 1
    ret
.wrap:
    ld (ls_start), hl
    call line_end
    ld de, (ls_start)
    call col_from
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call div16
    inc hl
    ld a, l
    ret

move_left:
    ld hl, (cur_pos)
    ld a, h
    or l
    ret z
    dec hl
    ld (new_pos), hl
    call peek
    cp LF
    jr z, .maybe_crlf
    cp CR
    jr z, .break
    ; normal character
    ld hl, (new_pos)
    ld (cur_pos), hl
    cp TAB
    jr z, .recompute
    ld hl, (cur_col)
    dec hl
    ld (cur_col), hl
    ret
.recompute:
    jp recompute_col
    ret
.maybe_crlf:
    ld hl, (new_pos)
    ld a, h
    or l
    jr z, .break
    dec hl
    call peek
    cp CR
    jr nz, .break
    ld hl, (new_pos)
    dec hl
    ld (new_pos), hl
.break:
    ld hl, (line_start)
    ld (join_old_start), hl
    ld hl, (new_pos)
    ld (cur_pos), hl
    ld hl, (cur_line)
    dec hl
    ld (cur_line), hl
    ld hl, (join_old_start)
    call prev_line_start
    ld (line_start), hl
    jp recompute_col
    ret

move_right:
    ld hl, (cur_pos)
    ld de, (len)
    call cmp16
    jr nc, .none
    call peek
    cp CR
    jr z, .cr
    cp LF
    jr z, .lf
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    cp TAB
    jr z, .tab
    jp inc_col
    ret
.tab:
    jp tab_col
    ret
.cr:
    ld hl, (cur_pos)
    inc hl
    ld de, (len)
    call cmp16
    jr nc, .cr_one
    call peek
    cp LF
    jr nz, .cr_one
    inc hl
    jr .new_line
.cr_one:
    ld hl, (cur_pos)
    inc hl
.new_line:
    ld (cur_pos), hl
    ld (line_start), hl
    ld hl, (cur_line)
    inc hl
    ld (cur_line), hl
    xor a
    ld (cur_col), a
    ld (cur_col + 1), a
    ret
.lf:
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld (line_start), hl
    ld hl, (cur_line)
    inc hl
    ld (cur_line), hl
    xor a
    ld (cur_col), a
    ld (cur_col + 1), a
.none:
    ret

move_up:
    ld hl, (cur_col)
    ld (want_col), hl
    ld hl, (cur_line)
    ld a, h
    or l
    ret z
    ld hl, (line_start)
    call prev_line_start
    ld (line_start), hl
    ld hl, (cur_line)
    dec hl
    ld (cur_line), hl
    jp move_to_want_col
    ret

move_down:
    ld hl, (cur_col)
    ld (want_col), hl
    ld hl, (line_start)
    call line_end
    ld de, (len)
    call cmp16
    ret nc
    call next_line
    ld (line_start), hl
    ld hl, (cur_line)
    inc hl
    ld (cur_line), hl
    jp move_to_want_col
    ret

; move_to_want_col - place the cursor at want_col in the current line
move_to_want_col:
    ld hl, (line_start)
    ld (mtw_pos), hl
    ld hl, 0
    ld (mtw_col), hl
.loop:
    ld hl, (mtw_pos)
    call line_end
    ld de, (mtw_pos)
    ex de, hl
    call cmp16
    ex de, hl
    jr nc, .done
    ld hl, (mtw_col)
    ld de, (want_col)
    call cmp16
    jr nc, .done
    ld hl, (mtw_pos)
    call peek
    cp TAB
    jr z, .tab
    ld hl, (mtw_col)
    inc hl
    ld (mtw_col), hl
    jr .next
.tab:
    ld hl, (mtw_col)
    ld a, l
    and 0xF8
    ld l, a
    ld de, 8
    add hl, de
    ld de, (want_col)
    call cmp16
    jr c, .tab_ok
    jr nz, .done
.tab_ok:
    ld (mtw_col), hl
.next:
    ld hl, (mtw_pos)
    inc hl
    ld (mtw_pos), hl
    jr .loop
.done:
    ld hl, (mtw_pos)
    ld (cur_pos), hl
    ld hl, (mtw_col)
    ld (cur_col), hl
    ret

; sync_from_pos - HL = target position; recompute line/line_start/col
sync_from_pos:
    ld (sync_target), hl
    ld hl, 0
    ld (sync_pos), hl
    ld (sync_line), hl
.loop:
    ld hl, (sync_pos)
    ld de, (sync_target)
    call cmp16
    jr nc, .done
    call line_end
    ld de, (sync_target)
    call cmp16
    jr nc, .done
    call next_line
    ld (sync_pos), hl
    ld hl, (sync_line)
    inc hl
    ld (sync_line), hl
    jr .loop
.done:
    ld hl, (sync_pos)
    ld (line_start), hl
    ld hl, (sync_line)
    ld (cur_line), hl
    ld hl, (sync_target)
    ld (cur_pos), hl
    jp recompute_col
    ret

; ==========================================================================
; Rendering
; ==========================================================================
draw_all:
    call clear_screen
    ld hl, (top_pos)
    ld (draw_pos), hl
    ld a, (top_seg)
    ld (draw_seg), a
    xor a
    ld (draw_row), a
    ld (draw_done), a
.row_loop:
    ld a, (draw_row)
    cp TEXT_ROWS
    jr nc, .rows_done
    ld a, (draw_done)
    or a
    jr nz, .blank
    ; compare draw_pos with len
    ld hl, (draw_pos)
    ld de, (len)
    call cmp16
    jr c, .less
    jr nz, .set_done
    ; draw_pos == len
    call last_line_exists
    jr nc, .set_done
    ld a, (draw_seg)
    or a
    jr nz, .set_done
    call blank_row
    ld a, 1
    ld (draw_seg), a
    jr .next_row
.less:
    ld hl, (draw_pos)
    call line_segments
    ld b, a
    ld a, (draw_seg)
    cp b
    jr c, .render
    ; advance to the next logical line
    ld hl, (draw_pos)
    call next_line
    ld (draw_pos), hl
    xor a
    ld (draw_seg), a
    jr .row_loop
.render:
    call render_draw_segment
    ld a, (draw_seg)
    inc a
    ld (draw_seg), a
    jr .next_row
.set_done:
    ld a, 1
    ld (draw_done), a
.blank:
    call blank_row
.next_row:
    ld a, (draw_row)
    inc a
    ld (draw_row), a
    jr .row_loop
.rows_done:
    call draw_status
    jp place_cursor
    ret

; last_line_exists - carry set if a final empty line follows the last break
last_line_exists:
    ld hl, (len)
    ld a, h
    or l
    jr z, .yes
    dec hl
    call peek
    cp CR
    jr z, .yes
    cp LF
    jr z, .yes
    or a
    ret
.yes:
    scf
    ret

render_draw_segment:
    ld hl, (draw_pos)
    ld (r_pos), hl
    ld a, (draw_row)
    ld (r_row), a
    ld a, (draw_seg)
    ld e, a
    ld d, 0
    ld hl, 0
.mul:
    ld a, e
    or a
    jr z, .mul_done
    ld a, (text_cols)
    add a, l
    ld l, a
    jr nc, .noc
    inc h
.noc:
    dec e
    jr .mul
.mul_done:
    ld (r_start_col), hl
    jp render_segment
    ret

; render_segment - render one window of a line
;   r_pos = line start, r_row = screen row, r_start_col = first display column
render_segment:
    ld hl, (r_pos)
    call line_end
    ld (r_end), hl
    ld de, (r_pos)
    call col_from
    ld (r_width), hl
    ; position the cursor at (r_row, 0)
    ld a, (r_row)
    ld b, a
    ld c, 0
    call goto
    xor a
    ld (r_out), a
    ld (r_out + 1), a
    ld (r_col), a
    ld (r_col + 1), a
    ld hl, (r_pos)
    ld (r_q), hl
.loop:
    ; if out >= text_cols -> finish
    ld hl, (r_out)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call cmp16
    jp nc, .finish
    ; if q >= r_end -> finish
    ld hl, (r_q)
    ld de, (r_end)
    call cmp16
    jp nc, .finish
    call peek
    cp TAB
    jr z, .tab
    ; ordinary character
    ld c, a
    cp ' '
    jr nz, .not_space
    ld a, (show_ws)
    or a
    jr z, .not_space
    ld c, '~'
.not_space:
    ld a, c
    cp 0x20
    jr nc, .printable
    ld c, '.'
.printable:
    ; if r_col >= r_start_col then output
    ld hl, (r_col)
    ld de, (r_start_col)
    call cmp16
    jr c, .skip_char
    ld a, c
    call putc
    ld hl, (r_out)
    inc hl
    ld (r_out), hl
.skip_char:
    ld hl, (r_col)
    inc hl
    ld (r_col), hl
    ld hl, (r_q)
    inc hl
    ld (r_q), hl
    jr .loop
.tab:
    ld hl, (r_col)
    ld a, l
    and 0xF8
    ld l, a
    ld de, 8
    add hl, de
    ld (r_tabend), hl
.tab_loop:
    ld hl, (r_col)
    ld de, (r_tabend)
    call cmp16
    jr nc, .tab_done
    ld hl, (r_out)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call cmp16
    jr nc, .finish_tab
    ld hl, (r_col)
    ld de, (r_start_col)
    call cmp16
    jr c, .tab_skip
    ld a, (show_ws)
    or a
    jr z, .tab_space
    ld a, '>'
    jr .tab_put
.tab_space:
    ld a, ' '
.tab_put:
    call putc
    ld hl, (r_out)
    inc hl
    ld (r_out), hl
.tab_skip:
    ld hl, (r_col)
    inc hl
    ld (r_col), hl
    jr .tab_loop
.tab_done:
    ld hl, (r_q)
    inc hl
    ld (r_q), hl
    jp .loop
.finish_tab:
    ld hl, (r_tabend)
    ld (r_col), hl
    jr .finish
.finish:
    ; pad to text_cols
.pad:
    ld hl, (r_out)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call cmp16
    jr nc, .pad_done
    ld a, ' '
    call putc
    ld hl, (r_out)
    inc hl
    ld (r_out), hl
    jr .pad
.pad_done:
    ; the marker column
    ld a, (wrap_mode)
    or a
    jr nz, .no_marker
    ld hl, (r_q)
    ld de, (r_end)
    call cmp16
    jr c, .marker
.no_marker:
    ld a, ' '
    jr .put_marker
.marker:
    ld a, '>'
.put_marker:
    jp putc
    ret

blank_row:
    ld a, (draw_row)
    ld b, a
    ld c, 0
    call goto
    ld a, (cols)
    ld b, a
.loop:
    ld a, ' '
    call putc
    djnz .loop
    ret

; ==========================================================================
; Status bar
; ==========================================================================
build_status:
    xor a
    ld (stat_len), a
    ld a, (msg_active)
    or a
    jr z, .normal
    ld de, msg_text
    call sb_str
    jp .pad
.normal:
    ld de, file_disp
    call sb_str
    ld a, (modified)
    or a
    jr z, .nostar
    ld a, '*'
    call sb_char
.nostar:
    ld a, ' '
    call sb_char
    ld a, 'L'
    call sb_char
    ld hl, (cur_line)
    inc hl
    call sb_dec16
    ld a, (cols)
    cp 51
    jr c, .compact
    ld a, ' '
    call sb_char
    ld a, 'C'
    call sb_char
    ld hl, (cur_col)
    inc hl
    call sb_dec16
    ld a, ' '
    call sb_char
    ld a, (mode_ins)
    or a
    ld de, str_ins
    jr nz, .mode
    ld de, str_ovr
.mode:
    call sb_str
    ld a, (wrap_mode)
    or a
    jr z, .nowrap
    ld de, str_wrap
    call sb_str
.nowrap:
    ld a, (show_ws)
    or a
    jr z, .pad
    ld de, str_ws
    call sb_str
    jr .pad
.compact:
    ld a, 'C'
    call sb_char
    ld hl, (cur_col)
    inc hl
    call sb_dec16
    ld a, ' '
    call sb_char
    ld a, (mode_ins)
    or a
    ld a, 'I'
    jr nz, .cmode
    ld a, 'O'
.cmode:
    call sb_char
    ld a, (wrap_mode)
    or a
    jr z, .cnowrap
    ld a, 'W'
    call sb_char
.cnowrap:
    ld a, (show_ws)
    or a
    jr z, .pad
    ld a, 'V'
    call sb_char
.pad:
    ld a, (cols)
    sub 6
    ld (stat_target), a
.padloop:
    ld a, (stat_len)
    ld hl, stat_target
    cp (hl)
    jr nc, .extend
    ld a, ' '
    call sb_char
    jr .padloop
.extend:
    ld de, str_extend
    call sb_str
    ld a, (cols)
    ld (stat_target), a
.tailloop:
    ld a, (stat_len)
    ld hl, stat_target
    cp (hl)
    jr nc, .trunc
    ld a, ' '
    call sb_char
    jr .tailloop
.trunc:
    ld a, (cols)
    ld hl, stat_len
    cp (hl)
    jr nc, .done
    ld (hl), a
.done:
    ret

sb_char:
    ld c, a
    ld a, (stat_len)
    cp 81
    ret nc
    push hl
    push de
    ld e, a
    ld d, 0
    ld hl, stat_buf
    add hl, de
    ld (hl), c
    ld hl, stat_len
    inc (hl)
    pop de
    pop hl
    ret

sb_str:
    ld a, (de)
    or a
    ret z
    push de
    call sb_char
    pop de
    inc de
    jr sb_str

sb_dec16:
    ld (dec_val), hl
    xor a
    ld (dec_started), a
    ld hl, 10000
    call .place
    ld hl, 1000
    call .place
    ld hl, 100
    call .place
    ld hl, 10
    call .place
    ld hl, 1
    call .place
    ld a, (dec_started)
    or a
    ret nz
    ld a, '0'
    jp sb_char
.place:
    ld (dec_div), hl
    ld b, 0
.loop:
    ld hl, (dec_val)
    ld de, (dec_div)
    call cmp16
    jr c, .done
    ld hl, (dec_val)
    xor a
    sbc hl, de
    ld (dec_val), hl
    inc b
    jr .loop
.done:
    ld a, (dec_started)
    or a
    jr nz, .emit
    ld a, b
    or a
    ret z
.emit:
    ld a, 1
    ld (dec_started), a
    ld a, b
    add a, '0'
    jp sb_char

draw_status:
    call build_status
    ld a, STATUS_ROW
    ld b, a
    ld c, 0
    call goto
    ld a, ESC
    call putc
    ld a, '['
    call putc
    ld a, '7'
    call putc
    ld a, 'm'
    call putc
    ld hl, stat_buf
    ld a, (stat_len)
    ld b, a
.loop:
    ld a, b
    or a
    jr z, .reset
    ld a, (hl)
    call putc
    inc hl
    dec b
    jr .loop
.reset:
    ld a, ESC
    call putc
    ld a, '['
    call putc
    ld a, '0'
    call putc
    ld a, 'm'
    jp putc
    ret

; ==========================================================================
; Cursor placement and scrolling
; ==========================================================================
place_cursor:
    ld a, (wrap_mode)
    or a
    jr nz, .wrap
    ld hl, (cur_line)
    ld de, (top_line)
    or a
    sbc hl, de
    ld a, l
    ld b, a
    ld hl, (cur_col)
    ld de, (left_col)
    or a
    sbc hl, de
    ld a, l
    ld c, a
    jp goto
    ret
.wrap:
    call compute_cursor_row
    bit 7, h
    jr z, .nonneg
    ld hl, 0
.nonneg:
    ld a, h
    or a
    jr nz, .clamp
    ld a, l
    cp TEXT_ROWS
    jr c, .row_ok
.clamp:
    ld a, TEXT_ROWS - 1
.row_ok:
    ld (pc_row), a
    ld hl, (cur_col)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call div16
    ld (pc_col), a
    ld a, (pc_row)
    ld b, a
    ld a, (pc_col)
    ld c, a
    jp goto
    ret

compute_cursor_row:
    ld hl, (top_pos)
    ld (ccr_pos), hl
    ld hl, (top_line)
    ld (ccr_line), hl
    ld hl, 0
    ld (ccr_sum), hl
.loop:
    ld hl, (ccr_line)
    ld de, (cur_line)
    call cmp16
    jr nc, .sum_done
    ld hl, (ccr_pos)
    call line_segments
    ld e, a
    ld d, 0
    ld hl, (ccr_sum)
    add hl, de
    ld (ccr_sum), hl
    ld hl, (ccr_pos)
    call next_line
    ld (ccr_pos), hl
    ld hl, (ccr_line)
    inc hl
    ld (ccr_line), hl
    jr .loop
.sum_done:
    ld hl, (cur_col)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call div16
    ld de, (ccr_sum)
    add hl, de
    ld a, (top_seg)
    ld e, a
    ld d, 0
    or a
    sbc hl, de
    ret

ensure_visible:
    ld a, (wrap_mode)
    or a
    jr z, .nowrap
    xor a
    ld (left_col), a
    ld (left_col + 1), a
    ld a, 200
    ld (ev_count), a
.loop:
    ld a, (ev_count)
    or a
    ret z
    dec a
    ld (ev_count), a
    call compute_cursor_row
    bit 7, h
    jr nz, .up
    ld a, h
    or a
    jr nz, .down
    ld a, l
    cp TEXT_ROWS
    jr nc, .down
    ret
.up:
    call scroll_up_seg
    jr .loop
.down:
    call scroll_down_seg
    jr .loop
.nowrap:
    ld hl, (cur_line)
    ld de, (top_line)
    call cmp16
    jr c, .above
    ld hl, (cur_line)
    ld de, (top_line)
    xor a
    sbc hl, de
    ld a, l
    cp TEXT_ROWS
    jr nc, .below
    jr .horiz
.above:
    ld hl, (cur_line)
    ld (top_line), hl
    ld hl, (line_start)
    ld (top_pos), hl
    xor a
    ld (top_seg), a
    ld a, 1
    ld (structural), a
    jr .horiz
.below:
    ld hl, (cur_line)
    ld de, TEXT_ROWS - 1
    or a
    sbc hl, de
    ld (top_line), hl
    ld hl, (line_start)
    ld b, TEXT_ROWS - 1
.walk:
    call prev_line_start
    djnz .walk
    ld (top_pos), hl
    xor a
    ld (top_seg), a
    ld a, 1
    ld (structural), a
.horiz:
    ld hl, (cur_col)
    ld de, (left_col)
    call cmp16
    jr c, .left
    ld hl, (cur_col)
    ld de, (left_col)
    xor a
    sbc hl, de
    ld a, (text_cols)
    ld e, a
    ld d, 0
    call cmp16
    jr nc, .right
    ret
.left:
    ld hl, (cur_col)
    ld (left_col), hl
    ld a, 1
    ld (structural), a
    ret
.right:
    ld hl, (cur_col)
    ld a, (text_cols)
    ld e, a
    ld d, 0
    or a
    sbc hl, de
    inc hl
    ld (left_col), hl
    ld a, 1
    ld (structural), a
    ret

scroll_up_seg:
    ld a, (top_seg)
    or a
    jr z, .prev
    dec a
    ld (top_seg), a
    ld a, 1
    ld (structural), a
    ret
.prev:
    ld hl, (top_pos)
    call prev_line_start
    ld (top_pos), hl
    ld hl, (top_line)
    dec hl
    ld (top_line), hl
    ld hl, (top_pos)
    call line_segments
    dec a
    ld (top_seg), a
    ld a, 1
    ld (structural), a
    ret

scroll_down_seg:
    ld hl, (top_pos)
    call line_segments
    ld b, a
    ld a, (top_seg)
    inc a
    cp b
    jr c, .next_seg
    ld hl, (top_pos)
    call next_line
    ld de, (top_pos)
    call cmp16
    jr z, .no_move
    ld (top_pos), hl
    ld hl, (top_line)
    inc hl
    ld (top_line), hl
    xor a
    ld (top_seg), a
    ld a, 1
    ld (structural), a
    ret
.next_seg:
    ld (top_seg), a
    ld a, 1
    ld (structural), a
    ret
.no_move:
    ret

after_edit:
    call ensure_visible
    ld a, (structural)
    or a
    jr nz, .full
    call redraw_current_line
    call draw_status
    jp place_cursor
    ret
.full:
    xor a
    ld (structural), a
    jp draw_all
    ret

after_move:
    call ensure_visible
    ld a, (structural)
    or a
    jr nz, .full
    call draw_status
    jp place_cursor
    ret
.full:
    xor a
    ld (structural), a
    jp draw_all
    ret

redraw_current_line:
    ld a, (wrap_mode)
    or a
    jr nz, .wrap
    ld hl, (cur_line)
    ld de, (top_line)
    or a
    sbc hl, de
    ld a, l
    cp TEXT_ROWS
    jp nc, .full
    ld (r_row), a
    ld hl, (line_start)
    ld (r_pos), hl
    ld hl, (left_col)
    ld (r_start_col), hl
    jp render_segment
    ret
.wrap:
    ; first row and first segment of the current logical line
    ld hl, (cur_line)
    ld de, (top_line)
    call cmp16
    jr z, .same_line
    ld hl, (top_pos)
    ld (rcr_pos), hl
    ld hl, (top_line)
    ld (rcr_line), hl
    ld hl, 0
    ld (rcr_sum), hl
.sloop:
    ld hl, (rcr_line)
    ld de, (cur_line)
    call cmp16
    jr nc, .sdone
    ld hl, (rcr_pos)
    call line_segments
    ld e, a
    ld d, 0
    ld hl, (rcr_sum)
    add hl, de
    ld (rcr_sum), hl
    ld hl, (rcr_pos)
    call next_line
    ld (rcr_pos), hl
    ld hl, (rcr_line)
    inc hl
    ld (rcr_line), hl
    jr .sloop
.sdone:
    ld hl, (rcr_sum)
    ld a, (top_seg)
    ld e, a
    ld d, 0
    or a
    sbc hl, de
    bit 7, h
    jr nz, .full
    ld a, h
    or a
    jr nz, .full
    ld a, l
    ld (rcr_row), a
    xor a
    ld (rcr_seg), a
    jr .render_loop
.same_line:
    ld a, (top_seg)
    ld (rcr_seg), a
    xor a
    ld (rcr_row), a
.render_loop:
    ld hl, (line_start)
    ld (r_pos), hl
    call line_segments
    ld (rcr_segs), a
.rl:
    ld a, (rcr_seg)
    ld hl, rcr_segs
    cp (hl)
    jr nc, .rl_done
    ld a, (rcr_row)
    cp TEXT_ROWS
    jr nc, .full
    ld (r_row), a
    ld a, (rcr_seg)
    ld e, a
    ld d, 0
    ld hl, 0
.mul:
    ld a, e
    or a
    jr z, .mul_done
    ld a, (text_cols)
    add a, l
    ld l, a
    jr nc, .noc
    inc h
.noc:
    dec e
    jr .mul
.mul_done:
    ld (r_start_col), hl
    call render_segment
    ld a, (rcr_seg)
    inc a
    ld (rcr_seg), a
    ld a, (rcr_row)
    inc a
    ld (rcr_row), a
    jr .rl
.rl_done:
    ret
.full:
    jp draw_all
    ret

; ==========================================================================
; Prompts
; ==========================================================================
; prompt_string - uses prompt_ptr, prompt_alt, prompt_buf_ptr, prompt_max
prompt_string:
    call prompt_compute_width
    xor a
    ld (prompt_len), a
    ld a, 1
    ld (in_prompt), a
    call redraw_prompt
.loop:
    call get_raw
    jr nc, .loop
    ld a, (key_shift)
    cp 1
    jr z, .caps
    cp 3
    jr z, .extend
    ; normal / symbol
    ld e, a
    ld a, (key_raw)
    call map_key
    or a
    jr z, .loop
    cp CR
    jp z, .accept
    cp 0x20
    jr c, .loop
    cp 0x7F
    jr nc, .loop
    jr .append
.caps:
    ld a, (key_raw)
    cp 20
    jr z, .back
    cp 35
    jp z, .cancel
    cp 30
    jr z, .accept
    ld e, 1
    ld a, (key_raw)
    call map_key
    or a
    jr z, .loop
    cp 0x20
    jr c, .loop
    cp 0x7F
    jr nc, .loop
    jr .append
.extend:
    ld a, (key_raw)
    cp 3
    jr z, .toggle_case
    jr .loop
.toggle_case:
    ld hl, (prompt_alt)
    ld a, h
    or l
    jr z, .loop
    ld hl, (prompt_ptr)
    ld de, (prompt_alt)
    ld (prompt_ptr), de
    ld (prompt_alt), hl
    ld a, (case_sens)
    xor 1
    ld (case_sens), a
    call prompt_compute_width
    call redraw_prompt
    jr .loop
.append:
    ld c, a
    ld a, (prompt_len)
    ld hl, prompt_max
    cp (hl)
    jp nc, .loop
    ld hl, (prompt_buf_ptr)
    ld e, a
    ld d, 0
    add hl, de
    ld (hl), c
    ld hl, prompt_len
    inc (hl)
    call redraw_prompt
    jp .loop
.back:
    ld a, (prompt_len)
    or a
    jp z, .loop
    dec a
    ld (prompt_len), a
    call redraw_prompt
    jp .loop
.accept:
    ld hl, (prompt_buf_ptr)
    ld a, (prompt_len)
    ld e, a
    ld d, 0
    add hl, de
    ld (hl), 0
    xor a
    ld (in_prompt), a
    scf
    ret
.cancel:
    xor a
    ld (in_prompt), a
    or a
    ret

prompt_compute_width:
    ld de, (prompt_ptr)
    call str_len
    ld a, l
    ld (prompt_w), a
    ld a, (cols)
    sub 1
    ld hl, prompt_w
    sub (hl)
    ld hl, prompt_max
    cp (hl)
    jr nc, .ok
    ld (hl), a
.ok:
    ret

redraw_prompt:
    ld a, STATUS_ROW
    ld b, a
    ld c, 0
    call goto
    ld a, ESC
    call putc
    ld a, '['
    call putc
    ld a, '7'
    call putc
    ld a, 'm'
    call putc
    ld de, (prompt_ptr)
    call puts
    ld hl, (prompt_buf_ptr)
    ld a, (prompt_len)
    ld b, a
.loop:
    ld a, b
    or a
    jr z, .pad
    ld a, (hl)
    call putc
    inc hl
    dec b
    jr .loop
.pad:
    ld a, (prompt_w)
    ld hl, prompt_len
    add a, (hl)
    ld b, a
.padloop:
    ld a, b
    ld hl, cols
    cp (hl)
    jr nc, .reset
    ld a, ' '
    call putc
    inc b
    jr .padloop
.reset:
    ld a, ESC
    call putc
    ld a, '['
    call putc
    ld a, '0'
    call putc
    ld a, 'm'
    call putc
    ld a, (prompt_w)
    ld hl, prompt_len
    add a, (hl)
    ld c, a
    ld b, STATUS_ROW
    jp goto
    ret

; ==========================================================================
; Filenames
; ==========================================================================
; parse_filename - HL = text -> work_fcb, carry set if a name was found
parse_filename:
    ld (parse_src), hl
    ld de, work_fcb
    ld b, 36
.clear:
    xor a
    ld (de), a
    inc de
    djnz .clear
    ld hl, work_fcb + 1
    ld b, 11
.spaces:
    ld (hl), ' '
    inc hl
    djnz .spaces
    ld hl, (parse_src)
.skip:
    ld a, (hl)
    cp ' '
    jr nz, .start
    inc hl
    jr .skip
.start:
    ; drive prefix?
    ld a, (hl)
    call to_upper
    sub 'A'
    cp 16
    jr nc, .name
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .no_drive
    dec hl
    ld a, (hl)
    call to_upper
    sub 'A' - 1
    ld (work_fcb), a
    inc hl
    inc hl
    jr .name
.no_drive:
    dec hl
.name:
    ld de, work_fcb + 1
    ld b, 8
.nloop:
    ld a, (hl)
    or a
    jr z, .done
    cp '.'
    jr z, .type_start
    cp ' '
    jr z, .nskip
    cp ':'
    jr z, .done
    call to_upper
    ld (de), a
    inc de
    inc hl
    djnz .nloop
    ; name full: skip to '.' or end
.nskip2:
    ld a, (hl)
    or a
    jr z, .done
    cp '.'
    jr z, .type_start
    inc hl
    jr .nskip2
.nskip:
    inc hl
    jr .nloop
.type_start:
    inc hl
    ld de, work_fcb + 9
    ld b, 3
.tloop:
    ld a, (hl)
    or a
    jr z, .done
    cp ' '
    jr z, .done
    call to_upper
    ld (de), a
    inc de
    inc hl
    djnz .tloop
.done:
    ld hl, work_fcb + 1
    ld b, 8
.chk:
    ld a, (hl)
    cp ' '
    jr nz, .ok
    inc hl
    djnz .chk
    or a
    ret
.ok:
    ld hl, work_fcb + 12
    ld b, 24
.zero:
    xor a
    ld (hl), a
    inc hl
    djnz .zero
    scf
    ret

to_upper:
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    sub 0x20
    ret

build_file_disp:
    ld a, (have_name)
    or a
    jr nz, .named
    ld hl, str_noname
    ld de, file_disp
    jp strcpy
    ret
.named:
    ld de, file_disp
    ld a, (cols)
    cp 51
    jr c, .no_drive
    ld a, (file_fcb)
    or a
    jr nz, .drive
    ld c, F_CURDSK
    call BDOS
    inc a
.drive:
    add a, 'A' - 1
    ld (de), a
    inc de
    ld a, ':'
    ld (de), a
    inc de
.no_drive:
    ld hl, file_fcb + 1
    ld b, 8
.nloop:
    ld a, (hl)
    cp ' '
    jr z, .ndone
    ld (de), a
    inc de
    inc hl
    djnz .nloop
.ndone:
    ld a, (file_fcb + 9)
    cp ' '
    jr z, .done
    ld a, '.'
    ld (de), a
    inc de
    ld hl, file_fcb + 9
    ld b, 3
.tloop:
    ld a, (hl)
    cp ' '
    jr z, .done
    ld (de), a
    inc de
    inc hl
    djnz .tloop
.done:
    xor a
    ld (de), a
    ; truncate to the status-bar budget
    ld a, (cols)
    cp 51
    ld a, 8
    jr c, .max
    ld a, 16
.max:
    ld b, a
    ld hl, file_disp
    ld e, 0
.tr:
    ld a, e
    cp b
    jr nc, .trunc
    ld a, (hl)
    or a
    ret z
    inc hl
    inc e
    jr .tr
.trunc:
    ld (hl), 0
    ret

; ==========================================================================
; File I/O
; ==========================================================================
; open_work_fcb - open and read work_fcb.  allow_new permits a missing file.
open_work_fcb:
    ld de, work_fcb
    ld c, F_OPEN
    call BDOS
    cp 0xFF
    jr z, .nofile
    ; commit the name
    ld hl, work_fcb
    ld de, file_fcb
    ld bc, 36
    ldir
    ld a, 1
    ld (have_name), a
    call build_file_disp
    call reset_buffer_only
    ld de, iobuf
    ld c, F_SETDMA
    call BDOS
.read_loop:
    ld de, work_fcb
    ld c, F_READ
    call BDOS
    or a
    jr nz, .read_done
    ld hl, iobuf
    ld b, 128
.copy:
    ld a, (hl)
    inc hl
    cp EOF_Z
    jr z, .eof
    push hl
    push bc
    call append_byte
    pop bc
    pop hl
    jr c, .full
    djnz .copy
    jr .read_loop
.eof:
    ld a, 1
    ld (eof_z), a
.read_done:
    ld de, work_fcb
    ld c, F_CLOSE
    call BDOS
    call reset_cursor
    scf
    ret
.full:
    ld de, work_fcb
    ld c, F_CLOSE
    call BDOS
    ld de, msg_full
    call show_error
    or a
    ret
.nofile:
    ld a, (allow_new)
    or a
    jr z, .fail
    ld hl, work_fcb
    ld de, file_fcb
    ld bc, 36
    ldir
    ld a, 1
    ld (have_name), a
    call build_file_disp
    call reset_buffer_only
    scf
    ret
.fail:
    ld de, msg_nofile
    call show_error
    or a
    ret

reset_cursor:
    xor a
    ld (cur_pos), a
    ld (cur_pos + 1), a
    ld (cur_line), a
    ld (cur_line + 1), a
    ld (line_start), a
    ld (line_start + 1), a
    ld (cur_col), a
    ld (cur_col + 1), a
    ld (top_line), a
    ld (top_line + 1), a
    ld (left_col), a
    ld (left_col + 1), a
    ld (top_seg), a
    ld (modified), a
    ld (undo_type), a
    ld (structural), a
    ld (top_pos), a
    ld (top_pos + 1), a
    ret

save_file:
    ld a, (have_name)
    or a
    jr nz, .named
    ld hl, msg_saveas
    ld (prompt_ptr), hl
    xor a
    ld (prompt_alt), a
    ld (prompt_alt + 1), a
    ld hl, name_buf
    ld (prompt_buf_ptr), hl
    ld a, 80
    ld (prompt_max), a
    call prompt_string
    ret nc
    ld hl, name_buf
    call parse_filename
    ret nc
    ld hl, work_fcb
    ld de, file_fcb
    ld bc, 36
    ldir
    ld a, 1
    ld (have_name), a
    call build_file_disp
.named:
    ; Save to a temporary file, then rename it over the target only after
    ; every record has been written.  A failed save must never destroy the
    ; original file or leave a phantom directory entry.
    ld hl, file_fcb
    ld de, target_fcb
    ld bc, 36
    ldir
    ld hl, temp_fcb_template
    ld de, work_fcb
    ld bc, 36
    ldir
    ld a, (target_fcb)
    ld (work_fcb), a
    ; remove any stale temp
    ld de, work_fcb
    ld c, F_DELETE
    call BDOS
    ; create the temp
    ld de, work_fcb
    ld c, F_MAKE
    call BDOS
    cp 0xFF
    jp z, .error
    ld de, iobuf
    ld c, F_SETDMA
    call BDOS
    ld hl, 0
    ld (save_pos), hl
.record:
    ld hl, (save_pos)
    ld de, (len)
    call cmp16
    jr nc, .records_done
    ld hl, iobuf
    ld b, 128
.fill:
    push hl
    push bc
    ld hl, (save_pos)
    ld de, (len)
    call cmp16
    jr nc, .pad
    call peek
    jr .store
.pad:
    ld a, EOF_Z
.store:
    pop bc
    pop hl
    ld (hl), a
    inc hl
    push hl
    ld hl, save_pos
    inc (hl)
    jr nz, .no_hi
    inc hl
    inc (hl)
.no_hi:
    pop hl
    djnz .fill
    ld de, iobuf
    ld c, F_SETDMA
    call BDOS
    ld de, work_fcb
    ld c, F_WRITE
    call BDOS
    or a
    jp nz, .error
    jr .record
.records_done:
    ld a, (eof_z)
    or a
    jr z, .close
    ld a, (len)
    and 0x7F
    jr nz, .close
    ld hl, iobuf
    ld b, 128
.fillz:
    ld (hl), EOF_Z
    inc hl
    djnz .fillz
    ld de, iobuf
    ld c, F_SETDMA
    call BDOS
    ld de, work_fcb
    ld c, F_WRITE
    call BDOS
    or a
    jp nz, .error
.close:
    ld de, work_fcb
    ld c, F_CLOSE
    call BDOS
    ; the temp is complete: replace the target
    ld de, target_fcb
    ld c, F_DELETE
    call BDOS
    ; if the target still exists (read-only or delete failed), abort
    ld hl, target_fcb
    ld de, check_fcb
    ld bc, 36
    ldir
    ld de, check_fcb
    ld c, F_OPEN
    call BDOS
    cp 0xFF
    jr z, .target_gone
    ld de, check_fcb
    ld c, F_CLOSE
    call BDOS
    ld de, work_fcb
    ld c, F_DELETE
    call BDOS
    ld de, msg_writeerr
    jp show_error
.target_gone:
    ld hl, work_fcb
    ld de, rename_fcb
    ld bc, 36
    ldir
    ld hl, target_fcb + 1
    ld de, rename_fcb + 17
    ld b, 11
.maskname:
    ld a, (hl)
    and 0x7F
    ld (de), a
    inc hl
    inc de
    djnz .maskname
    ld de, rename_fcb
    ld c, F_RENAME
    call BDOS
    cp 0xFF
    jp z, .rename_error
    xor a
    ld (modified), a
    ld de, msg_saved
    jp set_message
.rename_error:
    ld de, msg_renameerr
    jp show_error
.error:
    ; the temp is incomplete: remove it and leave the target intact
    ld de, work_fcb
    ld c, F_CLOSE
    call BDOS
    ld de, work_fcb
    ld c, F_DELETE
    call BDOS
    ld de, msg_writeerr
    jp show_error

; ==========================================================================
; Messages
; ==========================================================================
set_message:
    ex de, hl
    ld de, msg_text
    call strcpy
    ld a, 1
    ld (msg_active), a
    jp draw_status
    ret

clear_message:
    ld a, (msg_active)
    or a
    ret z
    xor a
    ld (msg_active), a
    jp draw_status
    ret

show_message:
    jp set_message

show_error:
    call set_message
.wait:
    call get_raw
    jr nc, .wait
    call drain_tokens
    jp clear_message
    ret

confirm_save:
    ld a, (modified)
    or a
    jr nz, .ask
    scf
    ret
.ask:
    ld de, msg_saveq
    call set_message
.wait:
    call get_raw
    jr nc, .wait
    call clear_message
    ld a, (key_shift)
    cp 1
    jr nz, .map
    ld a, (key_raw)
    cp 35
    jr z, .cancel
.map:
    ld a, (key_shift)
    ld e, a
    ld a, (key_raw)
    call map_key
    call to_upper
    cp 'Y'
    jr z, .yes
    cp 'N'
    jr z, .no
    cp 'C'
    jr z, .cancel
    jr .ask
.yes:
    call save_file
    ld a, (modified)
    or a
    jr nz, .cancel
    scf
    ret
.no:
    scf
    ret
.cancel:
    or a
    ret

; ==========================================================================
; Help panel
; ==========================================================================
show_help:
    call draw_help_box
    ld de, msg_helpstat
    call set_message
.wait:
    call get_raw
    jr nc, .wait
    call drain_tokens
    call wait_extend_release
    xor a
    ld (msg_active), a
    jp draw_all
    ret

draw_help_box:
    ld a, (cols)
    cp 44
    jr c, .narrow
    ld a, 40
    jr .setw
.narrow:
    sub 4
.setw:
    ld (h_width), a
    ld b, a
    ld a, (cols)
    sub b
    srl a
    ld (h_left), a
    ld a, 4
    ld (h_top), a
    ; top border
    ld b, a
    ld a, (h_left)
    ld c, a
    call goto
    ld a, '+'
    call putc
    ld a, (h_width)
    sub 2
    ld b, a
    ld a, '-'
    call .spaces
    ld a, '+'
    call putc
    ; sides
    ld a, (h_top)
    inc a
    ld (h_row), a
    ld b, 11
.sloop:
    push bc
    ld a, (h_row)
    ld b, a
    ld a, (h_left)
    ld c, a
    call goto
    ld a, '|'
    call putc
    ld a, (h_width)
    sub 2
    ld b, a
    ld a, ' '
    call .spaces
    ld a, '|'
    call putc
    ld hl, h_row
    inc (hl)
    pop bc
    djnz .sloop
    ; bottom border
    ld a, (h_top)
    add a, 12
    ld b, a
    ld a, (h_left)
    ld c, a
    call goto
    ld a, '+'
    call putc
    ld a, (h_width)
    sub 2
    ld b, a
    ld a, '-'
    call .spaces
    ld a, '+'
    call putc
    ; text
    ld hl, help_table
    ld (help_ptr), hl
    ld a, (h_top)
    inc a
    ld (h_row), a
    ld b, 10
.tloop:
    push bc
    ld a, (h_row)
    ld b, a
    ld a, (h_left)
    add a, 2
    ld c, a
    call goto
    ld hl, (help_ptr)
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld (help_ptr), hl
    call puts
    ld hl, h_row
    inc (hl)
    pop bc
    djnz .tloop
    ret
.spaces:
    push af
.sp_loop:
    call putc
    djnz .sp_loop
    pop af
    ret

; ==========================================================================
; Find / replace
; ==========================================================================
; case_prompts - DE = case-sensitive prompt, HL = insensitive prompt
case_prompts:
    ld a, (case_sens)
    or a
    jr z, .insensitive
    ld (prompt_ptr), de
    ld (prompt_alt), hl
    ret
.insensitive:
    ld (prompt_ptr), hl
    ld (prompt_alt), de
    ret

cmd_find:
    ld de, msg_find_a
    ld hl, msg_find_i
    call case_prompts
    ld hl, find_buf
    ld (prompt_buf_ptr), hl
    ld a, 80
    ld (prompt_max), a
    call prompt_string
    ret nc
    ld hl, (cur_pos)
    inc hl
    ld (search_start), hl
    call find_next_wrap
    jr nc, .notfound
    jp refresh_all
    ret
.notfound:
    ld de, msg_notfound
    jp show_error
    ret

cmd_replace:
    ld de, msg_find_a
    ld hl, msg_find_i
    call case_prompts
    ld hl, find_buf
    ld (prompt_buf_ptr), hl
    ld a, 80
    ld (prompt_max), a
    call prompt_string
    ret nc
    ld de, msg_repl_a
    ld hl, msg_repl_i
    call case_prompts
    ld hl, repl_buf
    ld (prompt_buf_ptr), hl
    ld a, 80
    ld (prompt_max), a
    call prompt_string
    ret nc
    ld hl, (cur_pos)
    inc hl
    ld (search_start), hl
.loop:
    call search_from_start
    jr nc, .done
    call refresh_all
    ld de, msg_replaceq
    call set_message
.ask:
    call get_raw
    jr nc, .ask
    call clear_message
    ld a, (key_shift)
    cp 1
    jr nz, .map
    ld a, (key_raw)
    cp 35
    jr z, .done
.map:
    ld a, (key_shift)
    ld e, a
    ld a, (key_raw)
    call map_key
    call to_upper
    cp 'Y'
    jr z, .yes
    cp 'N'
    jr z, .skip
    cp 'A'
    jr z, .all
    cp 'Q'
    jr z, .done
    jr .ask
.yes:
    call replace_current
    ld hl, (cur_pos)
    ld (search_start), hl
    jr .loop
.skip:
    ; continue after the match
    ld hl, (cur_pos)
    ld de, (needle_len)
    add hl, de
    ld (search_start), hl
    jr .loop
.all:
    call replace_current
.ra_loop:
    ld hl, (cur_pos)
    ld (search_start), hl
    call search_from_start
    jr nc, .done
    call replace_current
    jr .ra_loop
.done:
    jp refresh_all
    ret

refresh_all:
    call ensure_visible
    xor a
    ld (structural), a
    jp draw_all
    ret

find_next_wrap:
    call search_from_start
    ret c
    ld hl, 0
    ld (search_start), hl
    jp search_from_start
    ret

search_from_start:
    ld de, find_buf
    call str_len
    ld (needle_len), hl
    ld a, h
    or l
    ret z
    ld hl, (search_start)
    ld (srch_pos), hl
.loop:
    ; if pos + needle_len > len, stop
    ld hl, (srch_pos)
    ld de, (needle_len)
    add hl, de
    ld de, (len)
    call cmp16
    jr z, .try
    jr c, .try
    jr .no
.try:
    ld hl, (srch_pos)
    call match_at
    jr c, .yes
    ld hl, (srch_pos)
    inc hl
    ld (srch_pos), hl
    jr .loop
.yes:
    ld hl, (srch_pos)
    ld (cur_pos), hl
    call sync_from_pos
    scf
    ret
.no:
    or a
    ret

match_at:
    ld hl, find_buf
    ld (m_ptr), hl
    ld hl, (srch_pos)
    ld (m_pos), hl
.mloop:
    ld hl, (m_ptr)
    ld a, (hl)
    or a
    jr z, .yes
    ld (m_char), a
    ld hl, (m_pos)
    ld de, (len)
    call cmp16
    jr nc, .no
    call peek
    ld hl, m_char
    cp (hl)
    jr z, .same
    ld a, (case_sens)
    or a
    jr nz, .no
    ld a, (m_char)
    call to_upper
    ld (m_uc), a
    ld hl, (m_pos)
    call peek
    call to_upper
    ld hl, m_uc
    cp (hl)
    jr nz, .no
.same:
    ld hl, (m_ptr)
    inc hl
    ld (m_ptr), hl
    ld hl, (m_pos)
    inc hl
    ld (m_pos), hl
    jr .mloop
.yes:
    scf
    ret
.no:
    or a
    ret

replace_current:
    ld de, find_buf
    call str_len
    ld (needle_len), hl
    ld a, h
    or l
    ret z
    ld de, repl_buf
    call str_len
    ld (repl_len), hl
    ; delete the match
    ld hl, (cur_pos)
    ld (rep_pos), hl
    ld b, 0
    ld a, (needle_len)
    ld b, a
.del:
    ld a, b
    or a
    jr z, .ins_start
    push bc
    ld hl, (rep_pos)
    ld (cur_pos), hl
    call buffer_delete
    pop bc
    djnz .del
.ins_start:
    ld hl, (rep_pos)
    ld (cur_pos), hl
    ld hl, repl_buf
    ld (rep_ptr), hl
.ins:
    ld hl, (rep_ptr)
    ld a, (hl)
    or a
    jr z, .done
    push af
    ld hl, (cur_pos)
    call buffer_insert
    pop af
    ld hl, (cur_pos)
    inc hl
    ld (cur_pos), hl
    ld hl, (rep_ptr)
    inc hl
    ld (rep_ptr), hl
    jr .ins
.done:
    call recompute_col
    ld a, 1
    ld (modified), a
    xor a
    ld (undo_type), a
    ret

; ==========================================================================
; Help trigger
; ==========================================================================
poll_extend_hold:
    ld a, (in_prompt)
    or a
    ret nz
    ld a, (hold_armed)
    or a
    ret z
    call extend_held
    jr nc, .released
    ld hl, (ext_tick)
    ld a, h
    or l
    jr nz, .check
    ld hl, (ISR_TICK)
    ld (ext_tick), hl
    ret
.check:
    ld hl, (ISR_TICK)
    ld de, (ext_tick)
    or a
    sbc hl, de
    ld de, 50
    call cmp16
    ret c
    ld hl, 0
    ld (ext_tick), hl
    xor a
    ld (hold_armed), a
    jp show_help
.released:
    ld hl, 0
    ld (ext_tick), hl
    ld a, 1
    ld (hold_armed), a
    ret

extend_held:
    ld bc, 0xFEFE
    in a, (c)
    bit 0, a
    jr nz, .no
    ld bc, 0x7FFE
    in a, (c)
    bit 1, a
    jr nz, .no
    scf
    ret
.no:
    or a
    ret

wait_extend_release:
.loop:
    call extend_held
    ret nc
    call drain_tokens
    jr .loop

drain_tokens:
    ld b, 16
.loop:
    push bc
    ld hl, 0x00DA
    ld (userf_dw), hl
    call userf_trampoline
    pop bc
    jr nc, .done
    djnz .loop
.done:
    ret

; ==========================================================================
; Key mapping
; ==========================================================================
; map_key - A = raw key, E = shift -> A = character (0 = none)
map_key:
    cp 40
    ret nc
    push hl
    push de
    ld l, a
    ld h, 0
    ld a, e
    and 3
    cp 3
    jr z, .ctrl
    cp 2
    jr z, .sym
    cp 1
    jr z, .caps
    ld de, key_noshift
    add hl, de
    ld a, (hl)
    jr .done
.caps:
    ld de, key_caps
    add hl, de
    ld a, (hl)
    jr .done
.sym:
    ld de, key_sym
    add hl, de
    ld a, (hl)
    jr .done
.ctrl:
    ld a, l
    cp 5
    jr c, .ctrl_letter
    cp 10
    jr c, .ctrl_sym
    cp 28
    jr c, .ctrl_letter
    cp 30
    jr nc, .ctrl_letter
.ctrl_sym:
    ld de, key_sym
    add hl, de
    ld a, (hl)
    jr .done
.ctrl_letter:
    ld de, key_noshift
    add hl, de
    ld a, (hl)
    cp 'a'
    jr c, .not_letter
    cp 'z' + 1
    jr nc, .not_letter
    and 0x1F
    jr .done
.not_letter:
    cp ' '
    jr nz, .none
    ld a, 0x03
    jr .done
.none:
    xor a
.done:
    pop de
    pop hl
    ret

; ==========================================================================
; Console and utility
; ==========================================================================
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

puts:
    ld a, (de)
    or a
    ret z
    push de
    call putc
    pop de
    inc de
    jr puts

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

clear_screen:
    ld a, ESC
    call putc
    ld a, 'H'
    call putc
    ld a, ESC
    call putc
    ld a, 'E'
    jp putc

strcpy:
    ld a, (hl)
    ld (de), a
    or a
    ret z
    inc hl
    inc de
    jr strcpy

str_len:
    ld hl, 0
.loop:
    ld a, (de)
    or a
    ret z
    inc hl
    inc de
    jr .loop

read_width:
    ld de, scb_width_pb
    ld c, F_SCB
    call BDOS
    inc a
    cp 32
    jr z, .ok
    cp 51
    jr z, .ok
    cp 64
    jr z, .ok
    cp 80
    jr z, .ok
    ld a, 51
.ok:
    ld (cols), a
    dec a
    ld (text_cols), a
    ret

restore_terminal:
    ld a, ESC
    call putc
    ld a, 'v'
    call putc
    call clear_screen
    ld de, 0x0080
    ld c, F_SETDMA
    jp BDOS
    ret

userf_trampoline:
    call 0
userf_dw:
    dw 0
    ret

; ==========================================================================
; Data
; ==========================================================================
cols:        db 51
text_cols:   db 50
have_name:   db 0
modified:    db 0
mode_ins:    db 1
show_ws:     db 0
wrap_mode:   db 0
eof_z:       db 0
structural:  db 0
in_prompt:   db 0
case_sens:   db 1
ext_tick:    dw 0
hold_armed:  db 1
msg_active:  db 0
allow_new:   db 0
key_shift:   db 0
key_raw:     db 0
edit_char:   db 0
undo_type:   db 0
undo_char:   db 0
undo_old:    db 0
undo_pos:    dw 0
len:         dw 0
gap_start:   dw BUF_START
gap_end:     dw BUF_END
cur_pos:     dw 0
cur_line:    dw 0
cur_col:     dw 0
line_start:  dw 0
top_line:    dw 0
top_pos:     dw 0
top_seg:     db 0
left_col:    dw 0
want_col:    dw 0
work_pos:    dw 0
move_target: dw 0
del_pos:     dw 0
new_pos:     dw 0
join_old_start: dw 0
draw_pos:    dw 0
draw_row:    db 0
draw_seg:    db 0
draw_done:   db 0
r_row:       db 0
r_pos:       dw 0
r_end:       dw 0
r_q:         dw 0
r_start_col: dw 0
r_col:       dw 0
r_out:       dw 0
r_width:     dw 0
r_tabend:    dw 0
stat_len:    db 0
stat_target: db 0
dec_val:     dw 0
dec_div:     dw 0
dec_started: db 0
prompt_ptr:  dw 0
prompt_alt:  dw 0
prompt_buf_ptr: dw 0
prompt_w:    db 0
prompt_len:  db 0
prompt_max:  db 0
save_pos:    dw 0
search_start: dw 0
srch_pos:    dw 0
needle_len:  dw 0
repl_len:    dw 0
rep_pos:     dw 0
rep_ptr:     dw 0
m_ptr:       dw 0
m_pos:       dw 0
m_char:      db 0
m_uc:        db 0
h_row:       db 0
h_top:       db 0
h_left:      db 0
h_width:     db 0
help_ptr:    dw 0
parse_src:   dw 0
cf_pos:      dw 0
cf_end:      dw 0
cf_col:      dw 0
le_pos:      dw 0
pls_p:       dw 0
ls_start:    dw 0
mtw_pos:     dw 0
mtw_col:     dw 0
sync_target: dw 0
sync_pos:    dw 0
sync_line:   dw 0
ccr_pos:     dw 0
ccr_line:    dw 0
ccr_sum:     dw 0
rcr_pos:     dw 0
rcr_line:    dw 0
rcr_sum:     dw 0
rcr_row:     db 0
rcr_seg:     db 0
rcr_segs:    db 0
pc_row:      db 0
pc_col:      db 0
ev_count:    db 0

file_fcb:    ds 36
work_fcb:    ds 36
target_fcb:  ds 36
rename_fcb:  ds 36
check_fcb:   ds 36
temp_fcb_template:
    db 0, '$$$$$$$', 'TMP'
    ds 25
file_disp:   ds 24
msg_text:    ds 64
stat_buf:    ds 82
name_buf:    ds 82
find_buf:    ds 82
repl_buf:    ds 82
iobuf:       ds 128

scb_width_pb: db 0x1A, 0, 0, 0

str_noname:  db '[No Name]', 0
str_ins:     db ' INS', 0
str_ovr:     db ' OVR', 0
str_wrap:    db ' WRAP', 0
str_ws:      db ' WS', 0
str_extend:  db 'EXTEND', 0

msg_open:    db 'Open: ', 0
msg_saveas:  db 'Save as: ', 0
msg_find_a:  db 'Find[Aa]: ', 0
msg_find_i:  db 'Find[aa]: ', 0
msg_repl_a:  db 'Repl[Aa]: ', 0
msg_repl_i:  db 'Repl[aa]: ', 0
msg_saveq:   db 'Save changes? (Y/N/C)', 0
msg_replaceq: db 'Replace? (Y/N/A/Q)', 0
msg_saved:   db 'Saved.', 0
msg_nofile:  db 'No file', 0
msg_full:    db 'Buffer full', 0
msg_writeerr: db 'Write error', 0
msg_renameerr: db 'Rename error', 0
msg_notfound: db 'Not found', 0
msg_helpstat: db 'Press any key to close', 0

help1:  db 'EXTEND commands', 0
help2:  db 'O Open    S Save', 0
help3:  db 'N New     Q Quit', 0
help4:  db 'F Find    R Repl', 0
help5:  db 'V Ws      W Wrap', 0
help6:  db 'I Ins     Z Undo', 0
help7:  db 'D Del     L Redraw', 0
help8:  db 'H Help', 0
help9:  db 'Arrows CAPS+5/6/7/8', 0
help10: db 'Any key closes', 0

help_table:
    dw help1, help2, help3, help4, help5
    dw help6, help7, help8, help9, help10

; EXTEND command table, indexed by raw key
extend_table:
    db 0, 12, 0, 0, 7           ; CS Z X C V
    db 0, 2, 13, 5, 0           ; A S D F G
    db 4, 8, 0, 6, 0            ; Q W E R T
    db 0, 0, 0, 0, 0            ; 1 2 3 4 5
    db 0, 0, 0, 0, 0            ; 0 9 8 7 6
    db 0, 1, 9, 0, 0            ; P O I U Y
    db 0, 10, 0, 0, 11          ; Ent L K J H
    db 0, 0, 0, 3, 0            ; Sp SS M N B

key_noshift:
    db 0, 'z', 'x', 'c', 'v'
    db 'a', 's', 'd', 'f', 'g'
    db 'q', 'w', 'e', 'r', 't'
    db '1', '2', '3', '4', '5'
    db '0', '9', '8', '7', '6'
    db 'p', 'o', 'i', 'u', 'y'
    db 0x0D, 'l', 'k', 'j', 'h'
    db ' ', 0, 'm', 'n', 'b'
key_caps:
    db 0, 'Z', 'X', 'C', 'V'
    db 'A', 'S', 'D', 'F', 'G'
    db 'Q', 'W', 'E', 'R', 'T'
    db 0x17, 0, 0x13, 0x09, 0x01
    db 0x08, 0x07, 0x06, 0x1F, 0x1E
    db 'P', 'O', 'I', 'U', 'Y'
    db 0x0D, 'L', 'K', 'J', 'H'
    db 0x1B, 0, 'M', 'N', 'B'
key_sym:
    db 0, ':', 0, '?', '/'
    db '~', '|', 0x5C, '{', '}'
    db '`', 0, 0, '<', '>'
    db '!', '@', '#', '$', '%'
    db '_', ')', '(', 0x27, '&'
    db '"', ';', 0, ']', '['
    db 0, '=', '+', '-', '^'
    db ' ', 0, '.', ',', '*'

    assert $ <= BUF_START, "EDIT.COM code+data overruns the gap buffer"

    end
