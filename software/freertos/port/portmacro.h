/*
 * portmacro.h — ntiny RV32 S-mode port macros for FreeRTOS.
 *
 * The kernel-facing API the rest of FreeRTOS uses (types, critical
 * sections, yield). All the heavy lifting is in port.c / portASM.S.
 */

#ifndef PORTMACRO_H
#define PORTMACRO_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/* ── Port types ─────────────────────────────────────────────────── */
#define portCHAR          char
#define portFLOAT         float
#define portDOUBLE        double
#define portLONG          long
#define portSHORT         short
#define portSTACK_TYPE    uint32_t
#define portBASE_TYPE     long

typedef portSTACK_TYPE   StackType_t;
typedef long             BaseType_t;
typedef unsigned long    UBaseType_t;

#if ( configUSE_16_BIT_TICKS == 1 )
    typedef uint16_t     TickType_t;
    #define portMAX_DELAY ( TickType_t ) 0xffff
#else
    typedef uint32_t     TickType_t;
    #define portMAX_DELAY ( TickType_t ) 0xffffffffUL
    #define portTICK_TYPE_IS_ATOMIC 1
#endif

/* ── Architecture constants ─────────────────────────────────────── */
#define portSTACK_GROWTH               ( -1 )
#define portTICK_PERIOD_MS             ( ( TickType_t ) 1000 / configTICK_RATE_HZ )
#define portBYTE_ALIGNMENT             16

/* ── Critical sections via sstatus.SIE ──────────────────────────── */
extern void vPortEnterCritical( void );
extern void vPortExitCritical( void );
extern UBaseType_t uxPortSetInterruptMaskFromISR( void );
extern void vPortClearInterruptMaskFromISR( UBaseType_t uxSavedMask );

#define portDISABLE_INTERRUPTS()       __asm volatile ( "csrc sstatus, 2" )
#define portENABLE_INTERRUPTS()        __asm volatile ( "csrs sstatus, 2" )
#define portENTER_CRITICAL()           vPortEnterCritical()
#define portEXIT_CRITICAL()            vPortExitCritical()
#define portSET_INTERRUPT_MASK_FROM_ISR()    uxPortSetInterruptMaskFromISR()
#define portCLEAR_INTERRUPT_MASK_FROM_ISR(x) vPortClearInterruptMaskFromISR( x )

/* ── Yield: self-pend supervisor software interrupt (sip.SSIP) ──── */
/* Writing 1 to sip bit 1 raises the S-mode software interrupt; the
 * trap handler clears it and calls vTaskSwitchContext(). */
#define portYIELD()                                                    \
    do {                                                               \
        __asm volatile ( "csrsi sip, 2" );                             \
        __asm volatile ( "fence" );                                    \
    } while( 0 )

#define portYIELD_FROM_ISR( xHigherPriorityTaskWoken )                 \
    do { if( ( xHigherPriorityTaskWoken ) != pdFALSE ) portYIELD(); } while( 0 )

#define portEND_SWITCHING_ISR( xSwitchRequired )                       \
    do { if( ( xSwitchRequired ) != pdFALSE ) portYIELD(); } while( 0 )

/* ── Task function macros ───────────────────────────────────────── */
#define portTASK_FUNCTION_PROTO( vFunction, pvParameters ) \
    void vFunction( void * pvParameters )
#define portTASK_FUNCTION( vFunction, pvParameters ) \
    void vFunction( void * pvParameters )

#define portNOP()  __asm volatile ( "nop" )

#ifdef __cplusplus
}
#endif

#endif /* PORTMACRO_H */
