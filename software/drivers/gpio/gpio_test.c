#include "gpio_test.h"
#include "timer.h"

static volatile uint32_t *m_gpio = (volatile uint32_t *)GPIO_BASE_ADDR;

int gpio_test()
{

   
#ifdef Peak_poke
return gpio_peak_poke_test ();
#endif

#ifdef fucntional
return gpio_fucntional_test ();
#endif

return 0;

}

#ifdef Peak_poke
int gpio_peak_poke_test ()
{
    gpio_mode(0,1);
    for (int i =0; i<5; i++)
    {
        gpio_write_pin(0,1);
        delay_ms(500);
        gpio_write_pin(0,0);
        delay_ms(500);
    }
    uint8_t register_list[] = {DDR,Dout};
	
	for ( int registers = 0; registers <2; registers++) // iterating through all 5 registers of I2C
	{
		for (int i = 1; i<16; i++) // setting every single bits of the register and conforming it
		{
			poke_reg(m_gpio,register_list[registers],1<<i);
			
			if (peak_reg(m_gpio,register_list[registers])!= (1<<i))
				{
                    gpio_mode(7,1);
                    gpio_write_pin(7,1);    // error signal

                    return 1;
				}
		}
	}



    // test completed successfully 
    gpio_mode(0,1);
    gpio_write_pin(0,1);    
    
    return 0;
}
#endif


#ifdef fucntional
int gpio_fucntional_test ()
{    
    gpio_reset();   // reseting all the internal registers
    gpio_set_ddr(0xff); // making gpio[7:0] as output and gpio[15:8] as input

    for ( int i = 0 ; i<8; i++)
    {
        gpio_set(1<<i);
        uint16_t data = (gpio_read_all() & 0xff00);
        if (!((data>>8) == (uint16_t)1<<i))
        {
            return 1;   // gpio not working          
        }
    }

    gpio_reset();   // reseting all the internal registers
    gpio_set_ddr(0xff00); // making gpio[7:0] as input and gpio[15:8] as output

    for ( int i = 0 ; i<8; i++)
    {
        gpio_set(1<<(i+8));
        uint16_t data = (gpio_read_all() & 0x00ff);
        if (!((data&0x00ff) == (uint16_t)1<<i))
        {
            return 1;   // gpio not working          
        }
    }

    // test completed successfully 
    return 0;
}
#endif