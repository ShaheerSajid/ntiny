## test_dep_chain.s — long RAW chain to stress write→read visibility.
##
## Each ADD reads the previous instruction's destination, so the
## arch-regfile write at posedge N+1 must be visible to the
## combinational decode read at cycle N+2.

    .section .text.startup, "ax"
    .globl _start
_start:
    li      x1, 1
    add     x2, x1, x1          # 2
    add     x3, x2, x1          # 3
    add     x4, x3, x1          # 4
    add     x5, x4, x1          # 5
    add     x6, x5, x1          # 6
    add     x7, x6, x1          # 7
    add     x8, x7, x1          # 8
    add     x9, x8, x1          # 9
    add     x10, x9, x1         # 10

    li      x11, 10
    bne     x10, x11, fail

    ## chain through a memory round-trip
    li      x12, 0x300
    sw      x10, 0(x12)
    lw      x13, 0(x12)
    bne     x13, x11, fail
    addi    x16, x13, 5         # use right after LOAD
    li      x17, 15
    bne     x16, x17, fail

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
