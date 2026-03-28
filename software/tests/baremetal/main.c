#include <stdint.h>
#include "uart.h"
#include "init.h"
#include "timer.h"
#include "csr.h"
#include "ee_printf.h"
#include "plic.h"
#include "gpio.h"

int t_cnt = 0;
int g_cnt = 0;
int id = 0;
int s_cnt = 0;
volatile uint32_t *soft_base_addr = (volatile uint32_t *)0x4000000;

void gpio_0_ext_isr()
{
  g_cnt++;
}
void gpio_1_ext_isr()
{
  g_cnt--;
}
void uart_rx_ext_isr()
{
  char y = uart_getchar();
  uart_putc(y);
}


void ISR_TIMER_ASM()
{
  t_cnt++;
}

void ISR_SOFT_ASM()
{
  s_cnt++;
  *soft_base_addr = 0;
}

void ISR_EXT_ASM()
{
  id = get_interrupt_id();
/*
  switch(id)
  {
    case 1: gpio_0_ext_isr(); break;
    case 2: gpio_1_ext_isr(); break;
    case 3: uart_rx_ext_isr(); break;
  }*/
  if(id == 1) gpio_0_ext_isr();
  else if(id == 2) gpio_1_ext_isr();
  else if(id == 3) uart_rx_ext_isr();
}

int main()
{
  int_disable();
  uart_init(115200);

  //set_interrupt_enable(0b000100);
  //set_interrupt_threshold(0);
  //set_interrupt_priority(0b001011001);

  //enable external
  //gpio_mode(0,0);
  //gpio_set_interrupt();
  //csr_set(mie , (1<<11));

  //set timer
  //timer_set_prescaler(1); // set value by which you want to divide the clock frequency
  //timer_set_compare(2000);
  //timer_set_count(0);
  //set timer interrupt
  //csr_set(mie , (1<<7));
  //start timer
  //timer_start();


  //set soft interrupt
  //csr_set(mie , (1<<3));

  //set global interrupts
  //int_enable();
  volatile uint32_t *crc_base_addr = (volatile uint32_t *)0x80000;

  //set state value
  //crc_base_addr[1] = 0xffffffff;
  //enable state
  //crc_base_addr[0] = 0x1; 

  //set data
  crc_base_addr[2] = 0x12345678;
  //enable crc
  crc_base_addr[0] = 0x2; 

  uint32_t crc = 0;
  crc = crc_base_addr[1];

  ee_printf("Data = %X\tCRC= %X\n", 0x12345678, crc);
	while(1)
	{
		//ee_printf("Software = %d\tTimer %d\tExternal = %d\tID = %d\n", s_cnt, t_cnt, g_cnt,id);
    //if(t_cnt >= 50000 && t_cnt <= 200000) *soft_base_addr = 1;
	}
	
}
