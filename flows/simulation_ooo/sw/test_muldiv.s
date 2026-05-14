## test_muldiv.s — M extension stress test for M2 phase B.
##
## What this exercises that the rest of the battery doesn't:
##   1. Each M-ext op end-to-end correctness
##      (MUL, MULH, MULHU, MULHSU, DIV, DIVU, REM, REMU)
##   2. RISC-V special cases (divide-by-zero, signed overflow)
##   3. OoO overlap: a long DIV in flight while independent ALU
##      ops complete first (CDB carries the DIV result later, ALU
##      consumer wakes up on it)
##   4. Cross-FU dep chain: DIV → ALU → MUL → ALU, all chained
##      via tag-broadcast wakeups
##   5. Concurrent ALU + MULDIV: two independent streams that the
##      ALU RS and MULDIV RS process in parallel
##
## Expected: halt with 0xdeadbeef. Any subtest mismatch jumps to
## `fail` and writes 0xbad to HALT_ADDR.

    .section .text.startup, "ax"
    .globl _start
_start:

    ## ── 1. each M-ext op ─────────────────────────────────────
    ## MUL: 7 * 6 = 42
    li      x10, 7
    li      x11, 6
    mul     x12, x10, x11
    li      x13, 42
    bne     x12, x13, fail

    ## MULH: signed-signed high — (-1) * (-1) = 1; high = 0
    li      x10, -1
    li      x11, -1
    mulh    x12, x10, x11
    bne     x12, x0, fail

    ## MULHU: unsigned-unsigned high — 0xFFFFFFFF * 2 = 0x1_FFFFFFFE; high = 1
    li      x10, -1
    li      x11, 2
    mulhu   x12, x10, x11
    li      x13, 1
    bne     x12, x13, fail

    ## MULHSU: signed-unsigned high — (-1) * 2 (unsigned) =
    ##   0xFFFFFFFE_FFFFFFFE; high = 0xFFFFFFFF
    li      x10, -1
    li      x11, 2
    mulhsu  x12, x10, x11
    li      x13, -1
    bne     x12, x13, fail

    ## DIV signed: -42 / 6 = -7
    li      x10, -42
    li      x11, 6
    div     x12, x10, x11
    li      x13, -7
    bne     x12, x13, fail

    ## DIVU unsigned: 42 / 6 = 7
    li      x10, 42
    li      x11, 6
    divu    x12, x10, x11
    li      x13, 7
    bne     x12, x13, fail

    ## REM signed: -42 % 5 = -2 (sign of dividend)
    li      x10, -42
    li      x11, 5
    rem     x12, x10, x11
    li      x13, -2
    bne     x12, x13, fail

    ## REMU unsigned: 42 % 5 = 2
    li      x10, 42
    li      x11, 5
    remu    x12, x10, x11
    li      x13, 2
    bne     x12, x13, fail

    ## ── 2. RISC-V special cases ──────────────────────────────
    ## divide-by-zero: DIVU x / 0 = all-ones, REMU x / 0 = x
    li      x10, 42
    li      x11, 0
    divu    x12, x10, x11
    li      x13, -1
    bne     x12, x13, fail
    remu    x12, x10, x11
    li      x13, 42
    bne     x12, x13, fail

    ## signed overflow: DIV INT_MIN / -1 = INT_MIN; REM = 0
    li      x10, 0x80000000        # INT_MIN
    li      x11, -1
    div     x12, x10, x11
    li      x13, 0x80000000
    bne     x12, x13, fail
    rem     x12, x10, x11
    bne     x12, x0, fail

    ## ── 3. OoO overlap: DIV in flight, independent ALU ops ───
    ## The DIV is a 30+ cycle op (large dividend). The ALU ops on
    ## an independent register chain should retire long before
    ## the DIV does — they're issuing OoO from the ALU RS while
    ## MULDIV churns. The post-DIV bne forces a wait for the DIV
    ## result, proving it landed correctly.
    li      x10, 1000000000
    li      x11, 7
    div     x20, x10, x11           # x20 = 142857142  (slow)

    li      x21, 1
    addi    x21, x21, 1
    addi    x21, x21, 1
    addi    x21, x21, 1
    addi    x21, x21, 1             # x21 = 5  (fast)

    li      x22, 142857142
    bne     x20, x22, fail
    li      x22, 5
    bne     x21, x22, fail

    ## ── 4. cross-FU dep chain ────────────────────────────────
    ## div → addi → mul → addi, each waiting on the prior via tag.
    ## Wakeups: DIV result (wb3) → ALU RS slot; ALU result (wb1)
    ##   → MULDIV RS slot; MUL result (wb3) → ALU RS slot.
    li      x10, 100
    li      x11, 4
    divu    x23, x10, x11           # x23 = 25
    addi    x23, x23, 5             # x23 = 30  (waits on DIV via wb3)
    li      x11, 3
    mul     x23, x23, x11           # x23 = 90  (waits on ALU via wb1)
    addi    x23, x23, 10            # x23 = 100 (waits on MUL via wb3)
    li      x10, 100
    bne     x23, x10, fail

    ## ── 5. concurrent ALU + MULDIV streams ───────────────────
    ## Two independent dep chains: one in ALU (slli stream), one
    ## in MULDIV (mul stream). Both end up at 256.
    li      x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1
    slli    x24, x24, 1             # x24 = 256

    li      x25, 1
    li      x26, 2
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26
    mul     x25, x25, x26           # x25 = 256

    bne     x24, x25, fail

    ## ── success ──────────────────────────────────────────────
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
