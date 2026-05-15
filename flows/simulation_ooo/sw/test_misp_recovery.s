## test_misp_recovery.s — directed mispredict-recovery battery for
## the M3-A snapshot/restore machinery.
##
## What this exercises that the rest of the battery doesn't:
##   1. RAT restore for an OLDER surviving in-flight producer:
##      a slow producer for x9 is in flight when a branch
##      mispredicts; after restore, dispatch must read RAT[x9] as
##      busy with that producer's tag (NOT as "free" → arch
##      regfile, which the M2-B wholesale flush would have done
##      and read stale data from)
##   2. Nested branches: B1 → B2 → B3 dispatched, B1 mispredicts;
##      B2 + B3 snapshots must be reclaimed (ring doesn't deadlock)
##   3. Muldiv-flush path: a YOUNGER DIV in flight when an older
##      branch mispredicts; the DIV's writeback must NOT corrupt
##      the re-allocated ROB slot on the correct path
##   4. Snapshot ring exhaustion: many back-to-back branches force
##      the snap-stall path; pipeline must drain and re-allocate
##
## Expected: halt with 0xdeadbeef. Any subtest mismatch jumps to
## `fail` and writes 0xbad to HALT_ADDR.

    .section .text.startup, "ax"
    .globl _start
_start:

    ## ── 1. RAT restore for older surviving producer ──────────
    ## Sequence the producer for x9 to be in flight (via a slow
    ## DIV → addi chain that ties up the ALU for several cycles)
    ## right when an unrelated branch mispredicts. The post-branch
    ## read of x9 must see the in-flight producer's value.
    ##
    ## Layout:
    ##   div  x20 = big / small        (~30+ cyc on the divider)
    ##   addi x9, x20, 0xbeef-result   (slow producer for x9)
    ##   li   x15, 1
    ##   li   x16, 1
    ##   beq  x15, x16, skip1          (taken; squashes wrong-path)
    ##     [ wrong path: would clobber x9 ]
    ##     li x9, 0xcafe
    ##     j fail
    ##   skip1:
    ##     bne x9, expected, fail      (must see in-flight x9)

    li      x10, 1000000000
    li      x11, 7
    divu    x20, x10, x11           # x20 = 142857142  (slow)
    li      x6,  0x1000             # constant 4096
    add     x9, x20, x6             # waits for DIV → x9 = 142861238

    li      x15, 1
    li      x16, 1
    beq     x15, x16, skip1         # taken — squash wrong path
    li      x9, 0xcafe              # wrong-path writer
    j       fail
skip1:
    li      x10, 142861238
    bne     x9, x10, fail1          # x9 must reflect the in-flight DIV+ADD

    ## ── 2. Nested-branch snapshot reclaim ────────────────────
    ## Three branches dispatched close together; the OUTER one
    ## mispredicts. Inner snapshots must be released so subsequent
    ## branches can dispatch without snap-stall deadlock.
    ##
    ## Note: at our 1-wide dispatch the "nested" structure is in
    ## ROB ordering, not call/return depth. Three branches with
    ## tight spacing land 3 snapshots in flight at once; the
    ## first to mispredict frees the younger two.

    li      x21, 0
    li      x22, 0
    li      x23, 0
    beq     x21, x22, n_skip_a      # T (snap1) — outer
    addi    x21, x21, 1             # squashed
    beq     x21, x22, n_skip_b      # speculative (snap2)
    addi    x22, x22, 1             # squashed
    beq     x22, x23, n_skip_c      # speculative (snap3)
    addi    x23, x23, 1             # squashed
n_skip_c:
n_skip_b:
n_skip_a:
    li      x10, 0
    bne     x21, x10, fail2
    bne     x22, x10, fail2
    bne     x23, x10, fail2

    ## ── 3. Muldiv flush on mispredict ────────────────────────
    ## A DIV dispatches and starts churning, then a younger branch
    ## (still older than ROB tail) mispredicts. The DIV is NEWER
    ## than the branch and must be drained — its rob_idx will be
    ## re-allocated on the correct path, and a stale wb3 there
    ## would corrupt the new uop's result.
    ##
    ## Sequence:
    ##   li   xN, 1                   (correct-path target)
    ##   beq  xN, xM, skip3           (taken; squashes wrong-path)
    ##     [ wrong-path: a DIV that takes many cycles ]
    ##     div  x24, big, small
    ##     addi x25, x24, 7           (wrong-path consumer)
    ##     j    fail
    ##   skip3:
    ##     ... independent ALU work ...
    ##     ... if x25 was clobbered by stale wb3, we'd see it here ...
    ##     bne  x25, expected, fail

    li      x25, 0xc0de             # known correct value for x25
    li      x15, 1
    li      x16, 1
    beq     x15, x16, skip3         # taken
    ## --- wrong path ---
    li      x10, 1000000000
    li      x11, 13
    div     x24, x10, x11           # slow DIV — must be flushed
    addi    x25, x24, 7             # would clobber x25 with stale data
    j       fail
skip3:
    ## A few correct-path ALU ops that re-use ROB slots the
    ## wrong-path uops would have held.
    addi    x26, x0, 1
    addi    x27, x0, 2
    addi    x28, x0, 3
    addi    x29, x0, 4
    li      x10, 0xc0de
    bne     x25, x10, fail3         # x25 must still be 0xc0de

    ## ── 4. Snapshot ring exhaustion → snap-stall recovery ────
    ## Burst 8 not-taken branches in a row; ring (N=4) fills,
    ## fetch stalls until older branches commit, then drains.
    ## The final state must still be consistent.

    li      x30, 0xface
    li      x10, 0xface
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4
    bne     x30, x10, fail4

    ## ── success ──────────────────────────────────────────────
    li      x14, 0xdeadbeef
    li      x15, 0x0000F000
    sw      x14, 0(x15)
    j       halt

fail1:
    li      x14, 0xbad1
    j       fail_write
fail2:
    li      x14, 0xbad2
    j       fail_write
fail3:
    li      x14, 0xbad3
    j       fail_write
fail4:
    li      x14, 0xbad4
fail_write:
    li      x15, 0x0000F000
    sw      x14, 0(x15)

fail:
    li      x14, 0xbad
    li      x15, 0x0000F000
    sw      x14, 0(x15)

halt:
    j       halt
