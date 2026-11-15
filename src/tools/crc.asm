; CRC.COM - CRC-32 and checksums for CP/M files
;
; Usage:  CRC filespec             CRC-32 of each matching file
;         CRC filespec $SUM        also show the 16-bit additive sum
;
; CRC-32 is the standard reflected CRC-32 (polynomial EDB88320h, initial
; FFFFFFFF, final XOR FFFFFFFF) - the value `crc32`, `zlib.crc32`, 7-Zip and
; PKZIP all produce.  That is the reason for choosing it over a faster CRC-16:
; the number can be checked against something outside this machine.
;
; The optional $SUM is a 16-bit additive sum of the bytes, which is what the
; AMSDOS and PLUS3DOS file headers carry.
;
; Reading is sequential through BDOS F20 with F44 set to an 8K multi-record
; count, the DMA moved to an 8K buffer, and the CRC folding whole records at a
; time, so a 64K file costs 8 BDOS calls.
;
; A filespec may carry a drive letter, "CRC C:FOO.COM"; the letter goes into
; both the search FCB and the open FCB.
;
; Build: sjasmplus --raw=build/crc.com src/tools/crc.asm

    org 0x0100

BDOS            equ 0x0005
F_CONOUT        equ 2
F_PSTR          equ 9
F_SELDRV        equ 14
F_OPEN          equ 15
F_CLOSE         equ 16
F_READ          equ 20
F_CURDRV        equ 25
F_SETDMA        equ 26
F_SEARCH_FIRST  equ 17
F_SEARCH_NEXT   equ 18
F_MULTI         equ 44

TAIL            equ 0x0080
FCB1            equ 0x005C
DEFAULT_DMA     equ 0x0080

BUFFER          equ 0x2000     ; 8K transfer buffer, inside the TPA
BUFLEN          equ 8192

F_ERA           equ 19

; --------------------------------------------------------------------------
; Entry
; --------------------------------------------------------------------------
start:
    ld c, F_CURDRV
    call BDOS
    ld (saved_drive), a

    call build_crc32_table

    ; Point the DMA at our transfer buffer.  F26 does not report the old
    ; value, so it is not saved: `finish` restores the 0080h that the CCP
    ; (and every transient) expects.
    ld de, BUFFER
    ld c, F_SETDMA
    call BDOS

    ; ---- Command tail ----
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, usage
    inc hl
    call skip_spaces
    ld a, (hl)
    or a
    jp z, usage
    cp 0x0D
    jp z, usage

    call parse_drive               ; "X:" prefix, if any; HL -> the name
    call parse_filespec            ; Cy = bad
    jp c, usage

    call crc_matches
    jp finish

; --------------------------------------------------------------------------
; Command line
; parse_drive - recognise an "X:" prefix on the filespec
;   In:       HL = the filespec
;   Out:      HL = past any "X:", otherwise unchanged
;             spec_drive = drive number, 1-based (0 = the current drive)
;   Clobbers: AF, B, HL
;
; An FCB's drive byte is 1 for A:, 2 for B: and 0 for "current", so this is
; the same number work_fcb and FCB1 want.  Without it the colon of "C:" was
; copied into the 8-character name field and the rest of the name shifted into
; the extension.
;
; A drive that does not exist is not rejected here: the search finds nothing
; and the caller reports "No file", which is how DIR behaves.
parse_drive:
    xor a
    ld (spec_drive), a            ; default: the current drive
    ld a, (hl)
    and 0xDF                      ; uppercase; only A-Z pass the range test
    cp 'A'
    ret c
    cp 'Z' + 1
    ret nc
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .not_a_drive
    dec hl
    ld a, (hl)
    and 0xDF
    sub 'A' - 1                   ; 'A' -> 1, 'C' -> 3
    ld (spec_drive), a
    inc hl
    inc hl                        ; past the name letter and the colon
    ret
.not_a_drive:
    dec hl                        ; the letter was part of the name
    ret

; --------------------------------------------------------------------------
; parse_filespec - copy "NAME.EXT" from HL into spec_name/spec_ext, and into
;   the FCB at 005Ch so F17 can search for it.
;   Out:      carry set = malformed
;   Clobbers: AF, BC, DE, HL
parse_filespec:
    xor a
    ld (star_seen), a
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
.name_done:
    ; A '*' means "the rest of this field is wildcards", which CP/M spells as
    ; padding with '?'.  name_char turned the '*' into a single '?', so fill
    ; whatever is left of the 8-character field.
    ld a, (star_seen)
    or a
    jr z, .no_star
    xor a
    ld (star_seen), a
    ld a, '?'
.fill_name:
    ld (de), a
    inc de
    djnz .fill_name
.no_star:
    call skip_name
    ld a, (hl)
    cp '.'
    jr nz, .no_ext
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
    ; Same '*' rule for the 3-character extension.
    ld a, (star_seen)
    or a
    jr z, .no_star_ext
    xor a
    ld (star_seen), a
    ld a, '?'
.fill_ext:
    ld (de), a
    inc de
    djnz .fill_ext
.no_star_ext:
    call skip_ext
.no_ext:

    ; Mirror into FCB1 for the directory search: drive byte plus 11 name
    ; bytes, then zero the rest.  The drive byte is 1-based and 0 means "the
    ; current drive", which is exactly what parse_drive left in spec_drive.
    push hl                       ; keep the tail pointer for parse_options
    ld a, (spec_drive)
    ld (FCB1 + 0), a
    ld hl, spec_name
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld hl, FCB1 + 12
    ld b, 24
.clr:
    ld (hl), 0
    inc hl
    djnz .clr
    pop hl
    xor a
    ret

; name_char - validate and uppercase one filespec character
;   Out:      carry set = end of field; else A = uppercased char, Cy clear
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
    ; '?' is CP/M's wildcard.  It is copied through as-is so the FCB search
    ; treats it as one.
    cp '?'
    jr z, .upper
    cp '*'
    jr z, .star
    jr .upper
.star:
    ld a, 1
    ld (star_seen), a
    ld a, '?'
.upper:
    cp 'a'
    jr c, .done
    cp 'z' + 1
    jr nc, .done
    and 0xDF
.done:
    ; Carry must be CLEAR here: it is how this routine says "more to copy".
    ; `or a` alone is not enough because it leaves carry from the compare
    ; above, which is what made "*.DAT" collapse to a one-character FCB.
    ld (name_save), a
    xor a                         ; clears carry without touching the char
    ld a, (name_save)
    ret
.end:
    scf
    ret

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

; --------------------------------------------------------------------------
; CRC-32 table
; --------------------------------------------------------------------------
; build_crc32_table - the standard reflected CRC-32 table (poly EDB88320h)
;   Each entry is the CRC of the single byte it is indexed by, computed here
;   once so the hot loop is four table reads instead of eight bit shifts.
;   Clobbers: everything
build_crc32_table:
    ld hl, CRC32_TAB
    ld (tab_ptr), hl
    ld b, 0                       ; B = the byte whose CRC we compute
.byte:
    ld a, b
    ld (t_crc + 0), a
    xor a
    ld (t_crc + 1), a
    ld (t_crc + 2), a
    ld (t_crc + 3), a
    ld c, 8
.bit:
    ; if (crc & 1) crc = (crc >> 1) ^ poly else crc >>= 1
    ld a, (t_crc + 0)
    and 1
    ld (t_odd), a
    call crc32_shr1
    ld a, (t_odd)
    or a
    jr z, .next_bit
    ld a, (t_crc + 0)
    xor 0x20                      ; EDB88320h, little-endian
    ld (t_crc + 0), a
    ld a, (t_crc + 1)
    xor 0x83
    ld (t_crc + 1), a
    ld a, (t_crc + 2)
    xor 0xB8
    ld (t_crc + 2), a
    ld a, (t_crc + 3)
    xor 0xED
    ld (t_crc + 3), a
.next_bit:
    dec c
    jr nz, .bit
    ; store the four bytes little-endian; the pointer lives in memory because
    ; crc32_shr1 uses HL
    ld hl, (tab_ptr)
    ld a, (t_crc + 0)
    ld (hl), a
    inc hl
    ld a, (t_crc + 1)
    ld (hl), a
    inc hl
    ld a, (t_crc + 2)
    ld (hl), a
    inc hl
    ld a, (t_crc + 3)
    ld (hl), a
    inc hl
    ld (tab_ptr), hl
    inc b
    jr nz, .byte
    ret

; crc32_shr1 - shift t_crc right one bit
;   Clobbers: AF
crc32_shr1:
    ld a, (t_crc + 3)
    srl a
    ld (t_crc + 3), a
    ld a, (t_crc + 2)
    rr a
    ld (t_crc + 2), a
    ld a, (t_crc + 1)
    rr a
    ld (t_crc + 1), a
    ld a, (t_crc + 0)
    rr a
    ld (t_crc + 0), a
    ret

; --------------------------------------------------------------------------
; CRC of every matching file
; --------------------------------------------------------------------------
; CRC of every matching file
; --------------------------------------------------------------------------
; crc_matches - CRC every matching file
;
; The directory search and the file reads must not interleave.  F15 and F20
; reset the BDOS's cached drive and directory-scan state, so a search paused
; half-way does not resume where it left off (in practice F18 kept returning
; the same entry, or stopped after one).  The matching names are therefore
; collected into a table first, and only then are the files hashed.
;
; MAX_MATCHES is the largest CP/M directory (64 entries); 64 names of 11
; bytes is 704 bytes, which the TPA has room for.
MAX_MATCHES     equ 64

crc_matches:
    xor a
    ld (match_count), a
    ld (match_idx), a

    call set_dma_buffer
    ld de, FCB1
    ld c, F_SEARCH_FIRST
    call BDOS
    inc a
    jr nz, .first
    ld de, msg_no_files
    jp pstr
.first:
    dec a
    call take_match
.loop:
    call set_dma_buffer
    ld de, FCB1
    ld c, F_SEARCH_NEXT
    call BDOS
    inc a
    jr z, .collected
    dec a
    call take_match
    jr .loop

.collected:
    ld a, (match_count)
    or a
    ret z
.hash:
    call crc_one
    ld a, (match_idx)
    inc a
    ld (match_idx), a
    ld hl, match_count
    cp (hl)
    jr c, .hash
    ret

; take_match - copy the matched entry's name into the table
;   In:       A = index of the matching entry within the 128 bytes at the DMA
;   Clobbers: everything
take_match:
    and 0x03                      ; the search returns the entry number; four
                                  ; entries share each 128-byte copy
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                    ; * 32
    ld de, BUFFER
    add hl, de
    inc hl                        ; past the user byte
    ld (tm_src), hl

    ; destination = match_table + count * 11
    ld a, (match_count)
    cp MAX_MATCHES
    ret nc
    ld b, a
    ld hl, 0
.mul11:
    ld a, b
    or a
    jr z, .have_off
    ld de, 11
    add hl, de
    dec b
    jr .mul11
.have_off:
    ld de, match_table
    add hl, de
    ld (tm_dst), hl

    ld hl, (tm_src)
    ld de, (tm_dst)
    ld b, 11
.copy:
    ld a, (hl)
    and 0x7F
    ld (de), a
    inc hl
    inc de
    djnz .copy

    ld a, (match_count)
    inc a
    ld (match_count), a
    ret

; crc_one - CRC the file whose name is entry match_idx of the table
;   Clobbers: everything
crc_one:
    ; HL = match_table + idx * 11
    ld a, (match_idx)
    ld b, a
    ld hl, 0
.mul:
    ld a, b
    or a
    jr z, .got
    ld de, 11
    add hl, de
    dec b
    jr .mul
.got:
    ld de, match_table
    add hl, de
    ld de, work_name
    ld b, 11
.copy:
    ld a, (hl)
    ld (de), a
    inc hl
    inc de
    djnz .copy

    call open_work
    ret c
    call crc_read_all
    push af
    call close_work
    pop af
    ret c

    call print_name
    jp print_crcs

; set_dma_buffer - point the DMA back at BUFFER
;   Clobbers: AF, BC, DE, HL ; lint: ignore
set_dma_buffer:
    ld de, BUFFER
    ld c, F_SETDMA
    jp BDOS

; open_work - open work_fcb
;   Out:      carry set = not found
;   Clobbers: AF, BC, DE, HL
open_work:
    ld hl, work_fcb
    ld b, 36
.clr:
    ld (hl), 0
    inc hl
    djnz .clr
    ; Same drive byte as the FCB1 the search used, or the open would look on
    ; the current drive while the search found the file somewhere else.
    ld a, (spec_drive)
    ld (work_fcb + 0), a
    ld hl, work_name
    ld de, work_fcb + 1
    ld bc, 11
    ldir
    ld de, work_fcb
    ld c, F_OPEN
    call BDOS
    inc a
    jr nz, .opened
    scf
    ret
.opened:
    ; CP/M 3's Open leaves the FCB positioned at the start of extent 0; the
    ; record offset is CR, which must be 0 to read from the beginning.
    xor a
    ld (work_fcb + 32), a         ; CR
    ld (work_fcb + 33), a
    or a
    ret

; close_work - F16
;   Clobbers: AF, BC, DE, HL ; lint: ignore
close_work:
    ld de, work_fcb
    ld c, F_CLOSE
    jp BDOS

; crc_read_all - fold the whole open file into crc32 and the sum
;   Out:      carry set = read error
;   Clobbers: everything
;
; F44 sets a multi-record count, so each F20 moves up to BUFLEN/128 records
; and reports how many it actually moved in H.  A 64K file therefore costs 8
; BDOS calls instead of 512, and F20 leaves the DMA where the caller expects
; (it advances it per record only while the count is above 1).
crc_read_all:
    ld hl, 0xFFFF
    ld (crc32 + 0), hl
    ld (crc32 + 2), hl

    ; F44 sets a multi-record count, so one F20 moves up to BUFLEN/128
    ; records instead of one: a 140K file then needs ~11 BDOS calls rather
    ; than 1100.  The BDOS advances the DMA per record while the count is
    ; above 1, so the DMA is reset to BUFFER after each call.
    ld de, BUFLEN / 128
    ld c, F_MULTI
    call BDOS
    call set_dma_buffer

.read:
    ld de, work_fcb
    ld c, F_READ
    call BDOS
    ; A = 0 (OK), 1 (EOF), 0xFF (error).  By CP/M 3's contract H is 0 on
    ; success and holds the record count only when the call stopped early, so
    ; a successful call moved the whole requested count.
    or a
    jr z, .full
    cp 1
    jr z, .at_eof
    ld de, msg_read_error
    call pstr
    scf
    ret
.full:
    ld bc, BUFLEN
    ld hl, BUFFER
    call fold_block
    call set_dma_buffer           ; F20 advanced it; read the next bufferful
    jr .read
.at_eof:
    ; A short final read: H holds the records moved.  H = 0 means the file
    ; ended exactly on a buffer boundary, and the previous call already
    ; folded everything.
    ld a, h
    or a
    jr z, .ok
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                    ; * 128
    ld b, h
    ld c, l
    ld hl, BUFFER
    call fold_block

.ok:
    ; Final XOR, as the standard CRC-32 specifies.
    ld hl, crc32 + 0
    ld a, (hl)
    cpl
    ld (hl), a
    inc hl
    ld a, (hl)
    cpl
    ld (hl), a
    inc hl
    ld a, (hl)
    cpl
    ld (hl), a
    inc hl
    ld a, (hl)
    cpl
    ld (hl), a
    or a
    ret

; --------------------------------------------------------------------------
; One CRC-32 step: fold the byte at (DE) into crc32, then advance DE.
;
; A macro, so the page loop and the tail loop cannot drift apart -- the subtle
; bugs in this routine's history were all copies of the body that had come to
; differ by a byte or an instruction.
;
; Registers: B = djnz counter (must survive), C = the byte, DE = buffer,
; HL = table entry, A = scratch.
; --------------------------------------------------------------------------
CRC_STEP        macro
    ld a, (de)                    ; A = the byte
    ld c, a
    ld a, (crc32 + 0)
    xor c                         ; index = byte ^ crc[0]
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl                    ; HL = index * 4
    ld a, h
    add a, CRC32_TAB / 256        ; entry page = table page + index >> 6
    ld h, a                       ; HL = address of the 4-byte entry
    ; crc >>= 8: little-endian, so the bytes each move down one slot
    ld a, (crc32 + 1)
    ld (crc32 + 0), a
    ld a, (crc32 + 2)
    ld (crc32 + 1), a
    ld a, (crc32 + 3)
    ld (crc32 + 2), a
    ; xor the entry into it; crc[3] is loaded rather than xored because the
    ; shift left it zero and e[3] is the whole top byte.
    ld a, (crc32 + 0)
    xor (hl)
    ld (crc32 + 0), a
    inc hl
    ld a, (crc32 + 1)
    xor (hl)
    ld (crc32 + 1), a
    inc hl
    ld a, (crc32 + 2)
    xor (hl)
    ld (crc32 + 2), a
    inc hl
    ld a, (hl)
    ld (crc32 + 3), a
    inc de                        ; next byte
    endm

; --------------------------------------------------------------------------
; fold_block - fold BC bytes at HL into crc32
;   In:       HL = data, BC = length
;   Clobbers: everything
;
; The 32-bit CRC has to live in memory (the Z80 has no 32-bit register), but
; everything else is in registers: DE walks the buffer, B drives `djnz` and HL
; addresses the table entry.  No call per byte.
;
; The old form kept the pointer and count in fb_ptr/fb_left and called
; crc32_byte for every byte.  Measured in isolation, with no disk or BDOS in
; the loop (8K, markers around the fold only):
;
;     old 558 T/byte (6.1 KB/s)   ->   new 311 T/byte (11.0 KB/s)
;
; tools/ckbench.py measures a tighter CRC-32 byte-table loop at 282 T/byte;
; the difference is this routine's extra `inc hl` per table byte.
;
; The walk is 256 bytes at a time so `djnz` can be the inner counter; the page
; count and the final partial page arrive in B and C.
;
; index * 4 needs ten bits, hence a 16-bit shift of HL rather than two
; `add a,a` -- the latter truncates every index >= 64 to the wrong entry, which
; was the first bug this routine had.  The table is 256-byte aligned, so the
; high byte of index * 4 plus the table's page is the entry's page, and the low
; byte is its offset within that page.
fold_block:
    ex de, hl                     ; DE = buffer; HL is free for the table
    ld a, b
    or a
    jr z, .short                  ; fewer than 256 bytes in total
    ld (fb_pages), a              ; full 256-byte pages
    ld a, c
    ld (fb_tail), a               ; leftover bytes, folded after them
.page:
    ld b, 0                       ; 256 iterations
.byte:
    CRC_STEP
    djnz .byte
    ld a, (fb_pages)
    dec a
    ld (fb_pages), a
    jr nz, .page
    ld a, (fb_tail)
    or a
    ret z                         ; the buffer ended on a page boundary
    ld b, a
    jr .tail
.short:
    ld b, c                       ; B was 0, so the count is C alone
    ld a, b
    or a
    ret z                         ; nothing to fold
.tail:
    CRC_STEP
    djnz .tail
    ret

; --------------------------------------------------------------------------
; Output
; --------------------------------------------------------------------------
; print_name - print work_name as "NAME.EXT", trailing spaces trimmed
;   Clobbers: everything
;
; pc goes through BDOS, which clobbers HL and B, so the name is walked with
; an index kept in memory.  The 8+3 fields are trimmed of padding, as DIR
; does, so "T       .DAT" prints as "T.DAT".
print_name:
    ; last non-space in the 8-byte name, else 1
    ld a, 8
    ld (trim_end), a
.find_name:
    ld a, (trim_end)
    dec a
    jr z, .name_len
    ld (trim_end), a
    ld hl, work_name
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    cp ' '
    jr z, .find_name
    ld a, (trim_end)
    inc a
    ld (trim_end), a
.name_len:

    xor a
    ld (name_idx), a
.name:
    ld a, (name_idx)
    ld hl, trim_end
    cp (hl)
    jr nc, .dot
    ld hl, work_name
    ld a, (name_idx)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    call pc
    ld a, (name_idx)
    inc a
    ld (name_idx), a
    jr .name

.dot:
    ld a, '.'
    call pc
    ; The extension starts at column 8.
    ld a, 8
    ld (name_idx), a

    ; The extension is never left empty in CP/M practice, but trim it too.
    ld a, 11
    ld (trim_end), a
.find_ext:
    ld a, (trim_end)
    dec a
    cp 8
    jr z, .ext_len
    ld (trim_end), a
    ld hl, work_name
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    cp ' '
    jr z, .find_ext
    ld a, (trim_end)
    inc a
    ld (trim_end), a
.ext_len:
.ext:
    ld a, (name_idx)
    ld hl, trim_end
    cp (hl)
    jr nc, .done
    ld hl, work_name
    ld a, (name_idx)
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    call pc
    ld a, (name_idx)
    inc a
    ld (name_idx), a
    jr .ext
.done:
    ld a, ' '
    jp pc

print_crcs:
    ld hl, crc32 + 3
    call print_hex_byte
    ld hl, crc32 + 2
    call print_hex_byte
    ld hl, crc32 + 1
    call print_hex_byte
    ld hl, crc32 + 0
    call print_hex_byte
.crlf:
    ld de, msg_crlf
    jp pstr

print_hex_byte:
    ld a, (hl)
    push af
    rrca
    rrca
    rrca
    rrca
    call hex_nibble
    pop af
    jp hex_nibble

print_hex16:
    ld a, h
    call hex_a
    ld a, l
    jp hex_a

hex_a:
    push af
    rrca
    rrca
    rrca
    rrca
    call hex_nibble
    pop af
    jp hex_nibble

; hex_nibble - print the low nibble of A as a hex digit
;   Clobbers: AF, BC, DE ; lint: ignore
hex_nibble:
    and 0x0F
    add a, '0'
    cp '9' + 1
    jr c, .out
    add a, 'A' - '0' - 10
.out:
    jp pc

; --------------------------------------------------------------------------
; Helpers
; --------------------------------------------------------------------------
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

usage:
    ld de, msg_usage
    call pstr
    jp finish

finish:
    ld de, DEFAULT_DMA
    ld c, F_SETDMA
    call BDOS
    ld a, (saved_drive)
    ld e, a
    ld c, F_SELDRV
    call BDOS
    rst 0

; --------------------------------------------------------------------------
; Data
; --------------------------------------------------------------------------
saved_drive:    db 0
spec_drive:     db 0                 ; 1-based drive from "X:", 0 = current
name_idx:       db 0
star_seen:      db 0
name_save:      db 0
match_idx:      db 0
fb_pages:       db 0                 ; fold_block: full 256-byte pages left
fb_tail:        db 0                 ; fold_block: leftover bytes after them
trim_end:       db 0
tab_ptr:        dw 0
moved:          db 0
moved_n:        db 0
match_count:    db 0
tm_src:         dw 0
tm_dst:         dw 0
t0:             db 0
t1:             db 0
t2:             db 0
t3:             db 0
t_crc:          ds 4
t_odd:          db 0
crc32:          ds 4
work_name:      ds 11
work_fcb:       ds 36
spec_name:      ds 8
spec_ext:       ds 3

msg_crlf:       db 0x0D, 0x0A, '$'
msg_no_files:   db "No file", 0x0D, 0x0A, '$'
msg_read_error: db " read error", 0x0D, 0x0A, '$'
msg_usage:
    db "CRC filespec        CRC-32 of each matching file", 0x0D, 0x0A, '$'

    align 256
CRC32_TAB:      ds 1024
match_table:    ds MAX_MATCHES * 11
