## test_jalr.s — function calls via JAL + return via JALR (`ret`).
##
## Two leaf functions, then a second call. Verifies that:
##   - JAL pushes pc+4 into ra
##   - JALR uses (rs1+imm)&~1 as target and pc+4 → rd

    .section .text.startup, "ax"
    .globl _start
_start:
    li      sp, 0x3F00          # stack top (unused at M0 but conventional)

    li      a0, 4
    li      a1, 6
    jal     ra, add_pair        # a0 = a0 + a1 = 10
    li      x6, 10
    bne     a0, x6, fail

    li      a0, 21
    jal     ra, double          # a0 = a0 + a0 = 42
    li      x6, 42
    bne     a0, x6, fail

    li      x14, 0xdeadbeef
    li      x15, 0x0000F000
    sw      x14, 0(x15)
    j       halt

add_pair:
    add     a0, a0, a1
    ret                          # jalr x0, 0(ra)

double:
    add     a0, a0, a0
    ret

fail:
    li      x14, 0xbad
    li      x15, 0x0000F000
    sw      x14, 0(x15)

halt:
    j       halt
