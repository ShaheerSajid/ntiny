/*
 * FreeRTOS configuration for the ntiny RV32 SoC, S-mode under OpenSBI.
 *
 * Tick source: Sstc — write `stimecmp` (CSR 0x14D / 0x14E) directly
 *              from S-mode, no SBI ecall per tick. The ntiny OpenSBI
 *              platform enables menvcfgh.STCE so this is legal.
 * Yield:       sip.SSIP self-set (CSR 0x144 bit 1). The trap handler
 *              clears SSIP and calls vTaskSwitchContext().
 * Console:     direct MMIO writes to the sifive,uart0 at 0x10000000.
 *              OpenSBI already configured div/txen during cold init,
 *              so we just poll TXDATA.full and write bytes.
 */

#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

#define configCPU_CLOCK_HZ                       ( 50000000UL )
#define configTICK_RATE_HZ                       ( ( TickType_t ) 100 )
#define configUSE_PREEMPTION                     1
#define configUSE_TIME_SLICING                   1
#define configUSE_IDLE_HOOK                      0
#define configUSE_TICK_HOOK                      0
#define configMAX_PRIORITIES                     ( 5 )
#define configMINIMAL_STACK_SIZE                 ( ( unsigned short ) 256 )
#define configTOTAL_HEAP_SIZE                    ( ( size_t ) ( 64 * 1024 ) )
#define configMAX_TASK_NAME_LEN                  ( 16 )
#define configUSE_TRACE_FACILITY                 0
#define configUSE_16_BIT_TICKS                   0
#define configIDLE_SHOULD_YIELD                  1
#define configUSE_MUTEXES                        1
#define configQUEUE_REGISTRY_SIZE                0
#define configCHECK_FOR_STACK_OVERFLOW           0
#define configUSE_RECURSIVE_MUTEXES              0
#define configUSE_MALLOC_FAILED_HOOK             0
#define configUSE_APPLICATION_TASK_TAG           0
#define configUSE_COUNTING_SEMAPHORES            0
#define configGENERATE_RUN_TIME_STATS            0
#define configSUPPORT_STATIC_ALLOCATION          1
#define configSUPPORT_DYNAMIC_ALLOCATION         1
#define configUSE_NEWLIB_REENTRANT               0

/* Co-routine and software-timer subsystems off — keeps the image small. */
#define configUSE_CO_ROUTINES                    0
#define configMAX_CO_ROUTINE_PRIORITIES          ( 2 )
#define configUSE_TIMERS                         0
#define configTIMER_TASK_PRIORITY                ( 2 )
#define configTIMER_QUEUE_LENGTH                 5
#define configTIMER_TASK_STACK_DEPTH             ( 128 )

/* Kernel API features we don't use. */
#define INCLUDE_vTaskPrioritySet                 0
#define INCLUDE_uxTaskPriorityGet                0
#define INCLUDE_vTaskDelete                      0
#define INCLUDE_vTaskCleanUpResources            0
#define INCLUDE_vTaskSuspend                     0
#define INCLUDE_vTaskDelayUntil                  1
#define INCLUDE_vTaskDelay                       1
#define INCLUDE_xTaskGetSchedulerState           1

/* Hard fault on assert. The trap handler prints `[assert]` and spins. */
extern void vAssertCalled( const char * pcFile, unsigned long ulLine );
#define configASSERT( x )                                              \
    do {                                                               \
        if( ( x ) == 0 ) {                                             \
            vAssertCalled( __FILE__, __LINE__ );                       \
        }                                                              \
    } while( 0 )

#endif /* FREERTOS_CONFIG_H */
