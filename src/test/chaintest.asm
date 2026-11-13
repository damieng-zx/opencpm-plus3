; ==========================================================================
; CHAINTST.COM - BDOS F47 chain-to-program
; ==========================================================================
; F47 sets the CCP's chain flag and warm-boots; the CCP then runs the
; command tail already sitting at 0080h instead of prompting.  Here the
; chain target is SCREEN with no argument, so the next output is
; "Mode: N columns".  Nothing after the F47 call may run.  "CHAINTST ARG"
; chains to a command that has an argument ("DIR SMOKE.TXT") instead, so the
; line is also checked past its first word.
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

    ; The command line for the next program at 0080h: a null-terminated
    ; string, with no length byte, as CP/M 3 defines it.
    ld hl, chain_cmd
    ld bc, chain_len
    ld a, (0080h)               ; our own command tail: any argument at all
    or a
    jr z, .copy
    ld hl, chain_arg
    ld bc, chain_arg_len
.copy:
    ld de, DMA
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

chain_cmd:  db "SCREEN", 0
chain_len   equ $ - chain_cmd
chain_arg:  db "DIR SMOKE.TXT", 0
chain_arg_len equ $ - chain_arg
