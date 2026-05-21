/*
 * boot.S — S-mode entry point for ntiny FreeRTOS.
 *
 * OpenSBI hands control here with:
 *   a0 = hartid (always 0 on ntiny — single hart)
 *   a1 = fdt pointer (ignored; we have no DT consumer)
 *   priv mode = S-mode
 *
 * Job:
 *   - point stvec at the trap handler so any fault is visible
 *   - set up an initial stack inside .bss
 *   - clear .bss
 *   - call main()
 *   - park if main returns
 */

    .section .text.entry
    .global _start
    .type   _start, @function

_start:
    /* Install the trap handler. stvec.MODE=0 (direct), BASE=&handler.
     * Handler is 4-byte aligned (see .align 4 in portASM.S) so the low
     * two bits are 0 and MODE=0 falls out naturally. */
    la      t0, freertos_risc_v_trap_handler
    csrw    stvec, t0

    /* Mask all S-mode interrupts until xPortStartScheduler() arms them. */
    csrw    sie, zero
    csrci   sstatus, 2          /* SIE = 0 */

    /* Stack at top of .bss-reserved region. _stack_top is a linker symbol. */
    la      sp, _stack_top

    /* Zero .bss. */
    la      t0, _bss_start
    la      t1, _bss_end
1:  beq     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:

    /* main() should call vTaskStartScheduler() and never return. */
    call    main

    /* Park if it does. */
3:  wfi
    j       3b

    .size   _start, . - _start
