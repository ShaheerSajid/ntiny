/*
 * port.c — ntiny RV32 S-mode FreeRTOS port.
 *
 * Two non-obvious things to understand:
 *
 *   1. The tick comes from Sstc. ntiny's csr_unit doesn't gate S-mode
 *      stimecmp access on menvcfg.STCE (see csr_unit.sv:404-407), so
 *      we can write stimecmp / stimecmph directly without any M-mode
 *      bootstrap. Note: stimecmph is at CSR 0x15D — not 0x14E. The
 *      0x14Dh / 0x15Dh pair is what the Sstc spec and the ntiny RTL
 *      decode; 0x14E is unallocated and an S-mode csrw there traps
 *      illegal-instruction (which was a fun way to get that wrong).
 *
 *   2. Yield is a self-pended supervisor software interrupt (sip.SSIP).
 *      portYIELD() sets that bit and the trap handler clears it before
 *      calling vTaskSwitchContext(). This is the same yield trick OpenSBI
 *      itself uses for IPIs, just kept inside S-mode.
 */

#include <stdint.h>

#include "FreeRTOS.h"
#include "task.h"

#include "ntiny_uart.h"

/* ── Scheduler state ────────────────────────────────────────────── */
volatile UBaseType_t uxCriticalNesting = 0xaaaaaaaa;
extern void *volatile pxCurrentTCB;

/* ── CSR / mtime helpers ────────────────────────────────────────── */
#define SIE_SSIE        (1u << 1)   /* supervisor software */
#define SIE_STIE        (1u << 5)   /* supervisor timer    */
#define SIE_SEIE        (1u << 9)   /* supervisor external */

#define SSTATUS_SIE     (1u << 1)
#define SSTATUS_SPIE    (1u << 5)
#define SSTATUS_SPP     (1u << 8)

static inline uint64_t read_mtime64( void )
{
    /* RV32 64-bit read: re-read hi if mid-read carry happened. The
     * unprivileged time/timeh CSRs alias the CLINT mtime. */
    uint32_t lo, hi, hi2;
    do {
        __asm volatile ( "csrr %0, timeh" : "=r"( hi ) );
        __asm volatile ( "csrr %0, time"  : "=r"( lo ) );
        __asm volatile ( "csrr %0, timeh" : "=r"( hi2 ) );
    } while( hi != hi2 );
    return ( ( uint64_t ) hi << 32 ) | lo;
}

static inline void write_stimecmp64( uint64_t v )
{
    /* Atomic 64-bit Sstc write on RV32: park the high half at max so a
     * mid-write low-half wraparound can't fire the comparator early.
     *   stimecmp  = 0x14D
     *   stimecmph = 0x15D  (NOT 0x14E — that address is unallocated and
     *                       writes there trap illegal-instruction.) */
    uint32_t lo = ( uint32_t ) v;
    uint32_t hi = ( uint32_t )( v >> 32 );
    __asm volatile ( "csrw 0x15D, %0" :: "r"( 0xFFFFFFFFu ) );
    __asm volatile ( "csrw 0x14D, %0" :: "r"( lo ) );
    __asm volatile ( "csrw 0x15D, %0" :: "r"( hi ) );
}

#define TICK_INCREMENT ( configCPU_CLOCK_HZ / configTICK_RATE_HZ )

/* ── Stack frame layout ─────────────────────────────────────────────
 *
 * Pushed by portASM.S on trap entry, popped on return. Mirror this in
 * pxPortInitialiseStack so the very first sret pops sensible values.
 *
 *   word 0   x1  (ra)         offset 0    — task return (portTaskExitError)
 *   word 1   x5  (t0)         offset 4
 *   word 2   x6  (t1)         offset 8
 *   word 3   x7  (t2)         offset 12
 *   word 4   x8  (s0/fp)      offset 16
 *   word 5   x9  (s1)         offset 20
 *   word 6   x10 (a0)         offset 24   — pvParameters
 *   word 7   x11 (a1)         offset 28
 *   ...      x12..x17         offset 32..52
 *   word 14  x18 (s2)         offset 56
 *   ...      x19..x27         offset 60..92
 *   word 24  x28 (t3)         offset 96
 *   ...      x29..x31         offset 100..108
 *   word 28  sepc             offset 112  — entry PC; sret targets it
 *   word 29  sstatus          offset 116  — SPP=1 (S-mode), SPIE=1
 *   word 30  (pad)            offset 120
 *   word 31  (pad)            offset 124
 *
 * 30 saved words + 2 pads = 32 words = 128 bytes = 16-byte aligned.
 */
#define FRAME_WORDS         32   /* 30 saved + 2 pad */
#define FRAME_BYTES         ( FRAME_WORDS * 4 )
#define FRAME_IDX_A0        6
#define FRAME_IDX_SEPC      28
#define FRAME_IDX_SSTATUS   29

static void portTaskExitError( void )
{
    /* A task tried to fall off the end of its main function. We don't
     * support task deletion in this build, so park here so the user
     * notices in the simulator. */
    portDISABLE_INTERRUPTS();
    for( ;; )
        ;
}

StackType_t * pxPortInitialiseStack( StackType_t * pxTopOfStack,
                                     TaskFunction_t pxCode,
                                     void * pvParameters )
{
    /* Align down to 16 bytes, then carve out one full frame. */
    uintptr_t addr = ( uintptr_t ) pxTopOfStack;
    addr &= ~( ( uintptr_t ) 0xF );
    addr -= FRAME_BYTES;
    StackType_t * sp = ( StackType_t * ) addr;

    for( int i = 0; i < FRAME_WORDS; i++ )
        sp[ i ] = 0;

    sp[ 0 ]                  = ( StackType_t ) portTaskExitError;   /* ra  */
    sp[ FRAME_IDX_A0 ]       = ( StackType_t ) pvParameters;
    sp[ FRAME_IDX_SEPC ]     = ( StackType_t ) pxCode;
    sp[ FRAME_IDX_SSTATUS ]  = ( StackType_t )( SSTATUS_SPP | SSTATUS_SPIE );

    return sp;
}

/* ── Critical sections ──────────────────────────────────────────── */
void vPortEnterCritical( void )
{
    portDISABLE_INTERRUPTS();
    uxCriticalNesting++;
}

void vPortExitCritical( void )
{
    configASSERT( uxCriticalNesting > 0 );
    uxCriticalNesting--;
    if( uxCriticalNesting == 0 )
        portENABLE_INTERRUPTS();
}

UBaseType_t uxPortSetInterruptMaskFromISR( void )
{
    UBaseType_t prev;
    __asm volatile ( "csrrci %0, sstatus, 2" : "=r"( prev ) );
    return prev & SSTATUS_SIE;
}

void vPortClearInterruptMaskFromISR( UBaseType_t uxSavedMask )
{
    if( uxSavedMask )
        __asm volatile ( "csrs sstatus, 2" );
}

/* ── Scheduler entry ────────────────────────────────────────────── */
extern void xPortStartFirstTask( void );  /* in portASM.S */

BaseType_t xPortStartScheduler( void )
{
    uxCriticalNesting = 0;

    /* Arm the first tick before enabling interrupts. */
    write_stimecmp64( read_mtime64() + TICK_INCREMENT );

    /* Enable supervisor software (yield) + timer interrupts. External
     * (PLIC) is left masked — this demo doesn't use it. */
    __asm volatile ( "csrs sie, %0" :: "r"( SIE_SSIE | SIE_STIE ) );

    /* Pops the first task's frame and srets. Never returns. */
    xPortStartFirstTask();

    /* Unreachable. */
    return pdFALSE;
}

void vPortEndScheduler( void )
{
    /* Not supported. Park. */
    portDISABLE_INTERRUPTS();
    for( ;; )
        ;
}

/* ── Trap dispatch (called from portASM.S after context save) ──── */
void freertos_trap_dispatch( void )
{
    uint32_t cause, code;
    __asm volatile ( "csrr %0, scause" : "=r"( cause ) );

    if( cause & 0x80000000UL ) {
        code = cause & 0x7FFFFFFFu;
        if( code == 5 ) {
            /* Supervisor timer: re-arm stimecmp, bump the kernel tick,
             * and let the kernel pick the next runnable task if the
             * tick made one ready. */
            write_stimecmp64( read_mtime64() + TICK_INCREMENT );
            if( xTaskIncrementTick() != pdFALSE )
                vTaskSwitchContext();
        }
        else if( code == 1 ) {
            /* Software (yield): clear SSIP, switch context. */
            __asm volatile ( "csrci sip, 2" );
            vTaskSwitchContext();
        }
        /* else: spurious — fall through, return to caller. */
    }
    else {
        /* Synchronous fault. Print sepc / scause / stval and spin so
         * the testbench timeout fires with a recognisable signature. */
        uint32_t sepc, stval;
        __asm volatile ( "csrr %0, sepc"  : "=r"( sepc ) );
        __asm volatile ( "csrr %0, stval" : "=r"( stval ) );
        ntiny_uart_puts( "\n[FreeRTOS] unhandled S-mode trap: scause=0x" );
        ntiny_uart_puthex( cause );
        ntiny_uart_puts( " sepc=0x" );
        ntiny_uart_puthex( sepc );
        ntiny_uart_puts( " stval=0x" );
        ntiny_uart_puthex( stval );
        ntiny_uart_puts( "\n" );
        for( ;; )
            ;
    }
}

void vAssertCalled( const char * pcFile, unsigned long ulLine )
{
    ( void ) pcFile;
    ( void ) ulLine;
    portDISABLE_INTERRUPTS();
    ntiny_uart_puts( "\n[FreeRTOS] assert @ " );
    ntiny_uart_puts( pcFile );
    ntiny_uart_puts( ":" );
    ntiny_uart_puthex( ulLine );
    ntiny_uart_puts( "\n" );
    for( ;; )
        ;
}

/* ── Static-allocation memory pools for idle/timer tasks ─────────── */
#if ( configSUPPORT_STATIC_ALLOCATION == 1 )

static StaticTask_t xIdleTaskTCB;
static StackType_t  xIdleTaskStack[ configMINIMAL_STACK_SIZE ];

void vApplicationGetIdleTaskMemory( StaticTask_t ** ppxIdleTaskTCBBuffer,
                                    StackType_t ** ppxIdleTaskStackBuffer,
                                    uint32_t * pulIdleTaskStackSize )
{
    *ppxIdleTaskTCBBuffer   = &xIdleTaskTCB;
    *ppxIdleTaskStackBuffer = xIdleTaskStack;
    *pulIdleTaskStackSize   = configMINIMAL_STACK_SIZE;
}

#if ( configUSE_TIMERS == 1 )
static StaticTask_t xTimerTaskTCB;
static StackType_t  xTimerTaskStack[ configTIMER_TASK_STACK_DEPTH ];

void vApplicationGetTimerTaskMemory( StaticTask_t ** ppxTimerTaskTCBBuffer,
                                     StackType_t ** ppxTimerTaskStackBuffer,
                                     uint32_t * pulTimerTaskStackSize )
{
    *ppxTimerTaskTCBBuffer   = &xTimerTaskTCB;
    *ppxTimerTaskStackBuffer = xTimerTaskStack;
    *pulTimerTaskStackSize   = configTIMER_TASK_STACK_DEPTH;
}
#endif

#endif /* configSUPPORT_STATIC_ALLOCATION */
