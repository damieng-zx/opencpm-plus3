; SETKEYS.COM - program the +3 key translation table from a key file
;
;   SETKEYS [file]      read "file" (default SETKEYS.KEY) and apply it
;
; One command per line; blank lines are ignored, as is anything after the
; closing quote.  Two forms exist, matching Amstrad's original tool:
;
;   n C "string"    set the translation for key n   (number 0-39)
;   E n "string"    set expansion token n           (number 80h-9Eh)
;
; A number is decimal unless it starts with '#', so these are equivalent:
;
;   E #83 "^S"
;   E 131 "^S"
;
; "string" is a double-quoted run of characters.  Inside the quotes:
;
;   ^X          control character X (^A = 01h .. ^Z = 1Ah)
;   ^'#NN'      the character with hex value NN (the +3 manual's form)
;   ^#NN        the same, without the apostrophes
;   \\          a literal backslash
;   ""          a literal double quote
;
; A backslash makes the following character literal, which is how the stock
; key files escape the apostrophes in the ^'#NN' form ("^\\'#83\\'").
; Outside a caret form the characters are taken literally, so "#83" is the
; three characters '#', '8', '3' - not a hex escape.
;
; A "C" line must resolve to exactly one character: a key holds a single
; translation, which is written into all four shift rows (NORMAL, CAPS,
; SYMB, EXTEND) so one line covers every shift state.  A later line for the
; same key replaces the earlier one.  A translation of FFh restores the
; BIOS built-in mapping.
;
; The table lives in bank 6, so it survives a warm boot; programming it once
; per session is enough.
;
; Errors are reported per line and the rest of the file still runs.
;
; Build: sjasmplus --raw=build/setkeys.com src/tools/setkeys.asm

    org 0x0100

BDOS            equ 0x0005
F_PSTR          equ 9
F_OPEN          equ 15
F_CLOSE         equ 16
F_READ          equ 20
F_SETDMA        equ 26
TAIL            equ 0x0080
FCB             equ 0x005C
DMA_BUF         equ 0x0080

; XBIOS extended jumpblock entries.  USERF (BIOS entry 30) takes one of
; these as the inline word after the CALL; the dispatcher uses its low byte.
TE_KM_SET_KEY    equ 0x00D7
TE_KM_SET_EXPAND equ 0x00D4

MAXKEY          equ 39
BUF_SIZE        equ 1024
QUOTE           equ 0x22
APOS            equ 0x27
BSLASH          equ 0x5C

start:
    ; USERF is BIOS jump-table entry 30 (three bytes per entry).
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl                      ; HL = BIOS base
    ld de, 90                   ; 30 * 3
    add hl, de
    ld (tramp_call + 1), hl

    ; --- file name: the command tail, or the default -------------------
    ld hl, TAIL
    ld a, (hl)                  ; length byte
    or a
    jr z, .default
    ld b, a
    inc hl
.tailsp:
    ld a, (hl)
    cp ' '
    jr nz, .named
    inc hl
    djnz .tailsp
    jr .default
.named:
    or a
    jr z, .default
    cp 0x0D
    jr z, .default
    call build_fcb
    jr .open
.default:
    ld hl, dflt_name
    call build_fcb

.open:
    ld de, FCB
    ld c, F_OPEN
    call BDOS
    inc a                       ; FFh (not found) becomes 00h
    jp z, no_file

    ; --- load the whole file -------------------------------------------
    ld hl, buffer
    ld (buf_end), hl
.read:
    ld de, DMA_BUF
    ld c, F_SETDMA
    call BDOS

    ld de, FCB
    ld c, F_READ
    call BDOS
    or a
    jr nz, .loaded

    ld hl, DMA_BUF
    ld de, (buf_end)
    ld bc, 128
    ldir
    ld (buf_end), de

    ld hl, (buf_end)
    ld de, buffer + BUF_SIZE
    ld a, h
    cp d
    jr c, .read
    jr nz, .loaded
    ld a, l
    cp e
    jr c, .read

.loaded:
    ld de, FCB
    ld c, F_CLOSE
    call BDOS

    ld hl, buffer
    ld de, (buf_end)
    ld (data_end), de
    call run_lines
    rst 0

no_file:
    ld de, m_nofile
    ld c, F_PSTR
    call BDOS
    rst 0

; --------------------------------------------------------------------------
; run_lines - apply every line from HL up to (data_end).
; --------------------------------------------------------------------------
run_lines:
.loop:
    ld de, (data_end)
    ld a, h
    cp d
    jr c, .have
    jr nz, .done
    ld a, l
    cp e
    jr nc, .done
.have:
    ld a, (hl)
    or a
    ret z
    cp 0x1A
    ret z
    cp 0x0D
    jr z, .skip
    cp 0x0A
    jr z, .skip
    cp ' '
    jr z, .skip
    call do_line
    jr .loop
.skip:
    inc hl
    jr .loop
.done:
    ret

; --------------------------------------------------------------------------
; do_line - HL -> first non-blank character of a line.  Applies the line
; and leaves HL just past its CR (and LF).
; --------------------------------------------------------------------------
do_line:
    ld (line_ptr), hl
    call skip_space             ; HL -> first non-blank
    ld a, (hl)
    call is_digit
    jr nc, .number_first

    ; --- letter first: "E n ".."" -------------------------------------
    call upper                  ; A = upper-case letter
    ld (cmd_letter), a
    inc hl
    call skip_space
    call get_number             ; DE = value, HL past the digits
    jp c, .bad
    ld (num_val), de
    jr .have_string

    ; --- number first: "n C ".."" -------------------------------------
.number_first:
    call get_number
    jp c, .bad
    ld (num_val), de
    call skip_space
    ld a, (hl)
    call upper
    ld (cmd_letter), a
    inc hl

.have_string:
    call skip_space
    call read_string            ; xlat_buf filled, (str_len) = count
    jp c, .bad

    ld a, (cmd_letter)
    cp 'C'
    jr z, .key
    cp 'E'
    jp z, .expand
    jp .bad

.key:
    ld a, (str_len)
    dec a
    jr nz, .bad_str             ; a key needs exactly one character
    ld a, (num_val + 1)
    or a
    jr nz, .bad_key
    ld a, (num_val)
    cp MAXKEY + 1
    jr nc, .bad_key
    ld c, a                     ; C = key number
    ld a, (xlat_buf)
    ld b, a                     ; B = translation
    ld d, 0x0F                  ; all four shift rows
    call set_key
    jr .eol

.expand:
    ld a, (num_val + 1)
    or a
    jr nz, .bad_tok
    ld a, (num_val)
    cp 0x80
    jr c, .bad_tok
    cp 0x9F
    jr nc, .bad_tok
    ld b, a                     ; B = token
    ld a, (str_len)
    ld c, a                     ; C = length (zero is allowed)
    ld hl, xlat_buf
    call set_expand
    jr .eol

.bad_key:
    ld de, m_badkey
    jr .say
.bad_tok:
    ld de, m_badtok
    jr .say
.bad_str:
    ld de, m_badstr
    jr .say
.bad:
    ld de, m_badline
.say:
    ld c, F_PSTR
    call BDOS

.eol:
    ld hl, (line_ptr)
.rest:
    ld a, (hl)
    or a
    ret z
    cp 0x1A
    ret z
    inc hl
    cp 0x0D
    jr nz, .rest
    ld a, (hl)
    cp 0x0A
    ret nz
    inc hl
    ret

; --------------------------------------------------------------------------
; read_string - HL -> the opening quote.  Two passes: first copy the quoted
; text to lex_buf with backslash escapes resolved, then interpret the ^
; forms into xlat_buf.
;   In:       HL = pointer to the opening quote
;   Out:      xlat_buf filled, (str_len) = count, HL past the closing quote
;   Out:      F carry set on a malformed or unterminated string
;   Clobbers: AF, BC, DE, HL
; --------------------------------------------------------------------------
read_string:
    ld a, (hl)
    cp QUOTE
    scf
    ret nz                      ; not a quoted string

    ; ---- pass 1: unescape into lex_buf -------------------------------
    inc hl
    ld de, lex_buf
.lex:
    ld a, (hl)
    or a
    jp z, .unterminated
    cp 0x1A
    jp z, .unterminated
    cp 0x0D
    jp z, .unterminated
    cp QUOTE
    jr z, .lexed
    cp BSLASH
    jr nz, .store
    inc hl                      ; take the next byte literally
    ld a, (hl)
    or a
    jp z, .unterminated
    cp 0x0D
    jp z, .unterminated
.store:
    ld (de), a
    inc de
    inc hl
    jr .lex
.lexed:
    inc hl                      ; past the closing quote
    ld a, e
    sub lex_buf & 0xFF
    ld (lex_left), a            ; lex_buf is page-aligned in effect (< 256)

    ; ---- pass 2: interpret the ^ forms -------------------------------
    ld hl, lex_buf
    ld de, xlat_buf
    ld b, 0
.body:
    call nextc                  ; A = byte, CF set at the end
    jr c, .done
    cp '^'
    jr z, .caret
    call emit
    jr .body

.caret:
    call nextc
    jp c, .unterminated
    cp APOS                     ; ^'#NN'
    jr z, .quoted
    cp '#'                      ; ^#NN
    jr z, .hash
    and 0x1F                    ; ^A..^Z -> 01h..1Ah
    call emit
    jr .body

.quoted:
    call nextc
    jp c, .unterminated
    cp '#'
    jr nz, .apos_lit
    call get_hex                ; consumes two more bytes, advances HL
    jp c, .unterminated
    call emit
    call nextc                  ; closing apostrophe
    jp c, .unterminated
    cp APOS
    jp nz, .unterminated
    jr .body
.apos_lit:
    ld a, APOS                  ; "^'" without '#' - the apostrophe itself
    call emit
    jr .body

.hash:
    call get_hex
    jp c, .unterminated
    call emit
    jr .body

.done:
    ld a, b
    ld (str_len), a
    or a                        ; CF clear = success
    ret
.unterminated:
    ld a, b
    ld (str_len), a
    scf
    ret

; nextc - A = next byte of lex_buf, HL advanced; CF set when exhausted.
nextc:
    ld a, (lex_left)
    or a
    scf
    ret z
    dec a
    ld (lex_left), a
    ld a, (hl)
    inc hl
    or a                        ; CF clear
    ret

; emit - store A at (DE), advance DE, count in B.
emit:
    ld (de), a
    inc de
    inc b
    ret

; --------------------------------------------------------------------------
; get_number - DE = the number at HL (decimal, or hex after '#').
; HL advanced past the digits.  CF set if there is no valid number.
; --------------------------------------------------------------------------
get_number:
    ld de, 0
    ld a, (hl)
    cp '#'
    jr z, .hex
    ld b, 0
.dec:
    ld a, (hl)
    sub '0'
    jr c, .dec_end
    cp 10
    jr nc, .dec_end
    inc hl
    inc b
    ld (digit), a
    call mul10
    jr .dec
.dec_end:
    ld a, b
    or a
    jr z, .none
    or a
    ret

.hex:
    inc hl
    ld b, 0
.hexloop:
    ld a, (hl)
    call hexval
    jr c, .hex_done
    inc hl
    inc b
    ld (digit), a
    call mul16
    jr .hexloop
.hex_done:
    ld a, b
    or a
    jr z, .none
    or a
    ret
.none:
    scf
    ret

; mul10 - DE = DE * 10 + (digit)
mul10:
    push hl
    ex de, hl
    add hl, hl                  ; *2
    ld (acc), hl
    add hl, hl                  ; *4
    add hl, hl                  ; *8
    ld de, (acc)
    add hl, de                  ; *10
    ld a, (digit)
    ld e, a
    ld d, 0
    add hl, de
    ex de, hl                   ; DE = total
    pop hl
    ret

; mul16 - DE = DE * 16 + (digit)
mul16:
    push hl
    ex de, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld a, (digit)
    ld e, a
    ld d, 0
    add hl, de
    ex de, hl
    pop hl
    ret

; --------------------------------------------------------------------------
; get_hex - A = the two hex digits following HL (via nextc); HL advanced.
; CF set if they are not hex digits.  DE and BC are preserved: they are the
; emit pointer and count.
; --------------------------------------------------------------------------
get_hex:
    push bc
    push de
    call nextc
    jr c, .fail
    call hexval
    jr c, .fail
    ld (hib), a
    call nextc
    jr c, .fail
    call hexval
    jr c, .fail
    ld e, a
    ld a, (hib)
    add a, a
    add a, a
    add a, a
    add a, a
    or e
    pop de
    pop bc
    or a
    ret
.fail:
    pop de
    pop bc
    scf
    ret

; is_digit - CF set if A is '0'..'9'
is_digit:
    cp '0'
    jr c, .no
    cp '9' + 1
    jr c, .yes
.no:
    scf
    ret
.yes:
    or a
    ret

; hexval - A = value of the hex digit in A; CF set if it is not one.
hexval:
    cp '0'
    jr c, .bad
    cp '9' + 1
    jr c, .dig
    and 0xDF
    cp 'A'
    jr c, .bad
    cp 'F' + 1
    jr nc, .bad
    sub 'A' - 10
    or a
    ret
.dig:
    sub '0'
    or a
    ret
.bad:
    scf
    ret

; skip_space - advance HL past spaces.
skip_space:
    ld a, (hl)
    cp ' '
    ret nz
    inc hl
    jr skip_space

; --------------------------------------------------------------------------
; build_fcb - fill FCB from the name at HL ("[d:]NAME.EXT").
; CF set if the name is empty.
; --------------------------------------------------------------------------
build_fcb:
    push hl
    ld hl, FCB
    ld (hl), 0
    inc hl
    ld b, 11
.clr:
    ld (hl), ' '
    inc hl
    djnz .clr
    pop hl

    ld a, (hl)
    or a
    jr z, .empty
    cp 0x0D
    jr z, .empty
    cp ' '
    jr z, .empty

    ld (name_start), hl
    ld a, (hl)
    inc hl
    cp ':'
    jr nz, .no_drive
    ld hl, (name_start)
    ld a, (hl)
    and 0xDF
    sub 'A' - 1
    jr c, .empty
    cp 17
    jr nc, .empty
    ld (FCB), a
    inc hl
    inc hl                      ; past "d:"
    jr .name
.no_drive:
    ld hl, (name_start)

.name:
    ld de, FCB + 1
    ld b, 8
.name_loop:
    ld a, (hl)
    or a
    jr z, .ext_start
    cp 0x0D
    jr z, .ext_start
    cp ' '
    jr z, .ext_start
    cp '.'
    jr z, .ext
    call upper
    ld (de), a
    inc de
    inc hl
    djnz .name_loop
.name_skip:
    ld a, (hl)
    or a
    jr z, .ext_start
    cp 0x0D
    jr z, .ext_start
    cp ' '
    jr z, .ext_start
    cp '.'
    jr z, .ext
    inc hl
    jr .name_skip

.ext_start:
    ld a, (hl)
    cp '.'
    jr nz, .ok
.ext:
    inc hl
    ld de, FCB + 9
    ld b, 3
.ext_loop:
    ld a, (hl)
    or a
    jr z, .ok
    cp 0x0D
    jr z, .ok
    cp ' '
    jr z, .ok
    call upper
    ld (de), a
    inc de
    inc hl
    djnz .ext_loop
.ok:
    or a
    ret
.empty:
    scf
    ret

; upper - A = A upper-cased (ASCII letters only).
upper:
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    and 0xDF
    ret

; --------------------------------------------------------------------------
; set_key - KM_SET_KEY.  B = translation, C = key, D = shift mask.
; --------------------------------------------------------------------------
set_key:
    ld hl, TE_KM_SET_KEY
    ld (tramp_dw), hl
    jp tramp

; --------------------------------------------------------------------------
; set_expand - KM_SET_EXPAND.  B = token, C = length, HL = string.
; --------------------------------------------------------------------------
set_expand:
    ld (exp_ptr), hl
    ld a, c
    ld (exp_clen), a
    ld hl, TE_KM_SET_EXPAND
    ld (tramp_dw), hl
    ld hl, (exp_ptr)
    ld a, (exp_clen)
    ld c, a
    jp tramp

tramp:
tramp_call:
    call 0                      ; patched to USERF
tramp_dw:
    dw 0                        ; patched to the XBIOS entry
    ret

dflt_name:  db "SETKEYS.KEY", 0
m_nofile:   db "No key file found.$"
m_badline:  db "Bad line.$"
m_badkey:   db "Bad key number.$"
m_badtok:   db "Bad token number.$"
m_badstr:   db "Bad string.$"

name_start: dw 0
line_ptr:   dw 0
num_val:    dw 0
acc:        dw 0
exp_ptr:    dw 0
buf_end:    dw 0
data_end:   dw 0
cmd_letter: db 0
digit:      db 0
hib:        db 0
exp_clen:   db 0
lex_left:   db 0
str_len:    db 0
lex_buf:    ds 64
xlat_buf:   ds 64
buffer:     ds BUF_SIZE
