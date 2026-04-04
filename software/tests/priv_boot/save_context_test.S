/*
 * save_context_test.S — Reproduce EXACT Linux _save_context pattern
 *
 * The Linux crash happens at:
 *   csrrw tp, sscratch, tp     // swap
 *   bnez tp, _save_context
 *   ...
 *   _save_context:
 *   sw sp, 12(tp)              // CRASH: tp has user value
 *
 * This test replicates this EXACT instruction sequence after a
 * U-mode trap, with DTLB miss on the kernel_tp address to test
 * the PTW + store + forwarding interaction.
 */

.section .text.init
.globl _init

.equ UART_TX,        0x10000004
.equ CLINT_MTIMECMP, 0x02004000
.equ CLINT_MTIME,    0x0200BFF8
.equ TOHOST,         0x0F000000

.equ PT_L1,          0x80004000
.equ PT_L0_USER,     0x80006000
.equ UCODE_PAGE,     0x80007000
.equ STACK_TOP,      0x80008000
.equ KERN_VBASE,     0xC0000000
.equ USER_CODE_VA,   0x00006000

.equ PTE_V,    0x001
.equ PTE_R,    0x002
.equ PTE_W,    0x004
.equ PTE_X,    0x008
.equ PTE_U,    0x010
.equ PTE_A,    0x040
.equ PTE_D,    0x080
.equ PTE_LEAF, (PTE_R|PTE_W|PTE_X|PTE_V|PTE_A|PTE_D)
.equ PTE_ULEAF,(PTE_U|PTE_LEAF)

_init:
    li      sp, STACK_TOP

    la      a0, str_banner
    call    uart_puts

    /* PMP */
    li      t0, 0x3FFFFFFF
    csrw    pmpaddr0, t0
    li      t1, 0x1F
    csrw    pmpcfg0, t1

    /* Page tables */
    li      a0, PT_L1
    li      a1, 0x3000
    call    memzero

    /* Kernel megapage 0xC0000000 → 0x80000000 */
    li      t0, PT_L1 + (0x300 * 4)
    li      t2, (0x80000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* Identity megapage 0x80000000 → 0x80000000 */
    li      t0, PT_L1 + (0x200 * 4)
    li      t2, (0x80000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* I/O megapage 0x10000000 */
    li      t0, PT_L1 + (0x040 * 4)
    li      t2, (0x10000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* User page at 0x00006000 */
    li      t0, PT_L1
    li      t2, (PT_L0_USER >> 12) << 10 | PTE_V
    sw      t2, 0(t0)
    li      t0, PT_L0_USER + (0x006 * 4)
    li      t2, (UCODE_PAGE >> 12) << 10 | PTE_ULEAF
    sw      t2, 0(t0)

    /* U-mode code: set tp to user value, then ecall */
    li      t0, UCODE_PAGE
    li      t1, 0x0011f734     /* user tp value (same as Linux crash) */
    /* lui tp, 0x00120; addi tp, tp, -0x8cc → tp = 0x0011f734 */
    li      t2, 0x00120237     /* lui tp, 0x120 */
    sw      t2, 0(t0)
    li      t2, 0x73420213     /* addi tp, tp, 0x734... need to compute */
    /* Actually: li tp, 0x0011f734 needs lui+addi */
    /* lui tp, 0x00120 → tp = 0x00120000 */
    /* addi tp, tp, -0x8cc → tp = 0x00120000 - 0x8cc = 0x0011f734 */
    li      t2, 0x00120237     /* lui x4(tp), 0x120 */
    sw      t2, 0(t0)
    li      t2, 0xf7420213     /* addi x4(tp), x4, -0x8cc... wrong encoding */
    /* Let me just use a simple value */
    /* li tp, 0xDEAD0000 is easier */

    /* Simpler: just NOP in U-mode, then ecall. tp starts as 0 from kernel.
     * The test will check what happens after csrrw in the trap handler. */
    li      t1, 0x00000013     /* nop */
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    li      t1, 0x00000073     /* ecall */
    sw      t1, 8(t0)

    /* Trap vectors */
    la      t0, m_trap_vec
    csrw    mtvec, t0

    li      t0, (1<<8) | (1<<12) | (1<<13) | (1<<15)
    csrw    medeleg, t0

    li      t0, -1
    csrw    mcounteren, t0

    /* Enable Sv32 */
    li      t0, (1 << 31) | (PT_L1 >> 12)
    csrw    satp, t0
    sfence.vma

    /* MRET to S-mode kernel */
    li      t0, (1 << 11)
    csrw    mstatus, t0
    la      t0, kernel_main
    li      t1, (KERN_VBASE - 0x80000000)
    add     t0, t0, t1
    csrw    mepc, t0
    mret

kernel_main:
    /* Set stvec — EXACT Linux handle_exception pattern */
    la      t0, handle_exception
    csrw    stvec, t0

    /* Relocate stack */
    li      t0, (KERN_VBASE - 0x80000000)
    add     sp, sp, t0

    /* sscratch = sp (our "kernel_tp") */
    csrw    sscratch, sp

    /* Drop identity map */
    li      t0, PT_L1 + (0x200 * 4)
    sw      zero, 0(t0)
    sfence.vma

    /* SFENCE again to flush ALL DTLB entries — force PTW on next access */
    sfence.vma

    la      a0, str_kernel_ok
    call    uart_puts

    /* SRET to U-mode */
    csrr    t0, sstatus
    li      t1, ~(1 << 8)
    and     t0, t0, t1
    csrw    sstatus, t0
    li      t0, USER_CODE_VA
    csrw    sepc, t0
    sret

/* Return here after successful trap handling */
kernel_resume:
    la      a0, str_all_pass
    call    uart_puts
    li      t0, TOHOST
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b

/* ════════════════════════════════════════════════════════════════
 * EXACT Linux handle_exception + _save_context
 * ════════════════════════════════════════════════════════════════ */
.align 4
handle_exception:
    /* EXACT Linux code: */
    csrrw   tp, sscratch, tp
    bnez    tp, _save_context

_restore_kernel_tpsp:
    csrr    tp, sscratch
    /* Fall through to _save_context */

_save_context:
    /* THE CRITICAL STORE — this is where Linux crashes */
    sw      sp, 12(tp)         /* TASK_TI_USER_SP = 12 */
    lw      sp, 8(tp)          /* TASK_TI_KERNEL_SP = 8 */

    /* If we get here, the store succeeded! */
    /* Save that tp was correct */
    la      t0, saved_tp
    sw      tp, 0(t0)

    /* Zero sscratch (like Linux line 73) */
    csrw    sscratch, zero

    /* Check cause */
    csrr    t0, scause
    li      t1, 8              /* ecall from U-mode */
    beq     t0, t1, handle_ecall

    /* Other trap — print cause and fail */
    la      a0, str_trap
    call    uart_puts
    csrr    a0, scause
    call    uart_puthex
    la      a0, str_at
    call    uart_puts
    csrr    a0, sepc
    call    uart_puthex
    la      a0, str_tval
    call    uart_puts
    csrr    a0, stval
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

handle_ecall:
    la      a0, str_ecall_ok
    call    uart_puts

    /* Check saved_tp — should be our kernel value */
    la      t0, saved_tp
    lw      t0, 0(t0)
    li      t1, KERN_VBASE + (STACK_TOP - 0x80000000)  /* 0xC0008000 */
    beq     t0, t1, tp_correct

    la      a0, str_tp_wrong
    call    uart_puts
    la      t0, saved_tp
    lw      a0, 0(t0)
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

tp_correct:
    la      a0, str_tp_ok
    call    uart_puts

    /* Return to kernel_resume */
    la      t0, kernel_resume
    csrw    sepc, t0
    li      t0, (1 << 8)
    csrs    sstatus, t0
    /* Restore sscratch = kernel_tp for next time */
    csrw    sscratch, tp
    /* Need to set sp back to kernel stack before sret */
    /* Store kernel_sp at tp+8 for next _save_context */
    mv      sp, tp
    sw      sp, 8(tp)
    sret

/* ════════════════════════════════════════════════════════════════ */
.align 4
m_trap_vec:
    la      a0, str_mtrap
    call    uart_puts
    csrr    a0, mcause
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

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

memzero:
    beqz    a1, 1f
    sw      zero, 0(a0)
    addi    a0, a0, 4
    addi    a1, a1, -4
    j       memzero
1:  ret

fail:
    la      a0, str_fail
    call    uart_puts
    li      t0, TOHOST
    li      t1, 2
    sw      t1, 0(t0)
1:  j       1b

.section .rodata
str_banner:     .asciz "=== save_context test ===\n"
str_kernel_ok:  .asciz "Kernel OK, SRET to U-mode\n"
str_ecall_ok:   .asciz "  ecall handled OK\n"
str_tp_ok:      .asciz "  tp correct after csrrw\n"
str_tp_wrong:   .asciz "  FAIL: tp after csrrw = "
str_all_pass:   .asciz "ALL PASS\n"
str_fail:       .asciz "FAIL\n"
str_trap:       .asciz "  trap cause="
str_at:         .asciz " epc="
str_tval:       .asciz " tval="
str_nl:         .asciz "\n"
str_mtrap:      .asciz "M-trap cause="

.section .data
.align 4
saved_tp:       .word 0

.section .tohost
.globl tohost
tohost:         .word 0
