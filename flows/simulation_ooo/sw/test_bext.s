## test_bext.s — B extension (Zba/Zbb/Zbc/Zbs) + Zicond directed
## sanity test for M6.
##
## Covers one representative op per group:
##   Zba: sh2add
##   Zbb: andn, max, sext.b, rol, ror, cpop, zext.h
##   Zbc: clmul
##   Zbs: bset, bclr, bext, binv (+ imm variants bseti, bclri)
##   Zicond: czero.eqz, czero.nez
##
## Expected: halt with 0xdeadbeef.

    .section .text.startup, "ax"
    .globl _start
_start:

    ## ── Zba: sh2add ──────────────────────────────────────────
    ## rd = (rs1 << 2) + rs2
    li      x10, 5
    li      x11, 100
    sh2add  x12, x10, x11           # 5*4 + 100 = 120
    li      x13, 120
    bne     x12, x13, fail

    ## ── Zbb: andn ────────────────────────────────────────────
    li      x10, 0xff00ff00
    li      x11, 0x0f0f0f0f
    andn    x12, x10, x11           # rd = rs1 & ~rs2 = 0xf000f000
    li      x13, 0xf000f000
    bne     x12, x13, fail

    ## ── Zbb: max ─────────────────────────────────────────────
    li      x10, -5
    li      x11, 3
    max     x12, x10, x11           # signed max = 3
    li      x13, 3
    bne     x12, x13, fail

    ## ── Zbb: sext.b ──────────────────────────────────────────
    li      x10, 0xff
    sext.b  x12, x10                # rd = 0xffffffff (sign-extend 0xff)
    li      x13, -1
    bne     x12, x13, fail

    ## ── Zbb: cpop (population count) ─────────────────────────
    li      x10, 0xf00f00ff         # 4 + 4 + 8 = 16 ones
    cpop    x12, x10
    li      x13, 16
    bne     x12, x13, fail

    ## ── Zbb: zext.h ──────────────────────────────────────────
    li      x10, 0xdeadbeef
    zext.h  x12, x10                # rd = 0xbeef (lower 16 bits)
    li      x13, 0xbeef
    bne     x12, x13, fail

    ## ── Zbb: rol / ror ───────────────────────────────────────
    li      x10, 0x80000001         # high + low bits
    li      x11, 1
    rol     x12, x10, x11           # rotate left 1 = 0x00000003
    li      x13, 3
    bne     x12, x13, fail
    ror     x12, x10, x11           # rotate right 1 = 0xc0000000
    li      x13, 0xc0000000
    bne     x12, x13, fail

    ## ── Zbc: clmul ───────────────────────────────────────────
    ## clmul(0x1, 0x1) = 0x1 (low 32 bits of carry-less product)
    li      x10, 0x3
    li      x11, 0x5
    clmul   x12, x10, x11           # 0b11 carry-less * 0b101 = 0b1111 = 15
    li      x13, 15
    bne     x12, x13, fail

    ## ── Zbs: bset / bclr / bext / binv ───────────────────────
    li      x10, 0x100
    li      x11, 4
    bset    x12, x10, x11           # x12 = x10 | (1<<4) = 0x110
    li      x13, 0x110
    bne     x12, x13, fail

    li      x10, 0x110
    bclr    x12, x10, x11           # x12 = x10 & ~(1<<4) = 0x100
    li      x13, 0x100
    bne     x12, x13, fail

    li      x10, 0x110
    bext    x12, x10, x11           # x12 = (x10 >> 4) & 1 = 1
    li      x13, 1
    bne     x12, x13, fail

    li      x10, 0x100
    binv    x12, x10, x11           # x12 = x10 ^ (1<<4) = 0x110
    li      x13, 0x110
    bne     x12, x13, fail

    ## ── Zbs immediate: bseti / bclri ─────────────────────────
    li      x10, 0
    bseti   x12, x10, 7             # x12 = 0x80
    li      x13, 0x80
    bne     x12, x13, fail

    li      x10, 0xff
    bclri   x12, x10, 0             # x12 = 0xfe
    li      x13, 0xfe
    bne     x12, x13, fail

    ## ── Zicond: czero.eqz / czero.nez ────────────────────────
    li      x10, 42
    li      x11, 0
    czero.eqz x12, x10, x11         # rs2==0 → rd=0
    bne     x12, x0, fail
    li      x11, 1
    czero.eqz x12, x10, x11         # rs2!=0 → rd=rs1=42
    li      x13, 42
    bne     x12, x13, fail

    li      x11, 0
    czero.nez x12, x10, x11         # rs2==0 → rd=rs1=42
    bne     x12, x13, fail
    li      x11, 1
    czero.nez x12, x10, x11         # rs2!=0 → rd=0
    bne     x12, x0, fail

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
