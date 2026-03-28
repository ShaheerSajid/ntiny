#ifndef GPIO_H_
#define GPIO_H_
#include <stdint.h>
#include "gpio_defs.h"

void gpio_mode(int, uint8_t);	// set GPIO as output or input
void gpio_write_pin(int, uint8_t);	// write data to pin
int gpio_read_pin(int);		// read data from pin
void gpio_reset();		// reset all the internal registers
void gpio_reset_DDR();		// reset Data direction Register
void gpio_reset_DOUT();		// reset data output Register
void gpio_set(uint32_t);	// set all the gpio pins  
void gpio_set_ddr(uint32_t);	// set all the gpio pins  
uint32_t gpio_read_all();
uint32_t gpio_check_pin_mode();
void gpio_set_interrupt();
#endif

