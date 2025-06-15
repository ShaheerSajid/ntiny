#include "init.h"
#include "csr.h"
#include "plic.h"
#include "gpio.h"
#include "uart.h"
#include "i2c.h"
#include "timer.h"

volatile uint32_t *soft_base_addr = (volatile uint32_t *)0x4000000;

int cnt  = 0;
int extractBit(unsigned int number, int bitPosition) {
    return (number & (1 << bitPosition)) != 0;
}


void ISR_TIMER_ASM()
{
  cnt++;


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
  I2C_init (100000);
  // set timer
  timer_set_prescaler(64); // set value by which you want to divide the clock frequency
  timer_set_compare(390625);
  timer_set_count(0);
  // set timer interrupt
  csr_set(mie , (1<<7));
  // start timer
  timer_start();

  int_enable();
  // uart_init(115200);

  gpio_mode(0,1);
  gpio_mode(1,1);
  gpio_mode(2,1);

  while(1)
  {
      gpio_write_pin(0,extractBit(cnt,0));
  gpio_write_pin(1,extractBit(cnt,1));
  gpio_write_pin(2,extractBit(cnt,2));

    uint16_t AccX,AccY,AccZ;
    I2C_start(0x53,0);

    I2C_write(0x32,0);
    I2C_start(0x53,1); // start in read
    //For a range of +-2g, we need to divide the raw values by 16384, according to the datasheet

    uint16_t x_0 = I2C_read(0);
    uint16_t x_1 = I2C_read(0);
    AccX = (x_0 << 8 | x_1) ; // X-axis value

    uint16_t y_0 = I2C_read(0);
    uint16_t y_1 = I2C_read(0);
    AccY = (y_0 << 8 | y_1) ; // X-axis value

    uint16_t z_0 = I2C_read(0);
    uint16_t z_1 = I2C_read(1);
    AccZ = (z_0 << 8 | z_1) ; // X-axis value
  }
}
