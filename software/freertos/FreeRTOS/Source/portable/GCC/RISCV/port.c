/*
    FreeRTOS Port Adapted for RISC-V S-Mode running over OpenSBI.
    Updated for ntiny hardware configuration with Sstc extension support.
*/

/* Scheduler includes. */
#include "FreeRTOS.h"
#include "task.h"
#include "portmacro.h"
#include "FreeRTOSConfig.h"

#ifdef __gracefulExit
BaseType_t xStartContext[31] = {0};
#endif

/* External and internal prototypes */
void vPortSysTickHandler( void );
void vPortSetupTimer( void );
static void prvSetNextTimerInterrupt( void );
static void prvTaskExitError( void );

/* Global state trackers to maintain continuous precision across ticks */
static uint64_t ullNextTime = 0;

/*-----------------------------------------------------------*/

/**
 * @brief Schedules the next S-mode timer tick using the Sstc extension registers.
 *        Directly updates stimecmp/stimecmph to prevent M-mode trap overhead.
 */
static void prvSetNextTimerInterrupt(void)
{
    uint32_t th, tl, th_check;
    uint64_t now;
    const uint64_t ullTickIncrement = (uint64_t)(configCPU_CLOCK_HZ / configTICK_RATE_HZ);

    /* 1. Safely read the 64-bit hardware time CSR split over two 32-bit registers */
    do {
        __asm__ volatile("csrr %0, 0xC81" : "=r"(th)); // Read timeh
        __asm__ volatile("csrr %0, 0xC01" : "=r"(tl)); // Read time
        __asm__ volatile("csrr %0, 0xC81" : "=r"(th_check));
    } while (th != th_check); // Guard against multi-bit rollover cascade
    
    now = ((uint64_t)th << 32) | tl;

    /* 2. Calculate next monotonic execution milestone */
    if (ullNextTime == 0 || ullNextTime < now) {
        ullNextTime = now;
    }
    ullNextTime += ullTickIncrement;

    /* 3. Extract upper and lower segments for 32-bit write targets */
    uint32_t wl = (uint32_t)(ullNextTime & 0xFFFFFFFF);
    uint32_t wh = (uint32_t)(ullNextTime >> 32);

    /* 4. Atomic update rules for Sstc 32-bit registers:
     *    Maximize lower value first to eliminate transient intermediate matches. */
    __asm__ volatile("csrw 0x14D, %0" :: "r"(0xFFFFFFFF)); /* Clear stimecmp */
    __asm__ volatile("csrw 0x15D, %0" :: "r"(wh));         /* Write stimecmph */
    __asm__ volatile("csrw 0x14D, %0" :: "r"(wl));         /* Write stimecmp */
}

/*-----------------------------------------------------------*/

/**
 * @brief Configures the system timer to fire at the requested FreeRTOS tick rate.
 */
void vPortSetupTimer(void)
{
    /* Calculate and arm the initial execution target */
    prvSetNextTimerInterrupt();

    /* Enable Supervisor Timer Interrupt Enable (STIE is Bit 5 of sie) */
    __asm__ volatile("csrs sie, %0" :: "r"(1 << 5));
}

/*-----------------------------------------------------------*/

static void prvTaskExitError( void )
{
    /* A task should never return from its top-level function. */
    configASSERT( 0 );
    portDISABLE_INTERRUPTS();
    for( ;; );
}

/*-----------------------------------------------------------*/

void vPortClearInterruptMask(int mask)
{
    /* Update Supervisor Interrupt Enable register (sie) */
    __asm__ volatile("csrw sie, %0" :: "r"(mask));
}

/*-----------------------------------------------------------*/

int vPortSetInterruptMask(void)
{
    int ret;
    /* Atomically read current sie and clear all S-mode interrupt enables.
     * The standard ISR-mask contract is "disable everything that can call
     * into the kernel" — masking only STIE leaves SSIE/SEIE live. */
    __asm__ volatile("csrrw %0, sie, zero" : "=r"(ret));
    return ret;
}
/*-----------------------------------------------------------*/

/**
 * @brief Implements explicit frame element mapping matching your macro structure 
 *        defined inside portasm.S.
 */
StackType_t *pxPortInitialiseStack( StackType_t *pxTopOfStack, TaskFunction_t pxCode, void *pvParameters )
{
    /* 1. Open up a clean, word-aligned 32-element slot array pool on the stack */
    pxTopOfStack -= 32;

    for (int i = 0; i < 32; i++) {
        pxTopOfStack[i] = 0;
    }

    /* 2. Bind application entry references directly to explicit index offsets.
     *    This bypasses fragile relative pointer subtraction mistakes. */
    pxTopOfStack[31] = (StackType_t)pxCode;             /* Restored to sepc (Slot 31) */
    pxTopOfStack[9]  = (StackType_t)pvParameters;       /* Restored to x10 / a0 (Slot 9) */
    pxTopOfStack[0]  = (StackType_t)prvTaskExitError;   /* Restored to x1 / ra (Slot 0) */

    /* 3. Seed slot 2 with the current global pointer (x3) so the task starts
     *    with the same gp the boot code set up. */
    register StackType_t gp asm("x3");
    pxTopOfStack[2]  = gp;                              /* Restored to x3 / gp (Slot 2) */

    return pxTopOfStack;
}

/*-----------------------------------------------------------*/

void vPortSysTickHandler( void )
{
    /* Reset stimecmp milestone for next scheduled interrupt */
    prvSetNextTimerInterrupt();

    /* Process the kernel time delta increment */
    if( xTaskIncrementTick() != pdFALSE )
    {
        vTaskSwitchContext();
    }
}

/* PLIC Hart 0 S-Mode Context Claim/Complete Register Address
 * Derived from your ntiny.dts memory map: PLIC base is 0x0c000000.
 * Context 1 (S-mode) Claim/Complete is at base + 0x201004. */
#define PLIC_S_CLAIM_COMPLETE    ((volatile uint32_t*)0x0C201004)

/**
 * @brief Handles asynchronous external and software interrupts.
 *        Called directly from freertos_risc_v_interrupt_handler in portasm.S
 * 
 * @param cause The value of the scause register passed in via a0.
 */
void external_interrupt_dispatcher(uint32_t cause) 
{
    /* Mask out the interrupt flag bit (Bit 31) to get the true exception code */
    uint32_t interrupt_code = cause & 0x7FFFFFFF;

    /* Code 9 = Supervisor External Interrupt (Line triggered by PLIC) */
    if (interrupt_code == 9) 
    {
        /* 1. Claim the active interrupt ID source from the PLIC hardware */
        uint32_t active_source = *PLIC_S_CLAIM_COMPLETE;

        if (active_source != 0) 
        {
            /* 2. Route to the correct peripheral handler based on your DTS */
            if (active_source == 1) 
            {
                /* UART0 RX Data Available Interruption */
                // extern void uart_handle_rx_irq(void);
                // uart_handle_rx_irq(); 
            } 
            else if (active_source == 2) 
            {
                /* UART0 TX Buffer Empty Interruption */
                // extern void uart_handle_tx_irq(void);
                // uart_handle_tx_irq();
            } 
            else if (active_source == 3)
            {
                /* SPI0 Interruption */
            }

            /* 3. Signal completion back to the PLIC to unblock the target line */
            *PLIC_S_CLAIM_COMPLETE = active_source;
        }
    }
    /* Code 1 = Supervisor Software Interrupt (IPI) */
    else if (interrupt_code == 1) 
    {
        /* Handle inter-processor interrupts here if running multi-core */
        /* Clear the SIP (Supervisor Interrupt Pending) SSIP bit */
        __asm__ volatile("csrc sip, %0" :: "r"(1 << 1));
    }
}

/* Helper to print 32-bit hex values over UART without printf */
static void uart_puthex(uint32_t val) {
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uint32_t nibble = (val >> i) & 0xF;
        if (nibble < 10) {
            uart_putc('0' + nibble);
        } else {
            uart_putc('A' + (nibble - 10));
        }
    }
}

/* 
 * cause = a0, epc = a1, tval = a2, fp = a3 (s0)
 */
void exception_panic(uint32_t cause, uint32_t epc, uint32_t tval, uint32_t fp) {
    /* Minimal header: EXC = Cause, PC = Error PC, VAL = Trap Value */
    uart_puts("\r\nEXC:"); uart_puthex(cause);
    uart_puts(" PC:"); uart_puthex(epc);
    uart_puts(" VAL:"); uart_puthex(tval);
    uart_puts("\r\nTRC:\r\n");

    /* Walk the stack frame linked list (Limit to 8 frames to prevent infinite loops) */
    int depth = 0;
    
    /* Sanity check: fp must be word-aligned and inside your 128MB RAM block */
    while (fp >= 0x80000000 && fp < 0x88000000 && (fp & 3) == 0 && depth < 8) {
        
        /* RISC-V GCC Frame Layout: 
         * fp - 4: Return Address (ra)
         * fp - 8: Previous Frame Pointer */
        uint32_t ra = *((uint32_t *)(fp - 4));
        uint32_t prev_fp = *((uint32_t *)(fp - 8));

        uart_puthex(ra);
        uart_puts("\r\n");

        /* Stacks grow downward. If prev_fp is smaller, the stack is corrupted. */
        if (prev_fp <= fp) {
            break;
        }
        
        fp = prev_fp;
        depth++;
    }

    /* Terminate Verilator */
    __asm__ volatile (
        "li t0, 0x0F000000\n"
        "li t1, 1\n"
        "sw t1, 0(t0)\n"
        ::: "t0", "t1", "memory"
    );

    while(1) {
        __asm__ volatile("nop");
    }
}