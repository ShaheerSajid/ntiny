// #include "ee_printf.h"
#include "init.h"
#include "csr.h"
// #include "gpio.h"
#include "uart.h"
// #include "timer.h"
// #include <time.h>

int main()
{
  int_disable();
  uart_init(115200);
  // gpio_mode(0,1);

  while(1)
  {
    // uint64_t t1 = clock();
    // gpio_write_pin(0,1);
    // delay_ms(500);
    // gpio_write_pin(0,0);
    // delay_ms(500);
    // ee_printf("Hello World: %d\n", 20);
    uart_puts("Hello\n");
  }
}
