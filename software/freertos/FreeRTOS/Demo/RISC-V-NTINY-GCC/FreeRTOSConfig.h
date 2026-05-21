#ifndef FREERTOS_CONFIG_H
#define FREERTOS_CONFIG_H

/* Board includes. */
#include "uart.h"

/*-----------------------------------------------------------
 * Application specific definitions for ntiny RISC-V SoC
 *----------------------------------------------------------*/

/* Hardware Base Addresses */
#define NTINY_CLINT_ADDR                ( 0x02000000UL )

/* 
 * CLINT Offsets based on your RTL decode map:
 * ADDR_MTIMECMP_LO = 0x4000
 * ADDR_MTIME_LO    = 0xBFF8
 * (Note: Since we configured Sstc in port.c, FreeRTOS will use the stimecmp CSRs 
 * instead of these M-mode memory-mapped registers, but we define them here to 
 * satisfy standard port dependencies). 
 */
#define configMTIME_BASE_ADDRESS        ( NTINY_CLINT_ADDR + 0xBFF8 )
#define configMTIMECMP_BASE_ADDRESS     ( NTINY_CLINT_ADDR + 0x4000 )

/* Match the SoC clock frequency from your ntiny.dts (50 MHz) */
#define configCPU_CLOCK_HZ              ( ( unsigned long ) 50000000 )
#define configTICK_RATE_HZ              ( ( TickType_t ) 1000 )

#define configISR_STACK_SIZE_WORDS      ( 300 )

#define configUSE_PREEMPTION            1
#define configUSE_IDLE_HOOK             0
#define configUSE_TICK_HOOK             0 /* Set to 0 to avoid missing vApplicationTickHook errors */

/* Memory Allocation */
#if __riscv_xlen == 64
    #define configMINIMAL_STACK_SIZE    ( ( unsigned short ) 240 )
    #define configTOTAL_HEAP_SIZE       ( ( size_t ) ( 220 * 1024 ) )
#else
    #define configMINIMAL_STACK_SIZE    ( ( unsigned short ) 120 )
    /* 128 KB Heap - You have 124 MB of S-mode RAM available, plenty of room */
    #define configTOTAL_HEAP_SIZE       ( ( size_t ) ( 128 * 1024 ) )
#endif

#define configMAX_TASK_NAME_LEN         ( 12 )
#define configUSE_TRACE_FACILITY        1
#define configUSE_16_BIT_TICKS          0
#define configIDLE_SHOULD_YIELD         0
#define configUSE_CO_ROUTINES           0
#define configUSE_MUTEXES               1
#define configUSE_RECURSIVE_MUTEXES     1
#define configCHECK_FOR_STACK_OVERFLOW  2
#define configUSE_MALLOC_FAILED_HOOK    1
#define configUSE_QUEUE_SETS            1
#define configUSE_COUNTING_SEMAPHORES   1
#define configUSE_PORT_OPTIMISED_TASK_SELECTION 0

#define configMAX_PRIORITIES            ( 9UL )
#define configMAX_CO_ROUTINE_PRIORITIES ( 2 )
#define configQUEUE_REGISTRY_SIZE       10

/* Set to 0 to prevent linker errors looking for vApplicationGetIdleTaskMemory */
#define configSUPPORT_STATIC_ALLOCATION     0
#define configSUPPORT_DYNAMIC_ALLOCATION    1

/* Timer related defines. */
#define configUSE_TIMERS                1
#define configTIMER_TASK_PRIORITY       ( configMAX_PRIORITIES - 3 )
#define configTIMER_QUEUE_LENGTH        20
#define configTIMER_TASK_STACK_DEPTH    ( configMINIMAL_STACK_SIZE * 2 )

#define configUSE_TASK_NOTIFICATIONS    1
#define configTASK_NOTIFICATION_ARRAY_ENTRIES 3

/* Set the following definitions to 1 to include the API function, or zero
to exclude the API function. */
#define INCLUDE_vTaskPrioritySet                1
#define INCLUDE_uxTaskPriorityGet               1
#define INCLUDE_vTaskDelete                     1
#define INCLUDE_vTaskCleanUpResources           0
#define INCLUDE_vTaskSuspend                    1
#define INCLUDE_vTaskDelayUntil                 1
#define INCLUDE_vTaskDelay                      1
#define INCLUDE_uxTaskGetStackHighWaterMark     1
#define INCLUDE_xTaskGetSchedulerState          1
#define INCLUDE_xTimerGetTimerDaemonTaskHandle  1
#define INCLUDE_xTaskGetIdleTaskHandle          1
#define INCLUDE_xSemaphoreGetMutexHolder        1
#define INCLUDE_eTaskGetState                   1
#define INCLUDE_xTimerPendFunctionCall          1
#define INCLUDE_xTaskAbortDelay                 1
#define INCLUDE_xTaskGetCurrentTaskHandle       1
#define INCLUDE_xTaskGetHandle                  1

#define configUSE_STATS_FORMATTING_FUNCTIONS    0
#define configRUN_ADDITIONAL_TESTS              0

/* 
 * Robust Custom Assertion for Bare-Metal UART
 * Forces a halt and prints immediately to avoid silent 0x0 Jumps
 */
#define configASSERT( x ) if( ( x ) == 0 ) { \
    uart_puts("\r\n[PANIC] FreeRTOS ASSERT FAILED!\r\n"); \
    __asm__ volatile("csrc sstatus, 2"); /* Disable S-Mode Interrupts */ \
    while(1) { __asm__ volatile("nop"); } \
}

#define configSTREAM_BUFFER_TRIGGER_LEVEL_TEST_MARGIN   2

#define intqHIGHER_PRIORITY     ( configMAX_PRIORITIES - 5 )
#define bktPRIMARY_PRIORITY     ( configMAX_PRIORITIES - 4 )
#define bktSECONDARY_PRIORITY   ( configMAX_PRIORITIES - 5 )

#endif /* FREERTOS_CONFIG_H */