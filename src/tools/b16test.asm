; B16TEST.COM — 16-bit block-number file I/O test (drive B:)
;
; Runs against a PCW DS/DD 720K image mounted on B: (2K blocks, DSM=351,
; eight 16-bit block numbers per extent).  Exercises F22/F21/F15/F16/F33/
; F35/F46/F99 and the 16-bit allocation map:
;
;   1. free space (F46) read
;   2. create a file and write 20 records (two 2K blocks)
;   3. file size (F35) is 20 records, and free space dropped by 32 records
;   4. read back the first/last record
;   5. truncate (F99) to 5 records: F35 = 5, one block freed (+16 records)
;   6. delete: free space returns to the starting value
;
; Prints "B16 PASS" or "B16 FAIL: <step>".
;
; Build: sjasmplus --raw=build/b16test.com src/tools/b16test.asm

    org 0x0100

BDOS    equ 0x0005
FCB     equ 0x005C
DMA     equ 0x1000
DRIVE_B equ 2               ; FCB drive code for B:

start:
    ld de, DMA
    ld c, 26                ; set DMA
    call BDOS

    ; --- start from a clean file -------------------------------------
    ld hl, fcb_test
    call set_fcb
    ld de, FCB
    ld c, 19                ; delete (ignore result)
    call BDOS

    ; --- 1. free space before ----------------------------------------
    call free_get
    jp c, fail_free
    ld (free_before), hl

    ; --- 2. create and write 20 records ------------------------------
    ld hl, fcb_test
    call set_fcb
    ld de, FCB
    ld c, 22                ; make
    call BDOS
    cp 0xFF
    jp z, fail_make

    ld hl, DMA
    ld b, 128
.fill:
    ld (hl), 0x5A
    inc hl
    djnz .fill

    ld b, 20
.wr_loop:
    push bc
    ld de, FCB
    ld c, 21                ; write sequential
    call BDOS
    pop bc
    or a
    jp nz, fail_write
    djnz .wr_loop

    ld de, FCB
    ld c, 16                ; close
    call BDOS

    ; --- 3. reopen, size and free space ------------------------------
    ld de, FCB
    ld c, 15                ; open
    call BDOS
    cp 0xFF
    jp z, fail_open

    ld de, FCB
    ld c, 35                ; compute file size
    call BDOS
    ld a, (FCB + 33)
    cp 20                  ; 20 records = 0x0014
    jp nz, fail_size
    ld a, (FCB + 34)
    or a
    jp nz, fail_size
    ld a, (FCB + 35)
    or a
    jp nz, fail_size

    call free_get
    jp c, fail_free
    ld de, (free_before)
    ld a, h
    cp d
    jr nz, .fg_lo
    ld a, l
    cp e
    jr nz, .fg_lo
    jp fail_free_delta
.fg_lo:
    ; expect before - 32 (two 2K blocks = 32 records)
    ld a, e
    sub 32
    ld e, a
    ld a, d
    sbc a, 0
    ld d, a
    ld a, h
    cp d
    jp nz, fail_free_delta
    ld a, l
    cp e
    jp nz, fail_free_delta

    ; --- 4. read back records 0 and 19 -------------------------------
    xor a
    call read_rec
    jp nz, fail_read
    ld a, (DMA)
    cp 0x5A
    jp nz, fail_read
    ld a, 19
    call read_rec
    jp nz, fail_read
    ld a, (DMA)
    cp 0x5A
    jp nz, fail_read

    ; --- 5. truncate to 5 records ------------------------------------
    ld hl, 5
    call truncate
    jp nz, fail_trunc

    ld de, FCB
    ld c, 35
    call BDOS
    ld a, (FCB + 33)
    cp 5                   ; 5 records
    jp nz, fail_tsize
    ld a, (FCB + 34)
    or a
    jp nz, fail_tsize
    ld a, (FCB + 35)
    or a
    jp nz, fail_tsize

    call free_get
    jp c, fail_free
    ld de, (free_before)
    ld a, e
    sub 16                  ; one 2K block still allocated
    ld e, a
    ld a, d
    sbc a, 0
    ld d, a
    ld a, h
    cp d
    jp nz, fail_free_delta
    ld a, l
    cp e
    jp nz, fail_free_delta

    ld a, 4
    call read_rec
    jp nz, fail_read
    ld a, (DMA)
    cp 0x5A
    jp nz, fail_read
    ld a, 100               ; well past the new EOF: unwritten block
    call read_rec
    cp 1
    jp nz, fail_read

    ; --- 6. delete and check the space is back -----------------------
    ld de, FCB
    ld c, 19
    call BDOS

    call free_get
    jp c, fail_free
    ld de, (free_before)
    ld a, h
    cp d
    jp nz, fail_free_delta
    ld a, l
    cp e
    jp nz, fail_free_delta

    ld de, msg_pass
    ld c, 9
    call BDOS
    rst 0

; --- helpers ---------------------------------------------------------

; set_fcb — copy the 36-byte FCB template at HL to the default FCB.
set_fcb:
    ld de, FCB
    ld bc, 36
    ldir
    ret

; free_get — B: free records (128-byte units) in HL; carry = error.
free_get:
    ld e, DRIVE_B - 1       ; F46 takes 0=A:, 1=B:, ...
    ld c, 46
    call BDOS
    or a
    jr nz, .bad
    ld hl, (DMA)
    or a                    ; clear carry
    ret
.bad:
    scf
    ret

; read_rec — read random record A of the open FCB; Z = success.
read_rec:
    ld (FCB + 33), a
    xor a
    ld (FCB + 34), a
    ld (FCB + 35), a
    ld de, FCB
    ld c, 33
    call BDOS
    or a
    ret

; truncate — F99 to HL records; Z = success.
truncate:
    ld a, l
    ld (FCB + 33), a
    ld a, h
    ld (FCB + 34), a
    xor a
    ld (FCB + 35), a
    ld de, FCB
    ld c, 99
    call BDOS
    or a
    ret

; --- failure paths ---------------------------------------------------
fail_free:
    ld hl, m_free
    jr fail
fail_free_delta:
    ld hl, m_fdelta
    jr fail
fail_make:
    ld hl, m_make
    jr fail
fail_write:
    ld hl, m_write
    jr fail
fail_open:
    ld hl, m_open
    jr fail
fail_size:
    ld hl, m_size
    jr fail
fail_read:
    ld hl, m_read
    jr fail
fail_trunc:
    ld hl, m_trunc
    jr fail
fail_tsize:
    ld hl, m_tsize

fail:
    push hl
    ld de, m_fail
    ld c, 9
    call BDOS
    pop de
    ld c, 9
    call BDOS
    rst 0

m_fail:   db "B16 FAIL: $"
m_free:   db "free space$"
m_fdelta: db "free delta$"
m_make:   db "make$"
m_write:  db "write$"
m_open:   db "open$"
m_size:   db "size$"
m_read:   db "read$"
m_trunc:  db "truncate$"
m_tsize:  db "truncated size$"
msg_pass: db "B16 PASS", 13, 10, "$"

free_before: dw 0

fcb_test:
    db DRIVE_B
    db "B16A    TMP"
    ds 24, 0
