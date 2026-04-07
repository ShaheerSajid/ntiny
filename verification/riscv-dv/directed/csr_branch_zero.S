# ── csrrw + bnez where rs1 starts at ZERO ──────────────────────────────────
# This is the EXACT scenario in Linux's handle_exception when the user
# ran with tp=0:
#   tp = 0
#   csrrw tp, sscratch, tp     # tp should become non-zero (sscratch was set)
#   bnez tp, taken             # should TAKE because new tp = old sscratch
#
# If forwarding works: bnez sees the NEW tp from csrrw → branch taken.
# If the bubble is missed: bnez sees the OLD tp = 0 → branch NOT taken → BUG.

.section .text
.globl _start
_start:
    # Setup: mscratch = 0xCAFE0000 (non-zero kernel ptr)
    li   t1, 0xCAFE0000
    csrw mscratch, t1

    # Setup: tp = 0 (the bug-triggering condition)
    li   tp, 0

    # The hazard sequence — back-to-back csrrw + bnez
    csrrw tp, mscratch, tp       # tp should become 0xCAFE0000
    bnez  tp, taken              # should branch if forwarding works

    # FAIL: branch not taken (bug confirmed)
    li   gp, 21
    j    write_tohost

taken:
    # Verify tp actually has 0xCAFE0000
    li   t0, 0xCAFE0000
    bne  tp, t0, value_fail
    li   gp, 1                   # PASS
    j    write_tohost

value_fail:
    li   gp, 23
    j    write_tohost

write_tohost:
    la   t0, tohost
    sw   gp, 0(t0)
1:  j    1b

.section .data
.align 6
.global tohost
tohost:    .word 0
.align 6
.global fromhost
fromhost:  .word 0
