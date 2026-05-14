## test_ooo_stress.s — exercise the OoO machinery beyond the M0/M1
## sanity battery:
##   1. cross-bank wakeup (LSU CDB result feeds an ALU consumer)
##   2. WAW renaming through the RAT (two producers for the same arch
##      reg in flight, intermediate read must still see the older one)
##   3. independent dep chains that should overlap in the ALU RS
##   4. branch squash + RAT recovery (speculative writers to x9 must
##      be dropped, post-branch read must see the pre-branch value)
##   5. speculative-store suppression (a SW on the wrong-path of a
##      taken branch must not reach memory)
##
## Expected: halt with 0xdeadbeef. Any subtest mismatch jumps to
## `fail` and writes 0xbad to HALT_ADDR.

    .section .text.startup, "ax"
    .globl _start
_start:

    ## ── 1. cross-bank wakeup ─────────────────────────────────
    li      x10, 0x100
    li      x11, 0xdeadbeef
    sw      x11, 0(x10)
    lw      x12, 0(x10)             # x12 = 0xdeadbeef (via LSU CDB)
    addi    x13, x12, 1             # ALU op consumes LSU result
    li      x14, 0xdeadbef0
    bne     x13, x14, fail

    ## ── 2. WAW renaming ──────────────────────────────────────
    li      x6, 100
    add     x7, x6, x6              # reads old x6 → 200
    li      x6, 500                 # WAW
    add     x8, x6, x6              # reads new x6 → 1000
    li      x10, 200
    bne     x7, x10, fail
    li      x10, 1000
    bne     x8, x10, fail
    li      x10, 500
    bne     x6, x10, fail

    ## ── 3. independent dep chains ────────────────────────────
    ## chain A: doubling via add; chain B: doubling via slli.
    ## Two streams sit in the ALU RS at once, both reach 16.
    li      x20, 1
    add     x20, x20, x20
    add     x20, x20, x20
    add     x20, x20, x20
    add     x20, x20, x20
    li      x21, 1
    slli    x21, x21, 1
    slli    x21, x21, 1
    slli    x21, x21, 1
    slli    x21, x21, 1
    bne     x20, x21, fail

    ## ── 4. branch squash + RAT recovery ──────────────────────
    li      x9, 0xbeef
    li      x15, 1
    li      x16, 1
    beq     x15, x16, skip4         # taken — squash everything below
    li      x9, 0xcafe              # speculative writers
    addi    x9, x9, 1
    j       fail
skip4:
    li      x10, 0xbeef
    bne     x9, x10, fail           # x9 must still be 0xbeef

    ## ── 5. speculative-store suppression ─────────────────────
    li      x10, 0x200
    li      x11, 0xfeedface
    sw      x11, 0(x10)             # mem[0x200] = 0xfeedface

    li      x15, 1
    li      x16, 1
    beq     x15, x16, skip5         # taken — squash wrong-path SW
    li      x11, 0xdeadbeef
    sw      x11, 0(x10)             # must NOT reach memory
    j       fail
skip5:
    lw      x12, 0(x10)
    li      x10, 0xfeedface
    bne     x12, x10, fail          # mem[0x200] must still be feedface

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
