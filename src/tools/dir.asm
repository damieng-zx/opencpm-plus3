; DIR.COM - DIR with options
;
;   DIR {d:}                          the CCP's built-in DIR handles these;
;   DIR {filespec}                    this program takes over when an option
;   DIR {filespec} {filespec} ... [options]   list follows (CP/M 3 User's Guide)
;
; Options (any one list, anywhere in the line, abbreviated while unambiguous):
;   ATT          show the user attributes F1-F4
;   DATE         time stamps - there are none on this system, so it says so
;   DIR / SYS    only files with / without the SYS attribute
;   RO / RW      only Read-Only / Read-Write files
;   DRIVE=ALL | d | (d,d,...)         DISK is a synonym
;   USER=ALL | n | (n,n,...)
;   EXCLUDE      the files that do NOT match the filespecs
;   FULL         name, size, records and attributes (the default)
;   SIZE         name and size only, several to a line
;   LENGTH=n     repeat the FULL heading every n lines (5 and up)
;   MESSAGE      name each drive and user area as it is searched
;   NOPAGE / FF  do not pause when the screen fills
;   NOSORT       directory order instead of alphabetical
;
; Each drive/user area is read in one pass with a "????????.???" search; the
; filespecs, EXCLUDE and the attribute filters are applied here, so a file
; reached by two filespecs is still listed once and its extents are summed
; correctly.  The files are kept in a table (16 bytes each), sorted through a
; table of pointers, and printed.
;
; Build: sjasmplus --raw=build/dir.com src/tools/dir.asm

    org 0x0100

BDOS            equ 0x0005
F_COUT          equ 2
F_PSTR          equ 9
F_SELDRV        equ 14
F_SEARCH_FIRST  equ 17
F_SEARCH_NEXT   equ 18
F_CURDRV        equ 25
F_SETDMA        equ 26
F_GETDPB        equ 31
F_USER          equ 32
F_LOGINVEC      equ 24
F_SCB           equ 49
F_CONMODE       equ 109

TAIL            equ 0x0080
MAXFILES        equ 1024
MAXSPECS        equ 8

; Work areas above the program image.
FILETAB         equ 0x4000         ; MAXFILES records of 16 bytes
PTRTAB          equ 0x8000         ; MAXFILES words: sorted order
dmabuf          equ 0x8800         ; directory sector from a search
scanfcb         equ 0x8880         ; the search FCB
specs           equ 0x88B0         ; MAXSPECS * 12: drive, name, type
spec_str        equ 0x8920         ; one filespec as typed, upper case

; File record: +0..10 name/type with attribute bits, +12 records (word),
; +14 allocated blocks (word).
REC_SIZE        equ 16

; ==========================================================================
; Entry
; ==========================================================================
start:
    ld c, F_CURDRV
    call BDOS
    ld (curdrv), a
    ld e, 0xFF
    ld c, F_USER
    call BDOS
    ld (curuser), a
    ld de, 0xFFFF
    ld c, F_CONMODE
    call BDOS
    ld (save_mode), hl

    call parse_tail
    call set_defaults

    ld a, (o_nopage)
    ld b, a
    ld a, (o_ff)
    or b
    jr z, .paged
    ld hl, (save_mode)
    res 0, l                   ; PAGE off for this listing
    ex de, hl
    ld c, F_CONMODE
    call BDOS
.paged:
    ld a, (o_date)
    or a
    jr z, .nodate
    ld de, msg_nodate
    call pstr
.nodate:
    ld de, dmabuf
    ld c, F_SETDMA
    call BDOS

    call run_groups

    ld hl, (found_total)
    ld a, h
    or l
    jr nz, .done
    ld de, msg_no_file
    call pstr
.done:
    jp restore

; restore - put back the drive and console mode
;   Clobbers: AF, BC, DE, HL
restore:
    ld a, (curdrv)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    ld de, (save_mode)
    ld c, F_CONMODE
    jp BDOS

; ==========================================================================
; Command line
; ==========================================================================
; parse_tail - filespecs and the one option list, in any order
;   Clobbers: AF, BC, DE, HL (an error ends the program)
parse_tail:
    ld hl, TAIL + 1
.token:
    call skip_spaces
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp '['
    jr z, .options
    ld a, (nspecs)
    cp MAXSPECS
    jp nc, err_name
    ld e, a                    ; destination = specs + nspecs * 12
    ld d, 0
    push hl
    ld h, d
    ld l, e
    add hl, hl
    add hl, de
    add hl, hl
    add hl, hl                 ; * 12 = (n * 3) * 4
    ld de, specs
    add hl, de
    ex de, hl                  ; DE = record
    pop hl
    call parse_spec
    jp c, err_name
    ld a, (nspecs)
    inc a
    ld (nspecs), a
    jr .token
.options:
    ld a, (opts_seen)
    or a
    jp nz, err_option          ; only one option list
    inc a
    ld (opts_seen), a
    inc hl
    call parse_options
    jp c, err_option
    jr .token

; set_defaults - the drive and user lists, the heading length
;   Clobbers: AF, BC, DE, HL
set_defaults:
    ld a, (user_given)
    or a
    jr nz, .have_users
    ld a, (curuser)
    call mask_bit
    ld (user_mask), hl
.have_users:
    ld a, (drive_given)
    or a
    jr z, .use_specs
    ld a, (drive_all)
    or a
    jr z, .have_drives         ; DRIVE=list: exactly those drives
.use_specs:
    ; No DRIVE= (or DRIVE=ALL): the drives named by the filespecs, else the
    ; current one.
    ld a, (nspecs)
    or a
    jr nz, .from_specs
    ld a, (drive_given)
    or a
    jr nz, .have_drives        ; DRIVE=ALL with no filespec: the login vector
    ld a, (curdrv)
    call mask_bit
    ld (drive_mask), hl
    jr .have_drives
.from_specs:
    ld b, a
    ld hl, specs
.spec:
    ld a, (hl)
    or a
    jr nz, .named
    ld a, (curdrv)
    jr .bit
.named:
    dec a
.bit:
    push hl
    push bc
    call mask_bit
    ld de, (drive_mask)
    ld a, d
    or h
    ld d, a
    ld a, e
    or l
    ld e, a
    ld (drive_mask), de
    pop bc
    pop hl
    ld de, 12
    add hl, de
    djnz .spec
.have_drives:
    ; Default heading length: one screen less the heading itself.
    ld hl, (o_length)
    ld a, h
    or l
    ret nz
    ld de, scb_pb
    ld c, F_SCB
    call BDOS                  ; A = page height - 1
    sub 3
    cp 5
    jr nc, .len_ok
    ld a, 5
.len_ok:
    ld l, a
    ld h, 0
    ld (o_length), hl
    ret

; ==========================================================================
; parse_spec - [d:]name[.type] into a 12-byte record: drive, name, type
;   In:       HL = first character of the token, DE = record
;   Out:      HL = first character after the token; carry = bad name
;   Clobbers: AF, BC, DE, HL
; ==========================================================================
parse_spec:
    ld (rec_dest), de
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
    push hl                    ; where the caller continues

    ld hl, (rec_dest)
    ld (hl), 0                 ; drive: default
    inc hl
    ld b, 11
.blank:
    ld (hl), ' '
    inc hl
    djnz .blank

    ld hl, spec_str
    ld a, (hl)
    or a
    jr z, .bad                 ; empty
    inc hl
    ld a, (hl)
    dec hl
    cp ':'
    jr nz, .name
    ld a, (hl)
    sub 'A'
    cp 16
    jr nc, .bad
    inc a
    ld de, (rec_dest)
    ld (de), a
    inc hl
    inc hl                     ; past "d:"
    ld a, (hl)
    or a
    jr nz, .name
    ; "d:" alone names every file
    ld hl, (rec_dest)
    inc hl
    ld b, 11
.all:
    ld (hl), '?'
    inc hl
    djnz .all
    jr .ok
.name:
    ld de, (rec_dest)
    inc de
    ld b, 8
    call parse_field
    jr c, .bad
    ld a, (hl)
    cp '.'
    jr nz, .ok
    inc hl
    ld de, (rec_dest)
    ld a, 9
    add a, e
    ld e, a
    jr nc, .nc
    inc d
.nc:
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
    ld a, (hl)
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
    ld a, (hl)
    or a
    ret z
    cp '.'
    ret z
    inc hl
    jr .skip

; ==========================================================================
; Option list
; ==========================================================================
; parse_options - everything up to the closing ']'
;   In:       HL = first character after '['
;   Out:      HL = after the ']'; carry = bad option
;   Clobbers: AF, BC, DE, HL
parse_options:
.next:
    call skip_seps
    ld a, (hl)
    cp ']'
    jr z, .close
    or a
    jr z, .end
    cp 0x0D
    jr z, .end
    call read_word
    ret c
    push hl
    call lookup_option         ; A = option id
    pop hl
    ret c
    cp 13
    jr nc, .valued
    push hl
    ld hl, opt_flags
    ld e, a
    ld d, 0
    add hl, de
    ld (hl), 1
    pop hl
    jr .next
.valued:
    jr z, .drive
    cp 14
    jr z, .user
    call skip_eq               ; LENGTH=n
    call parse_dec
    ret c
    ld a, d
    or a
    jr nz, .len_ok
    ld a, e
    cp 5
    jr c, .bad                 ; the manual says 5 and up
.len_ok:
    ld (o_length), de
    jr .next
.drive:
    call skip_eq
    call parse_drive_value
    ret c
    jr .next
.user:
    call skip_eq
    call parse_user_value
    ret c
    jr .next
.bad:
    scf
    ret
.close:
    inc hl
.end:
    or a
    ret

; read_word - copy the letters at HL into word (upper case), NUL-ended
;   Out:      HL after the word; carry = no letters or too long
;   Clobbers: AF, BC, DE, HL
read_word:
    ld de, word
    ld b, 0
.loop:
    ld a, (hl)
    call upper
    cp 'A'
    jr c, .end
    cp 'Z' + 1
    jr nc, .end
    ld (de), a
    inc de
    inc hl
    inc b
    ld a, b
    cp 10
    jr c, .loop
    scf                        ; too long to be an option
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

; lookup_option - match word against opt_table, allowing any unambiguous
;   prefix; DRIVE and DISK count as one option.
;   Out:      A = option id; carry = unknown or ambiguous
;   Clobbers: AF, BC, DE, HL
lookup_option:
    ld hl, opt_table
    ld a, 0xFF
    ld (opt_found), a
.entry:
    ld a, (hl)
    or a
    jr z, .finish
    ld (ent_ptr), hl
    ld de, word
.cmp:
    ld a, (de)
    or a
    jr z, .prefix              ; every letter of the word matched
    cp (hl)
    jr nz, .next
    inc hl
    inc de
    jr .cmp
.prefix:
    ld a, (hl)
    or a
    jr nz, .partial
    ld hl, (ent_ptr)           ; the whole name: an exact match wins
    call skip_entry
    dec hl
    ld a, (hl)
    or a
    ret
.partial:
    ld hl, (ent_ptr)
    call skip_entry
    dec hl
    ld b, (hl)                 ; B = id of this candidate
    ld a, (opt_found)
    cp 0xFF
    jr z, .first
    cp b
    jr z, .next                ; the same option under its other name
    scf                        ; two different options: ambiguous
    ret
.first:
    ld a, b
    ld (opt_found), a
.next:
    ld hl, (ent_ptr)
    call skip_entry
    jr .entry
.finish:
    ld a, (opt_found)
    cp 0xFF
    jr z, .none
    or a
    ret
.none:
    scf
    ret

; skip_entry - step over one opt_table entry: name, NUL, id
;   In:       HL = entry
;   Out:      HL = next entry
;   Clobbers: AF, HL
skip_entry:
    ld a, (hl)
    inc hl
    or a
    jr nz, skip_entry
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

; parse_drive_value - ALL, one drive letter, or (letter,letter,...)
;   In:       HL = value
;   Out:      HL after it; carry = bad; drive_mask / drive_given set
;   Clobbers: AF, BC, DE, HL
parse_drive_value:
    ld a, 1
    ld (drive_given), a
    ld a, (hl)
    cp '('
    jr z, .list
    call is_all
    jr z, .all
    jp one_drive
.all:
    ld a, 1
    ld (drive_all), a
    push hl
    ld c, F_LOGINVEC
    call BDOS                  ; HL = logged-in drives
    ld a, (curdrv)
    push hl
    call mask_bit
    pop de
    ld a, d
    or h
    ld h, a
    ld a, e
    or l
    ld l, a
    ld (drive_mask), hl
    pop hl
    or a
    ret
.list:
    inc hl
.item:
    call skip_spaces
    call one_drive
    ret c
    call skip_spaces
    ld a, (hl)
    inc hl
    cp ','
    jr z, .item
    cp ')'
    jr z, .okend
    scf
    ret
.okend:
    or a
    ret

; one_drive - one drive letter into drive_mask
;   In:       HL = letter
;   Out:      HL after it; carry = not A-P
;   Clobbers: AF, BC, DE, HL
one_drive:
    ld a, (hl)
    call upper
    sub 'A'
    cp 16
    jr nc, .bad
    inc hl
    push hl
    call mask_bit
    ld de, (drive_mask)
    ld a, d
    or h
    ld d, a
    ld a, e
    or l
    ld e, a
    ld (drive_mask), de
    pop hl
    or a
    ret
.bad:
    scf
    ret

; parse_user_value - ALL, one user number, or (n,n,...)
;   Out:      HL after it; carry = bad; user_mask / user_given set
;   Clobbers: AF, BC, DE, HL
parse_user_value:
    ld a, 1
    ld (user_given), a
    ld a, (hl)
    cp '('
    jr z, .list
    call is_all
    jr nz, .single
    ld de, 0xFFFF
    ld (user_mask), de
    xor a
    ret
.single:
    jp one_user
.list:
    inc hl
.item:
    call skip_spaces
    call one_user
    ret c
    call skip_spaces
    ld a, (hl)
    inc hl
    cp ','
    jr z, .item
    cp ')'
    jr z, .okend
    scf
    ret
.okend:
    or a
    ret

; one_user - one user number 0-15 into user_mask
;   In:       HL = digits
;   Out:      HL after them; carry = bad
;   Clobbers: AF, BC, DE, HL
one_user:
    call parse_dec
    ret c
    ld a, d
    or a
    jr nz, .bad
    ld a, e
    cp 16
    jr nc, .bad
    push hl
    call mask_bit
    ld de, (user_mask)
    ld a, d
    or h
    ld d, a
    ld a, e
    or l
    ld e, a
    ld (user_mask), de
    pop hl
    or a
    ret
.bad:
    scf
    ret

; is_all - is "ALL" next (and not the start of a longer word)?
;   In:       HL = text
;   Out:      Z = yes, and HL is after it; NZ = no, HL unchanged
;   Clobbers: AF, DE
is_all:
    push hl
    ld a, (hl)
    call upper
    cp 'A'
    jr nz, .no
    inc hl
    ld a, (hl)
    call upper
    cp 'L'
    jr nz, .no
    inc hl
    ld a, (hl)
    call upper
    cp 'L'
    jr nz, .no
    inc hl
    ld a, (hl)
    call upper
    cp 'A'
    jr c, .yes
    cp 'Z' + 1
    jr nc, .yes
.no:
    pop hl
    or 1
    ret
.yes:
    pop de                     ; the old HL is not wanted back
    xor a
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
    add hl, hl                 ; 2x
    ld d, h
    ld e, l
    add hl, hl
    add hl, hl                 ; 8x
    add hl, de                 ; 10x
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

; mask_bit - 1 << n
;   In:       A = n (0-15)
;   Out:      HL = 1 << n
;   Clobbers: AF, B, HL
mask_bit:
    ld hl, 1
    or a
    ret z
    ld b, a
.shift:
    add hl, hl
    djnz .shift
    ret

; test_bit - bit n of a mask
;   In:       HL = mask, A = n (0-15)
;   Out:      carry = the bit
;   Clobbers: AF, B, HL
test_bit:
    ld b, a
    inc b
.shift:
    srl h
    rr l
    djnz .shift
    ret

; ==========================================================================
; The drives and user areas to list
; ==========================================================================
; run_groups - every selected drive
;   Clobbers: AF, BC, DE, HL
run_groups:
    xor a
    ld (grp_drive), a
.drive:
    ld hl, (drive_mask)
    ld a, (grp_drive)
    call test_bit
    jr nc, .next_drive
    call process_drive
.next_drive:
    ld a, (grp_drive)
    inc a
    ld (grp_drive), a
    cp 16
    jr c, .drive
    ret

; process_drive - read one drive's directory, then print each selected user
;   area.  The whole directory is read in one pass (a '?' in the FCB's drive
;   byte matches every user), so no user number is ever switched: a Ctrl-C in
;   the middle cannot leave the CCP in another user area.
;   In:       grp_drive
;   Clobbers: AF, BC, DE, HL
process_drive:
    ld a, (grp_drive)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    inc a
    ret z                      ; the drive cannot be selected
    ld c, F_GETDPB
    call BDOS
    ld a, h
    or l
    ret z
    inc hl
    inc hl
    ld a, (hl)                 ; BSH
    sub 3
    ld (kshift), a             ; blocks of 1K << kshift
    inc hl
    inc hl
    ld a, (hl)                 ; EXM
    ld (exm), a
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)                 ; DSM
    ld a, d
    or a
    ld a, 0
    jr z, .narrow
    inc a
.narrow:
    ld (wide), a               ; 16-bit block numbers when DSM > 255
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)                 ; DRM
    inc de
    ld (dir_max), de

    ld hl, 0
    ld (nrec), hl
    ld (dir_used), hl
    call scan_dir

    xor a
    ld (grp_user), a
.user:
    ld hl, (user_mask)
    ld a, (grp_user)
    call test_bit
    jr nc, .next_user
    call process_user
.next_user:
    ld a, (grp_user)
    inc a
    ld (grp_user), a
    cp 16
    jr c, .user
    ret

; process_user - sort and print the files of one user area on this drive
;   In:       grp_drive, grp_user, the file table
;   Clobbers: AF, BC, DE, HL
process_user:
    ld a, (o_msg)
    or a
    jr z, .go
    ld de, msg_search
    call pstr
    call print_drive
    ld de, msg_user
    call pstr
    ld a, (grp_user)
    ld l, a
    ld h, 0
    ld bc, 0x0020
    call print_dec
    call crlf
.go:
    call build_ptrs            ; nfiles = this user's files
    ld hl, (nfiles)
    ld a, h
    or l
    ret z
    ld de, (found_total)
    add hl, de
    ld (found_total), hl
    ld a, (o_nosort)
    or a
    call z, sort_ptrs
    jp print_group

; ==========================================================================
; Reading the directory
; ==========================================================================
; scan_dir - every directory entry of the selected drive (all users) into
;   the file table, filtered and with extents merged; counts the entries in
;   use for the "Used/Max" line
;   Clobbers: AF, BC, DE, HL
scan_dir:
    call make_scan_fcb
    ld a, '?'
    ld (scanfcb), a            ; '?' in the drive byte: every entry
    ld de, scanfcb
    ld c, F_SEARCH_FIRST
    call BDOS
.loop:
    cp 0xFF
    ret z
    call entry_ptr             ; HL = the directory entry
    call handle_entry
    ld de, scanfcb
    ld c, F_SEARCH_NEXT
    call BDOS
    jr .loop

; make_scan_fcb - an FCB that matches every name and every extent
;   Clobbers: AF, BC, DE, HL
make_scan_fcb:
    ld hl, scanfcb
    ld de, scanfcb + 1
    ld bc, 35
    ld (hl), 0
    ldir
    ld hl, scanfcb + 1
    ld b, 12
.q:
    ld (hl), '?'
    inc hl
    djnz .q
    ret

; entry_ptr - address of directory entry A (0-3) in the DMA buffer
;   In:       A = index from the search
;   Out:      HL = entry
;   Clobbers: AF, DE, HL
entry_ptr:
    rrca
    rrca
    rrca
    and 0x60
    ld e, a
    ld d, 0
    ld hl, dmabuf
    add hl, de
    ret

; handle_entry - apply the filters to one directory entry and add it to the
;   file table (or to the file it is another extent of); the user number is
;   kept in the record, so a name in two user areas is two files
;   In:       HL = directory entry
;   Clobbers: AF, BC, DE, HL
handle_entry:
    ld (ent_ptr), hl
    ld a, (hl)
    cp 0xE5
    ret z                      ; erased
    push hl
    ld hl, (dir_used)
    inc hl
    ld (dir_used), hl          ; every entry that is not erased is in use
    pop hl
    ld a, (hl)
    cp 16
    ret nc                     ; labels and extended FCBs are not files
    ld (cur_user_byte), a
    ld hl, (user_mask)
    call test_bit              ; carry = a wanted user area
    ret nc
    ld hl, (ent_ptr)
    inc hl
    call name_selected         ; Z = listed
    ret nz
    ld hl, (ent_ptr)
    inc hl
    call pass_attrs            ; Z = passes
    ret nz

    ; Records and blocks this entry contributes.
    ld hl, (ent_ptr)
    ld de, 12
    add hl, de
    ld a, (hl)                 ; EX
    ld de, exm
    ld b, a
    ld a, (de)
    and b                      ; EX & EXM: which 16K piece RC counts in
    ld h, 0
    ld l, a
    add hl, hl                 ; * 128
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, (ent_ptr)
    push hl
    ld hl, 15
    add hl, de
    ld c, (hl)                 ; RC
    pop hl
    ld b, 0
    add hl, bc
    ld (cur_recs), hl
    call count_blocks
    ld (cur_blocks), hl

    ; Another extent of a file already in the table?  The last file added
    ; is the likeliest, so look backwards.
    ld hl, (nrec)
    ld a, h
    or l
    jr z, .append
    call rec_addr_of_last      ; HL = last record
.find:
    push hl
    ld de, (ent_ptr)
    inc de
    call same_name
    pop hl
    jr nz, .older
    push hl
    ld de, 11
    add hl, de
    ld a, (cur_user_byte)
    cp (hl)                    ; the same user area too
    pop hl
    jr z, .merge
.older:
    ld de, FILETAB
    xor a
    sbc hl, de
    jr z, .append              ; reached the first record: not there
    add hl, de
    ld de, REC_SIZE
    or a
    sbc hl, de
    jr .find
.merge:
    push hl
    ld de, 12
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld hl, (cur_recs)
    add hl, de
    ex de, hl
    pop hl
    push hl
    ld bc, 12
    add hl, bc
    ld (hl), e
    inc hl
    ld (hl), d
    inc hl
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld hl, (cur_blocks)
    add hl, de
    ex de, hl
    pop hl
    ld bc, 14
    add hl, bc
    ld (hl), e
    inc hl
    ld (hl), d
    ret
.append:
    ld hl, (nrec)
    ld de, MAXFILES
    or a
    sbc hl, de
    ret nc                     ; table full: later files are not listed
    ld hl, (nrec)
    call rec_addr              ; HL = new record
    ex de, hl
    ld hl, (ent_ptr)
    inc hl
    ld bc, 11
    ldir                       ; name and type with their attribute bits
    ld a, (cur_user_byte)
    ld (de), a                 ; +11 = the user area
    inc de
    ld hl, (cur_recs)
    ex de, hl
    ld (hl), e
    inc hl
    ld (hl), d
    inc hl
    ex de, hl
    ld hl, (cur_blocks)
    ex de, hl
    ld (hl), e
    inc hl
    ld (hl), d
    ld hl, (nrec)
    inc hl
    ld (nrec), hl
    ret

; rec_addr - address of file record n
;   In:       HL = n
;   Out:      HL = FILETAB + n * 16
;   Clobbers: AF, DE, HL
rec_addr:
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, FILETAB
    add hl, de
    ret

; rec_addr_of_last - address of the last file record
;   Out:      HL = record nrec - 1
;   Clobbers: AF, DE, HL
rec_addr_of_last:
    ld hl, (nrec)
    dec hl
    jr rec_addr

; same_name - do a record's name and a directory entry's name agree
;   In:       HL = record, DE = 11 name bytes of a directory entry
;   Out:      Z = same (attribute bits ignored)
;   Clobbers: AF, BC, DE, HL
same_name:
    ld b, 11
.loop:
    ld a, (de)
    xor (hl)
    and 0x7F
    ret nz
    inc hl
    inc de
    djnz .loop
    ret                        ; Z

; count_blocks - allocated blocks in the current directory entry
;   In:       ent_ptr
;   Out:      HL = number of non-zero block numbers
;   Clobbers: AF, BC, DE, HL
count_blocks:
    ld hl, (ent_ptr)
    ld de, 16
    add hl, de
    ld de, 0                   ; count
    ld a, (wide)
    or a
    jr nz, .wide
    ld b, 16
.byte:
    ld a, (hl)
    inc hl
    or a
    jr z, .bnext
    inc de
.bnext:
    djnz .byte
    ex de, hl
    ret
.wide:
    ld b, 8
.word:
    ld a, (hl)
    inc hl
    or (hl)
    inc hl
    jr z, .wnext
    inc de
.wnext:
    djnz .word
    ex de, hl
    ret

; name_selected - is a directory entry's name wanted?
;   In:       HL = 11 name bytes
;   Out:      Z = list it
;   Clobbers: AF, BC, DE, HL
name_selected:
    ld (name_ptr), hl
    ld a, (nspecs)
    or a
    jr nz, .any
    ld b, 1                    ; no filespec: everything matches
    jr .decided
.any:
    ld b, 0                    ; B = matched
    ld a, (nspecs)
    ld c, a
    ld de, specs
.spec:
    push bc
    push de
    call spec_applies          ; Z = this filespec is for this drive
    jr nz, .skip
    pop de
    push de
    inc de
    ld hl, (name_ptr)
    call match_spec            ; Z = matches
    jr nz, .skip
    pop de
    pop bc
    ld b, 1
    jr .decided
.skip:
    pop de
    pop bc
    ld hl, 12
    add hl, de
    ex de, hl
    dec c
    jr nz, .spec
.decided:
    ld a, (o_excl)
    xor b                      ; EXCLUDE inverts: B=1 means "matched"
    and 1
    ld a, b
    jr z, .excluded_same
    ; (EXCLUDE off and matched) or (EXCLUDE on and not matched): list it
    xor a
    ret
.excluded_same:
    or 1
    ret

; spec_applies - does the filespec record apply to the group's drive?
;   In:       DE = filespec record
;   Out:      Z = yes
;   Clobbers: AF, DE
spec_applies:
    ld a, (drive_given)
    or a
    jr z, .by_spec
    xor a                      ; DRIVE= given: every filespec applies
    ret
.by_spec:
    ld a, (de)
    or a
    jr nz, .named
    ld a, (curdrv)
    jr .cmp
.named:
    dec a
.cmp:
    ld e, a
    ld a, (grp_drive)
    cp e
    ret

; match_spec - match a directory name against a filespec pattern
;   In:       HL = 11 name bytes, DE = 11 pattern bytes
;   Out:      Z = match
;   Clobbers: AF, BC, DE, HL
match_spec:
    ld b, 11
.loop:
    ld a, (de)
    cp '?'
    jr z, .next
    xor (hl)
    and 0x7F
    ret nz
.next:
    inc hl
    inc de
    djnz .loop
    xor a                      ; Z
    ret

; pass_attrs - the DIR / SYS / RO / RW filters
;   In:       HL = 11 name bytes
;   Out:      Z = passes
;   Clobbers: AF, BC, DE, HL
pass_attrs:
    ld de, 8                   ; the type's first byte: R/O in bit 7
    add hl, de
    ld a, (hl)
    and 0x80
    ld b, a                    ; B = R/O bit
    inc hl
    ld a, (hl)                 ; the second: SYS
    and 0x80
    ld c, a                    ; C = SYS bit
    ld a, (o_sys)
    or a
    jr z, .no_sys_opt
    ld a, (o_dir)
    or a
    jr nz, .sys_done           ; both given: no filter
    ld a, c
    or a
    jr z, .fail                ; SYS only: needs the bit
    jr .sys_done
.no_sys_opt:
    ld a, (o_dir)
    or a
    jr z, .sys_done
    ld a, c
    or a
    jr nz, .fail               ; DIR only: needs it clear
.sys_done:
    ld a, (o_ro)
    or a
    jr z, .no_ro_opt
    ld a, (o_rw)
    or a
    jr nz, .pass
    ld a, b
    or a
    jr z, .fail
    jr .pass
.no_ro_opt:
    ld a, (o_rw)
    or a
    jr z, .pass
    ld a, b
    or a
    jr nz, .fail
.pass:
    xor a
    ret
.fail:
    or 1
    ret

; ==========================================================================
; Sorting
; ==========================================================================
; build_ptrs - PTRTAB = the records of the current user area, in table order
;   Out:      nfiles = how many
;   Clobbers: AF, BC, DE, HL
build_ptrs:
    ld bc, (nrec)
    ld hl, FILETAB
    ld de, PTRTAB
.loop:
    ld a, b
    or c
    jr z, .done
    push hl
    push de
    ld de, 11
    add hl, de
    ld a, (grp_user)
    cp (hl)
    pop de
    pop hl
    jr nz, .skip
    ex de, hl
    ld (hl), e
    inc hl
    ld (hl), d
    inc hl
    ex de, hl                  ; DE = next slot, HL = the record again
.skip:
    push de
    ld de, REC_SIZE
    add hl, de
    pop de
    dec bc
    jr .loop
.done:
    ex de, hl                  ; HL = end of the pointers
    ld de, PTRTAB
    xor a
    sbc hl, de
    srl h
    rr l                       ; two bytes a pointer
    ld (nfiles), hl
    ret

; sort_ptrs - insertion sort of PTRTAB by name (attribute bits ignored)
;   Clobbers: AF, BC, DE, HL
sort_ptrs:
    ld hl, 1
    ld (sort_i), hl
.outer:
    ld hl, (sort_i)
    ld de, (nfiles)
    or a
    sbc hl, de
    ret nc
    ; key = PTRTAB[i]
    ld hl, (sort_i)
    add hl, hl
    ld de, PTRTAB
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (sort_key), de
    ld hl, (sort_i)
    ld (sort_j), hl            ; j = i; slot j is the hole
.inner:
    ld hl, (sort_j)
    ld a, h
    or l
    jr z, .place
    dec hl                     ; compare PTRTAB[j-1] with the key
    add hl, hl
    ld de, PTRTAB
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl                  ; HL = record j-1
    ld de, (sort_key)
    call compare_names         ; carry = record j-1 > key
    jr nc, .place
    ; shift PTRTAB[j-1] up to PTRTAB[j]
    ld hl, (sort_j)
    add hl, hl
    ld de, PTRTAB
    add hl, de                 ; &PTRTAB[j]
    ld e, l
    ld d, h
    dec de
    dec de                     ; &PTRTAB[j-1]
    ex de, hl
    ld c, (hl)
    inc hl
    ld b, (hl)
    ex de, hl
    ld (hl), c
    inc hl
    ld (hl), b
    ld hl, (sort_j)
    dec hl
    ld (sort_j), hl
    jr .inner
.place:
    ld hl, (sort_j)
    add hl, hl
    ld de, PTRTAB
    add hl, de
    ld de, (sort_key)
    ld (hl), e
    inc hl
    ld (hl), d
    ld hl, (sort_i)
    inc hl
    ld (sort_i), hl
    jr .outer

; compare_names - order two records by name and type
;   In:       HL = record A, DE = record B
;   Out:      carry = A sorts after B
;   Clobbers: AF, BC, DE, HL
compare_names:
    ld b, 11
.loop:
    ld a, (de)
    and 0x7F
    ld c, a
    ld a, (hl)
    and 0x7F
    cp c
    jr nz, .differ
    inc hl
    inc de
    djnz .loop
    or a                       ; equal: not after
    ret
.differ:
    ; A (from the first record) > C (second): carry set
    ld b, a
    ld a, c
    cp b                       ; carry if C < B, i.e. first > second
    ret

; ==========================================================================
; Output
; ==========================================================================
; print_group - heading, one row per file, totals
;   Clobbers: AF, BC, DE, HL
print_group:
    ld hl, 0
    ld (tot_k), hl
    ld (tot_recs), hl
    ld (tot_1k), hl
    xor a
    ld (line_cnt), a
    ld (cell_col), a

    ld de, msg_dirfor
    call pstr
    call print_drive
    ld de, msg_user2
    call pstr
    ld a, (grp_user)
    ld l, a
    ld h, 0
    ld bc, 0x0220
    call print_dec
    call crlf
    call crlf

    ld a, (o_size)
    or a
    jr nz, .size_mode
    call print_heading
    jr .rows
.size_mode:
    call size_cells            ; cells per line
.rows:
    ld hl, 0
    ld (row_i), hl
.row:
    ld hl, (row_i)
    ld de, (nfiles)
    xor a
    sbc hl, de
    jr nc, .totals
    ld hl, (row_i)
    add hl, hl
    ld de, PTRTAB
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ld (rec_ptr), de
    call add_totals
    ld a, (o_size)
    or a
    jr nz, .size_row
    call full_row
    jr .advance
.size_row:
    call size_row
.advance:
    ld hl, (row_i)
    inc hl
    ld (row_i), hl
    jr .row
.totals:
    ld a, (o_size)
    or a
    jr z, .tot
    ld a, (cell_col)
    or a
    call nz, crlf              ; finish the last line of cells
.tot:
    call crlf
    jp print_totals

; print_heading - the two table heading lines of the FULL format
;   Clobbers: AF, BC, DE, HL
print_heading:
    ld de, msg_heading
    call pstr
    xor a
    ld (line_cnt), a
    ret

; add_totals - add the record at rec_ptr to the group totals
;   Clobbers: AF, BC, DE, HL
add_totals:
    ld hl, (rec_ptr)
    ld de, 12
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)                 ; DE = records
    ld hl, (tot_recs)
    add hl, de
    ld (tot_recs), hl
    ex de, hl
    ld de, 7
    add hl, de                 ; ceil(records / 8) = 1K blocks
    srl h
    rr l
    srl h
    rr l
    srl h
    rr l
    ex de, hl
    ld hl, (tot_1k)
    add hl, de
    ld (tot_1k), hl
    call rec_kbytes            ; HL = allocated K
    ex de, hl
    ld hl, (tot_k)
    add hl, de
    ld (tot_k), hl
    ret

; rec_kbytes - allocated kilobytes of the record at rec_ptr
;   Out:      HL = blocks << (BSH - 3)
;   Clobbers: AF, B, DE, HL
rec_kbytes:
    ld hl, (rec_ptr)
    ld de, 14
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ld a, (kshift)
    or a
    ret z
    ld b, a
.shift:
    add hl, hl
    djnz .shift
    ret

; full_row - one line of the FULL format
;   In:       rec_ptr
;   Clobbers: AF, BC, DE, HL
full_row:
    ld hl, (o_length)
    ld a, h
    or a
    jr z, .len_ok
    ld l, 255                  ; a very long length: effectively never
.len_ok:
    ld a, (line_cnt)
    cp l
    jr c, .go
    call print_heading
.go:
    ld a, (line_cnt)
    inc a
    ld (line_cnt), a

    ld hl, (rec_ptr)
    call print_name12
    ld a, ' '
    call cout
    call rec_kbytes
    ld bc, 0x0520
    call print_dec
    ld a, 'K'
    call cout
    ld a, ' '
    call cout
    ld hl, (rec_ptr)
    ld de, 12
    add hl, de
    ld e, (hl)
    inc hl
    ld d, (hl)
    ex de, hl
    ld bc, 0x0620
    call print_dec
    ld a, ' '
    call cout
    ld a, ' '
    call cout
    call print_attrs
    jp crlf

; print_attrs - "Dir RW" / "Sys RO", plus the F1-F4 flags with ATT
;   In:       rec_ptr
;   Clobbers: AF, BC, DE, HL
print_attrs:
    ld hl, (rec_ptr)
    ld de, 9
    add hl, de
    ld a, (hl)                 ; T2: SYS
    and 0x80
    ld de, str_dir
    jr z, .p1
    ld de, str_sys
.p1:
    call pstr
    ld hl, (rec_ptr)
    ld de, 8
    add hl, de
    ld a, (hl)                 ; T1: R/O
    and 0x80
    ld de, str_rw
    jr z, .p2
    ld de, str_ro
.p2:
    call pstr
    ld a, (o_att)
    or a
    ret z
    ld b, 4
    ld c, '1'
.f:
    push bc
    ld a, 4
    sub b                      ; name character 1-4 (record offset 0-3)
    ld e, a
    ld d, 0
    ld hl, (rec_ptr)
    add hl, de
    ld a, (hl)
    and 0x80
    jr z, .nof
    ld a, ' '
    call cout
    ld a, 'F'
    call cout
    pop bc
    push bc
    ld a, c
    call cout
.nof:
    pop bc
    inc c
    djnz .f
    ret

; size_cells - how many "name size" cells fit on a line
;   Out:      cells_per_line
;   Clobbers: AF, BC, DE, HL
size_cells:
    ld de, scb_pb_w
    ld c, F_SCB
    call BDOS                  ; A = columns - 1
    inc a
    ld c, 0
.div:
    sub 21
    jr c, .done
    inc c
    jr .div
.done:
    ld a, c
    or a
    jr nz, .ok
    inc a
.ok:
    ld (cells_per_line), a
    ret

; size_row - one cell of the SIZE format
;   In:       rec_ptr
;   Clobbers: AF, BC, DE, HL
size_row:
    ld a, (cell_col)
    or a
    jr nz, .sep
    call print_drive
    ld a, ':'
    call cout
    ld a, ' '
    call cout
    jr .cell
.sep:
    ld de, str_sep
    call pstr
.cell:
    ld hl, (rec_ptr)
    call print_name12
    ld a, ' '
    call cout
    call rec_kbytes
    ld bc, 0x0420
    call print_dec
    ld a, 'K'
    call cout
    ld a, (cell_col)
    inc a
    ld (cell_col), a
    ld hl, cells_per_line
    cp (hl)
    ret c
    xor a
    ld (cell_col), a
    jp crlf

; print_totals - the two summary lines
;   Clobbers: AF, BC, DE, HL
print_totals:
    ld de, msg_tot1
    call pstr
    ld hl, (tot_k)
    ld bc, 0x0520
    call print_dec
    ld de, msg_tot2
    call pstr
    ld hl, (tot_recs)
    ld bc, 0x0520
    call print_dec
    call crlf
    ld de, msg_tot3
    call pstr
    ld hl, (nfiles)
    ld bc, 0x0520
    call print_dec
    ld de, msg_tot4
    call pstr
    ld hl, (tot_1k)
    ld bc, 0x0520
    call print_dec
    call crlf
    ld de, msg_tot5
    call pstr
    call print_drive
    ld a, ':'
    call cout
    ld a, ' '
    call cout
    ld hl, (dir_used)
    ld bc, 0x0420
    call print_dec
    ld a, '/'
    call cout
    ld hl, (dir_max)
    ld bc, 0x0420
    call print_dec
    call crlf
    jp crlf

; print_drive - the group's drive letter
;   Clobbers: AF, BC, DE, HL
print_drive:
    ld a, (grp_drive)
    add a, 'A'
    jp cout

; print_name12 - "NAME     TYP": 8, a space, 3; attribute bits dropped
;   In:       HL = 11 name bytes
;   Clobbers: AF, BC, DE, HL
print_name12:
    ld b, 8
    call .chars
    push hl
    ld a, ' '
    call cout
    pop hl
    ld b, 3
.chars:
    ld a, (hl)
    and 0x7F
    inc hl
    push hl
    push bc
    call cout
    pop bc
    pop hl
    djnz .chars
    ret

; print_dec - right-aligned unsigned decimal
;   In:       HL = value, B = field width, C = pad character
;   Clobbers: AF, BC, DE, HL
print_dec:
    ld (pad_w), bc             ; pad_w = C (pad), pad_w + 1 = B (width)
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

; ==========================================================================
; Console helpers
; ==========================================================================
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
err_name:
    ld de, msg_bad_name
    jr fail
err_option:
    ld de, msg_bad_option
fail:
    call pstr
    rst 0

; --- Data ---
curdrv:         db 0
curuser:        db 0
save_mode:      dw 0
nspecs:         db 0
opts_seen:      db 0
drive_given:    db 0
drive_all:      db 0
user_given:     db 0
drive_mask:     dw 0
user_mask:      dw 0
o_length:       dw 0

; One flag byte per simple option, indexed by the option id (0-12).
opt_flags:
o_att:          db 0
o_date:         db 0
o_dir:          db 0
o_excl:         db 0
o_ff:           db 0
o_full:         db 0
o_msg:          db 0
o_nopage:       db 0
o_nosort:       db 0
o_ro:           db 0
o_rw:           db 0
o_size:         db 0
o_sys:          db 0

; Option names; ids 13-15 take a value (DRIVE/DISK, USER, LENGTH).
opt_table:
    db "ATT", 0, 0
    db "DATE", 0, 1
    db "DIR", 0, 2
    db "EXCLUDE", 0, 3
    db "FF", 0, 4
    db "FULL", 0, 5
    db "MESSAGE", 0, 6
    db "NOPAGE", 0, 7
    db "NOSORT", 0, 8
    db "RO", 0, 9
    db "RW", 0, 10
    db "SIZE", 0, 11
    db "SYS", 0, 12
    db "DRIVE", 0, 13
    db "DISK", 0, 13
    db "USER", 0, 14
    db "LENGTH", 0, 15
    db 0

word:           ds 12
opt_found:      db 0
ent_ptr:        dw 0
name_ptr:       dw 0
rec_dest:       dw 0
grp_drive:      db 0
grp_user:       db 0
kshift:         db 0
exm:            db 0
wide:           db 0
dir_max:        dw 0
dir_used:       dw 0
nrec:           dw 0                ; records in the file table
nfiles:         dw 0                ; this user area's files
cur_user_byte:  db 0
found_total:    dw 0
cur_recs:       dw 0
cur_blocks:     dw 0
sort_i:         dw 0
sort_j:         dw 0
sort_key:       dw 0
row_i:          dw 0
rec_ptr:        dw 0
tot_k:          dw 0
tot_recs:       dw 0
tot_1k:         dw 0
line_cnt:       db 0
cell_col:       db 0
cells_per_line: db 1
pad_w:          dw 0
ndig:           db 0
numbuf:         ds 6

scb_pb:         db 0x1C, 0, 0, 0   ; SCB console page height - 1 (get)
scb_pb_w:       db 0x1A, 0, 0, 0   ; SCB console width - 1 (get)

msg_crlf:       db 0x0D, 0x0A, '$'
msg_no_file:    db "No File", 0x0D, 0x0A, '$'
msg_nodate:     db "Date and Time Stamping Inactive", 0x0D, 0x0A, '$'
msg_bad_name:   db "Invalid file specification", 0x0D, 0x0A, '$'
msg_bad_option: db "Invalid option", 0x0D, 0x0A, '$'
msg_search:     db "Searching drive $"
msg_user:       db ": user $"
msg_dirfor:     db "Directory For Drive $"
msg_user2:      db ":  User $"
msg_heading:    db "Name         Bytes    Recs  Attributes", 0x0D, 0x0A
                db "------------ ------ ------  ------------", 0x0D, 0x0A, '$'
msg_tot1:       db "Total Bytes     = $"
msg_tot2:       db "K  Total Records = $"
msg_tot3:       db "Files Found     = $"
msg_tot4:       db "   Total 1K Blocks = $"
msg_tot5:       db "Used/Max Dir Entries For Drive $"
str_dir:        db "Dir $"
str_sys:        db "Sys $"
str_rw:         db "RW$"
str_ro:         db "RO$"
str_sep:        db " : $"
