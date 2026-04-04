/*
 * priv_boot_timer.S — Reproduce Linux _save_context crash
 *
 * Tests the EXACT scenario that crashes Linux:
 *   1. M-mode: PMP + page tables + MMU
 *   2. MRET to S-mode kernel
 *   3. SRET to U-mode init
 *   4. Timer interrupt fires in U-mode → trap to S-mode
 *   5. S-mode _save_context: csrrw tp, sscratch, tp
 *   6. Verify tp = kernel_tp (not user_tp)
 *
 * The key difference from priv_boot.S: U-mode runs with a timer
 * interrupt pending, forcing the trap path through the interrupt
 * handler rather than the ecall path.
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

/* ════════════════════════════════════════════════════════════════
 * M-MODE INIT
 * ════════════════════════════════════════════════════════════════ */
_init:
    li      sp, STACK_TOP

    la      a0, str_banner
    call    uart_puts

    /* PMP: NAPOT all 4GB RWX */
    li      t0, 0x3FFFFFFF
    csrw    pmpaddr0, t0
    li      t1, 0x1F
    csrw    pmpcfg0, t1

    /* Clear page tables */
    li      a0, PT_L1
    li      a1, 0x3000
    call    memzero

    /* L1[0x300] = kernel megapage VA 0xC0000000 → PA 0x80000000 */
    li      t0, PT_L1 + (0x300 * 4)
    li      t2, (0x80000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* L1[0x200] = identity megapage VA 0x80000000 → PA 0x80000000 */
    li      t0, PT_L1 + (0x200 * 4)
    li      t2, (0x80000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* L1[0x040] = I/O megapage VA 0x10000000 → PA 0x10000000 (UART) */
    li      t0, PT_L1 + (0x040 * 4)
    li      t2, (0x10000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* L1[0x008] = I/O megapage VA 0x02000000 → PA 0x02000000 (CLINT) */
    li      t0, PT_L1 + (0x008 * 4)
    li      t2, (0x02000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /* L1[0x000] = pointer to L0_USER */
    li      t0, PT_L1
    li      t2, (PT_L0_USER >> 12) << 10 | PTE_V
    sw      t2, 0(t0)

    /* L0_USER[0x006] = U-mode code page */
    li      t0, PT_L0_USER + (0x006 * 4)
    li      t2, (UCODE_PAGE >> 12) << 10 | PTE_ULEAF
    sw      t2, 0(t0)

    /* Install U-mode code: infinite NOP loop (timer will interrupt it) */
    li      t0, UCODE_PAGE
    li      t1, 0x00000013     /* nop */
    sw      t1, 0(t0)
    sw      t1, 4(t0)
    sw      t1, 8(t0)
    sw      t1, 12(t0)
    li      t1, 0xFF1FF06F     /* j -16 (loop back to start) */
    sw      t1, 16(t0)

    /* Trap vectors */
    la      t0, m_trap_vec
    csrw    mtvec, t0

    /* Delegation: delegate S-mode timer interrupt (bit 5) to S-mode */
    li      t0, (1<<8) | (1<<12) | (1<<13) | (1<<15)
    csrw    medeleg, t0
    li      t0, 0x222          /* SSIP + STIP + SEIP */
    csrw    mideleg, t0

    li      t0, -1
    csrw    mcounteren, t0
    csrw    scounteren, t0

    /* Enable Sv32 */
    li      t0, (1 << 31) | (PT_L1 >> 12)
    csrw    satp, t0
    sfence.vma

    la      a0, str_mmu_ok
    call    uart_puts

    /* Enable M-mode timer interrupt (must be done in M-mode) */
    li      t0, (1 << 7)       /* MTIE */
    csrs    mie, t0
    /* Enable global MIE so M-mode timer fires */
    li      t0, (1 << 3) | (1 << 1)  /* MIE + SIE */
    csrs    mstatus, t0

    /* MRET to S-mode kernel_main */
    li      t0, (1 << 11) | (1 << 3) | (1 << 1)  /* MPP=S, MIE=1, SIE=1 */
    csrw    mstatus, t0
    la      t0, kernel_main
    li      t1, (KERN_VBASE - 0x80000000)
    add     t0, t0, t1         /* virtual address */
    csrw    mepc, t0
    mret

/* ════════════════════════════════════════════════════════════════
 * S-MODE KERNEL
 * ════════════════════════════════════════════════════════════════ */
kernel_main:
    /* Set stvec to virtual address */
    la      t0, s_trap_vec
    csrw    stvec, t0

    /* Relocate stack to virtual */
    li      t0, (KERN_VBASE - 0x80000000)
    add     sp, sp, t0

    /* Set sscratch = kernel sp (for U→S trap swap) */
    csrw    sscratch, sp

    /* Drop identity map */
    li      t0, PT_L1 + (0x200 * 4)
    sw      zero, 0(t0)
    sfence.vma

    la      a0, str_kernel_ok
    call    uart_puts

    /* ── Set up timer to fire DURING U-mode execution ────── */
    /* Read current mtime, set mtimecmp to mtime + small delta */
    li      t0, CLINT_MTIME
    lw      t1, 0(t0)
    addi    t1, t1, 500        /* fire after ~500 cycles in U-mode */
    li      t0, CLINT_MTIMECMP
    sw      t1, 0(t0)
    li      t1, 0
    sw      t1, 4(t0)

    /* Enable S-mode timer interrupt via M-mode:
     * Timer interrupts always arrive in M-mode first. M-mode handler
     * will set STIP to forward it to S-mode. But with mideleg bit 5 set,
     * the STIP is delegated to S-mode automatically.
     *
     * Actually: CLINT timer fires MTIP. If STIP is delegated (mideleg[5]),
     * M-mode must forward by setting STIP in mip. We'll do this simpler:
     * enable MIE.MTIE, M-mode handler forwards to S-mode via STIP.
     */
    /* Enable SIE.STIE (S-mode timer interrupt enable) */
    li      t0, (1 << 5)
    csrs    sie, t0
    /* Enable global SIE via sstatus (S-mode can do this) */
    li      t0, (1 << 1)
    csrs    sstatus, t0

    /* Set SUM for S-mode to access U pages in handler */
    li      t0, (1 << 18)
    csrs    sstatus, t0

    la      a0, str_timer_armed
    call    uart_puts

    /* Store known kernel_tp value in a saved register for later check */
    .equ    KERN_TP_MAGIC, 0xC0008000   /* kernel sp = our "kernel_tp" */
    li      s0, KERN_TP_MAGIC

    /* ── Prepare for SRET to U-mode ──────────────────────── */
    /* SPP = U-mode (0), SPIE = 1 */
    csrr    t0, sstatus
    li      t1, ~(1 << 8)
    and     t0, t0, t1         /* clear SPP */
    li      t1, (1 << 5)
    or      t0, t0, t1         /* set SPIE */
    csrw    sstatus, t0

    li      t0, USER_CODE_VA
    csrw    sepc, t0

    /* Track test state */
    la      t0, test_state
    sw      zero, 0(t0)        /* 0 = waiting for timer trap */

    la      a0, str_sret
    call    uart_puts

    sret

/* ── Return here after timer trap successfully handled ────── */
kernel_after_timer:
    la      a0, str_timer_handled
    call    uart_puts

    /* Verify we survived the trap with correct context */
    la      t0, trap_tp_value
    lw      t0, 0(t0)
    li      t1, KERN_TP_MAGIC
    /* tp after csrrw should have been sscratch = kernel sp */
    beq     t0, t1, tp_ok
    /* tp was wrong! */
    la      a0, str_tp_bad
    call    uart_puts
    la      t0, trap_tp_value
    lw      a0, 0(t0)
    call    uart_puthex
    la      a0, str_expected
    call    uart_puts
    li      a0, KERN_TP_MAGIC
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

tp_ok:
    la      a0, str_all_pass
    call    uart_puts
    j       pass

/* ════════════════════════════════════════════════════════════════
 * S-MODE TRAP HANDLER (mimics Linux handle_exception)
 * ════════════════════════════════════════════════════════════════ */
.align 4
s_trap_vec:
    /* Linux handle_exception EXACTLY: swap tp with sscratch */
    csrrw   tp, sscratch, tp
    bnez    tp, 1f
    csrr    tp, sscratch       /* from S-mode: restore tp */
1:
    /* Record tp value we got from sscratch */
    la      t0, trap_tp_value
    sw      tp, 0(t0)

    /* Use tp as base for kernel stack (like Linux thread_info) */
    /* In our test, sscratch = kernel_sp, so tp = kernel_sp after swap */
    mv      sp, tp

    /* Save minimal context */
    addi    sp, sp, -32
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      a0, 12(sp)

    /* Check cause */
    csrr    t0, scause
    li      t1, 0x80000005     /* S-mode timer interrupt */
    beq     t0, t1, handle_timer

    /* Other trap — print and fail */
    la      a0, str_strap
    call    uart_puts
    csrr    a0, scause
    call    uart_puthex
    la      a0, str_at
    call    uart_puts
    csrr    a0, sepc
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

handle_timer:
    la      a0, str_got_timer
    call    uart_puts

    /* Disable timer: set mtimecmp to max (need ecall to M-mode) */
    /* Actually, clear SIE.STIE to prevent re-entry */
    li      t0, (1 << 5)
    csrc    sie, t0

    /* Return to kernel_after_timer instead of U-mode */
    la      t0, kernel_after_timer
    csrw    sepc, t0
    /* SPP = S-mode */
    li      t0, (1 << 8)
    csrs    sstatus, t0

    /* Restore context and sret to S-mode kernel */
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      a0, 12(sp)
    addi    sp, sp, 32
    /* Save kernel sp back to sscratch before sret */
    csrw    sscratch, sp
    sret

/* ════════════════════════════════════════════════════════════════
 * M-MODE TRAP HANDLER
 * ════════════════════════════════════════════════════════════════ */
.align 4
m_trap_vec:
    csrr    t0, mcause
    li      t1, 0x80000007     /* M-mode timer */
    beq     t0, t1, m_timer

    /* Unknown — print and fail */
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

m_timer:
    /* Forward timer interrupt to S-mode by setting STIP in mip */
    /* Actually, with mideleg[5] set, STIP is automatically visible to S-mode.
     * But MTIP comes from CLINT, not STIP. We need to disable MTIE and
     * set mtimecmp to max to clear MTIP, then set STIP manually. */

    /* Clear MTIP by setting mtimecmp to max */
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    sw      t1, 0(t0)
    sw      t1, 4(t0)

    /* Disable MTIE */
    li      t0, (1 << 7)
    csrc    mie, t0

    /* Set STIP (supervisor timer interrupt pending) in mip */
    li      t0, (1 << 5)
    csrs    mip, t0

    /* Return — the pending STIP will trap to S-mode after mret */
    mret

/* ════════════════════════════════════════════════════════════════
 * UTILITIES
 * ════════════════════════════════════════════════════════════════ */
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

pass:
    li      t0, TOHOST
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b

fail:
    la      a0, str_fail
    call    uart_puts
    li      t0, TOHOST
    li      t1, 2
    sw      t1, 0(t0)
1:  j       1b

/* ════════════════════════════════════════════════════════════════
 * DATA
 * ════════════════════════════════════════════════════════════════ */
.section .rodata
str_banner:        .asciz "=== priv_boot_timer test ===\n"
str_mmu_ok:        .asciz "MMU + PMP OK\n"
str_kernel_ok:     .asciz "Kernel S-mode OK\n"
str_timer_armed:   .asciz "Timer armed\n"
str_sret:          .asciz "SRET to U-mode (timer pending)\n"
str_got_timer:     .asciz "  S-mode timer interrupt!\n"
str_timer_handled: .asciz "Timer trap handled OK\n"
str_tp_bad:        .asciz "FAIL: tp after csrrw = "
str_expected:      .asciz " expected "
str_all_pass:      .asciz "ALL PASS\n"
str_fail:          .asciz "FAIL\n"
str_mtrap:         .asciz "M-trap cause="
str_strap:         .asciz "S-trap cause="
str_at:            .asciz " epc="
str_nl:            .asciz "\n"

.section .data
.align 4
test_state:        .word 0
trap_tp_value:     .word 0

.section .tohost
.globl tohost
tohost:            .word 0
