; ==========================================================================
; CHAINTEST.COM - BDOS F47 chain-to-program
; ==========================================================================
; F47 sets the CCP's chain flag and warm-boots; the CCP then runs the
; command tail already sitting at 0080h instead of prompting.  Here the
; chain target is SCREEN with no argument, so the next output is
; "Mode: N columns".  Nothing after the F47 call may run.
;
; Build: sjasmplus --raw=build/chaintest.com src/test/chaintest.asm

    ORG 0100h

BDOS    equ 0005h
F_PSTR  equ 9
F_CHAIN equ 47
DMA     equ 0080h

start:
    ld de, msg_start
    ld c, F_PSTR
    call BDOS

    ; Command tail for the next command: length byte + "SCREEN".
    ld hl, chain_cmd
    ld de, DMA
    ld bc, chain_len
    ldir

    ld c, F_CHAIN
    call BDOS                   ; never returns: warm boot + CCP chain

    ; Getting here means F47 behaved as a normal returning call.
    ld de, msg_returned
    ld c, F_PSTR
    call BDOS
    rst 0

msg_start:    db "CHAINTEST START", 0Dh, 0Ah, '$'
msg_returned:  db "CHAINTEST RETURNED", 0Dh, 0Ah, '$'

chain_cmd:  db 6, "SCREEN"
chain_len   equ $ - chain_cmd
