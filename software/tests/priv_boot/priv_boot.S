/*
 * priv_boot.S — Mini-OS boot test mimicking Linux on ntiny
 *
 * Simulates the actual Linux boot sequence that crashes:
 *   OpenSBI (M-mode) → Kernel (S-mode, Sv32) → init (U-mode)
 *   → syscall → page fault → context switch → repeat
 *
 * Specifically targets the _save_context crash scenario:
 *   - U-mode process runs, traps to S-mode
 *   - S-mode handler saves context to kernel stack
 *   - Page tables modified (mmap/munmap simulation)
 *   - SFENCE.VMA, TLB refill under new mapping
 *   - Return to U-mode
 *
 * Memory layout (physical, 32KB at 0x80000000):
 *   0x80000000 - 0x80003FFF : M/S-mode code + data (16KB)
 *   0x80004000 - 0x80004FFF : L1 page table
 *   0x80005000 - 0x80005FFF : L0 page table for kernel (VPN1=0x300)
 *   0x80006000 - 0x80006FFF : L0 page table for user (VPN1=0x000)
 *   0x80007000 - 0x80007FFF : U-mode code/data page
 *
 * Virtual memory map (mimics Linux):
 *   0xC0000000+ : S-mode kernel (megapage identity-ish map)
 *   0x00006000  : U-mode code page
 *   0x00007000  : U-mode data page (mapped/unmapped for mmap test)
 */

.section .text.init
.globl _init

/* ── Hardware ───────────────────────────────────────────────── */
.equ UART_TX,        0x10000004
.equ CLINT_MTIMECMP, 0x02004000
.equ CLINT_MTIME,    0x0200BFF8
.equ TOHOST,         0x0F000000

/* ── Physical layout ────────────────────────────────────────── */
.equ PT_L1,          0x80004000
.equ PT_L0_KERN,     0x80005000   /* L0 for kernel VPN1=0x300 */
.equ PT_L0_USER,     0x80006000   /* L0 for user VPN1=0x000 */
.equ UCODE_PAGE,     0x80007000   /* U-mode code+data */
.equ STACK_TOP,      0x80008000

/* ── Virtual addresses ──────────────────────────────────────── */
.equ KERN_VBASE,     0xC0000000   /* kernel megapage base (like Linux) */
.equ USER_CODE_VA,   0x00006000   /* user code VA */
.equ USER_DATA_VA,   0x00007000   /* user data VA (mmap target) */

/* ── PTE flags ──────────────────────────────────────────────── */
.equ PTE_V,    0x001
.equ PTE_R,    0x002
.equ PTE_W,    0x004
.equ PTE_X,    0x008
.equ PTE_U,    0x010
.equ PTE_A,    0x040
.equ PTE_D,    0x080
.equ PTE_LEAF, (PTE_R|PTE_W|PTE_X|PTE_V|PTE_A|PTE_D)  /* S-mode RWX leaf */
.equ PTE_ULEAF,(PTE_U|PTE_LEAF)                         /* U-mode RWX leaf */

/* ════════════════════════════════════════════════════════════════
 * PHASE 1: OpenSBI-like M-mode init
 * ════════════════════════════════════════════════════════════════ */
_init:
    li      sp, STACK_TOP

    /* Print banner */
    la      a0, str_banner
    call    uart_puts

    /* ── PMP: grant S/U full access (like OpenSBI sbi_hart_pmp_init) ── */
    li      t0, 0x3FFFFFFF      /* NAPOT all 4GB */
    csrw    pmpaddr0, t0
    li      t1, 0x1F            /* A=NAPOT, RWX */
    csrw    pmpcfg0, t1
    /* Verify readback */
    csrr    t1, pmpaddr0
    bne     t0, t1, fail_pmp_readback

    la      a0, str_pmp_ok
    call    uart_puts

    /* ── Build page tables (like Linux setup_vm) ──────────────── */
    /* Clear all page tables */
    li      a0, PT_L1
    li      a1, 0x3000          /* 3 pages */
    call    memzero

    /*
     * L1[0x300] = megapage: VA 0xC0000000 → PA 0x80000000 (kernel, S-mode)
     * VPN1 = 0xC0000000 >> 22 = 0x300
     * PTE  = (0x80000000 >> 12) << 10 | flags = 0x20000000 | PTE_LEAF
     */
    li      t0, PT_L1 + (0x300 * 4)
    li      t2, (0x20000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /*
     * L1[0x200] = megapage: VA 0x80000000 → PA 0x80000000 (early identity)
     * Needed so MRET target (physical addr) works before kernel relocates
     */
    li      t0, PT_L1 + (0x200 * 4)
    li      t2, (0x20000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /*
     * L1[0x040] = megapage: VA 0x10000000 → PA 0x10000000 (I/O peripherals)
     * VPN1 = 0x10000000 >> 22 = 0x040
     * PTE = (0x10000000 >> 12) << 10 | PTE_LEAF (no U bit — S-mode only)
     */
    li      t0, PT_L1 + (0x040 * 4)
    li      t2, (0x04000 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /*
     * L1[0x008] = megapage: VA 0x02000000 → PA 0x02000000 (CLINT)
     * VPN1 = 0x02000000 >> 22 = 0x008
     */
    li      t0, PT_L1 + (0x008 * 4)
    li      t2, (0x00800 << 10) | PTE_LEAF
    sw      t2, 0(t0)

    /*
     * L1[0x000] = pointer to L0_USER (for VA 0x00000000-0x003FFFFF)
     */
    li      t0, PT_L1
    li      t2, (PT_L0_USER >> 12) << 10 | PTE_V
    sw      t2, 0(t0)

    /*
     * L0_USER[0x006] = U-mode code: VA 0x6000 → PA UCODE_PAGE
     * L0_USER[0x007] = U-mode data: VA 0x7000 → PA UCODE_PAGE+0x1000
     *   (initially NOT mapped — will be demand-paged)
     */
    li      t0, PT_L0_USER + (0x006 * 4)
    li      t2, (UCODE_PAGE >> 12) << 10 | PTE_ULEAF
    sw      t2, 0(t0)
    /* L0_USER[0x007] intentionally left unmapped (PTE=0) */

    /* ── Install U-mode test program at UCODE_PAGE ────────────── */
    /*
     * U-mode program (mimics busybox init):
     *   0x6000: li a7, 222          # __NR_mmap (syscall number)
     *   0x6004: li a0, 0x7000       # addr = USER_DATA_VA
     *   0x6008: ecall               # syscall → S-mode
     *   0x600C: lw a0, 0(a0)        # access the mmap'd page
     *   0x6010: li a7, 215          # __NR_munmap
     *   0x6014: ecall               # syscall → S-mode
     *   0x6018: li a7, 93           # __NR_exit
     *   0x601C: ecall               # exit
     */
    li      t0, UCODE_PAGE
    li      t1, 0x0de00893      /* li a7, 222 (mmap) */
    sw      t1, 0(t0)
    li      t1, 0x00007537      /* lui a0, 7 (a0 = 0x7000) */
    sw      t1, 4(t0)
    li      t1, 0x00000073      /* ecall */
    sw      t1, 8(t0)
    li      t1, 0x00052503      /* lw a0, 0(a0) */
    sw      t1, 12(t0)
    li      t1, 0x0d700893      /* li a7, 215 (munmap) */
    sw      t1, 16(t0)
    li      t1, 0x00000073      /* ecall */
    sw      t1, 20(t0)
    li      t1, 0x05d00893      /* li a7, 93 (exit) */
    sw      t1, 24(t0)
    li      t1, 0x00000073      /* ecall */
    sw      t1, 28(t0)

    /* Write test data at UCODE_PAGE + 0x1000 (the mmap'd data page) */
    li      t0, UCODE_PAGE + 0x1000
    li      t1, 0xDEADBEEF
    sw      t1, 0(t0)

    la      a0, str_pt_ok
    call    uart_puts

    /* ── Trap delegation (like OpenSBI sbi_hart_switch_mode) ──── */
    la      t0, m_trap_vec
    csrw    mtvec, t0

    /* Set stvec to physical address — identity map still active during early boot.
     * kernel_main will update to virtual address after dropping identity map. */
    la      t0, s_trap_vec
    csrw    stvec, t0

    /* medeleg: delegate ecall-from-U(8), page faults(12,13,15) to S-mode */
    li      t0, (1<<8) | (1<<12) | (1<<13) | (1<<15)
    csrw    medeleg, t0
    /* mideleg: delegate SSIP(1), STIP(5), SEIP(9) to S-mode */
    li      t0, 0x222
    csrw    mideleg, t0

    li      t0, -1
    csrw    mcounteren, t0
    csrw    scounteren, t0

    /* Set sscratch = physical kernel stack (for early S-mode traps) */
    csrw    sscratch, sp

    /* ── Enable Sv32 MMU ──────────────────────────────────────── */
    li      t0, (1 << 31) | (PT_L1 >> 12)
    csrw    satp, t0
    sfence.vma

    la      a0, str_mmu_ok
    call    uart_puts

    /* ── MRET to S-mode (like OpenSBI → Linux kernel entry) ──── */
    /* MPP = S-mode, MPIE = 0 */
    li      t0, (1 << 11)
    csrw    mstatus, t0

    /* Jump to kernel_main at its VIRTUAL address (0xC0000000 + offset) */
    la      t0, kernel_main
    li      t1, KERN_VBASE
    li      t2, 0x80000000
    sub     t0, t0, t2          /* physical offset from 0x80000000 */
    add     t0, t0, t1          /* virtual = 0xC0000000 + offset */
    csrw    mepc, t0
    mret

/* ════════════════════════════════════════════════════════════════
 * PHASE 2: Linux kernel (S-mode, virtual addresses via Sv32)
 * ════════════════════════════════════════════════════════════════ */
kernel_main:
    /* Set stvec to virtual address (we're now in S-mode with MMU) */
    la      t0, s_trap_vec
    csrw    stvec, t0

    /* Relocate stack to kernel virtual address space */
    /* sp = 0x80008000 (physical) → 0xC0008000 (virtual, via megapage) */
    li      t0, (KERN_VBASE - 0x80000000)
    add     sp, sp, t0          /* sp = 0xC0008000 */

    /* Set sscratch = kernel stack pointer (for U→S trap swap) */
    csrw    sscratch, sp

    la      a0, str_kernel
    call    uart_puts

    /* Drop identity map (L1[0x200]) — kernel only uses 0xC0000000+ now */
    /* This mimics Linux's setup_vm_final which removes the early mapping */
    li      t0, PT_L1 + (0x200 * 4)
    sw      zero, 0(t0)
    sfence.vma

    /* ── Set SUM so S-mode can access U-mode pages ────────────── */
    li      t0, (1 << 18)       /* SUM bit */
    csrs    sstatus, t0

    /* ── Prepare kernel context save area (like Linux thread_info) ── */
    la      t0, kstack_ctx
    sw      sp, 0(t0)           /* save SP */
    sw      ra, 4(t0)           /* save RA */

    /* ── Switch to U-mode (like Linux ret_from_fork → sret) ──── */
    la      a0, str_sret_umode
    call    uart_puts

    /* SPP = U-mode (0), SPIE = 1 */
    csrr    t0, sstatus
    li      t1, ~(1 << 8)       /* clear SPP */
    and     t0, t0, t1
    li      t1, (1 << 5)        /* set SPIE */
    or      t0, t0, t1
    csrw    sstatus, t0

    li      t0, USER_CODE_VA
    csrw    sepc, t0
    sret

/* ── Return here after U-mode exit syscall ──────────────────── */
.globl kernel_resume
kernel_resume:
    /* Restore kernel SP */
    la      t0, kstack_ctx
    lw      sp, 0(t0)
    lw      ra, 4(t0)

    la      a0, str_all_pass
    call    uart_puts

    /* Exit via tohost */
    li      t0, TOHOST
    li      t1, 1
    sw      t1, 0(t0)
1:  j       1b

/* ════════════════════════════════════════════════════════════════
 * S-MODE TRAP HANDLER (mimics Linux _save_context + do_trap)
 * This is the code path that crashes on real Linux
 * ════════════════════════════════════════════════════════════════ */
.align 4
s_trap_vec:
    /* ── _save_context equivalent ───────────────────────────── */
    /* Swap sp with sscratch (user sp → sscratch, kernel sp → sp) */
    csrrw   sp, sscratch, sp

    /* If sp == 0, we came from S-mode (no sscratch set up) */
    bnez    sp, 1f
    csrr    sp, sscratch        /* restore sp, use kernel stack */
1:
    /* Save context on kernel stack (like Linux pt_regs) */
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a7, 24(sp)
    /* Save sepc, scause, stval */
    csrr    t0, sepc
    sw      t0, 28(sp)
    csrr    t0, scause
    sw      t0, 32(sp)
    csrr    t0, stval
    sw      t0, 36(sp)
    /* Save user sp from sscratch */
    csrr    t0, sscratch
    sw      t0, 40(sp)

    /* ── Dispatch trap cause ────────────────────────────────── */
    lw      t0, 32(sp)          /* scause */

    li      t1, 8               /* ecall from U-mode */
    beq     t0, t1, handle_ecall

    li      t1, 13              /* load page fault */
    beq     t0, t1, handle_pgfault

    li      t1, 15              /* store page fault */
    beq     t0, t1, handle_pgfault

/* ── Handle page fault (like Linux do_page_fault → mmap install) */
handle_pgfault:
    /* Check if faulting address is USER_DATA_VA (0x7000) */
    lw      t0, 36(sp)          /* stval = faulting VA */
    li      t1, USER_DATA_VA
    srli    t0, t0, 12          /* page number */
    srli    t1, t1, 12
    bne     t0, t1, pgfault_unexpected

    /* Map the page: install PTE at L0_USER[0x007] */
    la      a0, str_pgfault
    call    uart_puts
    li      t0, PT_L0_USER + (0x007 * 4)
    li      t2, ((UCODE_PAGE + 0x1000) >> 12) << 10 | PTE_ULEAF
    sw      t2, 0(t0)
    sfence.vma
    /* Return to the faulting instruction (retry the access) */
    j       trap_sret

pgfault_unexpected:
    /* Unknown trap — print and fail */
    la      a0, str_strap
    call    uart_puts
    lw      a0, 32(sp)          /* scause */
    call    uart_puthex
    la      a0, str_at
    call    uart_puts
    lw      a0, 28(sp)          /* sepc */
    call    uart_puthex
    la      a0, str_badaddr
    call    uart_puts
    lw      a0, 36(sp)          /* stval */
    call    uart_puthex
    la      a0, str_nl
    call    uart_puts
    j       fail

/* ── Handle ecall (like Linux sys_mmap / sys_munmap / sys_exit) */
handle_ecall:
    lw      a7, 24(sp)          /* syscall number */
    lw      a0, 16(sp)          /* arg0 */

    li      t0, 222             /* __NR_mmap */
    beq     a7, t0, do_mmap

    li      t0, 215             /* __NR_munmap */
    beq     a7, t0, do_munmap

    li      t0, 93              /* __NR_exit */
    beq     a7, t0, do_exit

    /* Unknown syscall */
    j       trap_return

/* ── do_mmap: map USER_DATA_VA → physical page ──────────────── */
do_mmap:
    la      a0, str_mmap
    call    uart_puts

    /* Install PTE for USER_DATA_VA (L0_USER[0x007]) */
    li      t0, PT_L0_USER + (0x007 * 4)
    li      t2, ((UCODE_PAGE + 0x1000) >> 12) << 10 | PTE_ULEAF
    sw      t2, 0(t0)
    sfence.vma
    j       trap_return

/* ── do_munmap: unmap USER_DATA_VA ──────────────────────────── */
do_munmap:
    la      a0, str_munmap
    call    uart_puts

    /* Clear PTE for USER_DATA_VA */
    li      t0, PT_L0_USER + (0x007 * 4)
    sw      zero, 0(t0)
    sfence.vma
    j       trap_return

/* ── do_exit: return to kernel ──────────────────────────────── */
do_exit:
    la      a0, str_exit
    call    uart_puts

    /* Restore kernel context and jump to kernel_resume */
    la      t0, kernel_resume
    /* Convert to virtual: offset from 0x80000000 + 0xC0000000 */
    li      t1, KERN_VBASE
    li      t2, 0x80000000
    sub     t0, t0, t2
    add     t0, t0, t1
    csrw    sepc, t0
    /* SPP = S-mode */
    li      t0, (1 << 8)
    csrs    sstatus, t0
    /* Restore sp to kernel stack */
    addi    sp, sp, 64
    j       trap_sret

/* ── Common trap return to U-mode ───────────────────────────── */
trap_return:
    /* Advance sepc past ecall (4 bytes) */
    lw      t0, 28(sp)
    addi    t0, t0, 4
    csrw    sepc, t0

trap_sret:
    /* ── _restore_context equivalent ────────────────────────── */
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a7, 24(sp)
    /* Restore user sp */
    lw      t0, 40(sp)
    addi    sp, sp, 64
    csrw    sscratch, sp        /* save kernel sp */
    mv      sp, t0              /* restore user sp */
    sret

/* ════════════════════════════════════════════════════════════════
 * M-MODE TRAP HANDLER
 * ════════════════════════════════════════════════════════════════ */
.align 4
m_trap_vec:
    csrr    t0, mcause
    li      t1, 0x80000007      /* M-mode timer interrupt */
    beq     t0, t1, m_timer_irq

    /* Other M-mode trap: print and fail */
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

m_timer_irq:
    /* Disable MTIE, set max timecmp */
    li      t0, (1 << 7)
    csrc    mie, t0
    li      t0, CLINT_MTIMECMP
    li      t1, -1
    sw      t1, 0(t0)
    sw      t1, 4(t0)
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

fail:
    la      a0, str_fail
    call    uart_puts
    li      t0, TOHOST
    li      t1, 2
    sw      t1, 0(t0)
1:  j       1b

fail_pmp_readback:
    la      a0, str_pmp_fail
    call    uart_puts
    j       fail

/* ════════════════════════════════════════════════════════════════
 * DATA
 * ════════════════════════════════════════════════════════════════ */
.section .rodata
str_banner:     .asciz "=== ntiny priv_boot test ===\n"
str_pmp_ok:     .asciz "PMP config OK\n"
str_pmp_fail:   .asciz "PMP readback FAIL\n"
str_pt_ok:      .asciz "Page tables OK\n"
str_mmu_ok:     .asciz "MMU enabled (Sv32)\n"
str_kernel:     .asciz "Kernel S-mode OK\n"
str_sret_umode: .asciz "SRET to U-mode\n"
str_mmap:       .asciz "  sys_mmap: mapping page\n"
str_munmap:     .asciz "  sys_munmap: unmapping page\n"
str_exit:       .asciz "  sys_exit: returning to kernel\n"
str_pgfault:    .asciz "  page fault: demand-mapping page\n"
str_all_pass:   .asciz "ALL PASS\n"
str_fail:       .asciz "FAIL\n"
str_mtrap:      .asciz "M-trap cause="
str_strap:      .asciz "S-trap cause="
str_at:         .asciz " epc="
str_badaddr:    .asciz " badaddr="
str_nl:         .asciz "\n"

.section .data
.align 4
kstack_ctx:     .word 0, 0      /* saved SP, RA */

.section .tohost
.globl tohost
tohost:         .word 0
