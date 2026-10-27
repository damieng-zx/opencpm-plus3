; SETDEF.COM — Configure system defaults
;
; Usage:
;   SETDEF                          show current settings
;   SETDEF [PAGE]                   enable console page-mode
;   SETDEF [NOPAGE]                 disable
;   SETDEF [DISPLAY]                enable SUBmit-line echo
;   SETDEF [NO DISPLAY]             disable
;   SETDEF [TEMPORARY=d:]           set temporary drive (d: = A:..P:, or 0: for default)
;   SETDEF d:,d:,d:,d:              set program search path (up to 4; * = current drive)
;   SETDEF [ORDER=(COM,SUB)]        look for .COM then .SUB (default)
;   SETDEF [ORDER=(SUB,COM)]        look for .SUB then .COM
;   SETDEF [ORDER=(COM)]            only .COM
;   SETDEF [ORDER=(SUB)]            only .SUB
;
; Build: sjasmplus --raw=build/setdef.com src/tools/setdef.asm

    ORG 0x0100

BDOS       equ 0x0005
F_COUT     equ 2
F_PRINT    equ 9
F_GETSCB   equ 49
F_CONMODE  equ 109
F_GET_ORD  equ 120
F_SET_ORD  equ 121
F_GET_PATH equ 122
F_SET_PATH equ 123

SCB_TEMPDRV equ 0x34

CON_MODE_PAGE    equ 0x01
CON_MODE_DISPLAY equ 0x02

ORDER_COM_SUB equ 0
ORDER_SUB_COM equ 1
ORDER_COM     equ 2
ORDER_SUB     equ 3


start:
    ld a, (0x0080)
    ld b, a                    ; B = remaining chars
    ld hl, 0x0081              ; HL = current pos in tail
.skip_ws:
    ld a, b
    or a
    jp z, show_settings
    ld a, (hl)
    cp ' '
    jr nz, got_arg
    inc hl
    dec b
    jr .skip_ws

got_arg:
    cp '['
    jr z, .bracketed
    ; Not a bracket — assume drive list (A:, *, etc.)
    call parse_drive_list
    jp done
.bracketed:
    inc hl
    dec b
    call parse_bracket
    jp done

done:
    rst 0


; parse_bracket — Copy uppercased bracket content to bracket_buf, match
;   against known directives and apply.
;   In: HL = first char after '[', B = remaining tail chars
parse_bracket:
    ld de, bracket_buf
    ld c, 0                    ; C = length
.copy:
    ld a, b
    or a
    jp z, err_syntax           ; no closing ']'
    ld a, (hl)
    cp ']'
    jr z, .terminated
    call upper
    ld (de), a
    inc de
    inc hl
    inc c
    dec b
    ld a, c
    cp BRACKET_BUF_MAX
    jp nc, err_syntax
    jr .copy
.terminated:
    xor a
    ld (de), a                 ; null-terminate

    ld de, str_page
    call match_exact
    jr nz, .n1
    ld a, CON_MODE_PAGE
    jp conmode_set
.n1:
    ld de, str_nopage
    call match_exact
    jr z, .do_nopage
    ld de, str_no_page
    call match_exact
    jr nz, .n2
.do_nopage:
    ld a, CON_MODE_PAGE
    jp conmode_clear
.n2:
    ld de, str_display
    call match_exact
    jr nz, .n3
    ld a, CON_MODE_DISPLAY
    jp conmode_set
.n3:
    ld de, str_nodisplay
    call match_exact
    jr z, .do_nodisplay
    ld de, str_no_display
    call match_exact
    jr nz, .n4
.do_nodisplay:
    ld a, CON_MODE_DISPLAY
    jp conmode_clear
.n4:
    ld de, str_temporary
    call match_prefix
    jr nz, .n5
    jp set_temporary           ; HL = past "TEMPORARY=" in bracket_buf
.n5:
    ld de, str_order
    call match_prefix
    jr nz, .n6
    jp set_order               ; HL = past "ORDER=" in bracket_buf
.n6:
    jp err_syntax


; match_exact — Compare bracket_buf vs DE-terminated string (0 terminator).
;   Out: Z set if strings are equal, NZ otherwise.
match_exact:
    ld hl, bracket_buf
.loop:
    ld a, (de)
    cp (hl)
    ret nz
    or a
    ret z
    inc de
    inc hl
    jr .loop


; match_prefix — Check if DE-string is a prefix of bracket_buf.
;   Out: Z set if yes, HL points just past the matched prefix.
;        NZ otherwise.
;   Clobbers: AF, BC, DE
match_prefix:
    ld hl, bracket_buf
.loop:
    ld a, (de)
    or a
    ret z                      ; end of DE-string → prefix match
    cp (hl)
    ret nz
    inc de
    inc hl
    jr .loop


; conmode_set — OR mask in A into con_mode.
conmode_set:
    push af
    ld de, 0xFFFF
    ld c, F_CONMODE
    call BDOS                  ; HL = current con_mode
    pop af
    or l
    ld l, a
    ex de, hl
    ld c, F_CONMODE
    call BDOS
    ret


; conmode_clear — AND ~mask in A into con_mode.
conmode_clear:
    push af
    ld de, 0xFFFF
    ld c, F_CONMODE
    call BDOS                  ; HL = current con_mode
    pop af
    cpl
    and l
    ld l, a
    ex de, hl
    ld c, F_CONMODE
    call BDOS
    ret


; set_temporary — Parse "X:" or "0:" at HL and write to scb_tempdrv.
;   HL = first char after "TEMPORARY=" in bracket_buf.
set_temporary:
    ld a, (hl)
    cp '0'
    jr nz, .letter
    inc hl
    ld a, (hl)
    cp ':'
    jp nz, err_syntax
    inc hl
    ld a, (hl)
    or a
    jp nz, err_syntax
    xor a
    jr .write
.letter:
    sub 'A'
    jp c, err_syntax
    cp 16
    jp nc, err_syntax
    inc a                      ; 1..16 = A..P
    push af
    inc hl
    ld a, (hl)
    cp ':'
    jp nz, err_syntax
    inc hl
    ld a, (hl)
    or a
    jp nz, err_syntax
    pop af
.write:
    ld (scb_pb_set_tempdrv + 2), a
    ld de, scb_pb_set_tempdrv
    ld c, F_GETSCB
    call BDOS
    ret


; set_order — Parse "(tok[,tok])" at HL and set bdos_order via F121.
;   HL = first char after "ORDER=" in bracket_buf (should be '(').
set_order:
    ld a, (hl)
    cp '('
    jp nz, err_syntax
    inc hl
    call read_order_token      ; A = 'C' for COM, 'S' for SUB
    ld b, a                    ; B = first token
    ld a, (hl)
    cp ')'
    jr z, .one
    cp ','
    jp nz, err_syntax
    inc hl
    call read_order_token
    ld c, a                    ; C = second token
    ld a, (hl)
    cp ')'
    jp nz, err_syntax
    inc hl
    ld a, (hl)
    or a
    jp nz, err_syntax          ; junk after ')'
    ; Two tokens: decide order
    ld a, b
    cp c
    jp z, err_syntax           ; e.g. (COM,COM)
    cp 'C'
    jr z, .two_com_sub
    ; First is SUB, second COM
    ld a, ORDER_SUB_COM
    jr .apply
.two_com_sub:
    ld a, ORDER_COM_SUB
    jr .apply
.one:
    inc hl
    ld a, (hl)
    or a
    jp nz, err_syntax
    ld a, b
    cp 'C'
    jr z, .one_com
    ld a, ORDER_SUB
    jr .apply
.one_com:
    ld a, ORDER_COM
.apply:
    ld e, a
    ld c, F_SET_ORD
    jp BDOS


; read_order_token — Consume "COM" or "SUB" at HL.
;   Out: A = 'C' or 'S'. HL advanced past token.
;   Clobbers: AF, HL (BC and DE preserved)
read_order_token:
    ld a, (hl)
    cp 'C'
    jr z, .rd_com
    cp 'S'
    jr z, .rd_sub
    jp err_syntax
.rd_com:
    inc hl
    ld a, (hl)
    cp 'O'
    jp nz, err_syntax
    inc hl
    ld a, (hl)
    cp 'M'
    jp nz, err_syntax
    inc hl
    ld a, 'C'
    ret
.rd_sub:
    inc hl
    ld a, (hl)
    cp 'U'
    jp nz, err_syntax
    inc hl
    ld a, (hl)
    cp 'B'
    jp nz, err_syntax
    inc hl
    ld a, 'S'
    ret


; parse_drive_list — Parse comma-separated drive list at HL into path_buf
;   then apply via F_SET_PATH. Format: "A:,B:,*" or similar. Up to 4 entries;
;   '*' is a single-char entry (no ':'). Trailing ',' or extra entries → error.
;   In: HL = first char, B = remaining tail bytes.
parse_drive_list:
    ld ix, path_buf
    xor a
    ld (path_buf), a
    ld (path_buf + 1), a
    ld (path_buf + 2), a
    ld (path_buf + 3), a
    ld c, 0                    ; C = slot count
.entry:
    ld a, b
    or a
    jp z, err_syntax           ; empty list (e.g. "SETDEF ," only)
    ld a, c
    cp 4
    jp nc, err_syntax          ; >4 entries
    ld a, (hl)
    cp '*'
    jr z, .wild
    call upper
    cp 'A'
    jp c, err_syntax
    cp 'P' + 1
    jp nc, err_syntax
    sub 'A' - 1                ; 1..16
    ld (ix + 0), a
    inc ix
    inc c
    inc hl
    dec b
    ld a, b
    or a
    jp z, err_syntax           ; expected ':'
    ld a, (hl)
    cp ':'
    jp nz, err_syntax
    inc hl
    dec b
    jr .sep
.wild:
    ld a, 0xFF
    ld (ix + 0), a
    inc ix
    inc c
    inc hl
    dec b
.sep:
    ld a, b
    or a
    jr z, .done
    ld a, (hl)
    cp ' '
    jr z, .done
    cp ','
    jp nz, err_syntax
    inc hl
    dec b
    jp .entry
.done:
    ld de, path_buf
    ld c, F_SET_PATH
    jp BDOS


show_settings:
    ; Page mode
    ld de, msg_page
    ld c, F_PRINT
    call BDOS
    ld de, 0xFFFF
    ld c, F_CONMODE
    call BDOS                  ; HL = con_mode
    push hl
    ld a, l
    and CON_MODE_PAGE
    call print_on_off

    ; Display mode
    ld de, msg_display
    ld c, F_PRINT
    call BDOS
    pop hl
    ld a, l
    and CON_MODE_DISPLAY
    call print_on_off

    ; Temporary drive
    ld de, msg_tempdrv
    ld c, F_PRINT
    call BDOS
    ld de, scb_pb_get_tempdrv
    ld c, F_GETSCB
    call BDOS
    ld a, l
    or a
    jr nz, .td_drive
    ld de, msg_default
    ld c, F_PRINT
    call BDOS
    jr .td_done
.td_drive:
    add a, 'A' - 1
    ld e, a
    ld c, F_COUT
    call BDOS
    ld e, ':'
    ld c, F_COUT
    call BDOS
.td_done:

    ; Search path
    ld de, msg_search
    ld c, F_PRINT
    call BDOS
    ld de, path_buf
    ld c, F_GET_PATH
    call BDOS
    call print_search_path

    ; Order
    ld de, msg_order
    ld c, F_PRINT
    call BDOS
    ld c, F_GET_ORD
    call BDOS
    call print_order

    ld de, msg_crlf
    ld c, F_PRINT
    call BDOS
    jp done


; print_on_off — Print "ON" or "OFF" based on A (nonzero = ON).
print_on_off:
    or a
    jr z, .off
    ld de, msg_on
    ld c, F_PRINT
    jp BDOS
.off:
    ld de, msg_off
    ld c, F_PRINT
    jp BDOS


; print_search_path — Print path_buf as drive list ("A:,B:,*" etc.).
print_search_path:
    ld a, (path_buf)
    or a
    jr nz, .nonempty
    ld de, msg_default
    ld c, F_PRINT
    jp BDOS
.nonempty:
    ld hl, path_buf
    ld b, 4
.pl_loop:
    ld a, (hl)
    or a
    ret z
    cp 0xFF
    jr z, .pl_wild
    add a, 'A' - 1
    push bc
    push hl
    ld e, a
    ld c, F_COUT
    call BDOS
    ld e, ':'
    ld c, F_COUT
    call BDOS
    pop hl
    pop bc
    jr .pl_after
.pl_wild:
    push bc
    push hl
    ld e, '*'
    ld c, F_COUT
    call BDOS
    pop hl
    pop bc
.pl_after:
    inc hl
    ld a, b
    cp 1
    jr z, .pl_last
    ld a, (hl)
    or a
    jr z, .pl_last
    push bc
    push hl
    ld e, ','
    ld c, F_COUT
    call BDOS
    pop hl
    pop bc
.pl_last:
    djnz .pl_loop
    ret


; print_order — Print bdos_order enum as "(COM,SUB)" etc.
print_order:
    cp ORDER_COM_SUB
    jr z, .o_cs
    cp ORDER_SUB_COM
    jr z, .o_sc
    cp ORDER_COM
    jr z, .o_c
    cp ORDER_SUB
    jr z, .o_s
    ret
.o_cs:
    ld de, str_paren_com_sub
    jr .pr
.o_sc:
    ld de, str_paren_sub_com
    jr .pr
.o_c:
    ld de, str_paren_com
    jr .pr
.o_s:
    ld de, str_paren_sub
.pr:
    ld c, F_PRINT
    jp BDOS


err_syntax:
    ld de, msg_syntax
    ld c, F_PRINT
    call BDOS
    rst 0


upper:
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    sub 0x20
    ret


str_page:       db 'PAGE', 0
str_nopage:     db 'NOPAGE', 0
str_no_page:    db 'NO PAGE', 0
str_display:    db 'DISPLAY', 0
str_nodisplay:  db 'NODISPLAY', 0
str_no_display: db 'NO DISPLAY', 0
str_temporary:  db 'TEMPORARY=', 0
str_order:      db 'ORDER=', 0

str_paren_com_sub: db '(COM,SUB)$'
str_paren_sub_com: db '(SUB,COM)$'
str_paren_com:     db '(COM)$'
str_paren_sub:     db '(SUB)$'

msg_page:     db 'Page mode:       $'
msg_display:  db 0x0D, 0x0A, 'Display mode:    $'
msg_tempdrv:  db 0x0D, 0x0A, 'Temporary drive: $'
msg_search:   db 0x0D, 0x0A, 'Search path:     $'
msg_order:    db 0x0D, 0x0A, 'Search order:    $'
msg_default:  db 'default$'
msg_on:       db 'ON$'
msg_off:      db 'OFF$'
msg_crlf:     db 0x0D, 0x0A, '$'

msg_syntax:   db 'SETDEF: syntax error', 0x0D, 0x0A, '$'

scb_pb_get_tempdrv: db SCB_TEMPDRV, 0x00
scb_pb_set_tempdrv: db SCB_TEMPDRV, 0xFE, 0

BRACKET_BUF_MAX equ 32
bracket_buf:  ds BRACKET_BUF_MAX
path_buf:     ds 4
