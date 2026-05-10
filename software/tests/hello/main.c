/* Tiny FPGA bring-up: print "Hello from ntiny!" on UART forever
 * and toggle gpio_o[3:0] (= LD0..LD3 on Zybo Z7) once per print so
 * a working bring-up shows both UART traffic AND blinking LEDs.
 * Never returns — leaves the core in a deterministic loop suitable
 * for power-on demo / OpenOCD attach.
 */
#include "ee_printf.h"
#include "uart.h"
#include "gpio.h"

#define DELAY_LOOPS 5000000u

static void busy_wait(unsigned n) {
    for (volatile unsigned i = 0; i < n; i++) ;
}

int main(void) {
    uart_init(115200);
    gpio_set_ddr(0xF);            /* LD0..LD3 outputs */
    unsigned counter = 0;
    while (1) {
        ee_printf("Hello from ntiny on Zybo Z7! count=%u\n", counter);
        gpio_set(counter & 0xF);  /* drive LDs to low 4 bits of counter */
        counter++;
        busy_wait(DELAY_LOOPS);
    }
    return 0;
}
