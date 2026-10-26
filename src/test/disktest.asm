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
    ; B = test number (1-14)
    ld a, b
    or a
    jp z, .run_all
    cp 16
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
    dw .run_t14, .run_t15

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
    ; === T10: Free space (F46) ===
    ; F46: DE = drive (0=A), returns free 128-byte records in DMA[0..2] (24-bit LE)
    ld de, msg_t10
    ld c, 9
    call BDOS

    ld de, DMA
    ld c, 26
    call BDOS

    ; Clear DMA first
    ld hl, DMA
    ld (hl), 0
    inc hl
    ld (hl), 0
    inc hl
    ld (hl), 0

    ld de, 0                ; Drive A
    ld c, 46                ; F46: Get Disk Free Space
    call BDOS

    ; Result at DMA[0..2]: 24-bit record count (LE)
    ; For a 180K disk with ~99K free = ~99*8 = ~792 records
    ; Should be non-zero
    ld a, (DMA)
    ld b, a
    ld a, (DMA + 1)
    or b
    ld b, a
    ld a, (DMA + 2)
    or b
    jr z, .t10_fail         ; Zero free space = fail

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

fn_cpm3:  db "CPM3    SYS"
fn_prof:  db "PROFILE SUB"
fn_test:  db "TEST    TMP"
fn_test2: db "TEST2   TMP"
fn_ro:    db "TEST    RO "

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
msg_t10:  db "T10 FreeSpace$"
msg_free: db " free=0x$"
msg_t11:  db "T11 RandomR/W$"
msg_t12:  db "T12 MultiExtent 17K$"
msg_rec:  db " rec=$"
msg_t13:  db "T13 Cleanup$"
msg_t14:  db "T14 F31 tracks drive$"
msg_t15:  db "T15 R/O protect+F45$"
