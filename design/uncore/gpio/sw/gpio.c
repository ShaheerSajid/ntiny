#include "gpio.h"

 volatile uint32_t *gpio__base_addr = (volatile uint32_t *)GPIO_BASE_ADDR;
 

void gpio_mode(int pin, uint8_t mode)
{
	if(mode)
		gpio__base_addr[DDR] |= (1<<pin);  // set output 
	else
		gpio__base_addr[DDR] &= ~(1<<pin); // set input

}
void gpio_write_pin(int pin, uint8_t state)
{
	if(state)
		gpio__base_addr[Dout] |= (1<<pin);
	else
		gpio__base_addr[Dout] &= ~(1<<pin);
}

int gpio_read_pin(int pin)
{
	return (gpio__base_addr[Din]>>pin)&1;
}

void gpio_reset()		// reset all the internal registers
{
	gpio__base_addr[cmd] = 0x04;
}
void gpio_reset_DDR()		// reset Data direction Register
{
	gpio__base_addr[cmd] = 0x02;
}
void gpio_reset_DOUT()		// reset data output Register
{
	gpio__base_addr[cmd] = 0x01;
}

void gpio_set_ddr(uint32_t set_value)
{
	gpio__base_addr[DDR] = set_value;	
}
void gpio_set(uint32_t set_value)
{
	gpio__base_addr[Dout] = set_value;	
}

uint32_t gpio_read_all ()
{	uint32_t read_value;
	read_value = gpio__base_addr[Din];
	return read_value;
}

uint32_t gpio_check_pin_mode()
{
	uint32_t read_value;
	read_value = gpio__base_addr[DDR];
	return read_value;
}

void gpio_set_interrupt()
{
	gpio__base_addr[cmd] |= (1 << 5) /*| (1<<4)*/;
}
