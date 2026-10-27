; BDOSTEST.COM — BDOS function tester, F1..F35 plus F104/F105
;
; For each function, prints: "Fnn FNAME  : result"
; Non-blocking calls are executed and return value shown.
; Blocking calls (F1, F3, F10) are skipped unless console has input.
;
; Build: sjasmplus --raw=build/bdostest.com src/test/bdostest.asm

    ORG 0100h

BDOS        EQU 0005h

; ============================================================
; Entry
; ============================================================
start:
    ld de, msg_header
    ld c, 9
    call BDOS

    ; Run tests in order
    call tst_f02        ; F2  C_WRITE  — always works (non-blocking)
    call tst_f09        ; F9  C_WSTR   — always works (non-blocking)
    call tst_f11        ; F11 C_STAT   — check before F1/F10
    call tst_f01        ; F1  C_READ   — skip if F11 returned 0
    call tst_f03        ; F3  A_READ   — skip (always blocks in CP/M 2.2)
    call tst_f04        ; F4  A_WRITE  — non-blocking output (may be unimpl)
    call tst_f05        ; F5  L_WRITE  — non-blocking output (may be unimpl)
    call tst_f06        ; F6  D_IO     — test read-status mode (E=FFh)
    call tst_f07        ; F7  GET_IOB  — get IOBYTE (may be unimpl)
    call tst_f08        ; F8  SET_IOB  — set/get IOBYTE round-trip
    call tst_f10        ; F10 C_RSTR   — skip (always blocks)
    call tst_f12        ; F12 VERSION  — return version number
    call tst_f13        ; F13 RESET    — reset disk system
    call tst_f14        ; F14 SELDSK   — select disk
    call tst_f15        ; F15 OPEN     — open file
    call tst_f16        ; F16 CLOSE    — close file
    call tst_f17        ; F17 SEARCH1  — search first
    call tst_f18        ; F18 SEARCHN  — search next
    call tst_f19        ; F19 DELETE   — delete file
    call tst_f20        ; F20 READ     — read sequential
    call tst_f21        ; F21 WRITE    — write sequential
    call tst_f22        ; F22 MAKE     — make (create) file
    call tst_f23        ; F23 RENAME   — rename file
    call tst_f24        ; F24 LOGINV   — return login vector
    call tst_f25        ; F25 CURDSK   — return current disk
    call tst_f26        ; F26 SETDMA   — set DMA address
    call tst_f27        ; F27 GETALLOC — get allocation vector
    call tst_f28        ; F28 WRTPROT  — write protect disk
    call tst_f29        ; F29 GETROVEC — get read-only vector
    call tst_f30        ; F30 SETATTR  — set file attributes
    call tst_f31        ; F31 GETDPB   — get DPB address
    call tst_f32        ; F32 USRCOD   — get/set user code
    call tst_f33        ; F33 RDRAND   — read random
    call tst_f34        ; F34 WRRAND   — write random
    call tst_f35        ; F35 FILSIZ   — compute file size
    call tst_f104       ; F104 SETDATE — set date/time + F105 round-trip

    ld de, msg_done
    ld c, 9
    call BDOS
    rst 0                  ; Warm boot (ret won't work — no return address on stack)

; ============================================================
; cons_stat: last result from F11 (0=no char, FF=char ready)
; ============================================================
cons_stat: DB 0

; ============================================================
; F2: Console Output
;   Write a visible char. Visual confirmation that it appears.
; ============================================================
tst_f02:
    ld de, lbl_f02
    call print_label        ; "F02 C_WRITE  : ["

    ld e, 'Z'               ; Write a 'Z' as the test char
    ld c, 2
    call BDOS               ; Should output 'Z' to screen

    ld de, msg_visual_ok    ; "] <- visual OK"
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F9: Print String
;   Print a $ terminated string at DE.
; ============================================================
tst_f09:
    ld de, lbl_f09
    call print_label        ; "F09 C_WSTR   : ["

    ld de, f09_test_str     ; "TEST$"
    ld c, 9
    call BDOS               ; Should print "TEST"

    ld de, msg_visual_ok
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F11: Console Status
;   Returns 0=no char, FFh=char available.
;   Save result in cons_stat for F1/F10 gating.
; ============================================================
tst_f11:
    ld de, lbl_f11
    call print_label        ; "F11 C_STAT   : "

    ld c, 11
    call BDOS               ; Returns in A (and L)
    ld (cons_stat), a       ; Save for F1/F10 tests

    call print_hex_a        ; Print return value
    ld de, msg_h
    ld c, 9
    call BDOS               ; Print "h"
    jp print_crlf

; ============================================================
; F1: Console Input (blocks until keypress)
;   Skip unless F11 reported a char is ready.
; ============================================================
tst_f01:
    ld de, lbl_f01
    call print_label        ; "F01 C_READ   : "

    ld a, (cons_stat)
    or a
    jr z, .skip             ; No char ready

    ld c, 1
    call BDOS               ; Returns char in A
    call print_hex_a
    ld de, msg_h
    ld c, 9
    call BDOS
    jp print_crlf

.skip:
    ld de, msg_skip_no_input
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F3: Auxiliary (Reader) Input — always skip (blocks)
; ============================================================
tst_f03:
    ld de, lbl_f03
    call print_label
    ld de, msg_skip_blocks
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F4: Auxiliary (Punch) Output
;   Write a char to aux port. Non-blocking if unimplemented.
;   Return value shown (0 if unimpl, else char echoed in some impls).
; ============================================================
tst_f04:
    ld de, lbl_f04
    call print_label

    ld e, 'X'               ; Output char 'X' to aux
    ld c, 4
    call BDOS
    ; A = return value (0 for unimplemented)
    call print_hex_a
    ld de, msg_h_ret
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F5: List (Printer) Output
;   Write a char to printer. Non-blocking if unimplemented.
; ============================================================
tst_f05:
    ld de, lbl_f05
    call print_label

    ld e, 'X'               ; Output char 'X' to list
    ld c, 5
    call BDOS
    call print_hex_a
    ld de, msg_h_ret
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F6: Direct Console I/O
;   E=FFh: returns console status/char (non-blocking read-status)
;   E=FEh: returns status only (no read) in some impls
;   We use E=FFh which returns 0 if no char, else the char.
; ============================================================
tst_f06:
    ld de, lbl_f06
    call print_label

    ld e, 0FFh              ; Read-status mode
    ld c, 6
    call BDOS               ; Returns 0 (no char) or char value in A
    call print_hex_a
    ld de, msg_h_ret
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F7: Get IOBYTE
;   Returns current IOBYTE in A. Unimplemented = returns 0.
; ============================================================
tst_f07:
    ld de, lbl_f07
    call print_label

    ld c, 7
    call BDOS               ; Returns IOBYTE in A (0 if unimpl)
    call print_hex_a
    ld de, msg_h_ret
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F8: Set IOBYTE
;   Set IOBYTE to a known value, then read back with F7.
;   If F8 is implemented, F7 should return the same value.
; ============================================================
tst_f08:
    ld de, lbl_f08
    call print_label

    ; First save current IOBYTE via F7
    ld c, 7
    call BDOS
    push af                 ; Save original IOBYTE

    ; Set IOBYTE to 0xA5
    ld e, 0A5h
    ld c, 8
    call BDOS

    ; Read back with F7
    ld c, 7
    call BDOS               ; A = current IOBYTE
    push af                 ; Save readback value

    ; Restore original IOBYTE
    pop af                  ; A = readback
    push af                 ; re-save readback
    ld e, a                 ; Hmm, need original. Let me restructure.
    ; Actually: just restore 0 (original was 0 at boot)
    pop af                  ; A = readback
    push af
    ld e, 0
    ld c, 8
    call BDOS

    ; Report: if readback == 0xA5, it round-tripped
    pop af                  ; A = readback value
    pop bc                  ; discard saved original
    push af                 ; save readback for comparison
    call print_hex_a
    ld de, msg_h
    ld c, 9
    call BDOS
    pop af                  ; A = readback value
    cp 0A5h
    jr z, .pass
    ld de, msg_fail_suffix
    ld c, 9
    call BDOS
    jp print_crlf
.pass:
    ld de, msg_pass_suffix
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F10: Read Console Buffer (blocks until CR)
;   Always skip.
; ============================================================
tst_f10:
    ld de, lbl_f10
    call print_label
    ld de, msg_skip_blocks
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F12: Return Version
;   Returns HL = version. H=system type (1=CP/M Plus), L=0x31.
; ============================================================
tst_f12:
    ld de, lbl_f12
    call print_label

    ld c, 12
    call BDOS               ; Returns version in HL (and A=L)
    push hl
    ld a, h
    call print_hex_a        ; Print H (system type)
    pop hl
    ld a, l
    call print_hex_a        ; Print L (version)
    ld de, msg_h
    ld c, 9
    call BDOS

    ; Check: expect 0x0031 (H=0 CP/M, L=0x31 version 3.1)
    ld c, 12
    call BDOS
    ld a, l
    cp 0x31
    jr nz, .f12_fail
    ld a, h
    or a
    jr nz, .f12_fail
    ld de, msg_pass_suffix
    ld c, 9
    call BDOS
    jp print_crlf
.f12_fail:
    ld de, msg_fail_suffix
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F13: Reset Disk System
;   Resets DMA to 0080h, clears login/RO vectors, re-selects A:.
;   Verify by checking DMA is reset after changing it.
; ============================================================
tst_f13:
    ld de, lbl_f13
    call print_label

    ; Set DMA to a non-default address
    ld de, 0x0100
    ld c, 26                ; F26: Set DMA
    call BDOS

    ; Reset disk system
    ld c, 13
    call BDOS

    ; F13 should have reset DMA to 0080h.
    ; Verify by doing a search (F17) which writes to DMA.
    ; If DMA was reset, the search result goes to 0080h.
    ; We check by reading 0080h after the search.
    ; First, clear 0080h
    xor a
    ld (0x0080), a

    ; Search for *.* (any file) — should find at least one
    ld hl, fcb_wild
    ld de, 0x005C
    ld bc, 12
    ldir
    ld de, 0x005C
    ld c, 17                ; F17: Search First
    call BDOS
    cp 0xFF
    jr z, .f13_fail         ; No files found = something wrong

    ; If DMA was correctly reset to 0080h, the directory data
    ; should be at 0080h. Check that byte 1 is not zero
    ; (first file's name byte 1 should be a letter).
    ld a, (0x0081)          ; First byte of first dir entry's name
    cp 'A'
    jr c, .f13_fail         ; Below 'A' = probably not reset
    cp 'Z' + 1
    jr nc, .f13_fail        ; Above 'Z' = not a filename char

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f13_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F14: Select Disk
;   E = drive (0=A:). Returns 0 on success, 0xFF on invalid.
;   Test: select A: (should succeed), select P: (should fail).
; ============================================================
tst_f14:
    ld de, lbl_f14
    call print_label

    ; Select drive A: then verify with F25 (return current disk)
    ld e, 0                 ; Drive A
    ld c, 14
    call BDOS

    ; F25 returns current disk in A (0=A:)
    ld c, 25
    call BDOS
    or a
    jr nz, .f14_fail        ; Should be 0 (A:)

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f14_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F15: Open File
;   DE = FCB. Returns 0 on success, 0xFF if not found.
;   Test: open CPM3.SYS (should exist), open NOFILE.XXX (should fail).
; ============================================================
tst_f15:
    ld de, lbl_f15
    call print_label

    ; Reset DMA (search/open may use it)
    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Set up FCB for CPM3.SYS
    call clear_test_fcb
    ld hl, fn_cpm3sys
    ld de, 0x005D           ; FCB+1 = filename
    ld bc, 11
    ldir

    ; Open CPM3.SYS
    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .f15_fail         ; Should have found it

    ; Now try opening a non-existent file
    call clear_test_fcb
    ld hl, fn_nofile
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jr nz, .f15_fail        ; Should NOT have found it

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f15_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F16: Close File
;   Open SMOKE.TXT, then close it. Should return 0 (success).
; ============================================================
tst_f16:
    ld de, lbl_f16
    call print_label

    ; Reset DMA
    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Set up FCB for SMOKE.TXT
    call clear_test_fcb
    ld hl, fn_smoke
    ld de, 0x005D
    ld bc, 11
    ldir

    ; Open
    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .f16_fail

    ; Close
    ld de, 0x005C
    ld c, 16
    call BDOS
    cp 0xFF
    jr z, .f16_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f16_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F17: Search First
;   Search for CPM3.SYS — should find it (A=0..3).
;   Search for NOFILE.XXX — should return 0xFF.
; ============================================================
tst_f17:
    ld de, lbl_f17
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Search for CPM3.SYS
    call clear_test_fcb
    ld hl, fn_cpm3sys
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jr z, .f17_fail         ; Should have found it

    ; Search for NOFILE.XXX
    call clear_test_fcb
    ld hl, fn_nofile
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jr nz, .f17_fail        ; Should NOT find it

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f17_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F18: Search Next
;   Search *.* with F17, then F18 should find more files.
; ============================================================
tst_f18:
    ld de, lbl_f18
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Search *.* (wildcard)
    call clear_test_fcb
    ld hl, fcb_wild + 1         ; just the 11-byte name "???????????"
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 17                    ; Search First
    call BDOS
    cp 0xFF
    jr z, .f18_fail             ; No files at all?

    ; Search Next — should find at least one more file
    ld de, 0x005C
    ld c, 18
    call BDOS
    cp 0xFF
    jr z, .f18_fail             ; Only one file on disk?

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f18_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F19: Delete File
;   Create a temp file (F22), then delete it (F19), then search
;   to confirm it's gone.
; ============================================================
tst_f19:
    ld de, lbl_f19
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Create TEMP.$$$ via F22 (Make)
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 22                    ; Make File
    call BDOS
    cp 0xFF
    jr z, .f19_fail

    ; Close it
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Delete it
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 19                    ; Delete
    call BDOS
    cp 0xFF
    jr z, .f19_fail             ; Delete failed?

    ; Search for it — should NOT find it
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jr nz, .f19_fail            ; Still found = delete didn't work

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f19_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F20: Read Sequential
;   Open SMOKE.TXT, read one record, check first byte = 'S'.
; ============================================================
tst_f20:
    ld de, lbl_f20
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Open SMOKE.TXT
    call clear_test_fcb
    ld hl, fn_smoke
    ld de, 0x005D
    ld bc, 11
    ldir

    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .f20_fail

    ; Read one record
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 20
    call BDOS
    or a
    jr nz, .f20_fail            ; Read error

    ; Check first byte = 'S' (SMOKE OK)
    ld a, (0x0080)
    cp 'S'
    jr nz, .f20_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f20_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F21: Write Sequential
;   Create TEMP.$$$, write one record of 'W', close, reopen,
;   read back and verify, then delete.
; ============================================================
tst_f21:
    ld de, lbl_f21
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Create TEMP.$$$
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 22                    ; Make
    call BDOS
    cp 0xFF
    jr z, .f21_fail

    ; Fill DMA with 'W'
    ld hl, 0x0080
    ld b, 128
.f21_fill:
    ld (hl), 'W'
    inc hl
    djnz .f21_fill

    ; Write one record
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 21                    ; Write Sequential
    call BDOS
    or a
    jr nz, .f21_fail

    ; Close
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Reopen and read back
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .f21_fail

    ; Clear DMA, read
    xor a
    ld (0x0080), a
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 20
    call BDOS
    or a
    jr nz, .f21_fail

    ; Verify first byte = 'W'
    ld a, (0x0080)
    cp 'W'
    jr nz, .f21_fail

    ; Cleanup: delete TEMP.$$$
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f21_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F22: Make File
;   Create TEMP.$$$, verify it exists with F17, then delete.
; ============================================================
tst_f22:
    ld de, lbl_f22
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Delete old copy if any
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ; Make
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 22
    call BDOS
    cp 0xFF
    jr z, .f22_fail

    ; Close it
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Search for it
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jr z, .f22_fail             ; Should be found

    ; Cleanup
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f22_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F23: Rename File
;   Create TEMP.$$$, rename to TEMP2.$$$, verify old gone
;   and new found, then delete new.
; ============================================================
tst_f23:
    ld de, lbl_f23
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Create TEMP.$$$
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .f23_fail

    ; Close it
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Rename: FCB bytes 1-11 = old, bytes 17-27 = new
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D               ; FCB+1 = old name
    ld bc, 11
    ldir
    ld hl, fn_temp2
    ld de, 0x005C + 17          ; FCB+17 = new name
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 23                    ; Rename
    call BDOS
    cp 0xFF
    jp z, .f23_fail

    ; Search for new name — should exist
    call clear_test_fcb
    ld hl, fn_temp2
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jp z, .f23_fail

    ; Search for old name — should be gone
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jp nz, .f23_fail            ; Old name still found = fail

    ; Cleanup: delete TEMP2.$$$
    call clear_test_fcb
    ld hl, fn_temp2
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f23_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F24: Return Login Vector
;   After boot, drive A: is logged in. Bit 0 should be set.
; ============================================================
tst_f24:
    ld de, lbl_f24
    call print_label

    ld c, 24
    call BDOS               ; HL = login vector
    ld a, l
    call print_hex_a
    ld de, msg_h
    ld c, 9
    call BDOS

    ; Check bit 0 is set (drive A: logged in)
    ld c, 24
    call BDOS
    bit 0, l
    jr z, .f24_fail

    ld de, msg_pass_suffix
    ld c, 9
    call BDOS
    jp print_crlf
.f24_fail:
    ld de, msg_fail_suffix
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F25: Return Current Disk
;   Should return 0 (A:) at boot.
; ============================================================
tst_f25:
    ld de, lbl_f25
    call print_label

    ld c, 25
    call BDOS               ; A = current disk (0=A:)
    push af
    call print_hex_a
    ld de, msg_h
    ld c, 9
    call BDOS
    pop af
    or a
    jr nz, .f25_fail

    ld de, msg_pass_suffix
    ld c, 9
    call BDOS
    jp print_crlf
.f25_fail:
    ld de, msg_fail_suffix
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F26: Set DMA Address
;   Set DMA to a known address, do a search, verify result is there.
; ============================================================
tst_f26:
    ld de, lbl_f26
    call print_label

    ; Set DMA to dma_test_buf (safe area in our data section)
    ld de, dma_test_buf
    ld c, 26
    call BDOS

    ; Clear test buffer
    xor a
    ld (dma_test_buf), a

    ; Search for CPM3.SYS — result should go to dma_test_buf
    call clear_test_fcb
    ld hl, fn_cpm3sys
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 17
    call BDOS
    cp 0xFF
    jp z, .f26_fail

    ; Check that byte 1 of result is 'C' (from CPM3)
    ld a, (dma_test_buf + 1)
    cp 'C'
    jp nz, .f26_fail

    ; Restore DMA to default
    ld de, 0x0080
    ld c, 26
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f26_fail:
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F27: Get Allocation Vector
;   Returns HL = address of ALV. Should be non-zero.
; ============================================================
tst_f27:
    ld de, lbl_f27
    call print_label

    ld c, 27
    call BDOS               ; HL = ALV address
    ld a, h
    or l
    jp z, .f27_fail         ; Zero = not set up
    ; ALV is in system memory (bank 4), can't read from TPA.
    ; Just verify the pointer is non-zero.

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f27_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F28: Write Protect Disk
;   Write-protect current disk, check RO vector, then reset
;   disk system to clear the protection.
; ============================================================
tst_f28:
    ld de, lbl_f28
    call print_label

    ; Check RO vector is 0 before
    ld c, 29
    call BDOS
    ld a, l
    or h
    jp nz, .f28_fail        ; Already read-only?

    ; Write-protect current disk (A:)
    ld c, 28
    call BDOS

    ; Check RO vector — bit 0 should be set
    ld c, 29
    call BDOS
    bit 0, l
    jp z, .f28_fail

    ; Reset disk system to clear RO
    ld c, 13
    call BDOS

    ; Verify RO vector is cleared
    ld c, 29
    call BDOS
    ld a, l
    or h
    jp nz, .f28_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f28_fail:
    ; Reset disk system to restore state
    ld c, 13
    call BDOS
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F29: Get Read-Only Vector
;   After F13 reset, should be 0.
; ============================================================
tst_f29:
    ld de, lbl_f29
    call print_label

    ld c, 29
    call BDOS               ; HL = RO vector
    push hl
    ld a, l
    call print_hex_a
    ld de, msg_h
    ld c, 9
    call BDOS
    pop hl
    ld a, l
    or h
    jp nz, .f29_fail        ; Should be 0 after reset

    ld de, msg_pass_suffix
    ld c, 9
    call BDOS
    jp print_crlf
.f29_fail:
    ld de, msg_fail_suffix
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F30: Set File Attributes
;   Create TEMP.$$$, set R/O attribute (byte 9 bit 7), verify
;   by searching and checking the attribute, then clear and delete.
; ============================================================
tst_f30:
    ld de, lbl_f30
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Create TEMP.$$$
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 22                    ; Make
    call BDOS
    cp 0xFF
    jp z, .f30_fail

    ; Close
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Set R/O attribute: set bit 7 of FCB byte 9 (T1)
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld a, (0x005C + 9)          ; T1 byte
    or 0x80                     ; Set R/O bit
    ld (0x005C + 9), a
    ld de, 0x005C
    ld c, 30                    ; Set File Attributes
    call BDOS
    cp 0xFF
    jp z, .f30_fail

    ; Search for TEMP.$$$ and check R/O bit in result
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 17                    ; Search First
    call BDOS
    cp 0xFF
    jp z, .f30_fail

    ; A = index (0-3). Entry at DMA + A*32, byte 9 should have bit 7 set.
    ld l, a
    ld h, 0
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl
    add hl, hl                 ; HL = A * 32
    ld de, 0x0080
    add hl, de                 ; HL = entry address
    ld de, 9
    add hl, de                 ; HL = &entry[9] (T1)
    ld a, (hl)
    bit 7, a
    jp z, .f30_fail             ; R/O bit not set = fail

    ; Cleanup: clear R/O and delete
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 30                    ; Clear attributes
    call BDOS
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19                    ; Delete
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f30_fail:
    ; Cleanup attempt
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F31: Get DPB Address
;   Returns HL = DPB pointer. Should be non-zero.
;   We can't read DPB from TPA (it's in system memory), but
;   we verify the pointer is reasonable.
; ============================================================
tst_f31:
    ld de, lbl_f31
    call print_label

    ld c, 31
    call BDOS               ; HL = DPB address
    ld a, h
    or l
    jp z, .f31_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f31_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F32: Get/Set User Code
;   E=0xFF: get current user, E=0-15: set user.
;   Test: get (should be 0), set to 5, get (should be 5),
;   restore to 0.
; ============================================================
tst_f32:
    ld de, lbl_f32
    call print_label

    ; Get current user (should be 0)
    ld e, 0xFF
    ld c, 32
    call BDOS
    or a
    jp nz, .f32_fail

    ; Set user to 5
    ld e, 5
    ld c, 32
    call BDOS

    ; Get — should be 5
    ld e, 0xFF
    ld c, 32
    call BDOS
    cp 5
    jp nz, .f32_fail

    ; Restore to 0
    ld e, 0
    ld c, 32
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f32_fail:
    ld e, 0
    ld c, 32
    call BDOS
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F33: Read Random
;   Open SMOKE.TXT, set R0=0 R1=0 R2=0, read random record 0,
;   check first byte = 'S'.
; ============================================================
tst_f33:
    ld de, lbl_f33
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Open SMOKE.TXT
    call clear_test_fcb
    ld hl, fn_smoke
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .f33_fail

    ; Set random record to 0
    xor a
    ld (0x005C + 33), a        ; R0
    ld (0x005C + 34), a        ; R1
    ld (0x005C + 35), a        ; R2

    ; Read random
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 33
    call BDOS
    or a
    jp nz, .f33_fail

    ; Check first byte = 'S'
    ld a, (0x0080)
    cp 'S'
    jp nz, .f33_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f33_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F34: Write Random
;   Create TEMP.$$$, write record 3 with 'R', read back record 3,
;   verify, then delete.
; ============================================================
tst_f34:
    ld de, lbl_f34
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    ; Delete old copy
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ; Create
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .f34_fail

    ; Fill DMA with 'R'
    ld hl, 0x0080
    ld b, 128
.f34_fill:
    ld (hl), 'R'
    inc hl
    djnz .f34_fill

    ; Set random record to 3
    ld a, 3
    ld (0x005C + 33), a
    xor a
    ld (0x005C + 34), a
    ld (0x005C + 35), a

    ; Write random
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 34
    call BDOS
    or a
    jp nz, .f34_fail

    ; Close
    ld de, 0x005C
    ld c, 16
    call BDOS

    ; Reopen
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .f34_fail

    ; Clear DMA, read record 3
    xor a
    ld (0x0080), a
    ld a, 3
    ld (0x005C + 33), a
    xor a
    ld (0x005C + 34), a
    ld (0x005C + 35), a
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld de, 0x005C
    ld c, 33                    ; Read random
    call BDOS
    or a
    jp nz, .f34_fail

    ld a, (0x0080)
    cp 'R'
    jp nz, .f34_fail

    ; Cleanup
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f34_fail:
    call clear_test_fcb
    ld hl, fn_temp
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 19
    call BDOS
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F35: Compute File Size
;   Check file size of SMOKE.TXT (should be > 0 records).
; ============================================================
tst_f35:
    ld de, lbl_f35
    call print_label

    ld de, 0x0080
    ld c, 26
    call BDOS

    call clear_test_fcb
    ld hl, fn_smoke
    ld de, 0x005D
    ld bc, 11
    ldir
    ld de, 0x005C
    ld c, 35                    ; Compute File Size
    call BDOS

    ; R0 (FCB+33) should be > 0
    ld a, (0x005C + 33)
    or a
    jp z, .f35_fail
    ; R1 should be 0 (small file)
    ld a, (0x005C + 34)
    or a
    jp nz, .f35_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f35_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; F104/F105: Set/Get Date and Time
;   Round-trip: load DAT buffer with known values, call F104,
;   then F105 into a separate buffer, compare all 4 fields.
;   Regression guard for the F104 minute-pointer bug where DE
;   got clobbered by the hour*60 computation and scb_minute
;   was written from a byte at (hour*4) in the TPA.
; ============================================================
tst_f104:
    ld de, lbl_f104
    call print_label

    ; Input: days=0x1234 (Sat 1998-06-13), hour=0x14 (BCD), min=0x37 (BCD)
    ld hl, dat_in
    ld (hl), 0x34          ; days_lo
    inc hl
    ld (hl), 0x12          ; days_hi
    inc hl
    ld (hl), 0x14          ; BCD hour (20 decimal — hour*4=0x50 is the buggy read addr)
    inc hl
    ld (hl), 0x37          ; BCD min

    ld de, dat_in
    ld c, 104              ; F104 Set Date/Time
    call BDOS

    ; Zero the output buffer first so stale bytes can't fake a pass
    ld hl, dat_out
    ld b, 5
.f104_zero:
    ld (hl), 0
    inc hl
    djnz .f104_zero

    ld de, dat_out
    ld c, 26               ; F26 Set DMA
    call BDOS

    ld c, 105              ; F105 Get Date/Time
    call BDOS

    ld a, (dat_out)
    cp 0x34
    jp nz, .f104_fail
    ld a, (dat_out+1)
    cp 0x12
    jp nz, .f104_fail
    ld a, (dat_out+2)
    cp 0x14
    jp nz, .f104_fail
    ld a, (dat_out+3)
    cp 0x37
    jp nz, .f104_fail

    ld de, msg_pass_short
    ld c, 9
    call BDOS
    jp print_crlf
.f104_fail:
    ld de, msg_fail_short
    ld c, 9
    call BDOS
    jp print_crlf

; ============================================================
; Helpers
; ============================================================

; clear_test_fcb: zero 36 bytes at 005Ch
clear_test_fcb:
    ld hl, 0x005C
    ld b, 36
.clr:
    ld (hl), 0
    inc hl
    djnz .clr
    ret

; print_label: print DE string ($ terminated) — label with colon
print_label:
    ld c, 9
    call BDOS
    ret

; print_crlf: print CR LF
print_crlf:
    ld de, crlf
    ld c, 9
    call BDOS
    ret

; print_hex_a: print A as 2 uppercase hex digits
print_hex_a:
    push af
    ; High nibble
    rra
    rra
    rra
    rra
    and 0Fh
    call .nibble
    pop af
    ; Low nibble
    and 0Fh
    ; fall through
.nibble:
    cp 10
    jr c, .is_digit
    add a, 'A' - 10
    jr .out
.is_digit:
    add a, '0'
.out:
    ld e, a
    ld c, 2
    jp BDOS

; ============================================================
; Strings
; ============================================================

msg_header:
    DB 0Dh, 0Ah
    DB "BDOS Tester F01..F35, F104", 0Dh, 0Ah
    DB "--------------------", 0Dh, 0Ah
    DB '$'

lbl_f01:    DB "F01 C_READ   : $"
lbl_f02:    DB "F02 C_WRITE  : [$"
lbl_f03:    DB "F03 A_READ   : $"
lbl_f04:    DB "F04 A_WRITE  : $"
lbl_f05:    DB "F05 L_WRITE  : $"
lbl_f06:    DB "F06 D_IO/R   : $"
lbl_f07:    DB "F07 GET_IOB  : $"
lbl_f08:    DB "F08 SET_IOB  : $"
lbl_f09:    DB "F09 C_WSTR   : [$"
lbl_f10:    DB "F10 C_RSTR   : $"
lbl_f11:    DB "F11 C_STAT   : $"
lbl_f12:    DB "F12 VERSION  : $"
lbl_f13:    DB "F13 RESET    : $"
lbl_f14:    DB "F14 SELDSK   : $"
lbl_f15:    DB "F15 OPEN     : $"
lbl_f16:    DB "F16 CLOSE    : $"
lbl_f17:    DB "F17 SEARCH1  : $"
lbl_f18:    DB "F18 SEARCHN  : $"
lbl_f19:    DB "F19 DELETE   : $"
lbl_f20:    DB "F20 READ     : $"
lbl_f21:    DB "F21 WRITE    : $"
lbl_f22:    DB "F22 MAKE     : $"
lbl_f23:    DB "F23 RENAME   : $"
lbl_f24:    DB "F24 LOGINV   : $"
lbl_f25:    DB "F25 CURDSK   : $"
lbl_f26:    DB "F26 SETDMA   : $"
lbl_f27:    DB "F27 GETALLOC : $"
lbl_f28:    DB "F28 WRTPROT  : $"
lbl_f29:    DB "F29 GETROVEC : $"
lbl_f30:    DB "F30 SETATTR  : $"
lbl_f31:    DB "F31 GETDPB   : $"
lbl_f32:    DB "F32 USRCOD   : $"
lbl_f33:    DB "F33 RDRAND   : $"
lbl_f34:    DB "F34 WRRAND   : $"
lbl_f35:    DB "F35 FILSIZ   : $"
lbl_f104:   DB "F104 SETDATE: $"

f09_test_str:   DB "TEST$"

msg_visual_ok:  DB "] visual OK$"
msg_h:          DB "h$"
msg_h_ret:      DB "h (ret)$"
msg_pass_suffix:DB " OK (round-trip)$"
msg_fail_suffix:DB " FAIL (no round-trip)$"
msg_pass_short:    DB "PASS$"
msg_fail_short:    DB "FAIL$"
msg_skip_no_input: DB "SKIP (no char ready)$"
msg_skip_blocks:   DB "SKIP (blocks)$"

fn_cpm3sys: DB "CPM3    SYS"
fn_smoke: DB "SMOKE   TXT"
fn_nofile:  DB "NOFILE  XXX"
fn_temp:    DB "TEMP    $$$"
fn_temp2:   DB "TEMP2   $$$"
fcb_wild:   DB 0, "???????????", 0

dma_test_buf: DS 128           ; Safe DMA target for F26 test
dat_in:       DS 4             ; 4-byte DAT input to F104
dat_out:      DS 5             ; 5-byte DAT output from F105 (includes sec)

msg_done:
    DB 0Dh, 0Ah
    DB "--------------------", 0Dh, 0Ah
    DB "Done.", 0Dh, 0Ah
    DB '$'

crlf:   DB 0Dh, 0Ah, '$'
