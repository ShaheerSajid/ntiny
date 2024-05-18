#include "timer.h"

#include <stdint.h>



volatile uint32_t	*timer_base_addr	= 	(volatile uint32_t*)TIMER_BASE_ADDR;

void timer_set_count(int count)
{
	timer_base_addr[Count_Register] = count;
}
void timer_set_prescaler(int pre)
{
	timer_base_addr[CLOCK_Prescaler] = pre - 1;
}
void timer_set_compare(int max_count_value)
{
	timer_base_addr[Compare_Register] = max_count_value;
}
void timer_start( )
{
	timer_base_addr[Control_Register] = 0x2;
}
void timer_stop( )
{
	timer_base_addr[Control_Register] = 0x0;
}

int timer_read_control()
{
	return timer_base_addr[Control_Register];
}
int timer_read_status()
{
	return timer_base_addr[Status_Register];
}
unsigned int timer_read_count_value()
{
	return timer_base_addr[Count_Register];
}
unsigned int timer_read_compare_value()
{
	return timer_base_addr[Compare_Register];
}
int timer_read_prescaler_value()
{
	return timer_base_addr[CLOCK_Prescaler];
}

void delay_ms(uint32_t ms_delay_value)
{				for (int i=0; i<ms_delay_value; i++)
				{
					timer_set_prescaler(1); // set value by which you want to divide the clock frequency
	                timer_set_compare(50000);
	                timer_set_count(0);
	                timer_start();
	                while (timer_read_status() == 0)
	                {
	                }
	                timer_stop();
	            }
}
void delay_us(uint32_t us_delay_value)
{				for (int i=0; i<us_delay_value; i++)
				{
					timer_set_prescaler(1); // set value by which you want to divide the clock frequency
	                timer_set_compare(50);
	                timer_set_count(0);
	                timer_start();
	                while (timer_read_status() == 0)
	                {
	                }
	                timer_stop();
	            }
}
