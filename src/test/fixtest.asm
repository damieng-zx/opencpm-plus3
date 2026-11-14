; FIXTEST.COM — regression checks for BDOS file-system fixes
;
; Each check prints "Xn name: PASS" or "FAIL".  The files it makes are all
; FIX*.TMP on the current drive, and it removes them again.
;
;   X1  F22 refuses an existing name (A=FFh, H=8)
;   X2  F21 rewriting a 3-extent file reuses its extents (3 entries, F35=300)
;   X3  F33 past RC returns 1, a missing extent 4, a written record 0
;   X4  F34 leaves CR on the record it wrote
;   X5  F35 ignores attribute bits in the FCB
;   X6  F23 refuses an existing new name, then renames
;   X7  F19 deletes nothing when a match is read-only
;   X8  F14 refuses a drive with no DPH
;   X9  F16 after a read works on a read-only drive
;   X10 F37 clears the drive's read-only bit
;   X11 F15 opens a user-0 system file from another user, read-only
;   X12 F15 ignores junk in S2, as CP/M's Open clears it
;
; Build: sjasmplus --raw=build/fixtest.com src/test/fixtest.asm

    ORG 0100h

BDOS    EQU 0005h
FCB     EQU 005Ch
DMA     EQU 0080h

start:
    ld c, 25
    call BDOS
    ld (home), a
    ld e, 0xFF                 ; error mode: return, so a failure is seen
    ld c, 45
    call BDOS
    ld de, msg_hdr
    call pstr
    call cleanup

; --- X1: make an existing file ---------------------------------------------
    ld de, msg_x1
    call pstr
    ld hl, fn_fix
    call make
    or a
    jp nz, x1_fail
    call close
    ld hl, fn_fix
    call make                  ; again: it exists
    cp 0xFF
    jr nz, x1_fail
    ld a, h
    cp 8
    jr nz, x1_fail
    call pass
    jr x2
x1_fail:
    call fail

; --- X2: rewrite a 3-extent file in place -----------------------------------
x2:
    ld de, msg_x2
    call pstr
    ld hl, fn_fix
    call open
    cp 0xFF
    jp z, x2_fail
    ld b, 300 - 256
    call write_n256            ; 300 records: 2 full extents + 44
    call close
    ld hl, fn_fix
    call open                  ; and again, over the same file
    cp 0xFF
    jp z, x2_fail
    ld b, 300 - 256
    call write_n256
    call close
    call count_fix             ; directory entries of FIX.TMP
    cp 3
    jr nz, x2_fail
    ld hl, fn_fix
    call set_name
    ld de, FCB
    ld c, 35
    call BDOS
    ld hl, (FCB + 33)
    ld de, 300
    or a
    sbc hl, de
    jr nz, x2_fail
    call pass
    jr x3
x2_fail:
    call fail

; --- X3: random reads at and past the end -----------------------------------
x3:
    ld de, msg_x3
    call pstr
    ld hl, fn_fix
    call open
    ld hl, 299
    call rand_read
    or a
    jr nz, x3_fail             ; the last record
    ld hl, 300
    call rand_read
    cp 1
    jr nz, x3_fail             ; past RC in the last extent
    ld hl, 400
    call rand_read
    cp 4
    jr nz, x3_fail             ; no such extent
    call pass
    jr x4
x3_fail:
    call fail

; --- X4: random write keeps CR ---------------------------------------------
x4:
    ld de, msg_x4
    call pstr
    ld hl, fn_fix
    call open
    ld hl, 10
    ld (FCB + 33), hl
    xor a
    ld (FCB + 35), a
    ld de, FCB
    ld c, 34
    call BDOS
    or a
    jr nz, x4_fail
    ld a, (FCB + 32)
    cp 10
    jr nz, x4_fail
    call close
    call pass
    jr x5
x4_fail:
    call fail

; --- X5: F35 with attribute bits set in the FCB ----------------------------
x5:
    ld de, msg_x5
    call pstr
    ld hl, fn_fix
    call set_name
    ld hl, FCB + 10
    set 7, (hl)                ; t2' (SYS) in the request
    ld de, FCB
    ld c, 35
    call BDOS
    ld hl, (FCB + 33)
    ld de, 300
    or a
    sbc hl, de
    jr nz, x5_fail
    call pass
    jr x6
x5_fail:
    call fail

; --- X6: rename onto an existing name --------------------------------------
x6:
    ld de, msg_x6
    call pstr
    ld hl, fn_fix2
    call make
    call close
    call ren_fix_fix2
    cp 0xFF
    jr nz, x6_fail
    ld a, h
    cp 8
    jr nz, x6_fail
    ld hl, fn_fix2
    call delete
    call ren_fix_fix2
    or a
    jr nz, x6_fail
    ld hl, fn_fix2
    call open
    cp 0xFF
    jr z, x6_fail
    call pass
    jr x7
x6_fail:
    call fail

; --- X7: wildcard delete stops at a read-only file -------------------------
x7:
    ld de, msg_x7
    call pstr
    ld hl, fn_fixa
    call make
    call close
    ld hl, fn_fixb
    call make
    call close
    ld hl, fn_fixb
    call set_name
    ld hl, FCB + 9
    set 7, (hl)                ; t1': read-only
    ld de, FCB
    ld c, 30
    call BDOS
    ld hl, fn_fixq             ; FIX?.TMP: FIXA and FIXB... and FIX2
    call delete
    cp 0xFF
    jr nz, x7_fail
    ld hl, fn_fixa
    call open
    cp 0xFF
    jr z, x7_fail              ; FIXA must still be there
    ld hl, fn_fixb
    call set_name              ; clear R/O again
    ld de, FCB
    ld c, 30
    call BDOS
    call pass
    jr x8
x7_fail:
    call fail

; --- X8: select a drive that does not exist --------------------------------
x8:
    ld de, msg_x8
    call pstr
    ld e, 10                   ; K:
    ld c, 14
    call BDOS
    cp 0xFF
    jr nz, x8_fail
    ld c, 25
    call BDOS
    ld hl, home
    cp (hl)
    jr nz, x8_fail
    call pass
    jr x9
x8_fail:
    ld a, (home)
    ld e, a
    ld c, 14
    call BDOS
    call fail

; --- X9: close after a read on a read-only drive ---------------------------
x9:
    ld de, msg_x9
    call pstr
    ld c, 28                   ; F28: write-protect the current drive
    call BDOS
    ld hl, fn_fix2
    call open
    ld de, FCB
    ld c, 20
    call BDOS
    call close
    or a
    jr nz, x9_fail
    call pass
    jr x10
x9_fail:
    call fail

; --- X10: F37 clears the read-only bit -------------------------------------
x10:
    ld de, msg_x10
    call pstr
    ld a, (home)
    ld hl, 1
    or a
    jr z, .mask
.shift:
    add hl, hl
    dec a
    jr nz, .shift
.mask:
    push hl
    ex de, hl
    ld c, 37
    call BDOS
    ld c, 29                   ; F29: read-only vector
    call BDOS
    pop de
    ld a, l
    and e
    ld b, a
    ld a, h
    and d
    or b
    jr nz, x10_fail
    call pass
    jr x11
x10_fail:
    call fail

; --- X11: a user-0 system file from user 5 ----------------------------------
x11:
    ld de, msg_x11
    call pstr
    ld hl, fn_fixs
    call make
    ld de, FCB
    ld c, 21
    call BDOS                  ; one record
    call close
    ld hl, fn_fixs
    call set_name
    ld hl, FCB + 10
    set 7, (hl)                ; t2': SYS
    ld de, FCB
    ld c, 30
    call BDOS
    ld e, 5
    ld c, 32
    call BDOS                  ; user 5
    ld hl, fn_fixs
    call open
    cp 0xFF
    jr z, x11_fail_u           ; the system file is found
    ld a, (FCB + 9)
    rla
    jr nc, x11_fail_u          ; and opened read-only
    ld de, FCB
    ld c, 20
    call BDOS
    or a
    jr nz, x11_fail_u          ; and read
    ld hl, fn_fix2
    call open
    cp 0xFF
    jr nz, x11_fail_u          ; an ordinary user-0 file is not
    ld e, 0
    ld c, 32
    call BDOS
    call pass
    jr x12
x11_fail_u:
    ld e, 0
    ld c, 32
    call BDOS
    call fail

; --- X12: Open with junk in S2 ---------------------------------------------
x12:
    ld de, msg_x12
    call pstr
    ld hl, fn_fix2
    call set_name
    ld a, 0x55
    ld (FCB + 14), a
    ld de, FCB
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, x12_fail
    call pass
    jr finish
x12_fail:
    call fail

finish:
    call cleanup
    ld e, 0
    ld c, 45
    call BDOS
    ld de, msg_done
    call pstr
    ret

; ---------------------------------------------------------------------------

cleanup:
    ld hl, fn_fixq
    call delete
    ld hl, fn_fixs
    jp delete

; set_name — FCB = current drive, the 11-byte name at HL, the rest zero
set_name:
    push hl
    ld hl, FCB
    ld b, 36
.clr:
    ld (hl), 0
    inc hl
    djnz .clr
    pop hl
    ld de, FCB + 1
    ld bc, 11
    ldir
    ret

make:
    call set_name
    ld de, FCB
    ld c, 22
    jp BDOS

open:
    call set_name
    ld de, FCB
    ld c, 15
    jp BDOS

delete:
    call set_name
    ld de, FCB
    ld c, 19
    jp BDOS

close:
    ld de, FCB
    ld c, 16
    jp BDOS

; ren_fix_fix2 — F23 FIX.TMP -> FIX2.TMP; A, H = result
ren_fix_fix2:
    ld hl, fn_fix
    call set_name
    ld hl, fn_fix2
    ld de, FCB + 17
    ld bc, 11
    ldir
    ld de, FCB
    ld c, 23
    jp BDOS

; write_n256 — 256 + B sequential records
write_n256:
    push bc
    ld b, 0
    call write_b
    pop bc
write_b:
.loop:
    push bc
    ld de, FCB
    ld c, 21
    call BDOS
    pop bc
    djnz .loop
    ret

; rand_read — F33 record HL of the open FCB; A = result
rand_read:
    ld (FCB + 33), hl
    xor a
    ld (FCB + 35), a
    ld de, FCB
    ld c, 33
    jp BDOS

; count_fix — A = directory entries of FIX.TMP (every extent)
count_fix:
    ld hl, fn_fix
    call set_name
    ld a, '?'
    ld (FCB + 12), a
    ld (FCB + 14), a
    xor a
    ld (count), a
    ld de, FCB
    ld c, 17
.loop:
    call BDOS
    cp 0xFF
    jr z, .done
    ld hl, count
    inc (hl)
    ld de, FCB
    ld c, 18
    jr .loop
.done:
    ld a, (count)
    ret

pass:
    ld de, msg_pass
    jr pstr
fail:
    ld de, msg_fail
pstr:
    ld c, 9
    jp BDOS

home:   db 0
count:  db 0

fn_fix:  db "FIX     TMP"
fn_fix2: db "FIX2    TMP"
fn_fixa: db "FIXA    TMP"
fn_fixb: db "FIXB    TMP"
fn_fixs: db "FIXS    TMP"
fn_fixq: db "FIX?    TMP"

msg_hdr:  db "FIXTEST", 13, 10, "$"
msg_x1:   db "X1 F22 exists  : $"
msg_x2:   db "X2 F21 rewrite : $"
msg_x3:   db "X3 F33 past RC : $"
msg_x4:   db "X4 F34 keeps CR: $"
msg_x5:   db "X5 F35 attrs   : $"
msg_x6:   db "X6 F23 exists  : $"
msg_x7:   db "X7 F19 R/O     : $"
msg_x8:   db "X8 F14 no drive: $"
msg_x9:   db "X9 F16 R/O read: $"
msg_x10:  db "X10 F37 R/O    : $"
msg_x11:  db "X11 F15 user 0 : $"
msg_x12:  db "X12 F15 S2 junk: $"
msg_pass: db "PASS", 13, 10, "$"
msg_fail: db "FAIL", 13, 10, "$"
msg_done: db "Done.", 13, 10, "$"
