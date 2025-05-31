#include "init.h"
#include "csr.h"
#include "plic.h"
#include "gpio.h"
#include "uart.h"
#include "timer.h"

volatile uint32_t *soft_base_addr = (volatile uint32_t *)0x4000000;

int state  = 0;

void ISR_TIMER_ASM()
{
  state = !state;
}

// void ISR_SOFT_ASM()
// {
//   *soft_base_addr = 0;
// }

// void ISR_EXT_ASM()
// {
//   id = get_interrupt_id();

//   if(id == 1) gpio_0_ext_isr();
//   else if(id == 2) gpio_1_ext_isr();
//   else if(id == 3) uart_rx_ext_isr();
// }


int main()
{
  int_disable();

  // set timer
  timer_set_prescaler(64); // set value by which you want to divide the clock frequency
  timer_set_compare(39062);
  timer_set_count(0);
  // set timer interrupt
  csr_set(mie , (1<<7));
  // start timer
  timer_start();

  int_enable();
  // uart_init(115200);

  gpio_mode(0,1);
  while(1)
  {
    gpio_write_pin(0,state);
    // delay_ms(500);
    // gpio_write_pin(0,0);
    // delay_ms(500);
  }
}
