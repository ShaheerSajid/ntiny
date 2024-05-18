#include "timer_test.h"
#include "uart.h"
#include "ee_printf.h"
#include "gpio.h"

volatile uint32_t	*m_timer	= 	(volatile uint32_t*)TIMER_BASE_ADDR;


int timer_test()
{  
    #ifdef Peak_poke
    return timer_peak_poke_test ();
    #endif

    #ifdef fucntional
    return timer_fucntional_test ();
    #endif

    return 0;
}


#ifdef Peak_poke
int timer_peak_poke_test ()
{
    
    gpio_mode(2,1);
    for (int i =0; i<5; i++)
    {
        gpio_write_pin(2,1);
        delay_ms(500);
        gpio_write_pin(2,0);
        delay_ms(500);
    }



    uint8_t register_list[] = {CLOCK_Prescaler,Count_Register,Compare_Register};
	
	for ( int registers = 0; registers <2; registers++) // iterating through all 5 registers of I2C
	{
		for (int i = 1; i<32; i++) // setting every single bits of the register and conforming it
		{
            if ((registers == 0) && (i==11))
                break;
			poke_reg(m_timer,register_list[registers],1<<i);
			
			if (peak_reg(m_timer,register_list[registers])!= (1<<i))
				{
                    gpio_mode(7,1);
                    gpio_write_pin(7,1);    // error signal
                    ee_printf("Registers:  %d  Iterations: %d  value:  %d  \n",registers,i,peak_reg(m_timer,register_list[registers] ));
                    return 1;
				}
		}
	}

   // test completed successfully 
    gpio_mode(2,1);
    gpio_write_pin(2,1);    
    
}
#endif

#ifdef fucntional
int timer_fucntional_test ()
{
                 /// timer test using uart
                ee_printf("Device is sleeping for 5 sec...\n");
                delay_ms(5000);
                ee_printf("Device on after 5 sec...\n ");
                // ee_printf ("If the interval was of 5 seconds. Please enter 1 else 0.\n");
                while (!uart_haschar());
                uint8_t x = uart_getchar();
                uart_putc((char)x);
                uart_puts("\n");  
                if (x == 48)
                    ee_printf("Timer delay was fine...\n");
                else 
                    return 1;
                

                /// timer test using gpio
                gpio_mode(0,1);
                gpio_mode(1,1);
                gpio_mode(2,1);
                gpio_set(0);
                ee_printf("Device is testing timer fucntionality.\n value time in seconds (binary) will displayed on leds \n");
                ee_printf("GPIO 0,1,2 is used for this testing");
                delay_ms(1000);
                gpio_set(1);
                delay_ms(1000);
                gpio_set(2);
                delay_ms(1000);
                gpio_set(3);
                delay_ms(1000);
                gpio_set(4);
                delay_ms(1000);
                gpio_set(5);
                ee_printf("GPIO testing completed\n");
    return 0;

}
#endif