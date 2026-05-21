/* FreeRTOS includes. */
#include "FreeRTOS.h"
#include "task.h"

/* Board includes. */
#include "uart.h"

static void vHelloWorldTask( void * pvParameters );

void main( void )
{
    uart_puts( "[FreeRTOS] Hello World from main()\r\n" );

    /* Create the hello-world task. */
    BaseType_t ret = xTaskCreate( vHelloWorldTask,
                                  "Hello",
                                  configMINIMAL_STACK_SIZE,
                                  NULL,
                                  tskIDLE_PRIORITY + 1,
                                  NULL );

    uart_puts("[FreeRTOS] Task created.\n");

    if (ret != pdPASS) {
        uart_puts( "[PANIC] xTaskCreate failed! Check configTOTAL_HEAP_SIZE.\r\n" );
    }

    uart_puts( "[FreeRTOS] Starting Scheduler...\n" );
    
    /* Start the scheduler. This hands execution control to FreeRTOS. */
    vTaskStartScheduler();

    /* If the scheduler returns, it means the Idle Task failed to allocate! */
    uart_puts( "[PANIC] Scheduler returned! Insufficient heap for Idle Task.\r\n" );
    for( ; ; );
}

static void vHelloWorldTask( void * pvParameters )
{
    ( void ) pvParameters;

    for( ; ; )
    {
        uart_puts( "[FreeRTOS] Hello World from loop\r\n" );
        vTaskDelay( pdMS_TO_TICKS( 10 ) );
    }
}

/*-----------------------------------------------------------*/
/* Fully Armed Debug Hooks */

void vApplicationMallocFailedHook( void )
{
    uart_puts( "[PANIC] Malloc Failed Hook Triggered!\r\n" );
    taskDISABLE_INTERRUPTS();
    for( ; ; );
}

void vApplicationStackOverflowHook( TaskHandle_t pxTask, char * pcTaskName )
{
    ( void ) pxTask;
    uart_puts( "[PANIC] Stack Overflow in task: " );
    uart_puts( pcTaskName );
    uart_puts( "\r\n" );
    taskDISABLE_INTERRUPTS();
    for( ; ; );
}