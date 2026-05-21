/*
 * portASM.S — ntiny RV32 S-mode FreeRTOS trap entry + first-task launcher.
 *
 * Frame layout (mirrored by pxPortInitialiseStack in port.c):
 *
 *   sp+0    x1  (ra)
 *   sp+4    x5  (t0)
 *   sp+8    x6  (t1)
 *   sp+12   x7  (t2)
 *   sp+16   x8  (s0)
 *   sp+20   x9  (s1)
 *   sp+24   x10 (a0)
 *   sp+28   x11 (a1)
 *   sp+32   x12 (a2)
 *   sp+36   x13 (a3)
 *   sp+40   x14 (a4)
 *   sp+44   x15 (a5)
 *   sp+48   x16 (a6)
 *   sp+52   x17 (a7)
 *   sp+56   x18 (s2)
 *   sp+60   x19 (s3)
 *   sp+64   x20 (s4)
 *   sp+68   x21 (s5)
 *   sp+72   x22 (s6)
 *   sp+76   x23 (s7)
 *   sp+80   x24 (s8)
 *   sp+84   x25 (s9)
 *   sp+88   x26 (s10)
 *   sp+92   x27 (s11)
 *   sp+96   x28 (t3)
 *   sp+100  x29 (t4)
 *   sp+104  x30 (t5)
 *   sp+108  x31 (t6)
 *   sp+112  sepc
 *   sp+116  sstatus
 *   sp+120  (pad)
 *   sp+124  (pad)
 *
 * 128 bytes (16-byte aligned). x4 (tp) and x3 (gp) are not saved/
 * restored — FreeRTOS tasks share gp and don't use tp.
 */

    .section .text.freertos_trap
    .align 4
    .global freertos_risc_v_trap_handler
    .type   freertos_risc_v_trap_handler, @function

freertos_risc_v_trap_handler:
    addi    sp, sp, -128

    sw      x1,   0(sp)
    sw      x5,   4(sp)
    sw      x6,   8(sp)
    sw      x7,  12(sp)
    sw      x8,  16(sp)
    sw      x9,  20(sp)
    sw      x10, 24(sp)
    sw      x11, 28(sp)
    sw      x12, 32(sp)
    sw      x13, 36(sp)
    sw      x14, 40(sp)
    sw      x15, 44(sp)
    sw      x16, 48(sp)
    sw      x17, 52(sp)
    sw      x18, 56(sp)
    sw      x19, 60(sp)
    sw      x20, 64(sp)
    sw      x21, 68(sp)
    sw      x22, 72(sp)
    sw      x23, 76(sp)
    sw      x24, 80(sp)
    sw      x25, 84(sp)
    sw      x26, 88(sp)
    sw      x27, 92(sp)
    sw      x28, 96(sp)
    sw      x29,100(sp)
    sw      x30,104(sp)
    sw      x31,108(sp)

    csrr    t0, sepc
    sw      t0, 112(sp)
    csrr    t0, sstatus
    sw      t0, 116(sp)

    /* pxCurrentTCB->pxTopOfStack = sp (pxTopOfStack lives at offset 0
     * of the TCB — FreeRTOS guarantees this layout). */
    la      t0, pxCurrentTCB
    lw      t1, 0(t0)
    sw      sp, 0(t1)

    /* Dispatch in C. Frees us from doing scause decode in asm. */
    call    freertos_trap_dispatch

    /* Reload sp from the (possibly new) pxCurrentTCB->pxTopOfStack. */
    la      t0, pxCurrentTCB
    lw      t1, 0(t0)
    lw      sp, 0(t1)

    lw      t0, 112(sp)
    csrw    sepc, t0
    lw      t0, 116(sp)
    csrw    sstatus, t0

    lw      x1,   0(sp)
    lw      x5,   4(sp)
    lw      x6,   8(sp)
    lw      x7,  12(sp)
    lw      x8,  16(sp)
    lw      x9,  20(sp)
    lw      x10, 24(sp)
    lw      x11, 28(sp)
    lw      x12, 32(sp)
    lw      x13, 36(sp)
    lw      x14, 40(sp)
    lw      x15, 44(sp)
    lw      x16, 48(sp)
    lw      x17, 52(sp)
    lw      x18, 56(sp)
    lw      x19, 60(sp)
    lw      x20, 64(sp)
    lw      x21, 68(sp)
    lw      x22, 72(sp)
    lw      x23, 76(sp)
    lw      x24, 80(sp)
    lw      x25, 84(sp)
    lw      x26, 88(sp)
    lw      x27, 92(sp)
    lw      x28, 96(sp)
    lw      x29,100(sp)
    lw      x30,104(sp)
    lw      x31,108(sp)

    addi    sp, sp, 128
    sret

    .size   freertos_risc_v_trap_handler, . - freertos_risc_v_trap_handler


/* xPortStartFirstTask — load the very first task's frame and sret.
 *
 * Same restore sequence as the trap handler tail; written out fully
 * so the asm reads top-to-bottom and so we don't need a jump into the
 * middle of the trap handler. */

    .section .text.start_first_task
    .align 4
    .global xPortStartFirstTask
    .type   xPortStartFirstTask, @function

xPortStartFirstTask:
    la      t0, pxCurrentTCB
    lw      t1, 0(t0)
    lw      sp, 0(t1)

    lw      t0, 112(sp)
    csrw    sepc, t0
    lw      t0, 116(sp)
    csrw    sstatus, t0

    lw      x1,   0(sp)
    lw      x5,   4(sp)
    lw      x6,   8(sp)
    lw      x7,  12(sp)
    lw      x8,  16(sp)
    lw      x9,  20(sp)
    lw      x10, 24(sp)
    lw      x11, 28(sp)
    lw      x12, 32(sp)
    lw      x13, 36(sp)
    lw      x14, 40(sp)
    lw      x15, 44(sp)
    lw      x16, 48(sp)
    lw      x17, 52(sp)
    lw      x18, 56(sp)
    lw      x19, 60(sp)
    lw      x20, 64(sp)
    lw      x21, 68(sp)
    lw      x22, 72(sp)
    lw      x23, 76(sp)
    lw      x24, 80(sp)
    lw      x25, 84(sp)
    lw      x26, 88(sp)
    lw      x27, 92(sp)
    lw      x28, 96(sp)
    lw      x29,100(sp)
    lw      x30,104(sp)
    lw      x31,108(sp)

    addi    sp, sp, 128
    sret

    .size   xPortStartFirstTask, . - xPortStartFirstTask
