#include <stdint.h>
#include <stdlib.h>
#include <string.h>


// Custom libraries
#include "uart_test.h"
#include "gpio_test.h"

#include "timer_test.h"
/*#include "spi_test.h"
#include "i2c_test.h" 
#include "pwm_test.h"
*/
// Fucntion protoypes
int run_tests();

// Globle Variables




// main fucntions
int main (void )
{   
    uart_init(115200);

    int test_result = run_tests();

    if (!test_result)
        uart_puts("All tests passed...  :-).\n");
    else
    {
        switch (test_result)
        {
        case 1:
             uart_puts("->GPIO test failed...  :-(.\n");
            break;
        case 2:
             uart_puts("->UART test failed...  :-(.\n");
            break;
        case 3:
             uart_puts("->TIMER test failed...  :-(.\n");
            break;
        case 4:
             uart_puts("->SPI test failed...  :-(.\n");
            break;
        case 5:
             uart_puts("->I2C test failed...  :-(.\n");
            break;
         case 6:
             uart_puts("->PWM test failed...  :-(.\n");
            break;    
        
        default:
            uart_puts("CORE failed...  :-(.\n");
            break;
        }
    } 

    while(1)
    {

    }

return 0;
}


// Fucntion definations
int run_tests()
{
       uart_puts ("Testing all Peripherals ...\n");

    // running tests for gpio (test 1)
        uart_puts ("->Testing GPIO Peripheral ...\n");
        if (gpio_test())    // if uart_test failed
            return 1;
        uart_puts ("->GPIO test passed...  :-).\n");
    
    // running tests for uart  (test 2)
        uart_puts ("->Testing UART Peripheral ...\n");
        if (uart_test())    // if uart_test failed
            return 2;
        uart_puts ("->UART test passed...  :-).\n");

    // running tests for timer (test 3)
        uart_puts ("->Testing TIMER Peripheral ...\n");
        if (timer_test())    // if uart_test failed
            return 3;
        uart_puts ("->TIMER test passed...  :-).\n");

/*
    // running tests for spi (test 4)
        uart_puts ("->Testing SPI Peripheral ...\n");
        if (spi_test())    // if uart_test failed
            return 4;
        uart_puts ("->SPI test passed...  :-).\n");

    // running tests for I2C (test 5)
        uart_puts ("->Testing I2C Peripheral ...\n");
        if (I2C_test())    // if uart_test failed
            return 5;
        uart_puts ("->I2C test passed...  :-).\n");

    // running tests for pwm (test 6)
        uart_puts ("->Testing PWM Peripheral ...\n");
        if (pwm_test())    // if uart_test failed
            return 6;
        uart_puts ("->PWM test passed...  :-).\n");
        
*/    

    // All tests are completed successfully.
    return 0;

}