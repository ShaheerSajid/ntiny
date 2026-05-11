## test_basic.s — smallest end-to-end M0 sanity:
##   * ALU R-type + I-type
##   * conditional branch (taken + not-taken)
##   * forward jump
##   * SW + LW
##   * write 0xdeadbeef to HALT_ADDR (0x0000F000) → end of sim
##
## Expected: halt_value = 0xdeadbeef, final pc settles in `halt:` loop.

    .section .text.startup, "ax"
    .globl _start
_start:
    li    x1, 5
    li    x2, 7
    add   x3, x1, x2          # x3 = 12
    addi  x4, x3, 100          # x4 = 112
    sub   x5, x4, x1           # x5 = 107

    li    x10, 0x100
    sw    x5, 0(x10)           # mem[0x100] = 107
    lw    x11, 0(x10)          # x11 = 107

    bne   x11, x5, fail        # 107 == 107 → not taken
    beq   x11, x1, fail        # 107 != 5   → not taken

    li    x12, 1
    li    x13, 1
    beq   x12, x13, ok         # taken — skip fail

fail:
    li    x14, 0xbad
    li    x15, 0x0000F000
    sw    x14, 0(x15)
    j     halt

ok:
    li    x14, 0xdeadbeef
    li    x15, 0x0000F000
    sw    x14, 0(x15)          # halt with success token

halt:
    j     halt
