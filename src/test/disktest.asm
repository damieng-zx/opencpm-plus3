; DISKTEST.COM — BDOS disk function tester
;
; Tests disk BDOS functions in isolation. Each test prints PASS or FAIL.
;
; Build: sjasmplus --raw=build/disktest.com src/test/disktest.asm

    ORG 0100h

BDOS    EQU 0005h
FCB1    EQU 005Ch
DMA     EQU 0080h

start:
    ; Print header
    ld de, msg_hdr
    ld c, 9
    call BDOS

    ; Parse optional test number from command tail (0x0080)
    ; If no arg or 0, run all tests. Otherwise run only that test.
    ld a, (0x0080)             ; Tail length
    or a
    jp z, .run_all             ; No args → run all

    ; Skip leading spaces in tail
    ld hl, 0x0081
.skip_sp:
    ld a, (hl)
    cp ' '
    jr nz, .got_digit
    inc hl
    jr .skip_sp

.got_digit:
    ; Parse 1-2 digit decimal number
    sub '0'
    cp 10
    jp nc, .run_all            ; Not a digit → run all
    ld b, a                    ; B = first digit
    inc hl
    ld a, (hl)
    sub '0'
    cp 10
    jr nc, .single_digit       ; Only one digit
    ; Two digits: B*10 + A
    ld c, a                    ; C = second digit
    ld a, b
    add a, a                   ; ×2
    add a, a                   ; ×4
    add a, b                   ; ×5
    add a, a                   ; ×10
    add a, c                   ; + second digit
    ld b, a
.single_digit:
    ; B = test number (1-22)
    ld a, b
    or a
    jp z, .run_all
    cp 23
    jp nc, .run_all            ; Out of range → run all
    ; Jump to the specific test via table
    dec a                      ; 0-based index
    add a, a                   ; ×2 (word offsets)
    ld l, a
    ld h, 0
    ld de, .test_table
    add hl, de
    ld a, (hl)
    inc hl
    ld h, (hl)
    ld l, a                    ; HL = test address
    jp (hl)

.test_table:
    dw .run_t1, .run_t2, .run_t3, .run_t4, .run_t5, .run_t6
    dw .run_t7, .run_t8, .run_t9, .run_t10, .run_t11, .run_t12, .run_t13
    dw .run_t14, .run_t15, .run_t16, .run_t17
    dw .run_t18, .run_t19, .run_t20, .run_t21, .run_t22

    ; Single-test runners: run the test then exit
.run_t1:  call test1
    jp done
.run_t2:  call test2
    jp done
.run_t3:  call test3
    jp done
.run_t4:  call test4
    jp done
.run_t5:  call test5
    jp done
.run_t6:  call test6
    jp done
.run_t7:  call test7
    jp done
.run_t8:  call test8
    jp done
.run_t9:  call test9
    jp done
.run_t10: call test10
    jp done
.run_t11: call test11
    jp done
.run_t12: call test12
    jp done
.run_t13: call test13
    jp done
.run_t14: call test14
    jp done
.run_t15: call test15
    jp done
.run_t16: call test16
    jp done
.run_t17: call test17
    jp done
.run_t18: call test18
    jp done
.run_t19: call test19
    jp done
.run_t20: call test20
    jp done
.run_t21: call test21
    jp done
.run_t22: call test22
    jp done

.run_all:
    call test1
    call test2
    call test3
    call test4
    call test5
    call test6
    call test7
    call test8
    call test9
    call test10
    call test11
    call test12
    call test13
    call test14
    call test15
    call test16
    call test17
    call test18
    call test19
    call test20
    call test21
    call test22
    jp done

test1:
    ; === T1: Search for CPM3.SYS ===
    ld de, msg_t1
    ld c, 9
    call BDOS

    ; Set up FCB with CPM3.SYS
    call clear_fcb
    ld hl, fn_cpm3
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Reset DMA
    ld de, DMA
    ld c, 26
    call BDOS

    ; Search first
    ld de, FCB1
    ld c, 17
    call BDOS

    ; A = 0-3 if found, 0xFF if not
    cp 0xFF
    jr z, .t1_fail
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t1_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test2:
    ; === T2: Open PROFILE.SUB and read ===
    ld de, msg_t2
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_prof
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Open
    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .t2_fail

    ; Reset DMA and read
    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 20
    call BDOS
    or a
    jr nz, .t2_fail

    ; Check first byte = 'S' (SETDEF...)
    ld a, (DMA)
    cp 'S'
    jr nz, .t2_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t2_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test3:
    ; === T3: Make, write, close TEST.TMP ===
    ld de, msg_t3
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Delete first (ignore error)
    ld de, FCB1
    ld c, 19
    call BDOS

    ; Make
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jr z, .t3_fail

    ; Fill DMA with 'X'
    ld hl, DMA
    ld b, 128
.t3_fill:
    ld (hl), 'X'
    inc hl
    djnz .t3_fill

    ; Set DMA
    ld de, DMA
    ld c, 26
    call BDOS

    ; Write
    ld de, FCB1
    ld c, 21
    call BDOS
    or a
    jr nz, .t3_fail

    ; Close
    ld de, FCB1
    ld c, 16
    call BDOS
    cp 0xFF
    jr z, .t3_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t3_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test4:
    ; === T4: Reopen TEST.TMP and verify ===
    ld de, msg_t4
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Open
    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jr z, .t4_fail

    ; Clear DMA
    ld hl, DMA
    ld b, 128
.t4_clr:
    ld (hl), 0
    inc hl
    djnz .t4_clr

    ; Set DMA and read
    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 20
    call BDOS
    or a
    jr nz, .t4_fail

    ; Check data
    ld a, (DMA)
    cp 'X'
    jr nz, .t4_fail
    ld a, (DMA + 127)
    cp 'X'
    jr nz, .t4_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t4_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test5:
    ; === T5: Delete TEST.TMP ===
    ld de, msg_t5
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 19
    call BDOS
    cp 0xFF
    jr z, .t5_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t5_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test6:
    ; === T6: Verify originals still searchable ===
    ld de, msg_t6
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_cpm3
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, DMA
    ld c, 26
    call BDOS

    ld de, FCB1
    ld c, 17
    call BDOS
    cp 0xFF
    jr z, .t6_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t6_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test7:
    ; === T7: Make file, write 3 records, close, check file size ===
    ld de, msg_t7
    ld c, 9
    call BDOS

    ; Create TEST.TMP with 3 records
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Delete old copy (ignore error)
    ld de, FCB1
    ld c, 19
    call BDOS

    ; Make
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .t7_fail

    ; Fill DMA
    ld hl, DMA
    ld b, 128
.t7_f:
    ld (hl), 'Z'
    inc hl
    djnz .t7_f

    ; Write 3 records
    ld de, DMA
    ld c, 26
    call BDOS

    ld b, 3
.t7_wr:
    push bc
    ld de, FCB1
    ld c, 21
    call BDOS
    pop bc
    or a
    jp nz, .t7_fail
    djnz .t7_wr

    ; Close
    ld de, FCB1
    ld c, 16
    call BDOS
    cp 0xFF
    jp z, .t7_fail

    ; Now check file size: F35 sets R0/R1/R2 in FCB to record count
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 35               ; F35: Compute File Size
    call BDOS

    ; R0 (FCB+33) should be 3, R1 (FCB+34) should be 0
    ld a, (FCB1 + 33)      ; R0 = low byte of record count
    cp 3
    jp nz, .t7_fail
    ld a, (FCB1 + 34)      ; R1 = high byte
    or a
    jp nz, .t7_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t7_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test8:
    ; === T8: Rename TEST.TMP → TEST2.TMP, verify findable ===
    ld de, msg_t8
    ld c, 9
    call BDOS

    ; F23 rename: FCB byte 0 = drive, bytes 1-11 = old name,
    ;             bytes 17-27 = new name (16 bytes into FCB)
    call clear_fcb
    ; Old name at FCB+1
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ; New name at FCB+17
    ld hl, fn_test2
    ld de, FCB1 + 17
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 23               ; F23: Rename
    call BDOS
    cp 0xFF
    jr z, .t8_fail

    ; Search for new name — should be found
    call clear_fcb
    ld hl, fn_test2
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 17
    call BDOS
    cp 0xFF
    jr z, .t8_fail

    ; Search for old name — should NOT be found
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 17
    call BDOS
    cp 0xFF
    jr nz, .t8_fail         ; Old name should be gone

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t8_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test9:
    ; === T9: Clean up — delete TEST2.TMP ===
    ld de, msg_t9
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test2
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 19
    call BDOS
    cp 0xFF
    jr z, .t9_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t9_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test10:
    ; === T10: F46 Get Free Space (documented stub) ===
    ; F46 is deliberately deferred (P2 follow-up): it returns A=0 and HL=0
    ; and leaves the DMA buffer untouched.  Assert that contract so a
    ; future implementation has to update this test deliberately.
    ld de, msg_t10
    ld c, 9
    call BDOS

    ld de, DMA
    ld c, 26
    call BDOS

    ; Put a sentinel in DMA[0..2] so a clobber would be visible
    ld hl, DMA
    ld (hl), 0xAA
    inc hl
    ld (hl), 0xAA
    inc hl
    ld (hl), 0xAA

    ld de, 0                ; Drive A
    ld c, 46                ; F46: Get Disk Free Space (stub)
    call BDOS

    or a
    jr nz, .t10_fail        ; Stub must report success
    ld a, h
    or l
    jr nz, .t10_fail        ; HL must be 0

    ld a, (DMA)
    cp 0xAA
    jr nz, .t10_fail
    ld a, (DMA + 1)
    cp 0xAA
    jr nz, .t10_fail
    ld a, (DMA + 2)
    cp 0xAA
    jr nz, .t10_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t10_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test11:
    ; === T11: Random write + random read ===
    ; Create TEST.TMP, write record 5 with 'A', record 0 with 'B',
    ; then random-read record 5 (expect 'A'), record 0 (expect 'B')
    ld de, msg_t11
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Delete old (ignore error)
    ld de, FCB1
    ld c, 19
    call BDOS

    ; Make
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .t11_fail

    ; --- Write record 5 with 'A' ---
    ; Fill DMA with 'A'
    ld hl, DMA
    ld b, 128
.t11_fa:
    ld (hl), 'A'
    inc hl
    djnz .t11_fa

    ld de, DMA
    ld c, 26
    call BDOS

    ; Set random record to 5: FCB[33]=5, FCB[34]=0, FCB[35]=0
    ld a, 5
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ; F34: Write Random
    ld de, FCB1
    ld c, 34
    call BDOS
    or a
    jp nz, .t11_fail

    ; --- Write record 0 with 'B' ---
    ld hl, DMA
    ld b, 128
.t11_fb:
    ld (hl), 'B'
    inc hl
    djnz .t11_fb

    ld de, DMA
    ld c, 26
    call BDOS

    ; Set random record to 0
    xor a
    ld (FCB1 + 33), a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ld de, FCB1
    ld c, 34
    call BDOS
    or a
    jp nz, .t11_fail

    ; --- Write record 200 with 'C' (second extent, EX=1 CR=72) ---
    ld hl, DMA
    ld b, 128
.t11_fc:
    ld (hl), 'C'
    inc hl
    djnz .t11_fc

    ld de, DMA
    ld c, 26
    call BDOS

    ; R = 200 = EX 1, CR 72.  This must create the EX=1 extent; the old
    ; code wrote into the EX=0 allocation map and lost the record.
    ld a, 200
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ld de, FCB1
    ld c, 34                ; F34: Write Random
    call BDOS
    or a
    jp nz, .t11_fail

    ; Close
    ld de, FCB1
    ld c, 16
    call BDOS

    ; --- Reopen and read back ---
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .t11_fail

    ; Clear DMA
    ld hl, DMA
    ld b, 128
.t11_clr1:
    ld (hl), 0
    inc hl
    djnz .t11_clr1

    ; Set DMA
    ld de, DMA
    ld c, 26
    call BDOS

    ; Read record 5: expect 'A'
    ld a, 5
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ld de, FCB1
    ld c, 33                ; F33: Read Random
    call BDOS
    or a
    jp nz, .t11_fail

    ld a, (DMA)
    cp 'A'
    jp nz, .t11_fail
    ld a, (DMA + 127)
    cp 'A'
    jp nz, .t11_fail

    ; Clear DMA again
    ld hl, DMA
    ld b, 128
.t11_clr2:
    ld (hl), 0
    inc hl
    djnz .t11_clr2

    ld de, DMA
    ld c, 26
    call BDOS

    ; Read record 0: expect 'B'
    xor a
    ld (FCB1 + 33), a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ld de, FCB1
    ld c, 33
    call BDOS
    or a
    jp nz, .t11_fail

    ld a, (DMA)
    cp 'B'
    jp nz, .t11_fail

    ; Clear DMA and read record 200: expect 'C'
    ld hl, DMA
    ld b, 128
.t11_clr3:
    ld (hl), 0
    inc hl
    djnz .t11_clr3

    ld de, DMA
    ld c, 26
    call BDOS

    ld a, 200
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a

    ld de, FCB1
    ld c, 33                ; F33: Read Random
    call BDOS
    or a
    jp nz, .t11_fail

    ld a, (DMA)
    cp 'C'
    jp nz, .t11_fail
    ld a, (DMA + 127)
    cp 'C'
    jp nz, .t11_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t11_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test12:
    ; === T12: Multi-extent write + read (136 records = 17K, 2 extents) ===
    ld de, msg_t12
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir

    ; Delete old (ignore error)
    ld de, FCB1
    ld c, 19
    call BDOS

    ; Make
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .t12_fail

    ; Write 136 records sequentially
    ; Each record: byte 0 = record number (0-135), rest = 0
    ld de, DMA
    ld c, 26
    call BDOS

    ld a, 0
    ld (rec_counter), a

.t12_wr_loop:
    ; Fill DMA: byte 0 = record number, bytes 1-127 = record number
    ld a, (rec_counter)
    ld hl, DMA
    ld b, 128
.t12_fill:
    ld (hl), a
    inc hl
    djnz .t12_fill

    ; Write sequential
    ld de, FCB1
    ld c, 21
    call BDOS
    or a
    jp nz, .t12_fail

    ; Increment and check
    ld a, (rec_counter)
    inc a
    ld (rec_counter), a
    cp 136                  ; 136 records = 17K (2 extents)
    jr c, .t12_wr_loop

    ; Close
    ld de, FCB1
    ld c, 16
    call BDOS
    cp 0xFF
    jp z, .t12_fail

    ; Check file size — should be 136 records
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 35                ; F35: Compute File Size
    call BDOS
    ld a, (FCB1 + 33)      ; R0
    cp 136
    jp nz, .t12_fail
    ld a, (FCB1 + 34)      ; R1
    or a
    jp nz, .t12_fail

    ; Reopen and read back, verify each record
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .t12_fail

    ld de, DMA
    ld c, 26
    call BDOS

    ld a, 0
    ld (rec_counter), a

.t12_rd_loop:
    ; Clear DMA
    ld hl, DMA
    ld b, 128
    ld a, 0xFF
.t12_clr:
    ld (hl), a
    inc hl
    djnz .t12_clr

    ; Read sequential
    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 20
    call BDOS
    or a
    jp nz, .t12_fail

    ; Verify: DMA[0] should equal record number
    ld a, (rec_counter)
    ld b, a
    ld a, (DMA)
    cp b
    jp nz, .t12_fail

    ; Also check DMA[127]
    ld a, (rec_counter)
    ld b, a
    ld a, (DMA + 127)
    cp b
    jp nz, .t12_fail

    ld a, (rec_counter)
    inc a
    ld (rec_counter), a
    cp 136
    jr c, .t12_rd_loop

    ; --- Attribute-bit extent test -------------------------------------
    ; Close, set R/O on all extents, reopen and read across EX=0/EX=1.
    ; The FCB then carries bit 7 in its type bytes; F20/F33 must mask it.
    ld de, FCB1
    ld c, 16
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld a, (FCB1 + 9)
    or 0x80
    ld (FCB1 + 9), a
    ld de, FCB1
    ld c, 30                ; F30: Set File Attributes (R/O)
    call BDOS
    cp 0xFF
    jp z, .t12_fail

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 15                ; F15: Open
    call BDOS
    cp 0xFF
    jp z, .t12_fail

    ld de, DMA
    ld c, 26
    call BDOS
    xor a
    ld (rec_counter), a
.t12_attr_loop:
    ld de, FCB1
    ld c, 20                ; F20: crosses EX=1 at record 128
    call BDOS
    or a
    jp nz, .t12_fail
    ld a, (rec_counter)
    ld b, a
    ld a, (DMA)
    cp b
    jp nz, .t12_fail
    ld a, (rec_counter)
    inc a
    ld (rec_counter), a
    cp 136
    jr c, .t12_attr_loop

    ; Random read record 135 with the R/O FCB (F33 path)
    ld a, 135
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a
    ld de, FCB1
    ld c, 33                ; F33: Read Random
    call BDOS
    or a
    jp nz, .t12_fail
    ld a, (DMA)
    cp 135
    jp nz, .t12_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t12_fail:
    ; Print which record failed
    ld de, msg_rec
    ld c, 9
    call BDOS
    ld a, (rec_counter)
    call print_hex_a
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test13:
    ; === T13: Cleanup ===
    ld de, msg_t13
    ld c, 9
    call BDOS

    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 19
    call BDOS
    cp 0xFF
    jr z, .t13_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t13_fail:
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test14:
    ; === T14: F31 tracks the drive selected by F14 ===
    ; F31 used to return cached_dpb for the last drive used by a file
    ; operation, so A: and C: reported the same DPB.
    ld de, msg_t14
    ld c, 9
    call BDOS

    ; Save current drive
    ld c, 25
    call BDOS
    ld (save_drive14), a

    ; F14(A:), F31 -> DPB A
    xor a
    ld e, a
    ld c, 14
    call BDOS
    ld c, 31
    call BDOS
    ld (dpb_a14), hl

    ; F14(C:), F31 -> DPB C
    ld a, 2
    ld e, a
    ld c, 14
    call BDOS
    ld c, 31
    call BDOS
    ld (dpb_c14), hl

    ; C: must exist and differ from A:
    ld a, h
    or l
    jr z, .t14_fail
    ld de, (dpb_a14)
    or a
    sbc hl, de
    jr z, .t14_fail

    ld a, (save_drive14)
    ld e, a
    ld c, 14
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t14_fail:
    ld a, (save_drive14)
    ld e, a
    ld c, 14
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test15:
    ; === T15: F28 write-protect is enforced; F45 return mode ===
    ld de, msg_t15
    ld c, 9
    call BDOS

    ; F45 = 1: return errors instead of aborting
    ld e, 1
    ld c, 45
    call BDOS

    ; F28: write-protect the current drive (A:)
    ld c, 28
    call BDOS

    ; F22 Make must fail with 0xFF
    call clear_fcb
    ld hl, fn_ro
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jr nz, .t15_fail

    ; Clear the R/O bit and restore error mode
    ld c, 13
    call BDOS
    ld e, 0
    ld c, 45
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t15_fail:
    ld c, 13
    call BDOS
    ld e, 0
    ld c, 45
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test16:
    ; === T16: SCB writes do not reset unrelated BDOS state ===
    ld de, msg_t16
    ld c, 9
    call BDOS

    ; F45 = 1: return errors
    ld e, 1
    ld c, 45
    call BDOS

    ; User 3 and DMA 0x0200 (both intentionally left stale in the SCB)
    ld e, 3
    ld c, 32
    call BDOS
    ld de, 0x0200
    ld c, 26
    call BDOS

    ; F49 set tempdrv (offset 0x34, op 0xFE, value 0)
    ld hl, scb_pb
    ld (hl), 0x34
    inc hl
    ld (hl), 0xFE
    inc hl
    ld (hl), 0
    ld de, scb_pb
    ld c, 49
    call BDOS

    ; User must still be 3
    ld e, 0xFF
    ld c, 32
    call BDOS
    cp 3
    jr nz, .t16_fail

    ; DMA must still be 0x0200: F49 get offset 0x3C
    ld hl, scb_pb
    ld (hl), 0x3C
    inc hl
    ld (hl), 0
    ld de, scb_pb
    ld c, 49
    call BDOS
    ld a, h
    cp 2
    jr nz, .t16_fail
    ld a, l
    or a
    jr nz, .t16_fail

    ; Restore user 0, DMA 0x0080, error mode 0
    ld e, 0
    ld c, 32
    call BDOS
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld e, 0
    ld c, 45
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t16_fail:
    ld e, 0
    ld c, 32
    call BDOS
    ld de, 0x0080
    ld c, 26
    call BDOS
    ld e, 0
    ld c, 45
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test17:
    ; === T17: F30 respects the current user area ===
    ld de, msg_t17
    ld c, 9
    call BDOS

    ; Create TEST.TMP in user 0
    ld e, 0
    ld c, 32
    call BDOS
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 19
    call BDOS                ; delete stale (ignore)
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 22
    call BDOS
    cp 0xFF
    jp z, .t17_fail

    ; Switch to user 1 and try to set R/O on the user-0 file
    ld e, 1
    ld c, 32
    call BDOS
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld a, (FCB1 + 9)
    or 0x80
    ld (FCB1 + 9), a
    ld de, FCB1
    ld c, 30
    call BDOS
    cp 0xFF
    jr nz, .t17_fail         ; must not find it in user 1

    ; Back to user 0: the attribute must still be clear
    ld e, 0
    ld c, 32
    call BDOS
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .t17_fail
    ld a, (FCB1 + 9)
    and 0x80
    jr nz, .t17_fail

    ; Close and delete
    ld de, FCB1
    ld c, 16
    call BDOS
    ld de, FCB1
    ld c, 19
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t17_fail:
    ld e, 0
    ld c, 32
    call BDOS
    call clear_fcb
    ld hl, fn_test
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ld de, FCB1
    ld c, 19
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test18:
    ; === T18: extended BDOS info functions ===
    ld de, msg_t18
    ld c, 9
    call BDOS

    ; Safe restore values for the failure path
    ld hl, 0x0003
    ld (save_mode), hl
    xor a
    ld (save_order), a
    ld hl, default_path
    ld de, path_save
    ld bc, 4
    ldir

    ; F36: R = EX*128 + CR
    call clear_fcb
    ld a, 10
    ld (FCB1 + 32), a
    ld de, FCB1
    ld c, 36
    call BDOS
    ld a, (FCB1 + 33)
    cp 10
    jp nz, .t18_fail
    ld a, (FCB1 + 34)
    or a
    jp nz, .t18_fail

    ; F48 flush buffers -> A=0
    ld c, 48
    call BDOS
    or a
    jp nz, .t18_fail

    ; F49 get conwidth (offset 0x1A) -> 50
    ld hl, scb_pb
    ld (hl), 0x1A
    inc hl
    ld (hl), 0
    ld de, scb_pb
    ld c, 49
    call BDOS
    cp 50
    jp nz, .t18_fail

    ; F49 invalid offset 0x63 -> A=0xFF
    ld hl, scb_pb
    ld (hl), 0x63
    inc hl
    ld (hl), 0
    ld de, scb_pb
    ld c, 49
    call BDOS
    cp 0xFF
    jp nz, .t18_fail

    ; F109 get/set/restore console mode
    ld de, 0xFFFF
    ld c, 109
    call BDOS
    ld (save_mode), hl
    ld de, 1
    ld c, 109
    call BDOS
    ld de, 0xFFFF
    ld c, 109
    call BDOS
    ld a, l
    cp 1
    jp nz, .t18_fail
    ld de, (save_mode)
    ld c, 109
    call BDOS

    ; F110 get default '$'
    ld de, 0xFFFF
    ld c, 110
    call BDOS
    cp '$'
    jp nz, .t18_fail

    ; F120/F121 SETDEF order
    ld c, 120
    call BDOS
    ld (save_order), a
    ld e, 1
    ld c, 121
    call BDOS
    ld c, 120
    call BDOS
    cp 1
    jp nz, .t18_fail
    ld a, (save_order)
    ld e, a
    ld c, 121
    call BDOS

    ; F122/F123 SETDEF search path
    ld de, path_save
    ld c, 122
    call BDOS
    ld hl, path_set
    ld de, path_buf
    ld bc, 4
    ldir
    ld de, path_buf
    ld c, 123
    call BDOS
    ld de, path_get
    ld c, 122
    call BDOS
    ld a, (path_get)
    cp 1
    jp nz, .t18_fail
    ld hl, path_save
    ld de, path_buf
    ld bc, 4
    ldir
    ld de, path_buf
    ld c, 123
    call BDOS

    ; F50 direct BIOS call: DEVTBL (fn 20) -> HL != 0
    ld hl, f50_pb
    ld b, 8
    xor a
.t18_clr:
    ld (hl), a
    inc hl
    djnz .t18_clr
    ld a, 20
    ld (f50_pb), a
    ld de, f50_pb
    ld c, 50
    call BDOS
    ld a, h
    or l
    jp z, .t18_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t18_fail:
    ld de, (save_mode)
    ld c, 109
    call BDOS
    ld a, (save_order)
    ld e, a
    ld c, 121
    call BDOS
    ld hl, path_save
    ld de, path_buf
    ld bc, 4
    ldir
    ld de, path_buf
    ld c, 123
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test19:
    ; === T19: file functions reject an invalid drive ===
    ld de, msg_t19
    ld c, 9
    call BDOS

    ; D:CPM3.SYS (FCB drive code 4; 1=A, 2=B, 3=C, 4=D)
    ld hl, fn_cpm3
    call set_fcb
    ld a, 4
    ld (FCB1), a

    ld a, 1
    ld (t19_step), a
    ld c, 15                 ; F15 open
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 2
    ld (t19_step), a
    ld c, 17                 ; F17 search first
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 3
    ld (t19_step), a
    ld c, 16                 ; F16 close
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 4
    ld (t19_step), a
    ld c, 19                 ; F19 delete
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 5
    ld (t19_step), a
    ld c, 21                 ; F21 write
    call BDOS
    or a
    jp z, .t19_fail

    ld de, FCB1
    ld a, 6
    ld (t19_step), a
    ld c, 22                 ; F22 make
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 7
    ld (t19_step), a
    ld c, 23                 ; F23 rename
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 8
    ld (t19_step), a
    ld c, 30                 ; F30 set attributes
    call BDOS
    cp 0xFF
    jp nz, .t19_fail

    ld de, FCB1
    ld a, 9
    ld (t19_step), a
    ld c, 33                 ; F33 read random
    call BDOS
    or a
    jp z, .t19_fail

    ld de, FCB1
    ld a, 10
    ld (t19_step), a
    ld c, 34                 ; F34 write random
    call BDOS
    or a
    jp z, .t19_fail

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t19_fail:
    ld de, msg_step
    ld c, 9
    call BDOS
    ld a, (t19_step)
    call print_hex_a
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test20:
    ; === T20: directory full ===
    ld de, msg_t20
    ld c, 9
    call BDOS

    ; Remove leftovers from an interrupted run
    ld hl, fn_fill_all
    call delete_name

    xor a
    ld (fill_i), a
    ld (fill_count), a

.t20_loop:
    ld hl, fn_fill
    call set_fcb
    ld a, (fill_i)
    ld b, a
    rrca
    rrca
    rrca
    rrca
    and 0x0F
    call nibble_to_ascii
    ld (FCB1 + 5), a
    ld a, b
    and 0x0F
    call nibble_to_ascii
    ld (FCB1 + 6), a

    ld de, FCB1
    ld c, 22                 ; F22 make
    call BDOS
    cp 0xFF
    jp z, .t20_full

    ld a, (fill_count)
    inc a
    ld (fill_count), a
    ld a, (fill_i)
    inc a
    ld (fill_i), a
    cp 64
    jp c, .t20_loop
    jp .t20_fail

.t20_full:
    ld a, (fill_count)
    or a
    jp z, .t20_fail

    ; Delete every FILLxx.TMP and confirm the wildcard search is empty
    ld hl, fn_fill_all
    call delete_name
    ld hl, fn_fill_all
    call set_fcb
    ld de, FCB1
    ld c, 17
    call BDOS
    cp 0xFF
    jp nz, .t20_fail

    ; The original directory must still be usable
    ld hl, fn_cpm3
    call set_fcb
    ld de, FCB1
    ld c, 15
    call BDOS
    cp 0xFF
    jp z, .t20_fail
    ld de, FCB1
    ld c, 16
    call BDOS

    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t20_fail:
    ld hl, fn_fill_all
    call delete_name
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test21:
    ; === T21: C: ramdisk file I/O ===
    ld de, msg_t21
    ld c, 9
    call BDOS

    ld c, 25
    call BDOS
    ld (save_drive), a

    ld e, 2
    ld c, 14                 ; select C:
    call BDOS
    ld c, 31                 ; F31: is C: present?
    call BDOS
    ld a, h
    or l
    jp z, .t21_skip

    ld hl, fn_ram
    call delete_name

    ld hl, fn_ram
    call set_fcb
    ld de, FCB1
    ld c, 22                 ; make
    call BDOS
    cp 0xFF
    jp z, .t21_fail

    ld hl, DMA
    ld b, 128
.t21_fill:
    ld (hl), 'R'
    inc hl
    djnz .t21_fill

    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 21                 ; write record 0
    call BDOS
    or a
    jp nz, .t21_fail
    ld de, FCB1
    ld c, 16                 ; close
    call BDOS

    ld hl, fn_ram
    call set_fcb
    ld de, FCB1
    ld c, 15                 ; reopen
    call BDOS
    cp 0xFF
    jp z, .t21_fail

    ld hl, DMA
    ld b, 128
.t21_clr:
    ld (hl), 0
    inc hl
    djnz .t21_clr
    ld de, DMA
    ld c, 26
    call BDOS
    ld de, FCB1
    ld c, 20                 ; read record 0
    call BDOS
    or a
    jp nz, .t21_fail
    ld a, (DMA)
    cp 'R'
    jp nz, .t21_fail
    ld a, (DMA + 127)
    cp 'R'
    jp nz, .t21_fail

    ld de, FCB1
    ld c, 19                 ; delete
    call BDOS

    ld a, (save_drive)
    ld e, a
    ld c, 14
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t21_skip:
    ld a, (save_drive)
    ld e, a
    ld c, 14
    call BDOS
    ld de, msg_skip
    ld c, 9
    call BDOS
    ret

.t21_fail:
    ; Best-effort cleanup on C:, then restore the saved drive
    ld e, 2
    ld c, 14
    call BDOS
    ld hl, fn_ram
    call delete_name
    ld a, (save_drive)
    ld e, a
    ld c, 14
    call BDOS
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

test22:
    ; === T22: F40 random write ===
    ld de, msg_t22
    ld c, 9
    call BDOS

    ld hl, fn_test3
    call delete_name

    ld hl, fn_test3
    call set_fcb
    ld de, FCB1
    ld c, 22                 ; make
    call BDOS
    cp 0xFF
    jp z, .t22_fail

    ld hl, DMA
    ld b, 128
.t22_fill:
    ld (hl), 'Q'
    inc hl
    djnz .t22_fill
    ld de, DMA
    ld c, 26
    call BDOS

    ld a, 3
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a
    ld de, FCB1
    ld c, 40                 ; write random with zero fill
    call BDOS
    or a
    jp nz, .t22_fail

    ld de, FCB1
    ld c, 16                 ; close
    call BDOS

    ld hl, fn_test3
    call set_fcb
    ld de, FCB1
    ld c, 15                 ; reopen
    call BDOS
    cp 0xFF
    jp z, .t22_fail

    ld hl, DMA
    ld b, 128
.t22_clr:
    ld (hl), 0
    inc hl
    djnz .t22_clr
    ld de, DMA
    ld c, 26
    call BDOS

    ld a, 3
    ld (FCB1 + 33), a
    xor a
    ld (FCB1 + 34), a
    ld (FCB1 + 35), a
    ld de, FCB1
    ld c, 33                 ; read random
    call BDOS
    or a
    jp nz, .t22_fail
    ld a, (DMA)
    cp 'Q'
    jp nz, .t22_fail
    ld a, (DMA + 127)
    cp 'Q'
    jp nz, .t22_fail

    ld de, FCB1
    ld c, 19                 ; delete
    call BDOS
    ld de, msg_pass
    ld c, 9
    call BDOS
    ret

.t22_fail:
    ld hl, fn_test3
    call delete_name
    ld de, msg_fail
    ld c, 9
    call BDOS
    ret

; --- shared helpers for T18-T22 ---
; set_fcb: HL = 11-byte name; clear FCB1 and copy the name to FCB1+1.
set_fcb:
    push hl
    call clear_fcb
    pop hl
    ld de, FCB1 + 1
    ld bc, 11
    ldir
    ret

; delete_name: HL = 11-byte name; delete the file on the current drive.
delete_name:
    call set_fcb
    ld de, FCB1
    ld c, 19
    call BDOS
    ret

; nibble_to_ascii: A = 0..15 -> '0'..'9','A'..'F'.
nibble_to_ascii:
    add a, '0'
    cp '9' + 1
    ret c
    add a, 7
    ret

done:
    ld de, msg_end
    ld c, 9
    call BDOS
    rst 0

; print_hex_a — Print A as 2 hex digits
print_hex_a:
    push af
    rrca
    rrca
    rrca
    rrca
    call .nib
    pop af
.nib:
    and 0x0F
    add a, '0'
    cp '9'+1
    jr c, .ok
    add a, 7
.ok:
    ld e, a
    ld c, 2
    call BDOS
    ret

; Clear 36-byte FCB at FCB1
clear_fcb:
    ld hl, FCB1
    ld b, 36
.cl:
    ld (hl), 0
    inc hl
    djnz .cl
    ret

; Filenames (8+3 padded with spaces)
rec_counter: db 0
save_drive14: db 0
dpb_a14: dw 0
dpb_c14: dw 0
scb_pb: ds 4
save_mode: dw 0x0003
save_order: db 0
save_drive: db 0
t19_step: db 0
fill_i: db 0
fill_count: db 0
path_save: ds 4
path_set: db 1, 0, 0, 0
path_get: ds 4
path_buf: ds 4
f50_pb: ds 8
default_path: db 0xFF, 0, 0, 0

fn_cpm3:  db "CPM3    SYS"
fn_prof:  db "PROFILE SUB"
fn_test:  db "TEST    TMP"
fn_test2: db "TEST2   TMP"
fn_ro:    db "TEST    RO "
fn_test3: db "TEST3   TMP"
fn_fill:  db "FILL00  TMP"
fn_fill_all: db "FILL????TMP"
fn_ram:   db "RAMTEST TMP"

msg_hdr:  db "DISKTEST v6", 13, 10, "$"
msg_pass: db " PASS", 13, 10, "$"
msg_fail: db " FAIL", 13, 10, "$"
msg_end:  db "All tests done.", 13, 10, "$"
msg_t1:   db "T1 Search$"
msg_t2:   db "T2 Open+Read$"
msg_t3:   db "T3 Make+Write+Close$"
msg_t4:   db "T4 Reopen+Verify$"
msg_t5:   db "T5 Delete$"
msg_t6:   db "T6 Originals intact$"
msg_t7:   db "T7 FileSize (3 recs)$"
msg_t8:   db "T8 Rename$"
msg_t9:   db "T9 Cleanup$"
msg_t10:  db "T10 F46 stub$"
msg_free: db " free=0x$"
msg_t11:  db "T11 RandomR/W$"
msg_t12:  db "T12 MultiExtent 17K$"
msg_rec:  db " rec=$"
msg_t13:  db "T13 Cleanup$"
msg_t14:  db "T14 F31 tracks drive$"
msg_t15:  db "T15 R/O protect+F45$"
msg_t16:  db "T16 SCB write isolation$"
msg_t17:  db "T17 F30 user area$"
msg_t18:  db "T18 Extended BDOS$"
msg_t19:  db "T19 Invalid drives$"
msg_t20:  db "T20 Directory full$"
msg_t21:  db "T21 C: ramdisk$"
msg_t22:  db "T22 F40 random write$"
msg_step: db " step=0x$"
msg_skip: db " SKIP", 13, 10, "$"
