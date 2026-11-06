; DISKCOPY.COM - copy one disc to another, track by track
;
; Usage:  DISKCOPY A: B:        (any pair of A: and B:, including the same
;                                drive twice: A: A: or B: B:)
;
; The source layout is detected with DD_LOGIN (the login probe reads the
; boot sector's AMSDOS spec, or the sector-ID group for CPC discs), and the
; copy uses the source's XDPB for both drives, so the target must be
; formatted with the same layout.  DISKCOPY copies sectors; it does not
; format.
;
; Each pass reads as many logical tracks as fit in the track buffer
; (1000h-D000h, 48K), then writes them back.  When both roles are on one
; drive the user is asked to swap the discs between the two halves of the
; pass; with two drives each track is read and written straight away.
;
; The progress line is rewritten in place, one line per track, with the
; completed percentage, the logical track, the head and whether that track
; is being read or written:
;
;    37%  Track 045 of 160  Side 0  READ
;    37%  Track 045 of 160  Side 0  WRITE
;
; Build: sjasmplus --raw=build/diskcopy.com src/tools/diskcopy.asm

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
DD_READ_SECTOR  equ 0x0086
DD_WRITE        equ 0x0089
DD_LOGIN        equ 0x0092

SECTOR_SIZE    equ 512

; Track buffer and XDPB.  The XDPB has to sit at C000+ (the window that is
; valid in both TPA and system mode); the buffer stops below it and leaves
; the stack at F600 alone.
BUF            equ 0x1000
BUF_END        equ 0xD000
BUFSIZE        equ BUF_END - BUF
XDPB           equ 0xD200

; XDPB field offsets
XDPB_PSH       equ 15
XDPB_SIDES     equ 17
XDPB_TRACKS    equ 18
XDPB_SECTS     equ 19
XDPB_SSIZE     equ 21

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

    ; ---- Command tail: two unit letters, "A:" and "B:" ----
    ld hl, TAIL
    ld a, (hl)
    or a
    jp z, usage
    inc hl
    call skip_spaces
    call parse_unit
    jp c, usage
    ld (src_unit), a
    call skip_spaces
    call parse_unit
    jp c, usage
    ld (dst_unit), a
    call tail_end_ok
    jp nz, usage                  ; lint: ignore - Z flag is the result

    ld a, (src_unit)
    ld b, a
    ld a, (dst_unit)
    cp b
    jr nz, .two_drives
    ld a, 1
    ld (same_drive), a
    jr .title
.two_drives:
    xor a
    ld (same_drive), a

.title:
    ; "DISKCOPY A: -> B:"
    ld de, msg_title
    call pstr
    ld a, (src_unit)
    call print_unit
    ld de, msg_arrow
    call pstr
    ld a, (dst_unit)
    call print_unit
    call crlf

    ; ---- Ask for the source (and target) and detect the layout ----
    call prompt_for_source
    call disk_changed

    ld hl, DD_LOGIN
    ld (userf_dw), hl
    ld a, (src_unit)
    ld c, a
    ld ix, XDPB
    call userf_call
    jp nc, bad_geometry

    ; ---- Geometry checks ----
    ld a, (XDPB + XDPB_SSIZE)
    or a
    jp nz, bad_sector_size
    ld a, (XDPB + XDPB_SSIZE + 1)
    cp 2
    jp nz, bad_sector_size       ; 512 = 0x0200

    ld a, (XDPB + XDPB_TRACKS)
    or a
    jp z, bad_geometry
    ld (tracks), a
    ld a, (XDPB + XDPB_SIDES)
    cp 2
    jp nc, bad_geometry
    ld (sides), a

    ld a, (XDPB + XDPB_SECTS)
    or a
    jp z, bad_geometry
    cp 33
    jp nc, bad_geometry
    ld (sectors), a
    ld b, a
    ld a, (XDPB + XDPB_PSH)
    cp 4
    jp nc, bad_geometry
    ld (psh), a
    ; The XBIOS takes a 128-byte record number in E, so
    ; sectors << psh has to stay inside a byte.
    ld c, a
    ld a, b
.psh_scale:
    dec c
    jp m, .psh_done
    sla a
    jp c, bad_geometry
    jr .psh_scale
.psh_done:
    or a
    jp z, bad_geometry

    ; total logical tracks = tracks per side << sides
    ld a, (tracks)
    ld b, a
    ld a, (sides)
    or a
    jr z, .total_ready
    ld a, b
    add a, a
    jp c, bad_geometry
    ld b, a
.total_ready:
    ld a, b
    or a
    jp z, bad_geometry
    ld (total_tracks), a

    ; ---- Geometry banner ----
    ld de, msg_geometry
    call pstr
    ld a, (sides)
    or a
    ld de, msg_ss
    jr z, .print_sides
    ld de, msg_ds
.print_sides:
    call pstr
    ld a, (tracks)
    call print_dec
    ld de, msg_tracks_line
    call pstr
    ld a, (sectors)
    call print_dec
    ld de, msg_sectors_line
    call pstr

    ; ---- Pass size ----
    ; track_bytes = sectors * 512
    ld a, (sectors)
    ld l, a
    ld h, 0
    ld b, 9
.byte_loop:
    add hl, hl
    djnz .byte_loop
    ld (track_bytes), hl

    ; With two drives each track is read and written straight away; only a
    ; single drive needs a buffer big enough to bridge the disc swap.
    ld a, (same_drive)
    or a
    jr z, .per_pass_one
    call div_buffer
    jr .per_pass_ready
.per_pass_one:
    ld a, 1
.per_pass_ready:
    ld b, a
    ld a, (total_tracks)
    cp b
    jr nc, .per_pass_ok
    ld b, a
.per_pass_ok:
    ld a, b
    ld (per_pass), a

    ; ---- Copy ----
    xor a
    ld (cur_track), a
    ld hl, 0
    ld (ops_done), hl
.pass_loop:
    ; chunk = min(per_pass, total - cur_track)
    ld a, (per_pass)
    ld b, a
    ld a, (total_tracks)
    ld c, a
    ld a, (cur_track)
    ld d, a
    ld a, c
    sub d
    cp b
    jr nc, .chunk_ok
    ld b, a
.chunk_ok:
    ld a, b
    ld (chunk), a

    ; Read the chunk from the source.
    xor a
    ld (xfer_op), a
    call do_chunk

    ; Same drive: swap the target in before writing.
    ld a, (same_drive)
    or a
    jr z, .write_now
    call prompt_for_target
    call disk_changed
.write_now:
    ld a, 1
    ld (xfer_op), a
    call do_chunk

    ; Advance past the chunk.
    ld a, (cur_track)
    ld b, a
    ld a, (chunk)
    add a, b
    ld (cur_track), a
    ld b, a
    ld a, (total_tracks)
    cp b
    jr z, .copied

    ; Same drive: the source has to go back for the next pass.
    ld a, (same_drive)
    or a
    jr z, .pass_loop
    call prompt_for_source_again
    call disk_changed
    jr .pass_loop

.copied:
    call crlf
    ld de, msg_done
    call pstr
    ld a, (total_tracks)
    call print_dec
    ld de, msg_done_tracks
    call pstr

    ; Let the BDOS probe the drives again (the target changed).
    ld c, F_RESET
    call BDOS
    rst 0

; ==========================================================================
; Copy engine
; ==========================================================================
; do_chunk - transfer `chunk` logical tracks between the drives
;   In:       cur_track, chunk, xfer_op (0 = read source, 1 = write target)
;   Out:      buffer filled/emptied; ops_done advanced per track
;   Clobbers: everything
do_chunk:
    ld hl, BUF
    ld (buf_ptr), hl
    ld a, (cur_track)
    ld (t_track), a
    ld a, (chunk)
    ld (t_left), a
.track_loop:
    call set_track_geom
    ld de, st_read
    ld a, (xfer_op)
    or a
    jr z, .status_ready
    ld de, st_write
.status_ready:
    ld (status_ptr), de
    call progress

    xor a
    ld (s_idx), a
.sector_loop:
    ; E = sector index << PSH
    ld a, (s_idx)
    ld b, a
    ld a, (psh)
    or a
    jr z, .have_e
    ld c, a
    ld a, b
.shift:
    sla a
    dec c
    jr nz, .shift
.have_e:
    ld e, a

    ; Entry and unit for this direction.
    ld a, (xfer_op)
    or a
    ld hl, DD_READ_SECTOR
    ld a, (src_unit)
    jr z, .op_ready
    ld hl, DD_WRITE
    ld a, (dst_unit)
.op_ready:
    ld (userf_dw), hl
    ld c, a
    ld a, (t_track)
    ld d, a
    ld b, 1                      ; CP/M bank 1 (TPA)
    ld hl, (buf_ptr)
    ld ix, XDPB
    call userf_call
    jr nc, .failed               ; A = error, carry clear
    ld hl, (buf_ptr)
    ld de, SECTOR_SIZE
    add hl, de
    ld (buf_ptr), hl

    ld a, (s_idx)
    inc a
    ld (s_idx), a
    ld b, a
    ld a, (sectors)
    cp b
    jr nz, .sector_loop

    ; One track done: count it and move on.
    ld hl, (ops_done)
    inc hl
    ld (ops_done), hl
    ld a, (t_track)
    inc a
    ld (t_track), a
    ld a, (t_left)
    dec a
    ld (t_left), a
    jp nz, .track_loop
    ret

.failed:
    ld (last_error), a
    ld a, (xfer_op)
    or a
    jr nz, write_failed
    call crlf
    ld de, msg_read_fail
    call pstr
    jr report_track

write_failed:
    call crlf
    ld de, msg_write_fail
    call pstr
report_track:
    ld a, (t_track)
    call print3z
    ld de, msg_side_line
    call pstr
    ld a, (cur_side)
    add a, '0'
    call cout
    ld a, '('
    call cout
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
    ld de, msg_check_target
    call pstr
.stop:
    call crlf
    ld c, F_RESET
    call BDOS
    rst 0

; set_track_geom - cylinder and head for the logical track in t_track
;   Out:      cur_cyl, cur_side
;   Clobbers: AF, B
set_track_geom:
    ld a, (t_track)
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

; progress - redraw the one-track progress line
;   In:       t_track, cur_side, status_ptr, ops_done, total_tracks
;   Clobbers: AF, BC, DE, HL
progress:
    ld a, 0x0D
    call cout
    ; percent = ops_done * 50 / total_tracks  (= ops * 100 / (2 * total))
    ld hl, (ops_done)
    call mul100
    srl h
    rr l
    ld a, (total_tracks)
    ld c, a
    call div_hl_c
    ld a, l
    call print_pct
    ld de, msg_line_track
    call pstr
    ld a, (t_track)
    call print3z
    ld de, msg_line_of
    call pstr
    ld a, (total_tracks)
    call print3z
    ld de, msg_line_side
    call pstr
    ld a, (cur_side)
    add a, '0'
    call cout
    ld de, msg_line_gap
    call pstr
    ld de, (status_ptr)
    call pstr
    ret

; div_buffer - how many tracks fit in the buffer
;   In:       track_bytes
;   Out:      A = BUFSIZE / track_bytes
;   Clobbers: AF, B, DE, HL
div_buffer:
    ld hl, BUFSIZE
    ld de, (track_bytes)
    ld b, 0
.loop:
    ld a, h
    cp d
    jr c, .done
    jr nz, .sub
    ld a, l
    cp e
    jr c, .done
.sub:
    ld a, l
    sub e
    ld l, a
    ld a, h
    sbc a, d
    ld h, a
    inc b
    jr .loop
.done:
    ld a, b
    ret

; ==========================================================================
; Prompts
; ==========================================================================
prompt_for_source:
    ld a, (same_drive)
    or a
    jr z, .two
    ld de, msg_put_source
    call pstr
    ld a, (src_unit)
    call print_unit
    ld de, msg_and_key
    call pstr
    jr .wait
.two:
    ld de, msg_put_source
    call pstr
    ld a, (src_unit)
    call print_unit
    ld de, msg_comma_nl
    call pstr
    ld de, msg_target_in
    call pstr
    ld a, (dst_unit)
    call print_unit
    ld de, msg_then_key
    call pstr
.wait:
    jp wait_key

prompt_for_target:
    ld de, msg_swap_target
    call pstr
    ld a, (src_unit)
    call print_unit
    ld de, msg_then_key
    call pstr
    jp wait_key

prompt_for_source_again:
    ld de, msg_source_back
    call pstr
    ld a, (src_unit)
    call print_unit
    ld de, msg_and_key
    call pstr
    jp wait_key

; disk_changed - reset the disc driver after a disc swap
;   Clobbers: AF, BC, DE, HL, IX, IY ; lint: ignore - tail call
disk_changed:
    ld hl, DD_INIT
    ld (userf_dw), hl
    jp userf_call

; ==========================================================================
; Command tail
; ==========================================================================
; parse_unit - read "A:" / "B:" and return the unit number
;   In:       HL = pointer into the tail
;   Out:      A = 0 or 1, HL advanced; carry set on a bad or missing unit
;   Clobbers: AF, B, HL
parse_unit:
    ld a, (hl)
    or a
    jr z, .bad
    cp 0x0D
    jr z, .bad
    and 0xDF
    cp 'A'
    jr c, .bad
    cp 'B' + 1
    jr nc, .bad
    sub 'A'
    ld b, a
    inc hl
    ld a, (hl)
    cp ':'
    jr nz, .done
    inc hl
.done:
    ld a, b
    and a                        ; clear carry
    ret
.bad:
    scf
    ret

; skip_spaces - advance HL past spaces and tabs
;   Clobbers: AF, HL
skip_spaces:
    ld a, (hl)
    cp ' '
    jr z, .next
    cp 9
    ret nz
.next:
    inc hl
    jr skip_spaces

; tail_end_ok - Z set when only spaces remain
;   In:       HL = tail pointer
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
    or a
    ret

; ==========================================================================
; Console and numbers
; ==========================================================================
; wait_key - wait for one keypress, without echoing it
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

; crlf - end the current line
;   Clobbers: AF, BC, DE ; lint: ignore
crlf:
    ld de, msg_crlf
    jp pstr

; print_unit - print a unit number as "A:" / "B:"
;   In:       A = unit (0 or 1)
;   Clobbers: AF, BC, DE ; lint: ignore
print_unit:
    add a, 'A'
    call cout
    ld a, ':'
    jp cout

; print_dec - print A as decimal, no leading zeros
;   In:       A = 0-255
;   Clobbers: AF, BC, E ; lint: ignore
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
    ld (pd_u), a
    ld a, c
    ld (pd_t), a
    ld a, b
    ld (pd_h), a
    or a
    jr nz, .three
    ld a, (pd_t)
    or a
    jr z, .last
    add a, '0'
    call cout
    jr .last
.three:
    add a, '0'
    call cout
    ld a, (pd_t)
    add a, '0'
    call cout
.last:
    ld a, (pd_u)
    add a, '0'
    jp cout

; print3z - print A as three zero-padded decimal digits
;   In:       A = 0-255
;   Clobbers: AF, BC, E ; lint: ignore
print3z:
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
    ld (pd_u), a
    ld a, c
    ld (pd_t), a
    ld a, b
    add a, '0'
    call cout
    ld a, (pd_t)
    add a, '0'
    call cout
    ld a, (pd_u)
    add a, '0'
    jp cout

; print_pct - print A as a right-aligned three-digit percentage
;   In:       A = 0-100
;   Clobbers: AF, BC, E ; lint: ignore
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
    ld (pd_u), a
    ld a, c
    ld (pd_t), a
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
    ld a, (pd_t)
    add a, '0'
    call cout
    ld a, (pd_u)
    add a, '0'
    call cout
    ld a, '%'
    jp cout

; print_hex - print A as two hex digits
;   In:       A = value
;   Clobbers: AF, C, E ; lint: ignore
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

; mul100 - HL = HL * 100
;   In:       HL = value
;   Out:      HL = value * 100
;   Clobbers: F, DE, HL
mul100:
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    ld d, h
    ld e, l
    srl d
    rr e
    add hl, de
    srl d
    rr e
    srl d
    rr e
    srl d
    rr e
    add hl, de
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

; ==========================================================================
; Failures
; ==========================================================================
bad_geometry:
    ld de, msg_bad_geometry
    call pstr
    ld c, F_RESET
    call BDOS
    rst 0

bad_sector_size:
    ld de, msg_bad_sector_size
    call pstr
    rst 0

usage:
    ld de, msg_usage
    call pstr
    rst 0

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
src_unit:      db 0
dst_unit:      db 0
same_drive:    db 0
tracks:        db 0
sides:         db 0
sectors:       db 0
psh:           db 0
total_tracks:  db 0
track_bytes:   dw 0
per_pass:      db 0
chunk:         db 0
cur_track:     db 0
t_track:       db 0
t_left:        db 0
cur_cyl:       db 0
cur_side:      db 0
s_idx:         db 0
ops_done:      dw 0
xfer_op:       db 0
buf_ptr:       dw 0
status_ptr:    dw 0
last_error:    db 0
pd_h:          db 0
pd_t:          db 0
pd_u:          db 0

msg_crlf:      db 0x0D, 0x0A, '$'

st_read:       db "READ ", '$'
st_write:      db "WRITE", '$'

msg_title:     db "DISKCOPY ", '$'
msg_arrow:     db " -> ", '$'
msg_geometry:  db 0x0D, 0x0A, "Source: ", '$'
msg_ss:        db "SS, ", '$'
msg_ds:        db "DS, ", '$'
msg_tracks_line:  db " tracks, ", '$'
msg_sectors_line: db " sectors of 512 bytes.", 0x0D, 0x0A, '$'

msg_put_source:   db 0x0D, 0x0A, "Put the SOURCE disc in ", '$'
msg_comma_nl:     db ",", 0x0D, 0x0A, '$'
msg_target_in:    db "the TARGET disc in ", '$'
msg_then_key:     db ",", 0x0D, 0x0A, "then press any key.", '$'
msg_and_key:      db " and press any key.", '$'
msg_swap_target:  db 0x0D, 0x0A, "Take the SOURCE disc out,", 0x0D, 0x0A
                  db "put the TARGET disc in ", '$'
msg_source_back:  db 0x0D, 0x0A, "Put the SOURCE disc back in ", '$'

msg_line_track:   db "  Track ", '$'
msg_line_of:      db " of ", '$'
msg_line_side:    db "  Side ", '$'
msg_line_gap:     db "  ", '$'

msg_done:         db 0x0A, "Copied ", '$'
msg_done_tracks:  db " tracks.", 0x0D, 0x0A, '$'

msg_read_fail:    db "Read error: track ", '$'
msg_write_fail:   db "Write error: track ", '$'
msg_side_line:    db " side ", '$'
msg_write_protect: db " - the TARGET disc is write-protected.", 0x0D, 0x0A, '$'
msg_check_target: db " - is the TARGET disc formatted with the same", 0x0D, 0x0A
                  db "  layout? (FORMAT it first)", 0x0D, 0x0A, '$'

msg_bad_geometry:
    db 0x0D, 0x0A, "Cannot read the SOURCE disc, or its layout is", 0x0D, 0x0A
    db "not supported.", 0x0D, 0x0A, '$'
msg_bad_sector_size:
    db 0x0D, 0x0A, "Only 512-byte sectors are supported.", 0x0D, 0x0A, '$'

msg_usage:
    db "DISKCOPY source: target:", 0x0D, 0x0A
    db "  e.g. DISKCOPY A: B:", 0x0D, 0x0A
    db "  A: A: and B: B: work too - you swap the discs.", 0x0D, 0x0A
    db "  The target must be formatted with the same layout.", 0x0D, 0x0A, '$'
