# ── CSR-then-branch forwarding hazard test ──────────────────────────────────
# Reproduces the exact pipeline hazard observed in Linux's handle_exception
# prologue:
#   csrrw tp, sscratch, tp     # tp = OLD sscratch  (write new tp into sscratch)
#   bnez  tp, taken            # branch if old sscratch != 0
#
# If forwarding correctly delivers the CSR read result to the branch
# comparator in ID, this works. If branch-after-CSR is mishandled, the
# branch sees a stale tp and goes the wrong way.
#
# Pass: tohost = 1
# Fail: tohost = 2*test_number+1 (3, 5, 7, 9, 11)

.section .text
.globl _start
_start:
    # Test 1: csrrw + bnez forwarding (old value non-zero, branch should TAKE)
    li   t1, 0xCAFEBABE          # known non-zero value for mscratch
    csrw mscratch, t1            # mscratch = 0xCAFEBABE
    li   t0, 0xDEAD0001          # known non-zero "user value"
    csrrw t0, mscratch, t0       # t0 should become 0xCAFEBABE
                                 # mscratch should become 0xDEAD0001
    bnez t0, test1_pass          # ← branch SHOULD be taken
    li   gp, 3                   # FAIL: branch not taken (t0 looked zero)
    j    write_tohost
test1_pass:
    # Verify t0 actually has 0xCAFEBABE
    li   t2, 0xCAFEBABE
    bne  t0, t2, test1_value_fail
    j    test2
test1_value_fail:
    li   gp, 5                   # FAIL: branch taken but wrong t0 value
    j    write_tohost

test2:
    # Test 2: csrrw + bnez (old value zero, branch should NOT take)
    csrw mscratch, zero          # mscratch = 0
    li   t0, 0xDEAD0002          # non-zero user value
    csrrw t0, mscratch, t0       # t0 should become 0 (old mscratch)
    bnez t0, test2_fail          # ← branch should NOT be taken
    j    test3
test2_fail:
    li   gp, 7                   # FAIL: branch taken when t0 should be 0
    j    write_tohost

test3:
    # Test 3: csrrw + beq (uses both rs1 and rs2 from CSR result)
    li   t1, 0xBEEFBEEF
    csrw mscratch, t1
    li   t0, 0xDEAD0003
    csrrw t0, mscratch, t0       # t0 = 0xBEEFBEEF
    li   t2, 0xBEEFBEEF
    beq  t0, t2, test3_pass
    li   gp, 9                   # FAIL
    j    write_tohost
test3_pass:
    j    test4

test4:
    # Test 4: chained csrrw — write then read
    li   t1, 0x12345678
    csrw mscratch, t1
    li   t0, 0
    csrrw t0, mscratch, t0       # t0 = 0x12345678, mscratch = 0
    li   t2, 0x12345678
    bne  t0, t2, test4_fail
    csrr t1, mscratch            # t1 should be 0 now
    bnez t1, test4_fail
    j    pass
test4_fail:
    li   gp, 11
    j    write_tohost

pass:
    li   gp, 1                   # exit code 1 = pass
    # fall through

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
