; SUBMIT.COM - Create a $$$.SUB command file for the MiniCCP
;
; Usage:
;   SUBMIT filename[.SUB]
;   filename            (when SETDEF [ORDER=(COM,SUB)] finds a .SUB file)
;
; CP/M 3's DRI SUBMIT uses a SYSINnn.$$$ redirect file that a CP/M 3 CCP
; consumes through console redirection.  MiniCCP instead drains the CP/M 2.2
; $$$.SUB format, so this clean-room SUBMIT writes that format directly:
; each record is <length>, <command text>, 0; records are stored in reverse
; order and the CCP reads them from the last record backwards.
;
; SUB files may use $1..$9 parameter substitution.  Nested SUBMIT is not
; implemented; it is rejected rather than overwriting the queue the CCP is
; draining.  $0 is left literal.
;
; Build: sjasmplus --raw=build/submit.com src/tools/submit.asm

    ORG 0x0100

BDOS        equ 0x0005

F_PRINT     equ 9
F_OPEN     equ 15
F_CLOSE    equ 16
F_DELETE   equ 19
F_READ     equ 20
F_MAKE     equ 22
F_SETDMA   equ 26
F_WRITE_R  equ 40

CR          equ 13
LF          equ 10
EOF_MARK    equ 0x1A

IN_BUF      equ 0x2000
IN_MAX      equ 0x4000
STACK_TOP   equ 0x1E00

    ld sp, STACK_TOP

    ; The CCP leaves the first command-tail token as an FCB at 005C.
    ; Require a non-blank filename.
    ld hl, 0x005D
    ld b, 11
.check_name:
    ld a, (hl)
    cp ' '
    jr nz, .have_name
    inc hl
    djnz .check_name
    jp usage

.have_name:
    ; Assume .SUB when the command line did not give an extension.
    ld hl, 0x0065
    ld a, (hl)
    cp ' '
    jr nz, .parse_args
    ld (hl), 'S'
    inc hl
    ld (hl), 'U'
    inc hl
    ld (hl), 'B'

.parse_args:
    call parse_args

.check_active:
    ; A nested SUBMIT would overwrite the queue the CCP is draining.
    ld de, out_fcb
    ld c, F_OPEN
    call BDOS
    cp 0xFF
    jr z, .open_input
    ld de, out_fcb
    ld c, F_CLOSE
    call BDOS
    ld de, msg_active
    jp fail

.open_input:
    ld de, 0x005C
    ld c, F_OPEN
    call BDOS
    cp 0xFF
    jp z, no_sub

    call read_input
    jp c, too_big

    ; Close the input before creating the output.
    ld de, 0x005C
    ld c, F_CLOSE
    call BDOS

    call count_lines
    ld hl, (total)
    ld a, h
    or l
    jr z, done

    ; Remove a stale $$$.SUB, then create the new one.
    ld de, out_fcb
    ld c, F_DELETE
    call BDOS
    ld de, out_fcb
    ld c, F_MAKE
    call BDOS
    cp 0xFF
    jp z, directory_full

    call write_lines

    ld de, out_fcb
    ld c, F_CLOSE
    call BDOS

done:
    xor a
    rst 0

; ---------------------------------------------------------------------------
; read_input - Read the whole input file into IN_BUF.
;   In:       nothing (005C FCB is open)
;   Out:      in_end = first byte after the data
;   Out:      F carry set on overflow
;   Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
read_input:
    ld hl, IN_BUF
    ld (in_end), hl
.read_loop:
    ld de, (in_end)
    ld c, F_SETDMA
    call BDOS
    ld de, 0x005C
    ld c, F_READ
    call BDOS
    or a
    jr nz, .finished

    ld hl, (in_end)
    ld de, 128
    add hl, de
    ld (in_end), hl

    ld de, IN_BUF + IN_MAX
    ld a, h
    cp d
    jr c, .read_loop
    jr nz, .overflow
    ld a, l
    cp e
    jr nc, .overflow
    jr .read_loop

.finished:
    or a
    ret
.overflow:
    scf
    ret

; ---------------------------------------------------------------------------
; parse_args - Collect up to 9 command-tail arguments after the filename.
;   In:       command tail at 0080h (length byte + text)
;   Out:      arg_tab entries {pointer, length}; pointer 0 = unused
;   Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
parse_args:
    ; Clear all nine 3-byte entries.
    ld hl, arg_tab
    ld (hl), 0
    ld d, h
    ld e, l
    inc de
    ld bc, 26
    ldir

    ld hl, 0x0081
    ld a, (0x0080)
    ld b, a
.skip_leading:
    ld a, b
    or a
    ret z
    ld a, (hl)
    cp ' '
    jr nz, .skip_name
    inc hl
    dec b
    jr .skip_leading

.skip_name:
    ld a, b
    or a
    ret z
    ld a, (hl)
    cp ' '
    jr z, .next_arg
    inc hl
    dec b
    jr .skip_name

.next_arg:
    ld de, arg_tab
    ld c, 9
.find_slot:
    ld a, (de)
    or a
    jr z, .slot
    inc de
    inc de
    inc de
    dec c
    ret z
    jr .find_slot

.slot:
.skip_spaces:
    ld a, b
    or a
    ret z
    ld a, (hl)
    cp ' '
    jr nz, .start
    inc hl
    dec b
    jr .skip_spaces

.start:
    ld a, l
    ld (de), a
    inc de
    ld a, h
    ld (de), a
    inc de
    push de
    ld c, 0
.scan:
    ld a, b
    or a
    jr z, .done
    ld a, (hl)
    cp ' '
    jr z, .done
    inc hl
    dec b
    inc c
    jr .scan
.done:
    ld a, c
    ld (de), a
    pop de
    jr .next_arg

; ---------------------------------------------------------------------------
; count_lines - Count non-empty command lines in IN_BUF.
;   Out:      total = number of lines
;   Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
count_lines:
    ld hl, 0
    ld (total), hl
    ld hl, IN_BUF
    ld de, (in_end)
    ld b, 0
.loop:
    ld a, h
    cp d
    jr nz, .read_byte
    ld a, l
    cp e
    jr z, .finish
.read_byte:
    ld a, (hl)
    cp EOF_MARK
    jr z, .finish
    cp CR
    jr z, .separator
    cp LF
    jr z, .separator
    inc b
    inc hl
    jr .loop
.separator:
    ld a, b
    or a
    jr z, .skip_sep
    call inc_total
.skip_sep:
    ld b, 0
    inc hl
    jr .loop
.finish:
    ld a, b
    or a
    ret z
    call inc_total
    ret

; ---------------------------------------------------------------------------
; inc_total - total = total + 1, preserving the scan registers.
;   In:       nothing
;   Out:      total incremented
;   Clobbers: none
; ---------------------------------------------------------------------------
inc_total:
    push af
    push hl
    ld hl, (total)
    inc hl
    ld (total), hl
    pop hl
    pop af
    ret

; ---------------------------------------------------------------------------
; write_lines - Store each command line in $$$.SUB, last line first.
;   In:       total = line count
;   Out:      $$$.SUB written
;   Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
write_lines:
    ld hl, IN_BUF
    ld de, (in_end)
    ld (line_start), hl
    push hl
    ld hl, 0
    ld (line_no), hl
    pop hl
    ld b, 0
.loop:
    ld a, h
    cp d
    jr nz, .read_byte
    ld a, l
    cp e
    jr z, .finish
.read_byte:
    ld a, (hl)
    cp EOF_MARK
    jr z, .finish
    cp CR
    jr z, .separator
    cp LF
    jr z, .separator
    inc b
    inc hl
    jr .loop
.separator:
    ld a, b
    or a
    jr z, .skip_sep
    push hl
    push de
    ld (line_len), a
    call emit_line
    pop de
    pop hl
.skip_sep:
    inc hl
    ld (line_start), hl
    ld b, 0
    jr .loop
.finish:
    ld a, b
    or a
    ret z
    ld (line_len), a
    call emit_line
    ret

; ---------------------------------------------------------------------------
; append_char - Append A to out_rec, enforcing the 126-character limit.
;   In:       A = character
;   Out:      out_len/rec_ptr advanced
;   Clobbers: AF, HL (BC and DE preserved)
; ---------------------------------------------------------------------------
append_char:
    ld (append_tmp), a
    push de
    ld hl, (rec_ptr)
    ld de, out_rec + 127
    ld a, h
    cp d
    jr c, .room
    jr nz, .full
    ld a, l
    cp e
    jr nc, .full
.room:
    ld a, (append_tmp)
    ld (hl), a
    inc hl
    ld (rec_ptr), hl
    ld a, (out_len)
    inc a
    ld (out_len), a
    pop de
    ret
.full:
    pop de
    jp line_too_long

; ---------------------------------------------------------------------------
; emit_line - Write one command record at the reverse index.
;   In:       line_start/line_len describe the line, line_no is its index
;   Out:      $$$.SUB record written, line_no incremented
;   Clobbers: AF, BC, DE, HL
; ---------------------------------------------------------------------------
emit_line:
    ; Zero the 128-byte record buffer.
    ld hl, out_rec
    ld (hl), 0
    ld d, h
    ld e, l
    inc de
    ld bc, 127
    ldir

    ; Substitute $1..$9 while building the record.
    ld hl, (line_start)
    ld (scan_ptr), hl
    ld a, (line_len)
    ld (scan_len), a
    ld hl, out_rec + 1
    ld (rec_ptr), hl
    xor a
    ld (out_len), a

.loop:
    ld a, (scan_len)
    or a
    jr z, .built
    dec a
    ld (scan_len), a
    ld hl, (scan_ptr)
    ld a, (hl)
    inc hl
    ld (scan_ptr), hl
    cp '$'
    jr nz, .append

    ld a, (scan_len)
    or a
    jr z, .dollar
    ld hl, (scan_ptr)
    ld a, (hl)
    sub '1'
    jr c, .dollar
    cp 9
    jr nc, .dollar

    ; A = argument index 0..8; each entry is pointer (2 bytes) + length.
    ld hl, arg_tab
    ld e, a
    ld d, 0
    add hl, de
    add hl, de
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    inc hl
    ld a, (hl)
    or a
    jp z, missing_param
    ld b, a                    ; B = argument length

    ; Consume the digit after '$'.
    ld hl, (scan_ptr)
    inc hl
    ld (scan_ptr), hl
    ld a, (scan_len)
    dec a
    ld (scan_len), a

.copy_arg:
    ld a, (de)
    inc de
    call append_char
    dec b
    jr nz, .copy_arg
    jr .loop

.dollar:
    ld a, '$'
.append:
    call append_char
    jr .loop

.built:
    ld a, (out_len)
    ld (out_rec), a
    ld hl, (rec_ptr)
    ld (hl), 0

    ld de, out_rec
    ld c, F_SETDMA
    call BDOS

    ; Random record = total - 1 - line_no.
    ld hl, (total)
    dec hl
    ld de, (line_no)
    or a
    sbc hl, de
    ld a, l
    ld (out_fcb + 33), a
    ld a, h
    ld (out_fcb + 34), a
    xor a
    ld (out_fcb + 35), a

    ld de, out_fcb
    ld c, F_WRITE_R
    call BDOS
    or a
    jp nz, write_error

    ld hl, (line_no)
    inc hl
    ld (line_no), hl
    ret

; ---------------------------------------------------------------------------
; Small exits.  All print a message and warm-boot back to the CCP.
; ---------------------------------------------------------------------------
usage:
    ld de, msg_usage
    jp fail
no_sub:
    ld de, msg_nofile
    jp fail
too_big:
    ld de, msg_toobig
    jp fail
directory_full:
    ld de, msg_dirfull
    jp fail
line_too_long:
    ld de, msg_toolong
    jr abort_output
missing_param:
    ld de, msg_param
    jr abort_output
write_error:
    ld de, msg_write
    jr abort_output

; abort_output - Close and delete the partially written $$$.SUB, then print
;   the message in DE and warm-boot.
;   In:       DE = message
;   Out:      does not return
;   Clobbers: AF, BC, DE, HL
abort_output:
    push de
    ld de, out_fcb
    ld c, F_CLOSE
    call BDOS
    ld de, out_fcb
    ld c, F_DELETE
    call BDOS
    pop de
    jr fail

fail:
    ld c, F_PRINT
    call BDOS
    rst 0

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------
total:      dw 0
line_no:    dw 0
line_start: dw 0
line_len:   db 0
in_end:     dw 0

arg_tab:    ds 27
scan_ptr:   dw 0
scan_len:   db 0
rec_ptr:    dw 0
out_len:    db 0
append_tmp: db 0

out_fcb:
    db 0
    db "$$$     SUB"
    ds 24

out_rec:    ds 128

msg_usage:   db "Usage: SUBMIT file", CR, LF, "$"
msg_nofile:  db "No 'SUB' File Found", CR, LF, "$"
msg_active:  db "SUBMIT already active", CR, LF, "$"
msg_toobig:  db "SUBMIT file too large", CR, LF, "$"
msg_dirfull: db "Directory Full", CR, LF, "$"
msg_toolong: db "SUBMIT line too long", CR, LF, "$"
msg_param:   db "SUBMIT parameter missing", CR, LF, "$"
msg_write:   db "SUBMIT write error", CR, LF, "$"
