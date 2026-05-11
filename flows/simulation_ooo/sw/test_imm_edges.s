## test_imm_edges.s — negative immediates + shift edge cases.

    .section .text.startup, "ax"
    .globl _start
_start:
    ## SRA on negative: -8 >> 1 = -4
    li      x1, -8
    srai    x2, x1, 1
    li      x3, -4
    bne     x2, x3, fail

    ## SRA on positive: 8 >> 1 = 4
    li      x1, 8
    srai    x2, x1, 1
    li      x3, 4
    bne     x2, x3, fail

    ## SLL by 0 is identity
    li      x1, 0xdead
    slli    x2, x1, 0
    bne     x2, x1, fail

    ## SLL by 31
    li      x1, 1
    slli    x2, x1, 31
    li      x3, 0x80000000
    bne     x2, x3, fail

    ## SRL by 31 on -1 → 1
    li      x1, -1
    srli    x2, x1, 31
    li      x3, 1
    bne     x2, x3, fail

    ## ADDI with negative imm
    li      x1, 100
    addi    x2, x1, -50
    li      x3, 50
    bne     x2, x3, fail

    ## SLTI signed: -1 < 0 → 1
    li      x1, -1
    slti    x2, x1, 0
    li      x3, 1
    bne     x2, x3, fail

    ## SLTIU unsigned: 0xffffffff < 0 → 0
    sltiu   x4, x1, 0
    li      x5, 0
    bne     x4, x5, fail

    ## SLTU: 1 < 0xffffffff → 1 (unsigned)
    li      x6, 1
    sltu    x7, x6, x1
    li      x8, 1
    bne     x7, x8, fail

    ## SLT: 1 < -1 signed → 0
    slt     x9, x6, x1
    li      x12, 0
    bne     x9, x12, fail

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
