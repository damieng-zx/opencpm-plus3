; ERASE.COM - ERASE / ERA with the [CONFIRM] option
;
;   ERASE [d:]filespec [[CONFIRM]]
;
; The CCP's built-in ERASE handles the plain form (including the "ERASE spec
; (Y/N)?" question for a wildcard); it loads this program only when an option
; list follows, as the CP/M 3 User's Guide describes.  The program accepts the
; plain form too, so ERASE.COM can be run directly.
;
;   [CONFIRM] (abbreviated C) asks "d:NAME.TYP (Y/N)?" before each matching
;   file is erased; Y erases it, anything else keeps it.  Without it a
;   wildcard asks once for the whole group, and a plain name asks nothing.
;
; Every match is collected before the first delete: a delete disturbs the
; directory search state, so erasing while searching would skip files.
;
; Build: sjasmplus --raw=build/erase.com src/tools/erase.asm

    org 0x0100

BDOS            equ 0x0005
F_CIN           equ 1
F_COUT          equ 2
F_PSTR          equ 9
F_CURDRV        equ 25
F_SETDMA        equ 26
F_SEARCH_FIRST  equ 17
F_SEARCH_NEXT   equ 18
F_DELETE        equ 19

TAIL            equ 0x0080
MAX_FILES       equ 256

; Work areas above the program image (the .COM file stays small).
dmabuf          equ 0x3000         ; 128-byte directory sector from the search
fcb             equ 0x3080         ; search FCB: drive, name/type, rest zero
dfcb            equ 0x30A4         ; FCB of one file to delete
spec_str        equ 0x30C8         ; the filespec as typed, upper case, NUL
list            equ 0x3100         ; MAX_FILES * 11 matched names
confirm         equ 0x3C00         ; 1 = [CONFIRM] given
have_spec       equ 0x3C01         ; 1 = a filespec was given
count           equ 0x3C02         ; matched names in list (word)

; ==========================================================================
; Entry: read the command tail
; ==========================================================================
start:
    xor a
    ld (confirm), a
    ld (have_spec), a
    ld h, a
    ld l, a
    ld (count), hl
    ld hl, TAIL + 1
.token:
    call skip_spaces
    ld a, (hl)
    or a
    jr z, .parsed
    cp 0x0D
    jr z, .parsed
    cp '['
    jr z, .options
    ld a, (have_spec)
    or a
    jp nz, usage               ; only one filespec
    inc a
    ld (have_spec), a
    call parse_spec            ; HL stops after the token
    jp c, bad_name
    jr .token
.options:
    inc hl
    call parse_options
    jp c, bad_option
    jr .token
.parsed:
    ld a, (have_spec)
    or a
    jp z, usage

    ; The search FCB needs the DMA for the directory sector.
    ld de, dmabuf
    ld c, F_SETDMA
    call BDOS

    ld a, (confirm)
    or a
    jr nz, per_file

    ; ---- Plain form: one question for a wildcard, then delete the lot ----
    call has_wildcard          ; Z = wildcard
    jr nz, .delete_all
    ld de, msg_erase
    call pstr
    ld de, spec_str
    call print_z
    call ask_yn                ; Z = yes
    ret nz                     ; anything but Y: nothing is erased
.delete_all:
    ld de, fcb
    ld c, F_DELETE
    call BDOS
    inc a                      ; 0xFF (nothing matched) -> 0
    ret nz
    jp no_file

; ==========================================================================
; [CONFIRM]: collect every matching name, then ask for each in turn
; ==========================================================================
per_file:
    ld de, fcb
    ld c, F_SEARCH_FIRST
    call BDOS
.search:
    cp 0xFF
    jr z, .collected
    call entry_ptr             ; HL = directory entry for index A
    inc hl                     ; name and type
    call add_unique
    ld de, fcb
    ld c, F_SEARCH_NEXT
    call BDOS
    jr .search
.collected:
    ld hl, (count)
    ld a, h
    or l
    jp z, no_file

    ld hl, list
    ld (cursor), hl
.each:
    ld hl, (count)
    ld a, h
    or l
    ret z
    dec hl
    ld (count), hl

    call drive_letter          ; A = 'A'..'P'
    call cout
    ld a, ':'
    call cout
    ld hl, (cursor)
    call print_fname
    call ask_yn                ; Z = yes
    jr nz, .next

    ; Build an exact FCB for the file and erase it.
    ld hl, dfcb
    ld de, dfcb + 1
    ld bc, 35
    ld (hl), 0
    ldir
    ld a, (fcb)
    ld (dfcb), a
    ld hl, (cursor)
    ld de, dfcb + 1
    ld bc, 11
    ldir
    ld de, dfcb
    ld c, F_DELETE
    call BDOS
.next:
    ld hl, (cursor)
    ld de, 11
    add hl, de
    ld (cursor), hl
    jr .each

; ==========================================================================
; Option list: [CONFIRM] or any abbreviation down to C.
;   In:       HL = first character after '['
;   Out:      HL = after the ']' (or at the end of the line); carry = bad
;   Clobbers: AF, BC, DE, HL
; ==========================================================================
parse_options:
.skip:
    ld a, (hl)
    cp ' '
    jr z, .step
    cp ','
    jr nz, .word
.step:
    inc hl
    jr .skip
.word:
    cp ']'
    jr z, .close
    or a
    jr z, .done
    cp 0x0D
    jr z, .done
    ld de, str_confirm
.cmp:
    ld a, (hl)
    call upper
    ld b, a
    ld a, (de)
    cp b
    jr nz, .mismatch
    inc hl
    inc de
    jr .cmp
.mismatch:
    ; The word ended: it was a prefix of CONFIRM, so it is the option.
    ld a, (hl)
    cp ' '
    jr z, .ended
    cp ','
    jr z, .ended
    cp ']'
    jr z, .ended
    or a
    jr z, .ended
    cp 0x0D
    jr z, .ended
    scf                        ; some other word
    ret
.ended:
.set:
    ld a, 1
    ld (confirm), a
    jr .skip
.close:
    inc hl
.done:
    or a
    ret

; ==========================================================================
; parse_spec - copy a token to spec_str (upper case) and build the search FCB
;   In:       HL = first character of the token
;   Out:      HL = first character after the token; carry = bad name
;   Clobbers: AF, BC, DE, HL
; ==========================================================================
parse_spec:
    ld de, spec_str
.copy:
    ld a, (hl)
    or a
    jr z, .copied
    cp 0x0D
    jr z, .copied
    cp ' '
    jr z, .copied
    cp '['
    jr z, .copied
    call upper
    ld (de), a
    inc de
    inc hl
    jr .copy
.copied:
    xor a
    ld (de), a
    push hl                    ; the caller continues after the token

    ; Clear the FCB: blank name and type, zero everything else.
    ld hl, fcb
    ld de, fcb + 1
    ld bc, 35
    ld (hl), 0
    ldir
    ld hl, fcb + 1
    ld b, 11
.blank:
    ld (hl), ' '
    inc hl
    djnz .blank

    ld hl, spec_str
    ld a, (hl)
    or a
    jr z, .bad                 ; empty name
    inc hl
    ld a, (hl)
    dec hl
    cp ':'
    jr nz, .name
    ld a, (hl)
    sub 'A'
    cp 16
    jr nc, .bad                ; drive letter out of range
    inc a
    ld (fcb), a
    inc hl
    inc hl                     ; past "d:"
.name:
    ld de, fcb + 1
    ld b, 8
    call parse_field
    jr c, .bad
    ld a, (hl)
    cp '.'
    jr nz, .ok
    inc hl
    ld de, fcb + 9
    ld b, 3
    call parse_field
    jr c, .bad
    ld a, (hl)
    or a
    jr nz, .bad                ; a second '.'
.ok:
    pop hl
    or a
    ret
.bad:
    pop hl
    scf
    ret

; parse_field - copy one name field, expanding '*' to '?'s
;   In:       HL = source, DE = destination, B = field width
;   Out:      HL stops at '.' or NUL; carry = field too long
;   Clobbers: AF, B, DE, HL
parse_field:
.loop:
    ld a, (hl)
    or a
    ret z
    cp '.'
    ret z
    cp '*'
    jr z, .star
    ld (de), a
    inc de
    inc hl
    djnz .loop
    ld a, (hl)                 ; width used up: the field must end here
    or a
    ret z
    cp '.'
    ret z
    scf
    ret
.star:
    ld a, '?'
.fill:
    ld (de), a
    inc de
    djnz .fill
    inc hl
.skip:
    ld a, (hl)                 ; anything after '*' up to the '.' is ignored
    or a
    ret z
    cp '.'
    ret z
    inc hl
    jr .skip

; has_wildcard - does the search FCB name or type hold a '?'
;   Out:      Z = a wildcard is present, NZ = none
;   Clobbers: AF, B, HL
has_wildcard:
    ld hl, fcb + 1
    ld b, 11
.loop:
    ld a, (hl)
    cp '?'
    ret z
    inc hl
    djnz .loop
    or 1                       ; NZ
    ret

; ==========================================================================
; Directory entries and the match list
; ==========================================================================
; entry_ptr - address of directory entry A (0-3) in the search DMA buffer
;   In:       A = index returned by the search
;   Out:      HL = entry address
;   Clobbers: AF, DE, HL
entry_ptr:
    rrca
    rrca
    rrca                       ; A * 32 for A in 0..3
    and 0x60
    ld e, a
    ld d, 0
    ld hl, dmabuf
    add hl, de
    ret

; add_unique - append a name to list unless it is there already
;   In:       HL = 11 name bytes (attribute bits ignored)
;   Clobbers: AF, BC, DE, HL
add_unique:
    ld de, name_tmp
    ld b, 11
.strip:
    ld a, (hl)
    and 0x7F
    ld (de), a
    inc hl
    inc de
    djnz .strip

    ld bc, (count)
    ld hl, list
.scan:
    ld a, b
    or c
    jr z, .append
    push bc
    push hl
    ld de, name_tmp
    ld b, 11
.cmp:
    ld a, (de)
    cp (hl)
    jr nz, .differs
    inc hl
    inc de
    djnz .cmp
    pop hl
    pop bc
    ret                        ; already listed
.differs:
    pop hl
    ld de, 11
    add hl, de
    pop bc
    dec bc
    jr .scan
.append:
    ld hl, (count)
    ld de, MAX_FILES
    or a
    sbc hl, de
    ret nc                     ; list full: later names are not offered
    ld hl, list - 11
    ld de, 11
    ld bc, (count)
    inc bc
.at:
    add hl, de
    dec bc
    ld a, b
    or c
    jr nz, .at
    ex de, hl                  ; DE = slot
    ld hl, name_tmp
    ld bc, 11
    ldir
    ld hl, (count)
    inc hl
    ld (count), hl
    ret

; ==========================================================================
; Console helpers
; ==========================================================================
; ask_yn - print " (Y/N)?" and read the answer
;   Out:      Z = yes (Y or y)
;   Clobbers: AF, BC, DE, HL
ask_yn:
    ld de, msg_yn
    call pstr
    ld c, F_CIN
    call BDOS
    and 0xDF
    push af
    ld de, msg_crlf
    call pstr
    pop af
    cp 'Y'
    ret

; drive_letter - letter of the drive the search FCB names
;   Out:      A = 'A'..'P'
;   Clobbers: AF, BC, DE, HL
drive_letter:
    ld a, (fcb)
    or a
    jr nz, .named
    ld c, F_CURDRV
    call BDOS                  ; 0 = A
    add a, 'A'
    ret
.named:
    add a, 'A' - 1
    ret

; print_fname - NAME.TYP from 11 stored bytes, blanks dropped
;   In:       HL = name bytes
;   Clobbers: AF, BC, DE, HL
print_fname:
    ld b, 8
    call .field
    ld a, (hl)
    cp ' '
    jr z, .done                ; no type
    push hl
    ld a, '.'
    call cout
    pop hl
    ld b, 3
    call .field
.done:
    ret
.field:
    ld a, (hl)
    inc hl
    cp ' '
    jr z, .blank
    push hl
    push bc
    call cout
    pop bc
    pop hl
.blank:
    djnz .field
    ret

; print_z - print a NUL-terminated string
;   In:       DE = string
;   Clobbers: AF, BC, DE, HL
print_z:
    ld a, (de)
    or a
    ret z
    push de
    call cout
    pop de
    inc de
    jr print_z

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

; skip_spaces - advance HL past spaces
;   Out:      HL = first non-space
;   Clobbers: AF, HL
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

; ==========================================================================
; Errors (each ends the program)
; ==========================================================================
no_file:
    ld de, msg_no_file
    call pstr
    rst 0

bad_name:
    ld de, msg_bad_name
    call pstr
    rst 0

bad_option:
    ld de, msg_bad_option
    call pstr
    rst 0

usage:
    ld de, msg_usage
    call pstr
    rst 0

; --- Data ---
cursor:         dw 0               ; the name being asked about
name_tmp:       ds 11
str_confirm:    db "CONFIRM", 0
msg_erase:      db "ERASE $"
msg_yn:         db " (Y/N)?$"
msg_crlf:       db 0x0D, 0x0A, '$'
msg_no_file:    db "No File", 0x0D, 0x0A, '$'
msg_bad_name:   db "Invalid file specification", 0x0D, 0x0A, '$'
msg_bad_option: db "Invalid option", 0x0D, 0x0A, '$'
msg_usage:      db "Syntax: ERASE {d:}filespec {[CONFIRM]}", 0x0D, 0x0A, '$'
