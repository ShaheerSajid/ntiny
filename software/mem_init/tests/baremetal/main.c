#include <stdlib.h>
#include <math.h>
#include "ee_printf.h"
#include "init.h"
#include "csr.h"
// #include "plic.h"
// #include "gpio.h"
#include "uart.h"
#include "i2c.h"
#include "timer.h"
#include <time.h>

volatile uint32_t *soft_base_addr = (volatile uint32_t *)0x4000000;

int cnt  = 0;
int extractBit(unsigned int number, int bitPosition) {
    return (number & (1 << bitPosition)) != 0;
}


// void ISR_TIMER_ASM()
// {
// }

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
  uart_init(115200);

  while(1)
  {
    uint64_t t1 = clock();
    uint16_t AccX,AccY,AccZ;
    I2C_start(0x53,0);

    I2C_write(0x32,0);
    I2C_start(0x53,1); // start in read
    //For a range of +-2g, we need to divide the raw values by 16384, according to the datasheet

    uint16_t x_0 = I2C_read(0);
    uint16_t x_1 = I2C_read(0);
    AccX = ((x_1 & 0x03) << 8 | x_0) ; // X-axis value
    int16_t xf = AccX;
    if(xf > 511)
    {
      xf = xf - 1024;
    }
    float xa = xf * 0.004;

    uint16_t y_0 = I2C_read(0);
    uint16_t y_1 = I2C_read(0);
    AccY = ((y_1 & 0x03) << 8 | y_0) ; // X-axis value
    int16_t yf = AccY;
    if(yf > 511)
    {
      yf = yf - 1024;
    }
    float ya = yf * 0.004;

    uint16_t z_0 = I2C_read(0);
    uint16_t z_1 = I2C_read(1);
    AccZ = ((z_1 & 0x03) << 8 | z_0) ; // X-axis value

    int16_t zf = AccZ;
    if(zf > 511)
    {
      zf = zf - 1024;
    }
    float za = zf * 0.004;

    float roll = atan(ya / sqrt(pow(xa, 2) + pow(za, 2))) * 180 / 3.1415;
    float pitch = atan(-1 * xa / sqrt(pow(ya, 2) + pow(za, 2))) * 180 / 3.1415;

    uint64_t t2 = clock();

    ee_printf("%0.2f, %0.2f, %0.2f\n", roll, pitch, (float)(t2-t1)/25000.0);

    delay_ms(10);
  }
}
