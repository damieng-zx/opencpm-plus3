; FORMAT.COM - format a 3-inch disc
;
; Usage:  FORMAT A:      or      FORMAT B:
;
; The drive letter is mandatory.  A: and B: are the units the XBIOS disc
; calls (DD_INIT, DD_FORMAT, DD_WRITE, DD_CHECK_SECTOR) address; whether a
; second drive is actually fitted is for the FDC to say, so a FORMAT B: on
; a single-drive machine fails with "not ready".
;
; The user is asked to take the disc out of the drive, put the one to be
; formatted in, and choose a layout:
;
;   1   180K  SS 40 track (PCW)     disc type 0, first sector 1
;   2   720K  DS 80 track (PCW)     disc type 3, first sector 1
;   3   CPC System  40 track        disc type 1, first sector 41h
;   4   CPC Data    40 track        disc type 2, first sector C1h
;   5   HiForm 203  42 track        10 sectors, 12/22 gaps, interleave 3
;   6   Ultra 208   42 track        10 sectors, no reserved track
;   7   SuperMat 192 40 track       10 sectors, 3 directory blocks
;   8   CPC IBM     40 track        8 sectors
;
; The 10-sector layouts lay their sector IDs down with an interleave (and,
; for Ultra, a per-track skew), so consecutive IDs are not physically
; adjacent; CP/M addresses sectors by ID, so this only changes timing.
;
; Every track is formatted and then verified sector by sector before the
; next track is touched.  A single progress line is rewritten in place:
;
;    45%  Track 18  Side 0  FORMAT
;    45%  Track 18  Side 0  VERIFY
;
; A successful format finishes by writing the 10-byte AMSDOS disc spec into
; the boot sector of the layouts that reserve a track for it (PCW SS, PCW DS
; and CPC System), so the BIOS login detects the geometry just selected.  A
; CPC Data disc has no reserved track - its first sector is directory - so
; there the sector IDs alone identify the layout.
;
; Build: sjasmplus --raw=build/format.com src/tools/format.asm

    org 0x0100

BDOS           equ 0x0005
F_CONOUT       equ 2
F_DIRECT       equ 6            ; direct console I/O (E=FF: read without echo)
F_PSTR         equ 9
F_RESET        equ 13

TAIL           equ 0x0080
USERF_OFFSET   equ 90           ; USERF = bios_visible + 3*30

; XBIOS extended jumpblock entries
DD_INIT         equ 0x0080
DD_WRITE        equ 0x0089
DD_CHECK_SECTOR equ 0x008C
DD_FORMAT       equ 0x008F
DD_L_XDPB       equ 0x00A1
DD_OFF_MOTOR    equ 0x00AA

SECTOR_SIZE    equ 512
FILL_BYTE      equ 0xE5         ; uPD765 FORMAT TRACK filler

; XDPB field offsets
XDPB_OFF       equ 13
XDPB_PSH       equ 15
XDPB_SIDES     equ 17
XDPB_TRACKS    equ 18
XDPB_SECTORS   equ 19
XDPB_FIRST     equ 20

; Working areas in bank 3.  C000-FFFF is the same physical memory in both
; TPA mode and system mode, which is what the XBIOS disc calls need: they
; run in system mode but their buffers and the XDPB stay readable here.
XDPB           equ 0xD200       ; 27-byte XDPB built by DD_L_XDPB
SPEC           equ 0xD240       ; 10-byte AMSDOS disc spec
HDR            equ 0xD280       ; DD_FORMAT header table (sectors * 4)
BUF            equ 0xD400       ; 512-byte sector buffer

; ==========================================================================
; Entry
; ==========================================================================
start:
    ; USERF address, from the WBOOT vector in page zero.
    ld hl, (0x0001)
    dec hl
    dec hl
    dec hl
    ld de, USERF_OFFSET
    add hl, de
    ld (userf_call + 1), hl

    ; ---- Command tail: "A:" (a bare "A" is accepted too) ----
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, usage
    inc hl
.skip_spaces:
    ld a, (hl)
    cp ' '
    jr nz, .letter
    inc hl
    jr .skip_spaces
.letter:
    and 0xDF                    ; fold to upper case
    cp 'A'
    jp c, usage
    cp 'Z' + 1
    jp nc, usage
    ld (drive_letter), a
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .tail_end
    inc hl
.tail_end:
    call tail_end_ok
    jp nz, usage

    ; Only the two FDC units are formattable.
    ld a, (drive_letter)
    sub 'A'
    cp 2
    jp nc, not_supported
    ld (drive_unit), a

    ; ---- Warning and the disc change ----
    ld de, msg_fmt_prefix
    call pstr
    ld a, (drive_letter)
    call cout
    ld de, msg_warning_tail
    call pstr

    ld de, msg_remove
    call pstr
    ld a, (drive_letter)
    call cout
    ld de, msg_remove_tail
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled

    ld de, msg_insert
    call pstr
    ld a, (drive_letter)
    call cout
    ld de, msg_insert_tail
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled

    ; The disc changed: drop the driver's cached track and deblock state.
    ld hl, DD_INIT
    ld (userf_dw), hl
    call userf_call

    ; ---- Geometry ----
    ld hl, 0
    ld (note_ptr), hl
    ld de, msg_menu
    call pstr
menu_key:
    call wait_key
    cp 0x1B
    jp z, cancelled
    cp '1'
    jr z, choose_180
    cp '2'
    jr z, choose_720
    cp '3'
    jr z, choose_cpc_sys
    cp '4'
    jr z, choose_cpc_data
    cp '5'
    jr z, choose_hiform
    cp '6'
    jr z, choose_ultra
    cp '7'
    jr z, choose_supermat
    cp '8'
    jp z, choose_cpc_ibm
    ld de, msg_bad_choice
    call pstr
    jr menu_key

; Each choice sets HL = spec, DE = name, B = interleave, C = track skew.
choose_180:
    ld a, '1'
    call echo_choice
    ld hl, spec_180
    ld de, name_180
    ld bc, 0x0100                   ; interleave 1, skew 0
    jr have_type
choose_720:
    ld a, '2'
    call echo_choice
    ld hl, spec_720
    ld de, name_720
    ld bc, 0x0100
    jr have_type
choose_cpc_sys:
    ld a, '3'
    call echo_choice
    ld hl, spec_cpc_sys
    ld de, name_cpc_sys
    ld bc, 0x0200                   ; CPC interleave 2
    jr have_type
choose_cpc_data:
    ld a, '4'
    call echo_choice
    ld hl, spec_cpc_data
    ld de, name_cpc_data
    ld bc, 0x0200
    jr have_type
choose_hiform:
    ld a, '5'
    call echo_choice
    ld hl, spec_hiform
    ld de, name_hiform
    ld bc, 0x0300                   ; interleave 3, no skew
    jr have_type
choose_ultra:
    ld a, '6'
    call echo_choice
    ld hl, spec_ultra
    ld de, name_ultra
    ld bc, 0x0302                   ; interleave 3, skew 2
    push hl
    push de
    ld hl, msg_ultra_note
    ld (note_ptr), hl
    pop de
    pop hl
    jr have_type
choose_supermat:
    ld a, '7'
    call echo_choice
    ld hl, spec_supermat
    ld de, name_supermat
    ld bc, 0x0100
    jr have_type
choose_cpc_ibm:
    ld a, '8'
    call echo_choice
    ld hl, spec_cpc_ibm
    ld de, name_cpc_ibm
    ld bc, 0x0200
have_type:
    ld (layout_ptr), de
    ld a, b
    ld (interleave), a
    ld a, c
    ld (skew), a
    ld de, SPEC
    ld bc, 10
    ldir

    ; Build the XDPB the disc calls will use (DD_L_XDPB is the tested path;
    ; it also derives DSM/DRM/AL0/CKS from the spec).
    ld hl, DD_L_XDPB
    ld (userf_dw), hl
    ld hl, SPEC
    ld ix, XDPB
    call userf_call
    jp nc, bad_spec

    ; ---- Read the geometry back out of the XDPB ----
    ld a, (XDPB + XDPB_SIDES)
    ld (sides), a
    ld a, (XDPB + XDPB_TRACKS)
    ld (tracks), a
    ld a, (XDPB + XDPB_SECTORS)
    ld (sectors), a
    ld a, (XDPB + XDPB_FIRST)
    ld (first), a
    ld a, (XDPB + XDPB_PSH)
    ld (psh), a

    ; Logical tracks = tracks per side * number of sides.
    ld a, (tracks)
    ld b, a
    ld a, (sides)
    or a
    jr z, .total_ready
    ld a, b
    add a, a
    ld b, a
.total_ready:
    ld a, b
    ld (total_tracks), a

    call fill_pattern

    ; ---- Format and verify one track at a time ----
    xor a
    ld (cur_track), a
track_loop:
    call set_track_geom
    call build_hdr

    ld de, st_format
    ld (status_ptr), de
    call progress

    ; DD_FORMAT: B=1 (TPA), C=0 (unit), D=logical track, E=fill,
    ;            HL=header table, IX=XDPB
    ld hl, DD_FORMAT
    ld (userf_dw), hl
    ld a, (cur_track)
    ld d, a
    ld e, FILL_BYTE
    ld b, 1                      ; CP/M bank 1 (TPA)
    ld a, (drive_unit)
    ld c, a
    ld hl, HDR
    ld ix, XDPB
    call userf_call
    jp nc, fail_format

    ld de, st_verify
    ld (status_ptr), de
    call progress

    call verify_track
    jp nc, fail_verify

    ld a, (cur_track)
    inc a
    ld (cur_track), a
    ld b, a
    ld a, (total_tracks)
    cp b
    jp nz, track_loop

    ; ---- Give the blank disc a disc spec so login detects the geometry ----
    call write_disc_spec
    jp nc, fail_label

    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_call

    ; Let the BDOS log the disc in again, now that it is blank but valid.
    ld c, F_RESET
    call BDOS

    call crlf
    ld de, msg_done
    call pstr
    ld de, (layout_ptr)
    call pstr
    ld de, msg_done_end
    call pstr
    ld a, (total_tracks)
    call print_dec
    ld de, msg_tracks
    call pstr
    ld a, (sectors)
    call print_dec
    ld de, msg_sectors
    call pstr
    ld de, msg_verified
    call pstr
    ld de, (note_ptr)
    ld a, d
    or e
    jr z, .no_note
    call pstr
.no_note:
    rst 0

; ==========================================================================
; Failures
; ==========================================================================
fail_format:
    ld (last_error), a
    ld de, st_failed
    ld (status_ptr), de
    call progress
    call crlf
    call report_where
    ld de, msg_fmt_error
    call pstr
    jr fail_common

fail_verify:
    ld (last_error), a
    ld de, st_failed
    ld (status_ptr), de
    call progress
    call crlf
    call report_where
    ld de, msg_ver_error
    call pstr
    jr fail_common

fail_label:
    ld (last_error), a
    call crlf
    ld de, msg_label_error
    call pstr
    jr fail_common

fail_common:
    ; "(NN)" -- hex is easier to read in a bug report than a name.
    ld de, msg_error_code
    call pstr
    ld a, (last_error)
    call print_hex
    ld a, ')'
    call cout

    ld a, (last_error)
    cp 1
    jr nz, .not_wp
    ld de, msg_write_protect
    call pstr
    jr .stop
.not_wp:
    cp 0xFF
    jr nz, .bios_error
    ld de, msg_mismatch
    call pstr
    jr .stop
.bios_error:
    call crlf
.stop:
    ld hl, DD_OFF_MOTOR
    ld (userf_dw), hl
    call userf_call

    ; The disc is partly formatted: make the BDOS look at it afresh.
    ld c, F_RESET
    call BDOS
    rst 0

cancelled:
    call crlf
    ld de, msg_cancelled
    call pstr
    rst 0

bad_spec:
    ld de, msg_bad_spec
    call pstr
    rst 0

usage:
    ld de, msg_usage
    call pstr
    rst 0

not_supported:
    call crlf
    ld de, msg_notsup1
    call pstr
    ld a, (drive_letter)
    call cout
    ld de, msg_notsup2
    call pstr
    rst 0

; ==========================================================================
; Track helpers
; ==========================================================================
; set_track_geom - cylinder and head of the current logical track
;   In:       cur_track, sides
;   Out:      cur_cyl, cur_side
;   Clobbers: AF, B
set_track_geom:
    ld a, (cur_track)
    ld b, a
    ld a, (sides)
    or a
    jr z, .single
    ld a, b
    and 1
    ld (cur_side), a
    ld a, b
    srl a
    ld (cur_cyl), a
    ret
.single:
    xor a
    ld (cur_side), a
    ld a, b
    ld (cur_cyl), a
    ret

; shift_for_track - sector skew for the current track
;   In:       skew, cur_track, sectors
;   Out:      A = (skew * cur_track) mod sectors
;   Clobbers: AF, BC, DE
shift_for_track:
    ld a, (skew)
    or a
    jr z, .none
    ld c, a
    ld a, (cur_track)
    ld b, a
    xor a
.loop:
    add a, c
    call mod_sectors
    dec b
    jr nz, .loop
    ret
.none:
    xor a
    ret

; mod_sectors - reduce A modulo sectors (A < 2 * sectors)
;   In:       A, sectors
;   Out:      A = A mod sectors
;   Clobbers: AF, DE
mod_sectors:
    ld d, a
    ld a, (sectors)
    ld e, a
    ld a, d
    cp e
    ret c
    sub e
    ret

; bit_taken - is position C already used in this track's layout?
;   In:       C = position (0-31)
;   Out:      carry set when taken
;   Clobbers: AF, DE, HL
bit_taken:
    ld hl, taken
    ld a, c
    and 0xF8
    rrca
    rrca
    rrca
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    ld e, a
    ld a, c
    and 7
    inc a
    ld d, a
    ld a, e
.shift:
    rrca
    dec d
    jr nz, .shift
    ret

; set_taken - mark position C as used
;   In:       C = position (0-31)
;   Clobbers: AF, DE, HL
set_taken:
    ld hl, taken
    ld a, c
    and 0xF8
    rrca
    rrca
    rrca
    ld e, a
    ld d, 0
    add hl, de
    ld a, c
    and 7
    ld e, a
    ld a, 1
    inc e
.mask:
    dec e
    jr z, .store
    add a, a
    jr .mask
.store:
    or (hl)
    ld (hl), a
    ret

; build_hdr - fill the DD_FORMAT ID table for the current track
;   In:       cur_cyl, cur_side, first, psh, sectors, interleave, skew
;   Out:      HDR = sectors * 4 bytes, in physical order
;   Clobbers: AF, BC, DE, HL
;
; The IDs are walked in steps of `interleave`, skipping positions already
; taken (that also copes with an interleave that does not divide the sector
; count, e.g. 2 of 8), which gives idtab[position].  The per-track skew then
; rotates the table: physical position q holds idtab[q + shift].  CP/M still
; addresses ID first + i, so the permutation only changes how long the
; drive takes to find a sector.
build_hdr:
    xor a
    ld (taken + 0), a
    ld (taken + 1), a
    ld (taken + 2), a
    ld (taken + 3), a

    ld a, (interleave)
    or a
    jr nz, .il_ok
    ld a, 1
.il_ok:
    ld (il), a

    ld b, 0                         ; B = sector index k
    ld c, 0                         ; C = walk position
.k_loop:
.take_loop:
    call bit_taken
    jr nc, .free
    inc c
    ld a, (sectors)
    cp c
    jr nz, .take_loop
    ld c, 0
    jr .take_loop
.free:
    ld a, (first)
    add a, b
    ld hl, idtab
    ld e, c
    ld d, 0
    add hl, de
    ld (hl), a
    call set_taken

    ld a, c
    ld d, a
    ld a, (il)
    ld e, a
    ld a, d
    add a, e
    call mod_sectors
    ld c, a

    inc b
    ld a, (sectors)
    cp b
    jr nz, .k_loop

    ; Emit in physical order, rotated by the track skew.
    call shift_for_track
    ld (shift), a
    xor a
    ld (pcur), a
.emit:
    ld a, (pcur)
    ld hl, idtab
    ld e, a
    ld d, 0
    add hl, de
    ld a, (hl)
    ld (cur_id), a

    ld a, (pcur)
    ld d, a
    ld a, (shift)
    ld e, a
    ld a, d
    sub e
    jr nc, .q_ok
    ld e, a
    ld a, (sectors)
    add a, e
.q_ok:
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    ld de, HDR
    add hl, de
    ld a, (cur_cyl)
    ld (hl), a                      ; C
    inc hl
    ld a, (cur_side)
    ld (hl), a                      ; H
    inc hl
    ld a, (cur_id)
    ld (hl), a                      ; R
    inc hl
    ld a, (psh)
    ld (hl), a                      ; N

    ld a, (pcur)
    inc a
    ld (pcur), a
    ld b, a
    ld a, (sectors)
    cp b
    jr nz, .emit
    ret

; verify_track - read every sector of the current track and compare it with
;                the filler the format wrote
;   In:       cur_track, sectors, psh
;   Out:      carry set OK, or carry clear + A = error (0xFF = different)
;   Clobbers: AF, BC, DE, HL, IX
verify_track:
    xor a
    ld (cur_sec), a
.loop:
    ; E = sector index << PSH (the XBIOS counts 128-byte records)
    ld a, (cur_sec)
    ld b, a
    ld a, (psh)
    or a
    jr z, .no_shift
    ld c, a
    ld a, b
.shift:
    sla a
    dec c
    jr nz, .shift
    jr .have_e
.no_shift:
    ld a, b
.have_e:
    ld e, a
    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld a, (cur_track)
    ld d, a
    ld b, 1                      ; CP/M bank 1 (TPA)
    ld a, (drive_unit)
    ld c, a
    ld hl, BUF
    ld ix, XDPB
    call userf_call
    jr nc, .error
    jr nz, .different
    ld a, (cur_sec)
    inc a
    ld (cur_sec), a
    ld b, a
    ld a, (sectors)
    cp b
    jr nz, .loop
    scf
    ret
.error:
    ; A already holds the BIOS error, carry is clear.
    ret
.different:
    ld a, 0xFF
    or a
    ret

; write_disc_spec - store the AMSDOS disc spec in the boot sector
;   In:       SPEC (chosen above), XDPB (OFF field)
;   Out:      carry set OK, or carry clear + A = error
;   Clobbers: AF, BC, DE, HL, IX
write_disc_spec:
    ; A data layout (OFF = 0) has no boot sector: its first sector is the
    ; directory, so leave it as filler.  (The original Ultra 208 wrote the
    ; spec there, which leaves junk directory entries; the login probe
    ; cannot see that geometry without it, hence the note after the run.)
    ld a, (XDPB + XDPB_OFF)
    or a
    jr nz, .write
    scf
    ret
.write:
    call fill_zero
    ; The same 10-byte spec the XDPB was built from: disc type, sidedness,
    ; tracks, sectors, size code, reserved tracks, block size, dir blocks,
    ; gap 1 and gap 2.  The login probe only needs byte 0 (type) and byte 7
    ; (dir blocks), but a complete spec is what AMSDOS and the +3 ROM expect.
    ld hl, SPEC
    ld de, BUF
    ld bc, 10
    ldir
    ld hl, DD_WRITE
    ld (userf_dw), hl
    ld de, 0
    ld b, 1                      ; CP/M bank 1 (TPA)
    ld a, (drive_unit)
    ld c, a
    ld hl, BUF
    ld ix, XDPB
    call userf_call
    ret nc
    ; Read it straight back so the boot sector is verified too.
    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld de, 0
    ld b, 1                      ; CP/M bank 1 (TPA)
    ld a, (drive_unit)
    ld c, a
    ld hl, BUF
    ld ix, XDPB
    call userf_call
    ret nc
    jr nz, .different
    scf
    ret
.different:
    ld a, 0xFF
    or a
    ret

; ==========================================================================
; Progress display
; ==========================================================================
; progress - redraw the one-line progress display
;   In:       cur_track, cur_cyl, cur_side, status_ptr
;   Clobbers: AF, BC, DE, HL
progress:
    ld a, 0x0D                  ; carriage return, no line feed
    call cout
    call calc_pct
    call print_pct
    ld de, msg_track
    call pstr
    ld a, (cur_cyl)
    call print_dec
    ld de, msg_side
    call pstr
    ld a, (cur_side)
    add a, '0'
    call cout
    ld de, msg_gap
    call pstr
    ld de, (status_ptr)
    call pstr
    ret

; calc_pct - percentage of the disc done, counting the current track
;   Out:      A = 0-100
;   Clobbers: AF, BC, DE, HL
calc_pct:
    ld a, (cur_track)
    inc a
    ld l, a
    ld h, 0
    call mul100
    ld a, (total_tracks)
    ld c, a
    call div_hl_c
    ld a, l
    ret

; mul100 - HL = HL * 100
;   In:       HL = value (0-160)
;   Out:      HL = value * 100
;   Clobbers: F, DE, HL
mul100:
    add hl, hl                  ; 2x
    add hl, hl                  ; 4x
    add hl, hl                  ; 8x
    add hl, hl                  ; 16x
    add hl, hl                  ; 32x
    add hl, hl                  ; 64x
    ld d, h
    ld e, l                     ; DE = 64x
    srl d
    rr e                        ; 32x
    add hl, de                  ; 96x
    srl d
    rr e                        ; 16x
    srl d
    rr e                        ; 8x
    srl d
    rr e                        ; 4x
    add hl, de                  ; 100x
    ret

; div_hl_c - HL = HL / C
;   In:       HL = dividend, C = divisor
;   Out:      HL = quotient
;   Clobbers: AF, B, HL
div_hl_c:
    xor a
    ld b, 16
.loop:
    add hl, hl
    rla
    jr c, .subtract
    cp c
    jr c, .next
.subtract:
    sub c
    inc l
.next:
    djnz .loop
    ret

; print_pct - print A as a right-aligned three-digit percentage
;   In:       A = 0-100
;   Clobbers: AF, BC, E
print_pct:
    ld b, 0
.hundreds:
    cp 100
    jr c, .tens
    sub 100
    inc b
    jr .hundreds
.tens:
    ld c, 0
.tens_loop:
    cp 10
    jr c, .units
    sub 10
    inc c
    jr .tens_loop
.units:
    ld (num_units), a
    ld a, c
    ld (num_tens), a
    ld a, b
    or a
    jr z, .blank
    add a, '0'
    call cout
    jr .print_tens
.blank:
    ld a, ' '
    call cout
.print_tens:
    ld a, (num_tens)
    add a, '0'
    call cout
    ld a, (num_units)
    add a, '0'
    call cout
    ld a, '%'
    jp cout

; print_dec - print A as decimal, no leading zeros
;   In:       A = 0-255
;   Clobbers: AF, BC, E
print_dec:
    ld b, 0
.hundreds:
    cp 100
    jr c, .tens
    sub 100
    inc b
    jr .hundreds
.tens:
    ld c, 0
.tens_loop:
    cp 10
    jr c, .units
    sub 10
    inc c
    jr .tens_loop
.units:
    ld (num_units), a
    ld a, c
    ld (num_tens), a
    ld a, b
    ld (num_hund), a
    or a
    jr nz, .three
    ld a, (num_tens)
    or a
    jr z, .last
    add a, '0'
    call cout
    jr .last
.three:
    add a, '0'
    call cout
    ld a, (num_tens)
    add a, '0'
    call cout
.last:
    ld a, (num_units)
    add a, '0'
    jp cout

; print_hex - print A as two hex digits
;   In:       A = value
;   Clobbers: AF, C, E
print_hex:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nibble
    pop af
    call .nibble
    ret
.nibble:
    and 0x0F
    add a, '0'
    cp '9' + 1
    jr c, .digit
    add a, 7
.digit:
    jp cout

; report_where - "Track nn side d: "
;   In:       cur_cyl, cur_side
;   Clobbers: AF, BC, DE
report_where:
    ld de, msg_track_cap
    call pstr
    ld a, (cur_cyl)
    call print_dec
    ld de, msg_side_lower
    call pstr
    ld a, (cur_side)
    add a, '0'
    call cout
    ld de, msg_colon
    jp pstr

; ==========================================================================
; Console and buffers
; ==========================================================================
; wait_key - wait for one keypress, without echoing it (ESC stays clean)
;   Out:      A = character
;   Clobbers: AF, BC, DE ; lint: ignore
wait_key:
    ld e, 0xFF
    ld c, F_DIRECT
    call BDOS
    or a
    jr z, wait_key
    ret

; cout - write A to the console
;   In:       A = character
;   Clobbers: AF, BC, DE ; lint: ignore
cout:
    ld e, a
    ld c, F_CONOUT
    jp BDOS

; pstr - print a '$'-terminated string
;   In:       DE = string
;   Clobbers: AF, BC, DE ; lint: ignore
pstr:
    ld c, F_PSTR
    jp BDOS

; crlf - end the progress line
;   Clobbers: AF, BC, DE ; lint: ignore
crlf:
    ld de, msg_crlf
    jp pstr

; echo_choice - echo the geometry digit (wait_key reads without echo)
;   In:       A = character
;   Clobbers: AF, BC, DE ; lint: ignore
echo_choice:
    call cout
    jp crlf

; fill_pattern - fill BUF with the format filler byte
;   Clobbers: AF, DE, HL
fill_pattern:
    ld hl, BUF
    ld de, SECTOR_SIZE
.loop:
    ld a, FILL_BYTE
    ld (hl), a
    inc hl
    dec de
    ld a, d
    or e
    jr nz, .loop
    ret

; fill_zero - fill BUF with zeroes
;   Clobbers: AF, B, DE, HL
fill_zero:
    ld hl, BUF
    ld de, SECTOR_SIZE
    ld b, 0
.loop:
    ld (hl), b
    inc hl
    dec de
    ld a, d
    or e
    jr nz, .loop
    ret

; tail_end_ok - is the tail finished at HL?
;   In:       HL = tail pointer
;   Out:      Z set when only spaces remain
;   Clobbers: AF, HL
tail_end_ok:
    ld a, (hl)
    or a
    ret z
    cp 0x0D
    ret z
    cp ' '
    jr nz, .junk
    inc hl
    jr tail_end_ok
.junk:
    or a                        ; clear Z: extra arguments are not supported
    ret

; ==========================================================================
; USERF trampoline (patched at start)
; ==========================================================================
userf_call:
    call 0                      ; patched to the USERF jumpblock entry
userf_dw:
    dw 0                        ; extended jumpblock entry for this call
    ret

; ==========================================================================
; Data
; ==========================================================================
; AMSDOS 10-byte disc specs: type, arrangement, tracks, sectors, size code,
; reserved tracks, block-size code, directory blocks, gap1, gap2.
spec_180:
    db 0, 0, 40, 9, 2, 1, 3, 2, 42, 82
spec_720:
    db 3, 1, 80, 9, 2, 1, 4, 2, 42, 82
spec_cpc_sys:
    db 1, 0, 40, 9, 2, 2, 3, 2, 42, 82
spec_cpc_data:
    db 2, 0, 40, 9, 2, 0, 3, 2, 42, 82
; 10-sector single-sided layouts packed onto a 3" disc.  The spec block is
; the same AMSDOS 10 bytes, so login can rebuild the geometry from it:
; type, arrangement, tracks, sectors, size code, reserved tracks, block
; size code, directory blocks, gap R/W, gap format.
spec_hiform:
    db 0, 0, 42, 10, 2, 1, 3, 2, 12, 22
spec_ultra:
    db 0, 0, 42, 10, 2, 0, 3, 2, 12, 22
spec_supermat:
    db 0, 0, 40, 10, 2, 1, 3, 3, 12, 23
spec_cpc_ibm:
    db 0, 0, 40, 8, 2, 1, 3, 2, 42, 80

drive_letter:  db 0
drive_unit:    db 0
sides:         db 0
tracks:        db 0
total_tracks:  db 0
sectors:       db 0
first:         db 0
psh:           db 0
cur_track:     db 0
cur_cyl:       db 0
cur_side:      db 0
cur_sec:       db 0
interleave:    db 0
skew:          db 0
shift:         db 0
il:            db 0
pcur:          db 0
cur_id:        db 0
taken:         db 0, 0, 0, 0
idtab:         ds 32
note_ptr:      dw 0
last_error:    db 0
num_hund:      db 0
num_tens:      db 0
num_units:     db 0
status_ptr:    dw 0
layout_ptr:    dw 0

st_format:     db "FORMAT", '$'
st_verify:     db "VERIFY", '$'
st_failed:     db "FAILED", '$'

msg_crlf:      db 0x0D, 0x0A, '$'
msg_track:     db "  Track ", '$'
msg_side:      db "  Side ", '$'
msg_gap:       db "  ", '$'

msg_fmt_prefix:
    db 0x0D, 0x0A, "FORMAT ", '$'
msg_warning_tail:
    db ": - ALL DATA ON THE DISC WILL BE LOST.", 0x0D, 0x0A, 0x0A, '$'
msg_remove:
    db "Take the disc out of drive ", '$'
msg_remove_tail:
    db ": and press any key.", 0x0D, 0x0A, "(ESC cancels)", 0x0D, 0x0A, '$'
msg_insert:
    db 0x0A, "Put the disc to be formatted in drive ", '$'
msg_insert_tail:
    db ":", 0x0D, 0x0A, "then press any key.", '$'
msg_menu:
    db 0x0D, 0x0A, 0x0A
    db "Format type:", 0x0D, 0x0A
    db "  1   180K  SS 40 track (PCW)", 0x0D, 0x0A
    db "  2   720K  DS 80 track (PCW)", 0x0D, 0x0A
    db "  3   CPC System  40 track", 0x0D, 0x0A
    db "  4   CPC Data    40 track", 0x0D, 0x0A
    db "  5   HiForm 203  42 track", 0x0D, 0x0A
    db "  6   Ultra 208   42 track", 0x0D, 0x0A
    db "  7   SuperMat 192 40 track", 0x0D, 0x0A
    db "  8   CPC IBM     40 track", 0x0D, 0x0A
    db 0x0A, "Choice (1-8, ESC cancels): ", '$'
msg_bad_choice:
    db 0x0D, 0x0A, "1-8: ", '$'

msg_done:
    db 0x0A, "Done - ", '$'
msg_done_end:
    db ".", 0x0D, 0x0A, '$'
msg_tracks:
    db " tracks, ", '$'
msg_sectors:
    db " sectors.", 0x0D, 0x0A, '$'
msg_verified:
    db "Every track formatted and verified.", 0x0D, 0x0A, '$'
msg_ultra_note:
    db "Note: no boot track, so CP/M sees 180K.", 0x0D, 0x0A, '$'

name_180:
    db "180K SS/40 track", '$'
name_720:
    db "720K DS/80 track", '$'
name_cpc_sys:
    db "CPC System 40 track", '$'
name_cpc_data:
    db "CPC Data 40 track", '$'
name_hiform:
    db "HiForm 203 42 track", '$'
name_ultra:
    db "Ultra 208 42 track", '$'
name_supermat:
    db "SuperMat 192 40 track", '$'
name_cpc_ibm:
    db "CPC IBM 40 track", '$'

msg_cancelled:
    db "Cancelled.", 0x0D, 0x0A, '$'
msg_bad_spec:
    db "Bad disc spec.", 0x0D, 0x0A, '$'

msg_track_cap:   db "Track ", '$'
msg_side_lower:  db " side ", '$'
msg_colon:       db ": ", '$'
msg_fmt_error:   db "format error ", '$'
msg_ver_error:   db "verify error ", '$'
msg_label_error: db "Error writing the disc spec: ", '$'
msg_error_code:  db "(", '$'
msg_write_protect:
    db " - the disc is write-protected.", 0x0D, 0x0A, '$'
msg_mismatch:
    db " - the data does not match the format pattern.", 0x0D, 0x0A, '$'

msg_usage:
    db "FORMAT A:", 0x0D, 0x0A
    db "FORMAT B:", 0x0D, 0x0A
    db "  Format the disc in the given drive.", 0x0D, 0x0A, '$'
msg_notsup1:
    db "FORMAT: drive ", '$'
msg_notsup2:
    db ": cannot be formatted.", 0x0D, 0x0A
    db "Only drives A: and B: are supported.", 0x0D, 0x0A, '$'
