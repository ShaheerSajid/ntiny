# ── Trap-entry CSR + branch hazard test ─────────────────────────────────────
# Reproduces Linux's exact handle_exception prologue:
#   trap → vector → csrrw tp, sscratch, tp → bnez tp, target
#
# The csrrw is the FIRST instruction after the pipeline flush from trap entry.
# Then a bnez immediately depending on its result.
#
# Setup:
#   1. mscratch = 0xCAFE0000 (a known non-zero "kernel ptr")
#   2. mtvec = trap_entry (vectored or direct)
#   3. tp = 0xUSER_TP (a non-zero "user value")
#   4. ecall → trap to mtvec
#   5. trap_entry: csrrw tp, mscratch, tp; bnez tp, taken; fail
#
# Expected: tp becomes 0xCAFE0000, bnez TAKES the branch.
# Bug: bnez doesn't take → tp seen as stale value or zero.

.section .text
.globl _start
_start:
    # Set up trap vector
    la   t0, trap_entry
    csrw mtvec, t0

    # Set up mscratch with a known non-zero kernel pointer
    li   t0, 0xCAFE0000
    csrw mscratch, t0

    # Set tp to a USER pointer (the value we DON'T want to see in the branch)
    li   tp, 0xDEADBEEF

    # Trigger the trap
    ecall

    # If we get back here, something went wrong
    li   gp, 99
    j    write_tohost

# ─── Trap entry — IDENTICAL form to Linux's handle_exception ────────────────
.align 6
trap_entry:
    csrrw tp, mscratch, tp     # tp = OLD mscratch = 0xCAFE0000
                               # mscratch = OLD tp = 0xDEADBEEF
    bnez  tp, trap_taken       # ← THIS BRANCH MUST TAKE

    # FAIL: branch was not taken (bug confirmed)
    li   gp, 13
    j    write_tohost

trap_taken:
    # Check tp actually has the correct value
    li   t0, 0xCAFE0000
    bne  tp, t0, trap_value_fail

    # Check mscratch was actually updated
    csrr t0, mscratch
    li   t1, 0xDEADBEEF
    bne  t0, t1, trap_swap_fail

    # SUCCESS — update gp and return
    li   gp, 1
    j    write_tohost

trap_value_fail:
    li   gp, 15
    j    write_tohost

trap_swap_fail:
    li   gp, 17
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
