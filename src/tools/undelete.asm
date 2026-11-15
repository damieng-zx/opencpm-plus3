; UNDELETE.COM - restore files deleted by the CP/M BDOS
;
; Usage:  UNDELETE                  list deleted files on the current drive
;         UNDELETE d:               list them on drive d:
;         UNDELETE filespec         list matching deleted files
;         UNDELETE filespec R       restore it, into user 0
;         UNDELETE filespec R U=n   restore it into user area n
;
; Deleting a file in CP/M writes 0E5h over the first byte of every directory
; entry it owns and clears the blocks in the allocation vector; the name,
; extent number, record count and block pointers are left on the disc.  The
; BDOS will not show such an entry again - F17/F18 skip any entry whose first
; byte is E5h - so this tool reads the directory sectors itself through the
; XBIOS disc calls (DD_LOGIN, DD_READ_SECTOR, DD_WRITE, DD_CHECK_SECTOR),
; the same path FORMAT, DISKCOPY and SYSGEN use.
;
; Restoring is that one byte: put a user number back.  Two things make it
; fail loudly instead of returning a corrupt file:
;
;   * the user number is genuinely gone - the delete overwrote it - so the
;     tool asks for one and defaults to 0;
;   * the freed blocks may have been handed to something written since.
;     Every block of every candidate extent is checked against every live
;     directory entry first, and the restore is refused if any is in use.
;
; Every extent of the name is restored together or none is, since restoring
; some of them would give back a truncated file.  Each rewritten sector is
; read back with DD_CHECK_SECTOR, and the BDOS's disk reset (F13) then drops
; its cached directory sector and rebuilds the allocation vector.
;
; A: and B: only.  The XBIOS disc calls address FDC units 0 and 1, so the
; C: RAM disc cannot be undeleted.  Layouts with 16-bit block numbers in the
; directory (DSM > 255, e.g. the 720K image) are refused rather than
; half-supported, because the block scan here reads one byte per block.
;
; Build: sjasmplus --raw=build/undelete.com src/tools/undelete.asm

    org 0x0100

BDOS            equ 0x0005
F_CONIN         equ 1
F_CONOUT        equ 2
F_DIRECT        equ 6
F_PSTR          equ 9
F_RESET         equ 13
F_SELDRV        equ 14
F_CURDRV        equ 25

TAIL            equ 0x0080
USERF_OFFSET    equ 90

DD_LOGIN        equ 0x0092
DD_READ_SECTOR  equ 0x0086
DD_WRITE        equ 0x0089
DD_CHECK_SECTOR equ 0x008C

SECTOR_SIZE     equ 512
ENTRY_SIZE      equ 32
ENTRIES_PER_SEC equ 16
DELETED         equ 0xE5

DIR_NAME        equ 1
DIR_EXTENT      equ 12
DIR_RC          equ 15
DIR_BLOCKS      equ 16
BLOCKS_PER_ENT  equ 16

; DPB / XDPB field offsets (the XDPB begins with the 17-byte DPB)
XDPB_SPT        equ 0
XDPB_DSM        equ 5
XDPB_DRM        equ 7
XDPB_OFF        equ 13
XDPB_PSH        equ 15
XDPB_SIDES      equ 17

; Buffers live at D200 upwards: C000-FFFF is bank 3 in both TPA and system
; mode, so the XBIOS disc calls can see them wherever they run from.
XDPB            equ 0xD200     ; 27 bytes, filled by DD_LOGIN
DIRBUF          equ 0xD400     ; the whole directory, entries contiguous
DIRBUF_MAX      equ 0x2000     ; 256 entries is the most CP/M allows

; ==========================================================================
; Entry
; ==========================================================================
start:
    ; USERF address, derived from the WBOOT vector in page zero.
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    ld de, USERF_OFFSET
    add hl, de
    ld (userf_call + 1), hl

    ld c, F_CURDRV
    call BDOS
    ld (orig_drive), a
    ld (drive), a

    ; ---- Command tail ----
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, no_argument
    inc hl
    call skip_spaces
    ld a, (hl)
    or a
    jp z, no_argument
    cp 0x0D
    jp z, no_argument

    call parse_drive_prefix
    call skip_spaces
    ld a, (hl)
    or a
    jr z, .options
    cp 0x0D
    jr z, .options
    call parse_filespec           ; Cy = bad name
    jp c, usage
.options:
    call parse_options            ; Cy = bad option
    jp c, usage

    ; ---- Read the whole directory ----
    call read_directory           ; Cy = failure, A = reason code
    jp c, read_failed

    ld a, (do_restore)
    or a
    jr nz, .restore
    call list_matches
    jp finish

.restore:
    ; Restoring needs one specific name: a wildcard is ambiguous.
    ld a, (have_spec)
    or a
    jp z, need_name
    ld a, (has_wild)
    or a
    jp nz, need_exact

    call collect_matches
    jp c, no_matches
    call check_blocks             ; Cy = a block is in use
    jp c, blocks_in_use
    call confirm_restore          ; Cy = declined
    jp c, cancelled
    call write_restored           ; Cy = write/verify failed
    jp c, write_failed

    ld de, msg_restored
    call pstr
    call print_spec
    ld de, msg_to_user
    call pstr
    ld a, (restore_user)
    call print_a_decimal
    ld de, msg_extents
    call pstr
    ld a, (cand_count)
    call print_a_decimal
    ld de, msg_crlf
    call pstr
    jp finish

; ==========================================================================
; Command line
; ==========================================================================
; parse_drive_prefix - consume "d:" if present
;   In:       HL = text
;   Out:      HL advanced past "d:", drive set; unchanged if no prefix
;   Clobbers: AF, B, HL
parse_drive_prefix:
    ld a, (hl)
    and 0xDF
    cp 'A'
    ret c
    cp 'Z' + 1
    ret nc
    ld b, a
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .none
    inc hl
    ld a, b
    sub 'A'
    ld (drive), a
    ret
.none:
    dec hl
    ret

; parse_filespec - copy "NAME.EXT" from HL into spec_name/spec_ext
;   Out:      carry set = malformed; have_spec and has_wild updated
;   Clobbers: AF, BC, DE, HL
parse_filespec:
    ld a, 1
    ld (have_spec), a
    xor a
    ld (has_wild), a

    ld de, spec_name
    call fill_spaces8
    ld de, spec_ext
    call fill_spaces3

    ld de, spec_name
    ld b, 8
.name:
    ld a, (hl)
    call name_char
    jr c, .name_done
    ld (de), a
    inc hl
    inc de
    djnz .name
    call skip_name
.name_done:
    ; Anything left before '.' is too long: skip it, as CP/M does.
    call skip_name

    ld a, (hl)
    cp '.'
    jr nz, .done
    inc hl
    ld de, spec_ext
    ld b, 3
.ext:
    ld a, (hl)
    call name_char
    jr c, .ext_done
    ld (de), a
    inc hl
    inc de
    djnz .ext
.ext_done:
    call skip_ext
.done:
    ; The name is complete; report success explicitly rather than relying on
    ; whatever flags the last skip left behind.
    xor a
    ret

; name_char - validate/copy one filespec character
;   In:       A = character
;   Out:      carry set = end of the field; else A = uppercased char,
;             carry clear
;   Clobbers: AF
name_char:
    cp ' '
    jr z, .end
    cp 0x0D
    jr z, .end
    or a
    jr z, .end
    cp '.'
    jr z, .end
    ; '*' is CP/M's shorthand for a whole field of '?', so it is just as
    ; much a wildcard as '?' is - a restore must refuse it either way.
    cp '*'
    jr z, .star
    cp '?'
    jr nz, .upper
    push af
    ld a, 1
    ld (has_wild), a
    pop af
    jr .upper
.star:
    push af
    ld a, 1
    ld (has_wild), a
    pop af
    ld a, '?'
.upper:
    ; Fold to upper case.  This must leave carry CLEAR: carry is how this
    ; routine says "end of field", and a compare-based ret would set it for
    ; every letter.
    cp 'a'
    jr c, .done
    cp 'z' + 1
    jr nc, .done
    and 0xDF
.done:
    or a                          ; clear carry: more characters to copy
    ret
.end:
    scf
    ret

; skip_name - advance HL to the next '.' or the end
;   In:       HL = text
;   Out:      HL = first character that ends the name
;   Clobbers: AF
skip_name:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    ret z
    cp '.'
    ret z
    inc hl
    jr skip_name

; skip_ext - advance HL past the extension to the end of the token
;   In:       HL = text
;   Out:      HL = first character after the extension
;   Clobbers: AF
skip_ext:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    ret z
    inc hl
    jr skip_ext

; fill_spaces8 / fill_spaces3 - pad a name field
;   In:       DE = field
;   Clobbers: AF, B, DE
fill_spaces8:
    ld b, 8
    jr fill_spaces
fill_spaces3:
    ld b, 3
fill_spaces:
    ld a, ' '
    ld (de), a
    inc de
    djnz fill_spaces
    ret

; parse_options - "R" for restore and "U=n" for the target user, in any order
;   In:       HL = text
;   Out:      carry set = syntax error
;   Clobbers: AF, BC, DE, HL
parse_options:
.again:
    call skip_spaces
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    and 0xDF
    cp 'R'
    jr nz, .user
    inc hl
    ld a, (hl)
    call .only_space_left
    ret c
    ld a, 1
    ld (do_restore), a
    jr .again
.user:
    cp 'U'
    jr nz, .bad
    inc hl
    ld a, (hl)
    cp '='
    jr nz, .bad
    inc hl
    call parse_decimal
    jr c, .bad
    cp 16
    jr nc, .bad
    ld (restore_user), a
    jr .again
.bad:
    scf
    ret
; only_space_left - carry set if what follows is not whitespace/end
.only_space_left:
    cp ' '
    ret z
    cp 0x0D
    ret z
    or a
    ret z
    scf
    ret

; parse_decimal - read a decimal number at HL
;   Out:      A = value (0-255), HL advanced; carry set if no digits or too big
;   Clobbers: AF, BC, DE, HL
parse_decimal:
    xor a
    ld (pd_seen), a
    ld b, 0                       ; accumulator
.loop:
    ld a, (hl)
    sub '0'
    jr c, .done
    cp 10
    jr nc, .done
    ld (pd_digit), a
    ; accumulator = accumulator * 10 + digit, with overflow to "too big"
    ld a, b
    add a, a
    jr c, .big
    ld d, a                       ; D = acc * 2
    add a, a                      ; * 4
    jr c, .big
    add a, a                      ; * 8
    jr c, .big
    add a, d                      ; * 10
    jr c, .big
    ld d, a
    ld a, (pd_digit)
    add a, d
    jr c, .big
    ld b, a
    inc hl
    ld a, 1
    ld (pd_seen), a
    jr .loop
.big:
    scf
    ret
.done:
    ld a, (pd_seen)
    or a
    jr z, .none
    ld a, b
    or a
    ret
.none:
    scf
    ret

; ==========================================================================
; Directory access
; ==========================================================================
; read_directory - log in the drive and read every directory sector into
;   DIRBUF as contiguous 32-byte entries.
;   Out:      carry set on failure, A = reason code (1..6); else
;             dir_entries and dir_sectors are set
;   Clobbers: AF, BC, DE, HL, IX
read_directory:
    ld a, (drive)
    cp 2
    jp nc, .err_unit

    ld hl, DD_LOGIN
    ld (userf_dw), hl
    ld a, (drive)
    ld c, a
    ld ix, XDPB
    call userf_call
    jp nc, .err_login

    ; 16-bit block numbers (DSM > 255) are not supported here.
    ld a, (XDPB + XDPB_DSM + 1)
    or a
    jp nz, .err_blocks

    ; entries = DRM + 1.  DRM is a 16-bit little-endian field; directories
    ; never exceed 256 entries, so the high byte is 0 or the value is 256.
    ld a, (XDPB + XDPB_DRM + 1)
    or a
    jp nz, .err_geometry          ; > 256 entries cannot happen; refuse anyway
    ld a, (XDPB + XDPB_DRM)
    inc a                         ; DRM=255 wraps to 0, meaning 256
    ld l, a
    ld h, 0
    jr nz, .have_entries
    ld hl, 256
.have_entries:
    ld (dir_entries), hl

    ; sectors = entries / 16 (entries is always a multiple of 16 here)
    ld b, 4
.entries_shift:
    srl h
    rr l
    djnz .entries_shift
    ld a, l
    ld (dir_sectors), a
    or a
    jp z, .err_geometry

    ; Read each sector to DIRBUF + n * 512.
    xor a
    ld (dir_sec), a
.sector:
    call dir_sector_address       ; HL = DIRBUF + n*512, E = record number
    ld (xfer_ptr), hl
    ld hl, DD_READ_SECTOR
    ld (userf_dw), hl
    ld a, (dir_sec)
    call dir_track_sector         ; D = track, E = record within it
    ld (xfer_track), de
    ld hl, (xfer_ptr)
    ld a, (drive)
    ld c, a
    ld b, 1
    ld ix, XDPB
    call userf_call
    jp nc, .err_read
    ld a, (dir_sec)
    inc a
    ld (dir_sec), a
    ld b, a
    ld a, (dir_sectors)
    cp b
    jr nz, .sector
    or a
    ret

.err_unit:
    ld a, 1
    scf
    ret
.err_login:
    ld a, 2
    scf
    ret
.err_blocks:
    ld a, 3
    scf
    ret
.err_geometry:
    ld a, 4
    scf
    ret
.err_read:
    ld a, 5
    scf
    ret

; dir_sector_address - HL = DIRBUF + dir_sec * 512
;   In:       dir_sec
;   Out:      HL = the buffer address for that sector
;   Clobbers: AF, DE, HL
dir_sector_address:
    ld a, (dir_sec)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                    ; * 512
    ld de, DIRBUF
    add hl, de
    ret

; dir_track_sector - map a directory sector to the XBIOS D/E pair
;   In:       A = directory sector index
;   Out:      D = logical track, E = 128-byte record within the track
;   Clobbers: AF, BC, HL
;
; The XBIOS takes E as a record number and D as a logical track.  A
; directory sector is 512 bytes = 4 records when PSH is 2, and the directory
; starts at record 0 of the first data track (track OFF).  The directory is
; small (4 sectors on a 180K disc, 8 on a 720K one), so it cannot span a
; track, but the division is done properly rather than assumed.
dir_track_sector:
    ld l, a
    ld h, 0                       ; HL = sector index
    ld a, (XDPB + XDPB_PSH)
    ld b, a
    or a
    jr z, .scaled
.scale:
    add hl, hl                    ; record = sector << PSH
    djnz .scale
.scaled:
    ; HL = record number.  E = record % SPT, C = record / SPT.  The directory
    ; is a few sectors at the start of the data area, so this is a short
    ; repeated subtraction in practice; doing it properly keeps it correct
    ; for any layout.
    ld a, (XDPB + XDPB_SPT)
    ld e, a
    ld d, 0                       ; DE = SPT
    ld c, 0
    ld a, e
    or d
    jr z, .divided                ; SPT of 0 cannot divide; leave as-is
.divide:
    or a
    sbc hl, de
    jr c, .remainder              ; went negative: HL is the remainder
    inc c
    jr .divide
.remainder:
    add hl, de                    ; undo the last subtraction
    ld e, l                       ; E = record within the track
    ld a, (XDPB + XDPB_OFF)
    add a, c
    ld d, a                       ; D = OFF + track offset
    ret
.divided:
    ld e, l
    ld a, (XDPB + XDPB_OFF)
    ld d, a
    ret

; ==========================================================================
; Entry helpers
; ==========================================================================
; entry_at - HL = DIRBUF + index * 32
;   In:       HL = entry index
;   Out:      HL = address; carry set if past dir_entries
;   Clobbers: AF, B, DE, HL
;
; Directories are at most 256 entries (DRM <= 255), so the index fits in a
; byte, but the comparison is 16-bit to stay correct when DRM is 255.
; The test is "index <= dir_entries - 1", so an index equal to dir_entries
; is already past the end.
entry_at:
    ld de, (dir_entries)
    or a
    sbc hl, de
    jr nc, .past                  ; index >= dir_entries
    add hl, de                    ; restore the index
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                    ; * 32
    ld de, DIRBUF
    add hl, de
    or a
    ret
.past:
    scf
    ret

; entry_matches - does the entry at HL match the filespec?
;   In:       HL = entry
;   Out:      carry set = no match
;   Clobbers: AF, BC, DE, HL
entry_matches:
    ld a, (have_spec)
    or a
    ret z
    push hl
    inc hl                        ; skip the user byte
    ld de, spec_name
    ld b, 8
.name:
    ld a, (de)
    cp '?'
    jr z, .name_next
    ld c, a
    ld a, (hl)
    and 0x7F                      ; ignore the attribute bits
    cp c
    jr nz, .no
.name_next:
    inc hl
    inc de
    djnz .name
    ld de, spec_ext
    ld b, 3
.ext:
    ld a, (de)
    cp '?'
    jr z, .ext_next
    ld c, a
    ld a, (hl)
    and 0x7F
    cp c
    jr nz, .no
.ext_next:
    inc hl
    inc de
    djnz .ext
    pop hl
    or a
    ret
.no:
    pop hl
    scf
    ret

; is_deleted_file - is the E5h entry at HL a real deleted file rather than a
;   directory slot that was never used?  A freshly formatted disc is all E5h
;   and the BDOS treats such slots as free, not as deleted files.  A slot
;   that once held a file keeps its name, so requiring at least one name
;   byte to differ from E5h tells them apart.
;   In:       HL = entry (first byte is E5h)
;   Out:      HL = the entry, unchanged; carry set = never used, skip it
;   Clobbers: AF, B
is_deleted_file:
    push hl
    inc hl
    ld b, 11
.loop:
    ld a, (hl)
    cp DELETED
    jr nz, .real
    inc hl
    djnz .loop
    pop hl
    scf
    ret
.real:
    pop hl
    or a
    ret

; ==========================================================================
; Listing
; ==========================================================================
; list_matches - print every deleted entry matching the filespec
;   Clobbers: everything
list_matches:
    xor a
    ld (matches), a
    ld hl, 0
    ld (ent_idx), hl
.loop:
    ld hl, (ent_idx)
    call entry_at
    jr c, .done
    ld a, (hl)
    cp DELETED
    jr nz, .next
    call is_deleted_file
    jr c, .next
    call entry_matches
    jr c, .next
    call print_entry
    ld a, (matches)
    inc a
    ld (matches), a
.next:
    ld hl, (ent_idx)
    inc hl
    ld (ent_idx), hl
    jr .loop
.done:
    ld a, (matches)
    or a
    ret nz
    ld de, msg_none
    jp pstr

; print_entry - print one deleted entry
;   In:       HL = entry
;   Clobbers: everything
print_entry:
    ld (cur_entry), hl
    ld de, msg_drive
    call pstr
    ld a, (drive)
    add a, 'A'
    call pc
    ld a, ':'
    call pc
    ld a, ' '
    call pc

    ld hl, (cur_entry)
    inc hl                        ; skip the deleted-user byte
    call print_name_field

    ; Extent number and record count.
    ld hl, (cur_entry)
    ld de, DIR_EXTENT
    add hl, de
    ld a, (hl)
    and 0x1F
    ld l, a
    ld h, 0
    ld (ext_num), hl
    ld hl, (cur_entry)
    ld de, DIR_RC
    add hl, de
    ld a, (hl)
    or a
    jr nz, .rc
    ld a, 128                     ; RC 0 means a full extent
.rc:
    ld l, a
    ld h, 0
    ld (recs), hl

    ld de, msg_sep
    call pstr
    ld hl, (ext_num)
    call print_de16
    ld de, msg_records
    call pstr
    ld hl, (recs)
    call print_de16
    ld de, msg_crlf
    jp pstr

; ==========================================================================
; Restore
; ==========================================================================
; collect_matches - count the matching deleted entries
;   Out:      cand_count, carry set if none
;   Clobbers: everything
collect_matches:
    xor a
    ld (cand_count), a
    ld hl, 0
    ld (ent_idx), hl
.loop:
    ld hl, (ent_idx)
    call entry_at
    jr c, .done
    ld a, (hl)
    cp DELETED
    jr nz, .next
    call is_deleted_file
    jr c, .next
    call entry_matches
    jr c, .next
    ld a, (cand_count)
    inc a
    ld (cand_count), a
.next:
    ld hl, (ent_idx)
    inc hl
    ld (ent_idx), hl
    jr .loop
.done:
    ld a, (cand_count)
    or a
    ret nz
    scf
    ret

; check_blocks - refuse if any block of any matching entry is in use
;   Out:      carry set = a block is in use
;   Clobbers: AF, BC, DE, HL
check_blocks:
    ld hl, 0
    ld (ent_idx), hl
.cand:
    ld hl, (ent_idx)
    call entry_at
    jr c, .ok
    ld a, (hl)
    cp DELETED
    jr nz, .cand_next
    call is_deleted_file
    jr c, .cand_next
    ld (cur_entry), hl
    call entry_matches
    jr c, .cand_next
    ; Each of the 16 block bytes.  entry_matches clobbers HL, so the entry
    ; address comes back from cur_entry.
    ld hl, (cur_entry)
    ld de, DIR_BLOCKS
    add hl, de
    ld (blk_ptr), hl
    xor a
    ld (blk_idx), a
.blk:
    ld hl, (blk_ptr)
    ld a, (hl)
    or a
    jr z, .blk_next
    ld (blk_test), a
    call block_in_use
    jr c, .busy
.blk_next:
    ld hl, (blk_ptr)
    inc hl
    ld (blk_ptr), hl
    ld a, (blk_idx)
    inc a
    ld (blk_idx), a
    cp BLOCKS_PER_ENT
    jr nz, .blk
.cand_next:
    ld hl, (ent_idx)
    inc hl
    ld (ent_idx), hl
    jr .cand
.ok:
    or a
    ret
.busy:
    scf
    ret

; block_in_use - is blk_test claimed by any live directory entry?
;   Out:      carry set = yes
;   Clobbers: everything except ent_idx and blk_ptr/blk_idx, which
;             check_blocks is using as its own loop state
block_in_use:
    ld hl, 0
    ld (use_ent), hl
.entry:
    ld hl, (use_ent)
    call entry_at
    jr c, .free
    ld a, (hl)
    cp DELETED
    jr z, .next                   ; a deleted entry claims nothing
    ; NOTE: user number 0 is the default user area and is a perfectly live
    ; entry.  0E5h is the only "slot never used" marker, so there must be no
    ; `or a` test here - it would skip every user-0 file, which is most of
    ; them.
    ld de, DIR_BLOCKS
    add hl, de
    ld (use_ptr), hl
    xor a
    ld (use_idx), a
.blk:
    ld hl, (use_ptr)
    ld a, (hl)
    ld c, a
    ld a, (blk_test)
    cp c
    jr z, .yes
    ld hl, (use_ptr)
    inc hl
    ld (use_ptr), hl
    ld a, (use_idx)
    inc a
    ld (use_idx), a
    cp BLOCKS_PER_ENT
    jr nz, .blk
.next:
    ld hl, (use_ent)
    inc hl
    ld (use_ent), hl
    jr .entry
.free:
    or a
    ret
.yes:
    scf
    ret

; confirm_restore - describe the restore and wait for Y
;   Out:      carry set = declined
;   Clobbers: everything
confirm_restore:
    ld de, msg_restore_q
    call pstr
    call print_spec
    ld de, msg_to_user
    call pstr
    ld a, (restore_user)
    call print_a_decimal
    ld de, msg_extents
    call pstr
    ld a, (cand_count)
    call print_a_decimal
    ld de, msg_question
    call pstr
    call read_confirm
    jr c, .no
    cp 'Y'
    jr z, .yes
.no:
    scf
    ret
.yes:
    or a
    ret

; write_restored - set the user byte on every matching deleted entry and
;   write each changed directory sector back, verifying it.
;   Out:      carry set = failed
;   Clobbers: everything
write_restored:
    xor a
    ld (dir_sec), a
.sector:
    xor a
    ld (sector_dirty), a
    call mark_sector
    ld a, (sector_dirty)
    or a
    jr z, .skip_sector
    call write_dir_sector
    jr c, .failed
.skip_sector:
    ld a, (dir_sec)
    inc a
    ld (dir_sec), a
    ld b, a
    ld a, (dir_sectors)
    cp b
    jr nz, .sector
    or a
    ret
.failed:
    scf
    ret

; mark_sector - restore every matching deleted entry in the current sector
;   In:       dir_sec
;   Out:      sector_dirty set if anything changed
;   Clobbers: AF, BC, DE, HL
mark_sector:
    ; Index of this sector's first entry = dir_sec * 16.
    ld a, (dir_sec)
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld de, (dir_entries)
    ; A sector wholly past the end of the directory has nothing to do.
    or a
    sbc hl, de
    ret nc                        ; first index >= entries
    add hl, de                    ; restore
    ld (sector_first), hl
    xor a
    ld (sector_n), a
.entry:
    ld hl, (sector_first)
    ld a, (sector_n)
    ld e, a
    ld d, 0
    add hl, de
    call entry_at
    jr c, .done
    ld (cur_entry), hl
    ld a, (hl)
    cp DELETED
    jr nz, .next
    call is_deleted_file
    jr c, .next
    call entry_matches
    jr c, .next
    ld hl, (cur_entry)
    ld a, (restore_user)
    ld (hl), a
    ld a, 1
    ld (sector_dirty), a
.next:
    ld a, (sector_n)
    inc a
    ld (sector_n), a
    cp ENTRIES_PER_SEC
    jr nz, .entry
.done:
    ret

; write_dir_sector - write the current directory sector back and verify it
;   Out:      carry set = failed
;   Clobbers: everything
write_dir_sector:
    call dir_sector_address
    ld (xfer_ptr), hl

    ld hl, DD_WRITE
    ld (userf_dw), hl
    ld a, (dir_sec)
    call dir_track_sector
    ld (xfer_track), de
    ld hl, (xfer_ptr)
    ld a, (drive)
    ld c, a
    ld b, 1
    ld ix, XDPB
    call userf_call
    jr nc, .failed

    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld a, (dir_sec)
    call dir_track_sector
    ld (xfer_track), de
    ld hl, (xfer_ptr)
    ld a, (drive)
    ld c, a
    ld b, 1
    ld ix, XDPB
    call userf_call
    jr nc, .failed
    jr nz, .failed
    or a
    ret
.failed:
    scf
    ret

; ==========================================================================
; Messages
; ==========================================================================
usage:
    ld de, msg_usage
    call pstr
    jp finish

no_argument:
    ; A bare command lists: that is the common case after a mistake.
    call read_drive_and_list
    jp finish

read_drive_and_list:
    call read_directory
    jp c, read_failed
    jp list_matches

need_name:
    ld de, msg_need_name
    call pstr
    jp finish

need_exact:
    ld de, msg_need_exact
    call pstr
    jp finish

no_matches:
    ld de, msg_none
    call pstr
    jp finish

blocks_in_use:
    ld de, msg_busy
    call pstr
    jp finish

write_failed:
    ld de, msg_write_failed
    call pstr
    jp finish

cancelled:
    ld de, msg_cancelled
    call pstr
    jp finish

read_failed:
    ; A = reason code 1..5
    dec a
    ld l, a
    ld h, 0
    add hl, hl
    ld de, read_errors
    add hl, de
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a
    ld d, h
    ld e, l
    call pstr
    jp finish

; ==========================================================================
; Helpers
; ==========================================================================
skip_spaces:
    ld a, (hl)
    cp ' '
    ret nz
    inc hl
    jr skip_spaces

; pc - print A
;   Clobbers: AF, BC, DE ; lint: ignore
pc:
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; pstr - print a '$'-terminated string
;   Clobbers: AF, BC, DE ; lint: ignore
pstr:
    ld c, F_PSTR
    jp BDOS

; read_key - wait for a key, folded to upper case, no echo
;   Out:      A = character
;   Clobbers: AF, BC, DE ; lint: ignore
read_key:
    ld c, F_DIRECT
    ld e, 0xFF
    call BDOS
    cp 'a'
    ret c
    cp 'z' + 1
    ret nc
    and 0xDF
    ret

; read_confirm - wait for a Y/N answer on a fresh line
;   Out:      A = 'Y' or 'N'; carry set if the answer was neither
;   Clobbers: AF, BC, DE
;
; The command that started us ended with a CR, which the keyboard layer may
; still be holding; reading one raw key would take that CR and answer "no".
; A line input (F10-free F1) skips it and lets the user type a full answer.
read_confirm:
    ld c, F_CONIN
    call BDOS
    cp 'a'
    jr c, .folded
    cp 'z' + 1
    jr nc, .folded
    and 0xDF
.folded:
    cp 'Y'
    jr z, .ok
    cp 'N'
    jr z, .ok
    scf
    ret
.ok:
    or a
    ret

; print_name_field - print the 11-byte name at HL as "NAME.EXT", trimming
;   the trailing padding spaces of each field (CP/M's DIR does the same)
;   In:       HL = the 11 name bytes
;   Clobbers: everything
print_name_field:
    ld (name_src), hl
    ; Name: the last non-space within the first 8 bytes.
    ld c, 8
.trim_name:
    dec c
    jr z, .name_at
    ld hl, (name_src)
    ld a, c
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    cp ' '
    jr z, .trim_name
    inc c
    jr .name_done
.name_at:
    ld c, 1
.name_done:
    ld a, c
    ld (name_len), a
    xor a
    ld (name_idx), a
.name:
    ld hl, (name_src)
    ld a, (name_idx)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    call pc
    ld a, (name_idx)
    inc a
    ld (name_idx), a
    ld hl, name_len
    cp (hl)
    jr nz, .name

    ; Extension: the last non-space within the 3 bytes at offset 8.
    ld c, 4
.trim_ext:
    dec c
    jr z, .ext_at
    ld hl, (name_src)
    ld a, c
    add a, 7                      ; offsets 8,9,10
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    cp ' '
    jr z, .trim_ext
    jr .ext_done
.ext_at:
    ld c, 1
.ext_done:
    ld a, c
    ld (name_len), a
    ld a, '.'
    call pc
    xor a
    ld (name_idx), a
.ext:
    ld hl, (name_src)
    ld a, (name_idx)
    add a, 8
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    call pc
    ld a, (name_idx)
    inc a
    ld (name_idx), a
    ld hl, name_len
    cp (hl)
    jr nz, .ext
    ret

; print_spec - print the requested name from the parsed filespec
;   Clobbers: everything
print_spec:
    ld hl, spec_name              ; spec_name and spec_ext are contiguous
    jp print_name_field

; print_a_decimal - print A as decimal, no leading zeros
;   Clobbers: everything
print_a_decimal:
    ld l, a
    ld h, 0
    jp print_de16

; print_de16 - print HL as decimal, no leading zeros
;   Clobbers: everything
print_de16:
    xor a
    ld (lead), a
    ld de, 10000
    call .place
    ld de, 1000
    call .place
    ld de, 100
    call .place
    ld de, 10
    call .place
    ld a, l
    add a, '0'
    jp pc
.place:
    ld b, 0
.sub:
    ld a, l
    sub e
    ld c, a
    ld a, h
    sbc a, d
    jr c, .under
    ld h, a
    ld l, c
    inc b
    jr .sub
.under:
    ld a, (lead)
    or a
    jr nz, .print
    ld a, b
    or a
    ret z
.print:
    ld a, 1
    ld (lead), a
    ld a, b
    add a, '0'
    push hl
    push de
    call pc
    pop de
    pop hl
    ret

; ==========================================================================
; Finish
; ==========================================================================
finish:
    ; Reset the disk system: drop the BDOS's cached directory sector and
    ; rebuild the allocation vector from what we just wrote.  F13 also
    ; flushes any pending deblocked write first, so this must come after the
    ; raw sector writes, never before.
    ld c, F_RESET
    call BDOS
    ld a, (orig_drive)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    rst 0

; ==========================================================================
; USERF trampoline
; ==========================================================================
; The extended jumpblock entry is called with the 2-byte function selector
; inline, immediately after the CALL: USERF finds it from the return address.
; So the sequence must be `call <userf>` then `dw <entry>` then `ret`.
userf_call:
    call 0                        ; patched to the USERF jumpblock entry
userf_dw:
    dw 0                          ; extended jumpblock entry for this call
    ret

; ==========================================================================
; State
; ==========================================================================
orig_drive:     db 0
drive:          db 0
do_restore:     db 0
restore_user:   db 0
have_spec:      db 0
has_wild:       db 0
pd_seen:        db 0
pd_digit:       db 0
dir_entries:    dw 0
dir_sectors:    db 0
dir_sec:        db 0
ent_idx:        dw 0
entry_index:    db 0
cur_entry:      dw 0
sector_first:   dw 0
sector_n:       db 0
sector_dirty:   db 0
cand_count:     db 0
matches:        db 0
blk_ptr:        dw 0
blk_idx:        db 0
blk_test:       db 0
use_ptr:        dw 0
use_idx:        db 0
use_ent:        dw 0
ext_num:        dw 0
recs:           dw 0
name_idx:       db 0
name_len:       db 0
name_src:       dw 0
lead:           db 0
xfer_ptr:       dw 0
xfer_track:     dw 0
spec_name:      ds 8
spec_ext:       ds 3
; The two halves above, contiguous, so the name printer can walk them as one
; 11-byte field; spec_name is 8 bytes and spec_ext immediately follows it.
; (spelled out here to make the coupling explicit)


; ==========================================================================
; Text
; ==========================================================================
msg_crlf:       db 0x0D, 0x0A, '$'
msg_drive:      db 0x0D, 0x0A, '$'
msg_sep:        db "  extent ", '$'
msg_records:    db "  records ", '$'
msg_restore_q:  db "Restore ", '$'
msg_to_user:    db " to user ", '$'
msg_extents:    db ", extents ", '$'
msg_question:   db " ? (Y/N) ", '$'
msg_restored:   db 0x0D, 0x0A, "Restored ", '$'
msg_none:       db 0x0D, 0x0A, "No deleted file matches.", 0x0D, 0x0A, '$'
msg_need_name:
    db 0x0D, 0x0A, "UNDELETE: a restore needs a file name.", 0x0D, 0x0A, '$'
msg_need_exact:
    db 0x0D, 0x0A, "UNDELETE: a restore needs one specific name, not a wildcard."
    db 0x0D, 0x0A, '$'
msg_busy:
    db 0x0D, 0x0A, "UNDELETE: refused - a block this file owned now belongs to"
    db 0x0D, 0x0A, "another file, so its data is not intact.", 0x0D, 0x0A, '$'
msg_write_failed:
    db 0x0D, 0x0A, "UNDELETE: the directory write did not verify.", 0x0D, 0x0A, '$'
msg_cancelled:
    db 0x0D, 0x0A, "UNDELETE: cancelled.", 0x0D, 0x0A, '$'
msg_usage:
    db "UNDELETE                list deleted files on the current drive", 0x0D, 0x0A
    db "UNDELETE d:             list them on drive d:", 0x0D, 0x0A
    db "UNDELETE filespec       list matching deleted files", 0x0D, 0x0A
    db "UNDELETE filespec R     restore it into user 0", 0x0D, 0x0A
    db "UNDELETE filespec R U=n restore it into user area n", 0x0D, 0x0A, '$'

read_errors:
    dw msg_err_unit
    dw msg_err_login
    dw msg_err_blocks
    dw msg_err_geometry
    dw msg_err_read

msg_err_unit:
    db "UNDELETE: only A: and B: can be undeleted - the XBIOS disc calls", 0x0D, 0x0A
    db "          address the two FDC units, and the C: RAM disc has no", 0x0D, 0x0A
    db "          directory sectors to rewrite.", 0x0D, 0x0A, '$'
msg_err_login:
    db "UNDELETE: the disc did not log in.", 0x0D, 0x0A, '$'
msg_err_blocks:
    db "UNDELETE: this layout stores 16-bit block numbers; only the 8-bit", 0x0D, 0x0A
    db "          block layouts (180K, 40 track) are supported.", 0x0D, 0x0A, '$'
msg_err_geometry:
    db "UNDELETE: the directory geometry is unusable.", 0x0D, 0x0A, '$'
msg_err_read:
    db "UNDELETE: a directory sector could not be read.", 0x0D, 0x0A, '$'
