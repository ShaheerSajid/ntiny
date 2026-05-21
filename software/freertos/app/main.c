/*
 * main.c — ntiny FreeRTOS two-task UART hello demo.
 *
 * Two tasks at the same priority, each printing a counter every
 * 500 ms via vTaskDelay. With configUSE_TIME_SLICING=1 + equal
 * priorities, the kernel round-robins them, so the boot log shows
 * "task A: tick N" and "task B: tick N" interleaved.
 *
 * Smoke-pass criterion (see flows/simulation/run_linux.sh logs):
 *   - 'task A: tick 3' appears
 *   - 'task B: tick 3' appears
 */

#include "FreeRTOS.h"
#include "task.h"

#include "ntiny_uart.h"

#define STACK_WORDS    ( configMINIMAL_STACK_SIZE * 2 )
/* 20 ms = 2 ticks at the configured 100 Hz tick rate. Short enough that
 * a 60M-cycle verilator run shows ~30 ticks per task without waiting
 * forever on the simulator. Bump for real silicon if you want pretty
 * 500 ms blinks. */
#define TICK_DELAY_MS  20U
#define TICK_DELAY     ( pdMS_TO_TICKS( TICK_DELAY_MS ) )

static StaticTask_t xTaskA_TCB, xTaskB_TCB;
static StackType_t  xTaskA_Stack[ STACK_WORDS ], xTaskB_Stack[ STACK_WORDS ];

static void vTask( void * pvParameters )
{
    const char * name = ( const char * ) pvParameters;
    uint32_t tick = 0;

    for( ;; ) {
        ntiny_uart_puts( "task " );
        ntiny_uart_puts( name );
        ntiny_uart_puts( ": tick " );
        ntiny_uart_putu32( tick++ );
        ntiny_uart_puts( "\n" );
        vTaskDelay( TICK_DELAY );
    }
}

int main( void )
{
    ntiny_uart_puts( "\n[FreeRTOS] ntiny S-mode demo starting...\n" );

    ( void ) xTaskCreateStatic( vTask, "A", STACK_WORDS, ( void * ) "A",
                                tskIDLE_PRIORITY + 1, xTaskA_Stack, &xTaskA_TCB );
    ( void ) xTaskCreateStatic( vTask, "B", STACK_WORDS, ( void * ) "B",
                                tskIDLE_PRIORITY + 1, xTaskB_Stack, &xTaskB_TCB );

    ntiny_uart_puts( "[FreeRTOS] starting scheduler\n" );
    vTaskStartScheduler();

    /* Unreachable. */
    ntiny_uart_puts( "[FreeRTOS] scheduler returned (out of heap?)\n" );
    for( ;; )
        ;
    return 0;
}
