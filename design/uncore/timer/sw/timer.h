#ifndef TIMER_H_
#define TIMER_H_
#include <stdint.h>

/*
#define NO_CLOCK 0
#define PRE_1 1
#define PRE_8 2
#define PRE_32 3
#define PRE_64 4
#define PRE_128 5
#define PRE_256 6
#define PRE_1024 7
*/

#define TIMER_BASE_ADDR  0x200000

#define CLOCK_Prescaler			0x00
#define Count_Register			0x01
#define Control_Register		0x02    // [6'b0,en,1'b0]
#define Status_Register			0x03    // [7'b0,count_complete]
#define Compare_Register		0x04





void timer_set_prescaler(int);
void timer_set_compare(int);
void timer_set_count(int);
void timer_start();
void timer_stop();
int timer_read_status();
int timer_read_control();
unsigned int timer_read_compare_value();
unsigned int timer_read_count_value();
int timer_read_prescaler_value();
void delay_ms(uint32_t ms_delay_value);
void delay_us(uint32_t us_delay_value);


#endif