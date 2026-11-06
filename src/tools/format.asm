; FORMAT.COM - format a 3-inch disc
;
; Usage:  FORMAT A:
;
; The drive letter is mandatory.  Only A: can be formatted: the XBIOS disc
; calls (DD_INIT, DD_FORMAT, DD_WRITE, DD_CHECK_SECTOR) handle unit 0 only
; in this BIOS, so the command refuses anything else rather than pretend.
;
; The user is asked to take the disc out of the drive, put the one to be
; formatted in, and choose a geometry:
;
;   1   180K  SS 40 track (PCW)     disc type 0
;   2   720K  DS 80 track (PCW)     disc type 3
;
; Every track is formatted and then verified sector by sector before the
; next track is touched.  A single progress line is rewritten in place:
;
;    45%  Track 18  Side 0  FORMAT
;    45%  Track 18  Side 0  VERIFY
;
; A successful format finishes by writing the 10-byte AMSDOS disc spec into
; the boot sector, so the BIOS login detects the geometry just selected.
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

    ; Only the first drive is formattable at the moment.
    ld a, (drive_letter)
    cp 'A'
    jp nz, not_supported

    ; ---- Warning and the disc change ----
    ld de, msg_warning
    call pstr

    ld de, msg_remove
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled

    ld de, msg_insert
    call pstr
    call wait_key
    cp 0x1B
    jp z, cancelled

    ; The disc changed: drop the driver's cached track and deblock state.
    ld hl, DD_INIT
    ld (userf_dw), hl
    call userf_call

    ; ---- Geometry ----
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
    ld de, msg_bad_choice
    call pstr
    jr menu_key

choose_180:
    ld a, '1'
    call echo_choice
    ld hl, spec_180
    jr have_type
choose_720:
    ld a, '2'
    call echo_choice
    ld hl, spec_720
have_type:
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
    ld bc, 0x0100
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
    ; "error NN" -- hex is easier to read in a bug report than a name.
    ld de, msg_error_code
    call pstr
    ld a, (last_error)
    call print_hex

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

; build_hdr - fill the DD_FORMAT ID table for the current track
;   In:       cur_cyl, cur_side, first, psh, sectors
;   Out:      HDR
;   Clobbers: AF, B, HL
build_hdr:
    ld hl, HDR
    ld b, 0
.loop:
    ld a, (cur_cyl)
    ld (hl), a                  ; C
    inc hl
    ld a, (cur_side)
    ld (hl), a                  ; H
    inc hl
    ld a, (first)
    add a, b
    ld (hl), a                  ; R
    inc hl
    ld a, (psh)
    ld (hl), a                  ; N
    inc hl
    inc b
    ld a, (sectors)
    cp b
    jr nz, .loop
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
    ld bc, 0x0100
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
;   In:       SPEC (chosen above)
;   Out:      carry set OK, or carry clear + A = error
;   Clobbers: AF, BC, DE, HL, IX
write_disc_spec:
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
    ld bc, 0x0100
    ld hl, BUF
    ld ix, XDPB
    call userf_call
    ret nc
    ; Read it straight back so the boot sector is verified too.
    ld hl, DD_CHECK_SECTOR
    ld (userf_dw), hl
    ld de, 0
    ld bc, 0x0100
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

drive_letter:  db 0
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
last_error:    db 0
num_hund:      db 0
num_tens:      db 0
num_units:     db 0
status_ptr:    dw 0

st_format:     db "FORMAT", '$'
st_verify:     db "VERIFY", '$'
st_failed:     db "FAILED", '$'

msg_crlf:      db 0x0D, 0x0A, '$'
msg_track:     db "  Track ", '$'
msg_side:      db "  Side ", '$'
msg_gap:       db "  ", '$'

msg_warning:
    db 0x0D, 0x0A
    db "FORMAT A: - ALL DATA ON THE DISC WILL BE LOST.", 0x0D, 0x0A, 0x0A, '$'
msg_remove:
    db "Take the disc out of drive A:, then press any key.", 0x0D, 0x0A
    db "(ESC cancels)", 0x0D, 0x0A, '$'
msg_insert:
    db 0x0A, "Put the disc to be formatted in drive A:,", 0x0D, 0x0A
    db "then press any key.", '$'
msg_menu:
    db 0x0D, 0x0A, 0x0A
    db "Format type:", 0x0D, 0x0A
    db "  1   180K  SS 40 track (PCW)", 0x0D, 0x0A
    db "  2   720K  DS 80 track (PCW)", 0x0D, 0x0A
    db 0x0A, "Choice (1-2, ESC cancels): ", '$'
msg_bad_choice:
    db 0x0D, 0x0A, "1 or 2: ", '$'

msg_done:
    db 0x0A, "Done - ", '$'
msg_tracks:
    db " tracks, ", '$'
msg_sectors:
    db " sectors.", 0x0D, 0x0A, '$'
msg_verified:
    db "Every track formatted and verified.", 0x0D, 0x0A, '$'

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
    db ") - the disc is write-protected.", 0x0D, 0x0A, '$'
msg_mismatch:
    db ") - the data does not match the format pattern.", 0x0D, 0x0A, '$'

msg_usage:
    db "FORMAT A:", 0x0D, 0x0A
    db "  Format the disc in drive A:.", 0x0D, 0x0A, '$'
msg_notsup1:
    db "FORMAT: drive ", '$'
msg_notsup2:
    db ": cannot be formatted.", 0x0D, 0x0A
    db "Only drive A: is supported.", 0x0D, 0x0A, '$'
