/*
    FreeRTOS Port Adapted for RISC-V S-Mode running over OpenSBI.
    Updated for ntiny hardware configuration.
*/

#if __riscv_xlen == 64
# define STORE    sd
# define LOAD     ld
# define REGBYTES 8
#else
# define STORE    sw
# define LOAD     lw
# define REGBYTES 4
#endif

/* 
 * S-Mode status configuration mask:
 * Bit 5 (SPIE): Supervisor Previous Interrupt Enable = 1
 * Bit 8 (SPP):  Supervisor Previous Privilege Mode  = 1 (Return to S-mode)
 * 0x0120 enforces that when sret executes, the CPU stays in S-mode with interrupts on.
 */
#define SSTATUS_S_MODE_PRV 0x0120

.global portSAVE_CONTEXT
.global portRESTORE_CONTEXT
.global xPortStartScheduler
.global vPortYield
.global vTaskIncrementTick
.global vPortEndScheduler
.global xExitStack

/* Register table entry points matching your new vector table layout */
.global freertos_risc_v_exception_handler
.global freertos_risc_v_interrupt_handler
.global freertos_risc_v_mtimer_interrupt_handler

/* External symbols inside the C runtime */
.extern vPortSysTickHandler
.extern vPortSetupTimer
.extern vTaskSwitchContext
.extern external_interrupt_dispatcher


/* Macro for saving task context */
.macro portSAVE_CONTEXT
    .global pxCurrentTCB
    /* Allocate one 32-slot frame on the task stack. Slot layout:
     *   0  : x1  (ra)
     *   1  : x2  (sp before frame was allocated) — informational, restored via addi
     *   2-30: x3-x31
     *   31 : sepc (written by portSAVE_EPC / portSAVE_RA)
     */
    addi    sp, sp, -REGBYTES * 32

    STORE    x1, 0 * REGBYTES(sp)
    /* Record the SP value as it was on trap entry (before the addi above) */
    addi    t0, sp, REGBYTES * 32
    STORE    t0, 1 * REGBYTES(sp)
    STORE    x3, 2 * REGBYTES(sp)
    STORE    x4, 3 * REGBYTES(sp)
    STORE    x5, 4 * REGBYTES(sp)
    STORE    x6, 5 * REGBYTES(sp)
    STORE    x7, 6 * REGBYTES(sp)
    STORE    x8, 7 * REGBYTES(sp)
    STORE    x9, 8 * REGBYTES(sp)
    STORE    x10, 9 * REGBYTES(sp)
    STORE    x11, 10 * REGBYTES(sp)
    STORE    x12, 11 * REGBYTES(sp)
    STORE    x13, 12 * REGBYTES(sp)
    STORE    x14, 13 * REGBYTES(sp)
    STORE    x15, 14 * REGBYTES(sp)
    STORE    x16, 15 * REGBYTES(sp)
    STORE    x17, 16 * REGBYTES(sp)
    STORE    x18, 17 * REGBYTES(sp)
    STORE    x19, 18 * REGBYTES(sp)
    STORE    x20, 19 * REGBYTES(sp)
    STORE    x21, 20 * REGBYTES(sp)
    STORE    x22, 21 * REGBYTES(sp)
    STORE    x23, 22 * REGBYTES(sp)
    STORE    x24, 23 * REGBYTES(sp)
    STORE    x25, 24 * REGBYTES(sp)
    STORE    x26, 25 * REGBYTES(sp)
    STORE    x27, 26 * REGBYTES(sp)
    STORE    x28, 27 * REGBYTES(sp)
    STORE    x29, 28 * REGBYTES(sp)
    STORE    x30, 29 * REGBYTES(sp)
    STORE    x31, 30 * REGBYTES(sp)
    
    /* Store current stackpointer in task control block (TCB) */
    LOAD    t0, pxCurrentTCB    //pointer
    STORE   sp, 0x0(t0)
.endm

/* Saves current supervisor error program counter (sepc) as task program counter */
.macro portSAVE_EPC
    csrr    t0, sepc
    STORE    t0, 31 * REGBYTES(sp)
.endm

/* Saves current return address (RA) as task program counter */
.macro portSAVE_RA
    STORE    ra, 31 * REGBYTES(sp)
.endm

/* Macro for restoring task context */
.macro portRESTORE_CONTEXT
    .global pxCurrentTCB
    /* Load stack pointer from the current TCB */
    LOAD    sp, pxCurrentTCB
    LOAD    sp, 0x0(sp)

    /* Load task program counter and write to sepc */
    LOAD    t0, 31 * REGBYTES(sp)
    csrw    sepc, t0

    /* Enforce Supervisor privilege return parameters */
    li      t0, SSTATUS_S_MODE_PRV
    csrs    sstatus, t0

    /* Restore registers. x2 (sp) is recomputed via the addi below. */
    LOAD    x1, 0 * REGBYTES(sp)
    LOAD    x3, 2 * REGBYTES(sp)
    LOAD    x4, 3 * REGBYTES(sp)
    LOAD    x5, 4 * REGBYTES(sp)
    LOAD    x6, 5 * REGBYTES(sp)
    LOAD    x7, 6 * REGBYTES(sp)
    LOAD    x8, 7 * REGBYTES(sp)
    LOAD    x9, 8 * REGBYTES(sp)
    LOAD    x10, 9 * REGBYTES(sp)
    LOAD    x11, 10 * REGBYTES(sp)
    LOAD    x12, 11 * REGBYTES(sp)
    LOAD    x13, 12 * REGBYTES(sp)
    LOAD    x14, 13 * REGBYTES(sp)
    LOAD    x15, 14 * REGBYTES(sp)
    LOAD    x16, 15 * REGBYTES(sp)
    LOAD    x17, 16 * REGBYTES(sp)
    LOAD    x18, 17 * REGBYTES(sp)
    LOAD    x19, 18 * REGBYTES(sp)
    LOAD    x20, 19 * REGBYTES(sp)
    LOAD    x21, 20 * REGBYTES(sp)
    LOAD    x22, 21 * REGBYTES(sp)
    LOAD    x23, 22 * REGBYTES(sp)
    LOAD    x24, 23 * REGBYTES(sp)
    LOAD    x25, 24 * REGBYTES(sp)
    LOAD    x26, 25 * REGBYTES(sp)
    LOAD    x27, 26 * REGBYTES(sp)
    LOAD    x28, 27 * REGBYTES(sp)
    LOAD    x29, 28 * REGBYTES(sp)
    LOAD    x30, 29 * REGBYTES(sp)
    LOAD    x31, 30 * REGBYTES(sp)

    addi    sp, sp, REGBYTES * 32
    sret
.endm

/* ========================================================================
 * FreeRTOS Vector Table Trap Handlers
 * ======================================================================== */

/* 1. Supervisor Timer Interrupt Handler (Sstc Tick Engine) */
freertos_risc_v_mtimer_interrupt_handler:
    portSAVE_CONTEXT
    portSAVE_EPC
    jal    vPortSysTickHandler
    portRESTORE_CONTEXT

/* 2. Supervisor External and Software Interrupt Dispatcher */
freertos_risc_v_interrupt_handler:
    portSAVE_CONTEXT
    portSAVE_EPC
    csrr    a0, scause
    jal     external_interrupt_dispatcher
    portRESTORE_CONTEXT

/* 3. Hardware Core Exception / Panic Trapping */
freertos_risc_v_exception_handler:
    la      sp, _stack_top
    csrr    a0, scause
    csrr    a1, sepc
    csrr    a2, stval
    mv      a3, s0         /* Pass current Frame Pointer (s0) to a3 */
    jal     exception_panic

/* ========================================================================
 * Scheduler Lifecycle Controls
 * ======================================================================== */

xPortStartScheduler:
#ifdef __gracefulExit
    la        t0, xStartContext
    STORE    x1, 0x0(t0)
    STORE    x2, 1 * REGBYTES(t0)
    STORE    x3, 2 * REGBYTES(t0)
    STORE    x4, 3 * REGBYTES(t0)
    STORE    x5, 4 * REGBYTES(t0)
    STORE    x6, 5 * REGBYTES(t0)
    STORE    x7, 6 * REGBYTES(t0)
    STORE    x8, 7 * REGBYTES(t0)
    STORE    x9, 8 * REGBYTES(t0)
    STORE    x10, 9 * REGBYTES(t0)
    STORE    x11, 10 * REGBYTES(t0)
    STORE    x12, 11 * REGBYTES(t0)
    STORE    x13, 12 * REGBYTES(t0)
    STORE    x14, 13 * REGBYTES(t0)
    STORE    x15, 14 * REGBYTES(t0)
    STORE    x16, 15 * REGBYTES(t0)
    STORE    x17, 16 * REGBYTES(t0)
    STORE    x18, 17 * REGBYTES(t0)
    STORE    x19, 18 * REGBYTES(t0)
    STORE    x20, 19 * REGBYTES(t0)
    STORE    x21, 20 * REGBYTES(t0)
    STORE    x22, 21 * REGBYTES(t0)
    STORE    x23, 22 * REGBYTES(t0)
    STORE    x24, 23 * REGBYTES(t0)
    STORE    x25, 24 * REGBYTES(t0)
    STORE    x26, 25 * REGBYTES(t0)
    STORE    x27, 26 * REGBYTES(t0)
    STORE    x28, 27 * REGBYTES(t0)
    STORE    x29, 28 * REGBYTES(t0)
    STORE    x30, 29 * REGBYTES(t0)
    STORE    x31, 30 * REGBYTES(t0)
#endif
    jal        vPortSetupTimer
    portRESTORE_CONTEXT

vPortEndScheduler:
#ifdef __gracefulExit
    la        t0, xStartContext
    LOAD    x1, 0x0(t0)
    LOAD    x2, 1 * REGBYTES(t0)
    LOAD    x3, 2 * REGBYTES(t0)
    LOAD    x4, 3 * REGBYTES(t0)
    LOAD    x5, 4 * REGBYTES(t0)
    LOAD    x6, 5 * REGBYTES(t0)
    LOAD    x7, 6 * REGBYTES(t0)
    LOAD    x8, 7 * REGBYTES(t0)
    LOAD    x9, 8 * REGBYTES(t0)
    LOAD    x10, 9 * REGBYTES(t0)
    LOAD    x11, 10 * REGBYTES(t0)
    LOAD    x12, 11 * REGBYTES(t0)
    LOAD    x13, 12 * REGBYTES(t0)
    LOAD    x14, 13 * REGBYTES(t0)
    LOAD    x15, 14 * REGBYTES(t0)
    LOAD    x16, 15 * REGBYTES(t0)
    LOAD    x17, 16 * REGBYTES(t0)
    LOAD    x18, 17 * REGBYTES(t0)
    LOAD    x19, 18 * REGBYTES(t0)
    LOAD    x20, 19 * REGBYTES(t0)
    LOAD    x21, 20 * REGBYTES(t0)
    LOAD    x22, 21 * REGBYTES(t0)
    LOAD    x23, 22 * REGBYTES(t0)
    LOAD    x24, 23 * REGBYTES(t0)
    LOAD    x25, 24 * REGBYTES(t0)
    LOAD    x26, 25 * REGBYTES(t0)
    LOAD    x27, 26 * REGBYTES(t0)
    LOAD    x28, 27 * REGBYTES(t0)
    LOAD    x29, 28 * REGBYTES(t0)
    LOAD    x30, 29 * REGBYTES(t0)
    LOAD    x31, 30 * REGBYTES(t0)
#endif
    ret

/* Manual Thread Context Yielding Trigger */
vPortYield:
    /* 
     * Clear SIE (Supervisor Interrupt Enable, bit 1) in sstatus 
     * to safely modify context without nested asynchronous race states.
     */
    csrci    sstatus, 2

    portSAVE_CONTEXT
    portSAVE_RA
    jal      vTaskSwitchContext
    portRESTORE_CONTEXT