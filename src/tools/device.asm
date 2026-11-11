; DEVICE.COM - show and assign the CP/M 3 character devices
;
;   DEVICE                          show the devices and assignments, then ask
;   DEVICE NAMES | VALUES           the physical devices | the assignments
;   DEVICE name                     one logical or physical device
;   DEVICE logical = physical {[option]} {,physical ...}
;   DEVICE logical = NULL
;   DEVICE physical [option]        set a physical device's protocol and speed
;   DEVICE CONSOLE [PAGE | COLUMNS=n | LINES=n]
;
; Logical devices are CONIN: CONOUT: AUXIN: AUXOUT: LST: (also CON: CONSOLE:
; KEYBOARD AUX: AUXILIARY: PRINTER).  The physical devices come from the
; BIOS character device table (function 20, DEVTBL); an assignment writes the
; matching SCB redirection vector (one bit per table entry, bit 15 = entry 0)
; through BDOS function 49.
;
; This BIOS acts on the LST and AUX vectors only (an unassigned device is a
; sink).  Console input and output always use the keyboard and screen, so
; CONIN: and CONOUT: accept only CON.  None of the physical devices is a
; serial port, so XON/NOXON and baud options are refused.
;
; Build: sjasmplus --raw=build/device.com src/tools/device.asm

    org 0x0100

BDOS            equ 0x0005
F_COUT          equ 2
F_PSTR          equ 9
F_RDBUF         equ 10
F_SCB           equ 49
F_BIOS          equ 50

TAIL            equ 0x0080

SCB_CONWIDTH    equ 0x1A
SCB_CONPAGE     equ 0x1C
SCB_CIVEC       equ 0x22           ; word each: CONIN, CONOUT, AUXIN, AUXOUT, LST

MODE_IN         equ 0x01
MODE_OUT        equ 0x02
MODE_SERIAL     equ 0x08
MODE_XON        equ 0x10

; Logical device bits in a logical-name mask.
L_CONIN         equ 0x01
L_CONOUT        equ 0x02
L_AUXIN         equ 0x04
L_AUXOUT        equ 0x08
L_LST           equ 0x10

ENTRY_SIZE      equ 8              ; name(6), mode, baud code
MAX_DEV         equ 16

; ==========================================================================
; Entry
; ==========================================================================
start:
    ld de, pb_devtbl
    ld c, F_BIOS
    call BDOS                  ; HL = character device table
    ld (devtbl), hl
    ld b, 0
.count:
    ld a, (hl)
    or a
    jr z, .counted
    ld de, ENTRY_SIZE
    add hl, de
    inc b
    ld a, b
    cp MAX_DEV
    jr c, .count
.counted:
    ld a, b
    ld (ndev), a

    ld hl, TAIL + 1
    call skip_spaces
    ld a, (hl)
    or a
    jr z, interactive
    cp 0x0D
    jr z, interactive
    jp process_line

; interactive - the bare DEVICE command: show everything, ask for a line
interactive:
    ld de, msg_phys
    call pstr
    call print_names
    ld de, msg_assign
    call pstr
    call print_values
    ld de, msg_enter
    call pstr
    ld de, linebuf
    ld c, F_RDBUF
    call BDOS
    call crlf
    ld a, (linebuf + 1)
    or a
    ret z                      ; just RETURN: nothing to change
    ld e, a
    ld d, 0
    ld hl, linebuf + 2
    add hl, de
    ld (hl), 0                 ; terminate what was typed
    ld hl, linebuf + 2
    jp process_line

; ==========================================================================
; process_line - one command (from the tail or the prompt)
;   In:       HL = text, NUL or CR terminated
;   Clobbers: AF, BC, DE, HL (errors end the program)
; ==========================================================================
process_line:
    call skip_spaces
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    call read_word             ; the first word
    jp c, err_syntax
    call skip_colon
    call skip_spaces
    ld a, (hl)
    cp '='
    jp z, assign

    ld (line_ptr), hl
    ld de, str_names
    call word_is
    jp z, print_names
    ld de, str_values
    call word_is
    jp z, print_values
    ld de, str_console
    call word_is
    jp z, console

    ; A logical device (CON, LST, ...) shows its assignment; a physical one
    ; shows its attributes or takes new ones.  CON, LST and AUX name both, so
    ; an option list ("DEVICE LST [XON]") means the physical device.
    ld hl, (line_ptr)
    call skip_spaces
    ld a, (hl)
    cp '['
    jr z, .physical
    call find_logical          ; A = mask, 0 = none
    or a
    jr z, .physical
    jp show_logical
.physical:
    call find_physical         ; A = index, carry = none
    jp c, err_device
    ld (cur_dev), a
    ld hl, (line_ptr)
    call skip_spaces
    ld a, (hl)
    cp '['
    jr nz, .show
    jp err_serial              ; DEVICE physical [options]: none can be set
.show:
    ld a, (cur_dev)
    jp print_phys_line

; ==========================================================================
; DEVICE logical = physical {, physical} / NULL
;   In:       HL at the '='; word holds the logical name
; ==========================================================================
assign:
    inc hl                     ; past '='
    ld (line_ptr), hl
    call find_logical
    or a
    jp z, err_device
    ld (target_mask), a
    ld hl, 0
    ld (new_vec), hl

    ld hl, (line_ptr)
.item:
    call skip_spaces
    call read_word
    jp c, err_syntax
    ld (line_ptr), hl
    ld de, str_null
    call word_is
    jr z, .null
    call find_physical
    jp c, err_device
    ld (cur_dev), a
    call device_bit            ; HL = mask of the device
    ld de, (new_vec)
    ld a, d
    or h
    ld d, a
    ld a, e
    or l
    ld e, a
    ld (new_vec), de
    ld hl, (line_ptr)
    call skip_spaces
    ld a, (hl)
    cp '['
    jp z, err_serial           ; options need a serial device
    jr .more
.null:
    ld hl, (line_ptr)
.more:
    call skip_spaces
    ld a, (hl)
    cp ','
    jr nz, .listed
    inc hl
    jr .item
.listed:
    or a
    jr z, .apply
    cp 0x0D
    jp nz, err_syntax

.apply:
    ; Every device in the list must suit each logical device it feeds, and
    ; the console is not redirectable here.
    ld a, (target_mask)
    ld b, a
    ld c, 0                    ; C = logical bit index
.check:
    ld a, b
    rrca
    ld b, a
    jr nc, .skip_check
    push bc
    call check_vector          ; C = index; exits with an error if unsuitable
    pop bc
.skip_check:
    inc c
    ld a, c
    cp 5
    jr c, .check

    ld a, (target_mask)
    ld b, a
    ld c, 0
.write:
    ld a, b
    rrca
    ld b, a
    jr nc, .skip_write
    push bc
    ld a, c
    add a, a
    add a, SCB_CIVEC
    ld (pb_set), a             ; offset
    ld hl, (new_vec)
    ld (pb_set + 2), hl
    ld de, pb_set
    ld c, F_SCB
    call BDOS
    pop bc
.skip_write:
    inc c
    ld a, c
    cp 5
    jr c, .write
    ret

; check_vector - may the devices in new_vec feed logical device C?
;   In:       C = logical index 0-4 (CONIN, CONOUT, AUXIN, AUXOUT, LST)
;   Clobbers: AF, BC, DE, HL (an unsuitable device ends the program)
check_vector:
    ld a, c
    cp 2
    jr nc, .devices
    ld hl, (new_vec)           ; CONIN / CONOUT: only CON (entry 0)
    ld de, 0x8000
    xor a
    sbc hl, de
    jp nz, err_console
.devices:
    ; Direction needed: input for CONIN and AUXIN, output for the rest.
    ld a, c
    or a
    jr z, .in
    cp 2
    jr z, .in
    ld a, MODE_OUT
    jr .go
.in:
    ld a, MODE_IN
.go:
    ld (need_mode), a
    ld hl, (new_vec)
    ld (vec), hl
    xor a
    ld (cur_dev), a
.dev:
    ld a, (ndev)
    ld b, a
    ld a, (cur_dev)
    cp b
    ret nc
    ld hl, (vec)
    add hl, hl                 ; carry = this entry is in the vector
    ld (vec), hl
    jr nc, .next
    ld a, (cur_dev)
    call entry_addr
    ld de, 6
    add hl, de
    ld a, (need_mode)
    and (hl)
    jp z, err_direction
.next:
    ld a, (cur_dev)
    inc a
    ld (cur_dev), a
    jr .dev

; device_bit - mask of one physical device
;   In:       cur_dev
;   Out:      HL = 0x8000 >> index
;   Clobbers: AF, B, HL
device_bit:
    ld hl, 0x8000
    ld a, (cur_dev)
    or a
    ret z
    ld b, a
.sh:
    srl h
    rr l
    djnz .sh
    ret

; ==========================================================================
; DEVICE CONSOLE [PAGE | COLUMNS=n | LINES=n]
;   In:       line_ptr after the word CONSOLE
; ==========================================================================
console:
    ld hl, (line_ptr)
    call skip_spaces
    ld a, (hl)
    cp '['
    jp nz, show_console
    inc hl
.next:
    call skip_seps
    ld a, (hl)
    cp ']'
    ret z
    or a
    ret z
    cp 0x0D
    ret z
    call read_word
    jp c, err_syntax
    ld (line_ptr), hl
    ld a, (word)
    cp 'P'
    jr z, .page
    cp 'C'
    jr z, .columns
    cp 'L'
    jp nz, err_syntax
    ; LINES=n
    ld hl, (line_ptr)
    call skip_eq
    call parse_dec
    jp c, err_syntax
    ld a, d
    or a
    jp nz, err_lines
    ld a, e
    cp 4
    jp c, err_lines
    cp 25
    jp nc, err_lines
    dec a
    ld (pb_page + 2), a
    ld (line_ptr), hl
    ld de, pb_page
    ld c, F_SCB
    call BDOS
    ld hl, (line_ptr)
    jr .next
.columns:
    ld hl, (line_ptr)
    call skip_eq
    call parse_dec
    jp c, err_syntax
    ld (line_ptr), hl
    ld a, d
    or a
    jp nz, err_columns
    ld a, e
    cp 32
    jr z, .set_cols
    cp 51
    jr z, .set_cols
    cp 64
    jp nz, err_columns
.set_cols:
    ld (pb_screen + 1), a
    ld de, pb_screen
    ld c, F_BIOS
    call BDOS                  ; function 32 clears the screen
    ld hl, (line_ptr)
    jp .next
.page:
    ld hl, (line_ptr)
    call show_console
    ld hl, (line_ptr)
    jp .next

; show_console - the console width and page length
;   Clobbers: AF, BC, DE, HL
show_console:
    ld de, msg_width
    call pstr
    ld de, pb_get_width
    ld c, F_SCB
    call BDOS
    inc a
    ld l, a
    ld h, 0
    ld bc, 0x0020
    call print_dec
    call crlf
    ld de, msg_length
    call pstr
    ld de, pb_get_page
    ld c, F_SCB
    call BDOS
    inc a
    ld l, a
    ld h, 0
    ld bc, 0x0020
    call print_dec
    jp crlf

; ==========================================================================
; Display
; ==========================================================================
; print_names - every physical device with its speed and attributes
;   Clobbers: AF, BC, DE, HL
print_names:
    xor a
    ld (cur_dev), a
.loop:
    ld a, (ndev)
    ld b, a
    ld a, (cur_dev)
    cp b
    jr nc, .done
    call print_phys_line
    ld a, (cur_dev)
    inc a
    ld (cur_dev), a
    jr .loop
.done:
    jp crlf

; print_phys_line - "NAME    9600 IOS": name, speed, attributes
;   In:       A = device index
;   Clobbers: AF, BC, DE, HL
print_phys_line:
    ld (cur_dev), a
    call entry_addr
    ld (ent_ptr), hl
    ld b, 6
    call print_chars           ; the six name characters, blanks and all
    ld a, ' '
    call cout
    ld hl, (ent_ptr)
    ld de, 7
    add hl, de
    ld a, (hl)                 ; baud code
    call print_baud
    ld a, ' '
    call cout
    ld hl, (ent_ptr)
    ld de, 6
    add hl, de
    ld a, (hl)                 ; mode
    ld (mode_tmp), a
    and MODE_IN
    ld a, 'I'
    call nz, cout
    ld a, (mode_tmp)
    and MODE_OUT
    ld a, 'O'
    call nz, cout
    ld a, (mode_tmp)
    and MODE_SERIAL
    ld a, 'S'
    call nz, cout
    ld a, (mode_tmp)
    and MODE_XON
    ld a, 'X'
    call nz, cout
    jp crlf

; print_baud - the speed for a baud code, right-aligned in five columns
;   In:       A = code 0-15 (0 = NONE)
;   Clobbers: AF, BC, DE, HL
print_baud:
    or a
    jr nz, .rate
    ld de, str_none
    jp pstr
.rate:
    cp 16
    jr c, .ok
    xor a
.ok:
    add a, a
    ld e, a
    ld d, 0
    ld hl, baud_table
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ld bc, 0x0520
    jp print_dec

; print_chars - B characters at HL
;   In:       HL = text, B = count
;   Clobbers: AF, BC, DE, HL
print_chars:
    ld a, (hl)
    inc hl
    push hl
    push bc
    call cout
    pop bc
    pop hl
    djnz print_chars
    ret

; print_values - the five logical devices and what feeds them
;   Clobbers: AF, BC, DE, HL
print_values:
    xor a
.loop:
    ld (cur_log), a
    call print_value_line
    ld a, (cur_log)
    inc a
    cp 5
    jr c, .loop
    jp crlf

; print_value_line - "CONIN:  = CON"
;   In:       A = logical index 0-4
;   Clobbers: AF, BC, DE, HL
print_value_line:
    ld (cur_log), a
    add a, a
    ld e, a
    ld d, 0
    ld hl, lname_tbl
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    push de
    call pstr
    pop hl                     ; pad the name to nine columns
    ld b, 0
.len:
    ld a, (hl)
    inc hl
    cp '$'
    jr z, .padded
    inc b
    jr .len
.padded:
    ld a, 9
    sub b
    jr z, .eq
    jr c, .eq
.pad:
    push af
    ld a, ' '
    call cout
    pop af
    dec a
    jr nz, .pad
.eq:
    ld de, msg_eq
    call pstr
    ld a, (cur_log)
    add a, a
    add a, SCB_CIVEC
    ld (pb_get + 0), a
    ld de, pb_get
    ld c, F_SCB
    call BDOS                  ; HL = the vector
    jp print_vector

; print_vector - the physical devices in a vector, comma-separated
;   In:       HL = vector
;   Clobbers: AF, BC, DE, HL
print_vector:
    ld (vec), hl
    ld a, h
    or l
    jr nz, .some
    ld de, str_nulldev
    call pstr
    jp crlf
.some:
    xor a
    ld (cur_dev), a
    ld (first_flag), a
.loop:
    ld a, (ndev)
    ld b, a
    ld a, (cur_dev)
    cp b
    jr nc, .done
    ld hl, (vec)
    add hl, hl                 ; carry = bit 15: this entry
    ld (vec), hl
    jr nc, .next
    ld a, (first_flag)
    or a
    jr z, .name
    ld a, ','
    call cout
.name:
    ld a, 1
    ld (first_flag), a
    ld a, (cur_dev)
    call entry_addr
    ld b, 6
.nm:
    ld a, (hl)
    cp ' '
    jr z, .next
    inc hl
    push hl
    push bc
    call cout
    pop bc
    pop hl
    djnz .nm
.next:
    ld a, (cur_dev)
    inc a
    ld (cur_dev), a
    jr .loop
.done:
    jp crlf

; show_logical - DEVICE CON / AUX / LST ...: the assignment(s)
;   In:       A = mask of logical devices
;   Clobbers: AF, BC, DE, HL
show_logical:
    ld (target_mask), a
    xor a
.loop:
    ld (cur_log), a
    ld hl, target_mask
    ld b, a
    ld a, (hl)
    inc b
.shift:
    rrca
    djnz .shift
    jr nc, .skip
    ld a, (cur_log)
    call print_value_line
.skip:
    ld a, (cur_log)
    inc a
    cp 5
    jr c, .loop
    ret

; ==========================================================================
; Table lookups
; ==========================================================================
; entry_addr - address of device table entry A
;   In:       A = index
;   Out:      HL = entry
;   Clobbers: AF, DE, HL
entry_addr:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, (devtbl)
    add hl, de
    ret

; find_physical - the device whose name is the current word
;   Out:      A = index; carry = no such device
;   Clobbers: AF, BC, DE, HL
find_physical:
    ld hl, word
    ld de, wpad
    ld b, 6
.copy:
    ld a, (hl)
    or a
    jr z, .fill
    ld (de), a
    inc hl
    inc de
    djnz .copy
    ld a, (hl)
    or a
    jr nz, .none               ; more than six characters
    jr .padded
.fill:
    ld a, ' '
.blank:
    ld (de), a
    inc de
    djnz .blank
.padded:
    xor a
    ld (cur_dev), a
.try:
    ld a, (ndev)
    ld b, a
    ld a, (cur_dev)
    cp b
    jr nc, .none
    call entry_addr
    ld de, wpad
    ld b, 6
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .next
    inc hl
    inc de
    djnz .cmp
    ld a, (cur_dev)
    or a
    ret
.next:
    ld a, (cur_dev)
    inc a
    ld (cur_dev), a
    jr .try
.none:
    scf
    ret

; find_logical - the logical device(s) named by the current word
;   Out:      A = mask of L_* bits, 0 = not a logical device name
;   Clobbers: AF, BC, DE, HL
find_logical:
    ld hl, log_table
.entry:
    ld a, (hl)
    or a
    ret z                      ; end of table: A = 0
    ld de, word
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .next
    or a
    jr z, .hit
    inc hl
    inc de
    jr .cmp
.hit:
    inc hl
    ld a, (hl)                 ; the mask follows the NUL
    ret
.next:
    ld a, (hl)
    inc hl
    or a
    jr nz, .next
    inc hl                     ; step over the mask
    jr .entry

; word_is - is the current word the string at DE
;   In:       DE = NUL-terminated upper-case string
;   Out:      Z = yes
;   Clobbers: AF, DE, HL
word_is:
    ld hl, word
.loop:
    ld a, (de)
    cp (hl)
    ret nz
    or a
    ret z
    inc hl
    inc de
    jr .loop

; ==========================================================================
; Scanning
; ==========================================================================
; read_word - copy a name (letters and digits) to word, upper case
;   In:       HL = text
;   Out:      HL after it; carry = empty or longer than 10
;   Clobbers: AF, BC, DE, HL
read_word:
    ld de, word
    ld b, 0
.loop:
    ld a, (hl)
    call upper
    cp '0'
    jr c, .end
    cp '9' + 1
    jr c, .take
    cp 'A'
    jr c, .end
    cp 'Z' + 1
    jr nc, .end
.take:
    ld (de), a
    inc de
    inc hl
    inc b
    ld a, b
    cp 11
    jr c, .loop
    scf
    ret
.end:
    xor a
    ld (de), a
    ld a, b
    or a
    jr nz, .ok
    scf
    ret
.ok:
    or a
    ret

; skip_colon - skip one ':' after a name
;   Out:      HL after it
;   Clobbers: AF
skip_colon:
    ld a, (hl)
    cp ':'
    ret nz
    inc hl
    ret

; skip_eq - skip spaces, one '=' and more spaces
;   Out:      HL = first character after them
;   Clobbers: AF
skip_eq:
    call skip_spaces
    ld a, (hl)
    cp '='
    jr nz, .done
    inc hl
.done:
    jp skip_spaces

; skip_seps - skip spaces and commas
;   Out:      HL = first other character
;   Clobbers: AF
skip_seps:
    ld a, (hl)
    cp ' '
    jr z, .step
    cp ','
    ret nz
.step:
    inc hl
    jr skip_seps

; skip_spaces - advance HL past spaces
;   Out:      HL = first non-space
;   Clobbers: AF
skip_spaces:
    ld a, (hl)
    cp ' '
    ret nz
    inc hl
    jr skip_spaces

; upper - fold a-z to A-Z
;   In:       A = character
;   Out:      A = upper-case character
;   Clobbers: F
upper:
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    and 0x5F
    ret

; parse_dec - an unsigned decimal number
;   In:       HL = text
;   Out:      DE = value, HL after the digits; carry = no digits
;   Clobbers: AF, BC, DE, HL
parse_dec:
    ld de, 0
    ld b, 0
.digit:
    ld a, (hl)
    sub '0'
    cp 10
    jr nc, .end
    ld c, a
    push hl
    ld h, d
    ld l, e
    add hl, hl
    ld d, h
    ld e, l
    add hl, hl
    add hl, hl
    add hl, de
    ld e, c
    ld d, 0
    add hl, de
    ex de, hl
    pop hl
    inc hl
    inc b
    jr .digit
.end:
    ld a, b
    or a
    jr z, .none
    or a
    ret
.none:
    scf
    ret

; ==========================================================================
; Numbers and console output
; ==========================================================================
; print_dec - right-aligned unsigned decimal
;   In:       HL = value, B = field width, C = pad character
;   Clobbers: AF, BC, DE, HL
print_dec:
    ld (pad_w), bc
    xor a
    ld (ndig), a
    ld de, numbuf
.digit:
    call div10
    add a, '0'
    ld (de), a
    inc de
    ld a, (ndig)
    inc a
    ld (ndig), a
    ld a, h
    or l
    jr nz, .digit
    ld a, (pad_w + 1)
    ld hl, ndig
    sub (hl)
    jr c, .out
    jr z, .out
.pad:
    push af
    ld a, (pad_w)
    call cout
    pop af
    dec a
    jr nz, .pad
.out:
    ld a, (ndig)
    or a
    ret z
    dec a
    ld (ndig), a
    ld e, a
    ld d, 0
    ld hl, numbuf
    add hl, de
    ld a, (hl)
    call cout
    jr .out

; div10 - HL / 10
;   In:       HL
;   Out:      HL = quotient, A = remainder
;   Clobbers: B
div10:
    ld b, 16
    xor a
.loop:
    add hl, hl
    rla
    cp 10
    jr c, .next
    sub 10
    inc l
.next:
    djnz .loop
    ret

; cout - print character A
;   In:       A = character
;   Clobbers: AF, BC, DE, HL
cout:
    ld e, a
    ld c, F_COUT
    jp BDOS

; pstr - print a '$'-terminated string
;   In:       DE = string
;   Clobbers: AF, BC, DE, HL
pstr:
    ld c, F_PSTR
    jp BDOS

; crlf - new line
;   Clobbers: AF, BC, DE, HL
crlf:
    ld de, msg_crlf
    jr pstr

; ==========================================================================
; Errors (each ends the program)
; ==========================================================================
err_syntax:
    ld de, msg_syntax
    jr fail
err_device:
    ld de, msg_device
    jr fail
err_console:
    ld de, msg_console
    jr fail
err_serial:
    ld de, msg_serial
    jr fail
err_columns:
    ld de, msg_columns
    jr fail
err_lines:
    ld de, msg_lines
    jr fail
err_direction:
    ld a, (cur_dev)
    call entry_addr
    ld b, 6
.name:
    ld a, (hl)
    cp ' '
    jr z, .named
    inc hl
    push hl
    push bc
    call cout
    pop bc
    pop hl
    djnz .name
.named:
    ld de, msg_direction
fail:
    call pstr
    rst 0

; --- Data ---
devtbl:         dw 0
ndev:           db 0
line_ptr:       dw 0
cur_dev:        db 0
cur_log:        db 0
target_mask:    db 0
new_vec:        dw 0
vec:            dw 0
first_flag:     db 0
ent_ptr:        dw 0
mode_tmp:       db 0
need_mode:      db 0
pad_w:          dw 0
ndig:           db 0
numbuf:         ds 6
word:           ds 12
wpad:           ds 6
linebuf:        db 60, 0
                ds 62

pb_devtbl:      db 20, 0, 0, 0, 0, 0, 0, 0   ; BIOS DEVTBL
pb_screen:      db 32, 0, 0, 0, 0, 0, 0, 0   ; BIOS SCRMODE, A = columns
pb_set:         db 0, 0xFF, 0, 0             ; SCB: offset, set word, value
pb_get:         db 0, 0, 0, 0                ; SCB: offset, get
pb_page:        db SCB_CONPAGE, 0xFE, 0, 0   ; SCB: page height - 1, set byte
pb_get_width:   db SCB_CONWIDTH, 0, 0, 0
pb_get_page:    db SCB_CONPAGE, 0, 0, 0

; Logical device names (index = bit number in the L_* masks).
lname_tbl:      dw ln0, ln1, ln2, ln3, ln4
ln0:            db "CONIN:$"
ln1:            db "CONOUT:$"
ln2:            db "AUXIN:$"
ln3:            db "AUXOUT:$"
ln4:            db "LST:$"

; Every name a logical device goes by, with its mask.
log_table:
    db "CONIN", 0, L_CONIN
    db "CONOUT", 0, L_CONOUT
    db "AUXIN", 0, L_AUXIN
    db "AUXOUT", 0, L_AUXOUT
    db "LST", 0, L_LST
    db "CON", 0, L_CONIN | L_CONOUT
    db "CONSOLE", 0, L_CONIN | L_CONOUT
    db "KEYBOARD", 0, L_CONIN
    db "AUX", 0, L_AUXIN | L_AUXOUT
    db "AUXILIARY", 0, L_AUXIN | L_AUXOUT
    db "PRINTER", 0, L_LST
    db 0

baud_table:     dw 0, 50, 75, 110, 134, 150, 300, 600, 1200, 1800
                dw 2400, 3600, 4800, 7200, 9600, 19200

str_names:      db "NAMES", 0
str_values:     db "VALUES", 0
str_console:    db "CONSOLE", 0
str_null:       db "NULL", 0
str_none:       db " NONE$"
str_nulldev:    db "Null Device$"

msg_crlf:       db 0x0D, 0x0A, '$'
msg_phys:       db "Physical Devices:", 0x0D, 0x0A, 0x0D, 0x0A
                db "I=Input,O=Output,S=Serial,X=Xon-Xoff", 0x0D, 0x0A
                db 0x0D, 0x0A, '$'
msg_assign:     db "Current Assignments:", 0x0D, 0x0A, 0x0D, 0x0A, '$'
msg_enter:      db "Enter new assignment or hit RETURN: $"
msg_eq:         db "= $"
msg_width:      db "Console width = $"
msg_length:     db "Page length   = $"
msg_syntax:     db "Syntax: DEVICE {NAMES | VALUES | name}", 0x0D, 0x0A
                db "        DEVICE logical = physical{,physical} | NULL", 0x0D, 0x0A
                db "        DEVICE CONSOLE [PAGE | COLUMNS=n | LINES=n]"
                db 0x0D, 0x0A, '$'
msg_device:     db "Invalid device name", 0x0D, 0x0A, '$'
msg_console:    db "CONIN: and CONOUT: can only be assigned to CON"
                db 0x0D, 0x0A, '$'
msg_serial:     db "Not a serial device: no protocol or speed to set"
                db 0x0D, 0x0A, '$'
msg_columns:    db "Columns must be 32, 51 or 64", 0x0D, 0x0A, '$'
msg_lines:      db "Lines must be 4 to 24", 0x0D, 0x0A, '$'
msg_direction:  db " cannot be used for that logical device"
                db 0x0D, 0x0A, '$'
