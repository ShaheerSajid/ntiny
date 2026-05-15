## test_csr.s — minimal M-mode CSR sanity (M7-minimal).
##
## Covers:
##   1. CSRRW write + CSRRW read-back (mscratch round-trip)
##   2. CSRRS set-bits (mstatus.MIE)
##   3. CSRRC clear-bits (mstatus.MIE)
##   4. CSRRWI immediate write (mtvec)
##   5. csrr alias (CSRRS rd, csr, x0 — read with no write)
##   6. Read-only CSRs return constants (mhartid=0, misa has I+M bits)
##
## Expected: halt with 0xdeadbeef.

    .section .text.startup, "ax"
    .globl _start
_start:

    ## ── 1. mscratch round-trip ───────────────────────────────
    li      x10, 0xcafebabe
    csrw    mscratch, x10          # CSRRW x0, mscratch, x10 (write only)
    csrr    x11, mscratch
    li      x12, 0xcafebabe
    bne     x11, x12, fail

    ## ── 2. CSRRW: read-and-write ─────────────────────────────
    li      x10, 0x12345678
    csrrw   x13, mscratch, x10     # x13 = old mscratch (0xcafebabe); mscratch = 0x12345678
    li      x14, 0xcafebabe
    bne     x13, x14, fail
    csrr    x11, mscratch
    li      x12, 0x12345678
    bne     x11, x12, fail

    ## ── 3. CSRRS: set bits ───────────────────────────────────
    ## mstatus.MIE = bit 3. csrrs sets bits whose mask = rs1.
    li      x10, 0x8                # bit 3
    csrrs   x0, mstatus, x10        # set MIE
    csrr    x11, mstatus
    andi    x12, x11, 0x8           # extract bit 3
    li      x13, 0x8
    bne     x12, x13, fail

    ## ── 4. CSRRC: clear bits ─────────────────────────────────
    li      x10, 0x8
    csrrc   x0, mstatus, x10        # clear MIE
    csrr    x11, mstatus
    andi    x12, x11, 0x8
    bne     x12, x0, fail

    ## ── 5. CSRRWI: immediate write ───────────────────────────
    csrrwi  x0, mscratch, 7         # mscratch = 7 (uimm5)
    csrr    x11, mscratch
    li      x12, 7
    bne     x11, x12, fail

    ## ── 6. CSRRSI / CSRRCI ───────────────────────────────────
    csrrsi  x0, mscratch, 8         # mscratch |= 8 → 0xf
    csrr    x11, mscratch
    li      x12, 0xf
    bne     x11, x12, fail
    csrrci  x0, mscratch, 1         # mscratch &= ~1 → 0xe
    csrr    x11, mscratch
    li      x12, 0xe
    bne     x11, x12, fail

    ## ── 7. mhartid = 0 ───────────────────────────────────────
    csrr    x11, mhartid
    bne     x11, x0, fail

    ## ── 8. misa has I (bit 8) and M (bit 12) ─────────────────
    csrr    x11, misa
    li      x12, 0x1100             # bits 8 + 12
    and     x13, x11, x12
    bne     x13, x12, fail          # required bits must be set

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
