## test_loop.s — backward branch (loop) sums 1..10 = 55.
##
## Exercises: backward branch redirect (BLT), accumulator dep chain.

    .section .text.startup, "ax"
    .globl _start
_start:
    li      x10, 0              # accumulator
    li      x11, 1              # counter
    li      x12, 11             # bound (loop while < 11)
loop:
    add     x10, x10, x11
    addi    x11, x11, 1
    blt     x11, x12, loop      # taken backward until x11 == 11

    li      x13, 55
    bne     x10, x13, fail

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
