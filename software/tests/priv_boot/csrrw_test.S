/*
 * csrrw_test.S — Test csrrw sscratch swap (the _save_context pattern)
 *
 * Tests the exact Linux handle_exception sequence:
 *   csrrw tp, sscratch, tp    # swap
 *   bnez  tp, done            # check
 *   csrr  tp, sscratch        # read back (S-mode path)
 *
 * Expected: after csrrw with sscratch=0, tp=kernel_val:
 *   tp <- 0 (old sscratch)
 *   sscratch <- kernel_val (old tp)
 *   then csrr tp, sscratch → tp = kernel_val
 */

.section .text.init
.globl _init

.equ UART_TX,  0x10000004
.equ TOHOST,   0x0F000000

_init:
    li      sp, 0x80008000

    /* ── Test 1: Basic csrrw swap ──────────────────────────── */
    la      a0, str_test1
    call    uart_puts

    li      t0, 0xDEADBEEF      /* "kernel tp" */
    mv      tp, t0               /* tp = kernel_val */
    csrw    sscratch, zero       /* sscratch = 0 (S-mode convention) */

    /* This is exactly what handle_exception does */
    csrrw   tp, sscratch, tp     /* tp = old_sscratch(0), sscratch = old_tp(0xDEADBEEF) */

    /* tp should be 0 */
    bnez    tp, fail_test1_tp

    /* Read back sscratch — should be 0xDEADBEEF */
    csrr    tp, sscratch
    li      t1, 0xDEADBEEF
    bne     tp, t1, fail_test1_sscratch

    la      a0, str_pass
    call    uart_puts

    /* ── Test 2: csrrw with forwarding (back-to-back) ─────── */
    la      a0, str_test2
    call    uart_puts

    li      tp, 0x12345678       /* kernel tp */
    csrw    sscratch, zero
    csrrw   tp, sscratch, tp     /* swap */
    /* NO NOP between csrrw and bnez — tests forwarding */
    bnez    tp, fail_test2_tp

    csrr    tp, sscratch
    li      t1, 0x12345678
    bne     tp, t1, fail_test2_sscratch

    la      a0, str_pass
    call    uart_puts

    /* ── Test 3: csrrw during interrupt ───────────────────── */
    la      a0, str_test3
    call    uart_puts

    /* Set up trap handler */
    la      t0, m_trap_handler
    csrw    mtvec, t0

    /* Set up timer to fire soon */
    li      t0, 0x0200BFF8       /* mtime */
    lw      t1, 0(t0)
    addi    t1, t1, 50           /* fire in ~50 cycles */
    li      t0, 0x02004000       /* mtimecmp */
    sw      t1, 0(t0)
    li      t1, 0
    sw      t1, 4(t0)

    /* Enable timer interrupt */
    li      t0, (1 << 7)         /* MTIE */
    csrs    mie, t0
    li      t0, (1 << 3)         /* MIE */
    csrs    mstatus, t0

    /* Now do the csrrw swap in a loop — eventually the timer fires during it */
    la      t2, timer_count
    sw      zero, 0(t2)
    li      s0, 0xCAFEBABE      /* kernel tp value */
    li      s1, 1000             /* iterations */

csrrw_loop:
    mv      tp, s0               /* tp = kernel_val */
    csrw    sscratch, zero       /* sscratch = 0 */

    /* The critical sequence — timer might fire here */
    csrrw   tp, sscratch, tp     /* swap */
    bnez    tp, fail_test3_tp    /* tp should be 0 */
    csrr    tp, sscratch         /* read back */
    bne     tp, s0, fail_test3_sscratch  /* compare with s0 (callee-saved) */

    addi    s1, s1, -1
    bnez    s1, csrrw_loop

    /* Disable timer */
    li      t0, (1 << 7)
    csrc    mie, t0

    la      t2, timer_count
    lw      a0, 0(t2)
    beqz    a0, skip_timer_msg
    la      a0, str_timer_fired
    call    uart_puts
skip_timer_msg:

    la      a0, str_pass
    call    uart_puts

    /* ── ALL PASS ── */
    la      a0, str_all_pass
    call    uart_puts
    li      t0, TOHOST
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b

/* ── Failures ──────────────────────────────────────────────── */
fail_test1_tp:
    la      a0, str_fail_tp
    call    uart_puts
    j       fail
fail_test1_sscratch:
    la      a0, str_fail_ss
    call    uart_puts
    j       fail
fail_test2_tp:
    la      a0, str_fail_tp
    call    uart_puts
    j       fail
fail_test2_sscratch:
    la      a0, str_fail_ss
    call    uart_puts
    j       fail
fail_test3_tp:
    la      a0, str_fail_tp
    call    uart_puts
    mv      a0, tp
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail
fail_test3_sscratch:
    la      a0, str_fail_ss
    call    uart_puts
    mv      a0, tp
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

fail:
    la      a0, str_fail
    call    uart_puts
    li      t0, TOHOST
    li      t1, 2
    sw      t1, 0(t0)
1:  j       1b

/* ── M-mode trap handler ──────────────────────────────────── */
.align 4
m_trap_handler:
    csrr    t0, mcause
    li      t1, 0x80000007       /* timer interrupt */
    bne     t0, t1, m_trap_other

    /* Count timer interrupts */
    la      t0, timer_count
    lw      t1, 0(t0)
    addi    t1, t1, 1
    sw      t1, 0(t0)

    /* Disable MTIE, set max mtimecmp */
    li      t0, (1 << 7)
    csrc    mie, t0
    li      t0, 0x02004000
    li      t1, -1
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    mret

m_trap_other:
    /* Unexpected trap */
    la      a0, str_mtrap
    call    uart_puts
    csrr    a0, mcause
    call    uart_puthex
    la      a0, str_at
    call    uart_puts
    csrr    a0, mepc
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

/* ── Utilities ─────────────────────────────────────────────── */
uart_puts:
    li      t0, UART_TX
1:  lbu     t1, 0(a0)
    beqz    t1, 2f
    sw      t1, 0(t0)
    addi    a0, a0, 1
    j       1b
2:  ret

uart_puthex:
    li      t0, UART_TX
    li      t2, 28
1:  srl     t1, a0, t2
    andi    t1, t1, 0xF
    li      t3, 10
    blt     t1, t3, 2f
    addi    t1, t1, ('a' - 10)
    j       3f
2:  addi    t1, t1, '0'
3:  sw      t1, 0(t0)
    addi    t2, t2, -4
    bgez    t2, 1b
    ret

/* ── Data ──────────────────────────────────────────────────── */
.section .rodata
str_test1:       .asciz "Test 1: basic csrrw swap... "
str_test2:       .asciz "Test 2: back-to-back csrrw+bnez+csrr... "
str_test3:       .asciz "Test 3: csrrw during timer interrupt... "
str_pass:        .asciz "PASS\n"
str_fail:        .asciz "FAIL\n"
str_fail_tp:     .asciz "FAIL: tp wrong = "
str_fail_ss:     .asciz "FAIL: sscratch wrong = "
str_all_pass:    .asciz "ALL PASS\n"
str_timer_fired: .asciz "(timer fired during test) "
str_mtrap:       .asciz "M-trap cause="
str_at:          .asciz " epc="
str_nl:          .asciz "\n"

.section .data
.align 4
timer_count:    .word 0

.section .tohost
.globl tohost
tohost:         .word 0
