#include "init.h"
#include "csr.h"
#include "gpio.h"
#include "uart.h"
#include <stddef.h>

int main(void);

/* Bare-metal libc subset. With -nostdlib we don't link glibc; FreeRTOS and
 * compiler-emitted block ops still expect these symbols. */
void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--) { *d++ = (unsigned char)c; }
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--) { *d++ = *s++; }
    return dst;
}

/* S-Mode Interrupt Enable/Disable (Bit 1 of sstatus is SIE) */
void int_disable(void) {
    csr_clear(sstatus, (1 << 1));
}

void int_enable(void) {
    csr_set(sstatus, (1 << 1));
}

/* External declarations for the FreeRTOS trap assembly handlers */
extern void freertos_risc_v_exception_handler(void);
extern void freertos_risc_v_interrupt_handler(void);
extern void freertos_risc_v_mtimer_interrupt_handler(void);

/* ========================================================================
 * FreeRTOS S-Mode Vectored Exception Table
 * ======================================================================== */
__asm__ (
".section .init_vector_table, \"ax\", @progbits\n"
".balign 128\n"
".option norvc\n"
".global freertos_vector_table\n"
"freertos_vector_table:\n"
"    j freertos_risc_v_exception_handler\n"  /* IRQ 0: Instruction Address Misaligned / Exceptions */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 1: Supervisor Software Interrupt */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 2: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 3: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 4: Reserved */
"    j freertos_risc_v_mtimer_interrupt_handler\n" /* IRQ 5 is Supervisor Timer (Sstc FreeRTOS Tick) */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 6: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 7: Machine Timer (Disabled in S-mode) */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 8: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 9: Supervisor External Interrupt (PLIC) */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 10: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 11: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 12: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 13: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 14: Reserved */
"    j freertos_risc_v_interrupt_handler\n"  /* IRQ 15: Reserved */
/* Local interrupts padding (matching your original assembly string block) */
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
"    j freertos_risc_v_interrupt_handler\n" "j freertos_risc_v_interrupt_handler\n"
);

/* ========================================================================
 * Boot Initialization Sequence 
 * ======================================================================== */

 /* A standard C function. The compiler knows the stack is safe to use here. */
void c_startup(void) 
{
    uart_puts("[OPENSBI] Hardware environment initialized.\r\n");
    uart_puts("[OPENSBI] Booting FreeRTOS Main...\r\n");
    
    main();

    /* Safe fallback wrapper execution loop */
    while(1) {
        __asm__ volatile("nop");
    }
}

/* The naked entry point. Only inline assembly is safe here! */
__attribute__((section (".RESET_HANDLER"), naked))
void RESET_HANDLER()
{
    __asm__ volatile (
        /* 1. Configure stvec to point to the FreeRTOS vector table */
        "la t0, freertos_vector_table\n"
        "ori t0, t0, 1\n"
        "csrw stvec, t0\n"

        /* 2. Enable Floating Point Unit context windows (sstatus.FS = 01) */
        "li t0, (1 << 13)\n"
        "csrs sstatus, t0\n"

        /* 3. Set up global pointer */
        ".option push\n"
        ".option norelax\n"
        "la gp, __global_pointer$\n"
        ".option pop\n"
        
        /* 4. Set up stack and frame pointer safely */
        "la sp, _stack_top\n"
        "mv s0, sp\n"

        /* 5. Clear the BSS Region entirely in assembly to avoid C-variable corruption */
        "la t0, _bss_start\n"
        "la t1, _bss_end\n"
        "bge t0, t1, bss_done\n"
        "bss_loop:\n"
        "sw zero, 0(t0)\n"
        "addi t0, t0, 4\n"
        "blt t0, t1, bss_loop\n"
        "bss_done:\n"

        /* 6. Jump into the safe C environment */
        "call c_startup\n"
    );
}

/* This section sits directly at 0x80400000. OpenSBI jumps here. */
__attribute__((section (".init"), naked))
void _init(){
    __asm__ volatile("j RESET_HANDLER");
}