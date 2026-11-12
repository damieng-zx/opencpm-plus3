; ==========================================================================
; CHAINTST.COM - BDOS F47 chain-to-program
; ==========================================================================
; F47 sets the CCP's chain flag and warm-boots; the CCP then runs the
; command tail already sitting at 0080h instead of prompting.  Here the
; chain target is SCREEN with no argument, so the next output is
; "Mode: N columns".  Nothing after the F47 call may run.
;
; Build: sjasmplus --raw=build/chaintst.com src/test/chaintest.asm

    ORG 0100h

BDOS    equ 0005h
F_PSTR  equ 9
F_CHAIN equ 47
DMA     equ 0080h

start:
    ld de, msg_start
    ld c, F_PSTR
    call BDOS

    ; The command line for the next program at 0080h.  Our CCP reads it as a
    ; length byte and text (the CP/M 2.2 command tail); Locomotive's reads a
    ; NUL-terminated string from 0080h itself.  One layout serves both: the
    ; first byte is a space, which is a blank to skip for the string reader
    ; and a length of 32 for ours (it parses up to the NUL).
    ld hl, chain_cmd
    ld de, DMA
    ld bc, chain_len
    ldir

    ld e, 0                     ; F47 flag: chain as a typed command would
    ld c, F_CHAIN
    call BDOS                   ; never returns: warm boot + CCP chain

    ; Getting here means F47 behaved as a normal returning call.
    ld de, msg_returned
    ld c, F_PSTR
    call BDOS
    rst 0

msg_start:    db "CHAINTEST START", 0Dh, 0Ah, '$'
msg_returned:  db "CHAINTEST RETURNED", 0Dh, 0Ah, '$'

chain_cmd:  db " SCREEN", 0
chain_len   equ $ - chain_cmd
