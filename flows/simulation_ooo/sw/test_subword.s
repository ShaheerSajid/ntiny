## test_subword.s — SB/SH + LB/LBU/LH/LHU.
##
## Exercises memunit's byte-enable + replicated wdata for sub-word
## stores, and the sign/zero-extend path on sub-word loads.

    .section .text.startup, "ax"
    .globl _start
_start:
    li      x10, 0x200          # data base

    ## ── SB lane test: 4 bytes 0x12 0x34 0x56 0x78 ─────────────
    li      x11, 0x12
    sb      x11, 0(x10)
    li      x11, 0x34
    sb      x11, 1(x10)
    li      x11, 0x56
    sb      x11, 2(x10)
    li      x11, 0x78
    sb      x11, 3(x10)

    lw      x12, 0(x10)
    li      x13, 0x78563412
    bne     x12, x13, fail

    ## ── LB positive: sign-extend a 0x78 byte ─────────────────
    lb      x14, 3(x10)
    li      x15, 0x78
    bne     x14, x15, fail

    ## ── LB negative: 0xff → 0xffffffff ───────────────────────
    li      x11, 0xff
    sb      x11, 4(x10)
    lb      x16, 4(x10)
    li      x17, -1
    bne     x16, x17, fail

    ## ── LBU on same byte: 0xff (no sign extend) ──────────────
    lbu     x18, 4(x10)
    li      x19, 0xff
    bne     x18, x19, fail

    ## ── SH + LH (signed): 0x8001 → 0xffff8001 ────────────────
    li      x11, 0x8001
    sh      x11, 8(x10)
    lh      x20, 8(x10)
    li      x21, 0xffff8001
    bne     x20, x21, fail

    ## ── LHU: zero-extend → 0x00008001 ────────────────────────
    lhu     x22, 8(x10)
    li      x23, 0x8001
    bne     x22, x23, fail

    ## ── SH at unaligned-from-word offset 10 (addr[1]==1) ─────
    li      x11, 0xbeef
    sh      x11, 10(x10)
    lhu     x24, 10(x10)
    li      x25, 0xbeef
    bne     x24, x25, fail

    li      x14, 0xdeadbeef
    li      x15, 0x0000F000
    sw      x14, 0(x15)
    j       halt

fail:
    li      x14, 0xbad
    li      x15, 0x0000F000
    sw      x14, 0(x15)

halt:
    j       halt
