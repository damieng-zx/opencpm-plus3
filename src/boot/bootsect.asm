; ==========================================================================
; CP/M 3.1 Boot Sector for ZX Spectrum +3
; ==========================================================================
;
; +3 boot mechanism (DOS_BOOT):
;   1. ROM reads logical sector 0, sums all 512 bytes mod 256
;   2. If sum = 3, copies to 0xFE00 in bank 3, sets all-RAM 4-5-6-3
;   3. Jumps to 0xFE10
;
; On entry:
;   PC=0xFE10, bank3 at C000-FFFF, DI not yet done, stack unknown
;   Memory: bank4(0000) bank5(4000) bank6(8000) bank3(C000)
;
; Loads stage 2 from track 0 (sectors 2-9) and track 1 (sectors 1-9)
; into 0x0000 (bank 4), giving up to 17 × 512 = 8704 bytes.
;
; uPD765A ports: 0x2FFD (status read), 0x3FFD (data read/write)
; Port 1FFD: bit0=special, bits2:1=mode, bit3=motor
;
; ==========================================================================

    device zxspectrum128
    org 0xFE00

PORT_1FFD   equ 0x1FFD
PORT_FDC_ST equ 0x2FFD
PORT_FDC_DT equ 0x3FFD
PORT_ULA    equ 0xFE
PAGING_M2   equ 0x0D           ; Special mode 2 + motor on

; --- Header (16 bytes, not executed) ---
disk_spec:
    db 0, 0, 40, 9, 2, 1, 3, 2     ; byte 5 = 1 reserved track
    db 0x2A, 0x52, 0, 0, 0, 0, 0, 0

    assert $ == 0xFE10

; --- Entry ---
boot_entry:
    ; lint-exempt: 1ffd  ; no shadow exists yet - this code boots the machine
    di
    ld sp, 0xFE00

    ; Motor on
    ld bc, PORT_1FFD
    ld a, PAGING_M2
    out (c), a

    ; Yellow border = loading
    ld a, 6
    out (PORT_ULA), a

    ; Load destination
    ld hl, 0x0000

    ; Read track 0, sectors 2-9 (8 sectors = 4KB)
    ; This loads the stage 2 loader which will find and load
    ; the system file (CPM3.SYS) from the CP/M directory.
    xor a                      ; Track 0
    ld d, 2                    ; Start sector 2
    ld e, 9                    ; End sector 9
    call fdc_read_track

    ; Jump to loader
    jp 0x0000


; ==========================================================================
; fdc_read_track — Read sectors from one track
;   In:  A = track number, D = first sector, E = last sector
;        HL = destination (updated on return)
;   Out: HL advanced past loaded data
;   Clobbers: AF, BC, DE
; ==========================================================================
fdc_read_track:
    push de                    ; Save D=first, E=last

    ; Send READ DATA command
    push af                    ; Save track number
    ld a, 0x46                 ; READ DATA (MFM)
    call fdc_send
    xor a                      ; HD=0, US=0
    call fdc_send
    pop af                     ; Track
    call fdc_send
    xor a                      ; H=0
    call fdc_send
    pop de                     ; Restore D=first sector, E=last
    ld a, d                    ; R = first sector
    call fdc_send
    ld a, 2                    ; N=2 (512 bytes/sector)
    call fdc_send
    ld a, e                    ; EOT = last sector
    call fdc_send
    ld a, 0x2A                 ; GPL
    call fdc_send
    ld a, 0xFF                 ; DTL
    call fdc_send

    ; Execution phase — read bytes into (HL)
    ld bc, PORT_FDC_ST
.exec:
    in a, (c)
    jp p, .exec
    bit 5, a                   ; EXM?
    jr z, .result
    ld b, high PORT_FDC_DT
    in a, (c)
    ld (hl), a
    inc hl
    ld b, high PORT_FDC_ST
    jr .exec

.result:
    ld d, 7
.res_lp:
    ld bc, PORT_FDC_ST
.res_w:
    in a, (c)
    jp p, .res_w
    ld bc, PORT_FDC_DT
    in a, (c)
    dec d
    jr nz, .res_lp
    ret


; ==========================================================================
; fdc_send — Send byte in A to FDC
;   In:  A = byte
;   Out: nothing
;   Clobbers: AF, BC
;   Preserves: HL, DE
; ==========================================================================
fdc_send:
    push af
    ld bc, PORT_FDC_ST
.wait:
    in a, (c)
    jp p, .wait
    pop af
    ld bc, PORT_FDC_DT
    out (c), a
    ret


; --- Pad and checksum ---
    assert $ <= 0xFFFF

    block 0xFFFF - $, 0

checksum_adjust:
    db 0
