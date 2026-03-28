#include "tohost.h"
#include "ee_printf.h"
#include "uart.h"
#include "pwm_test.h"

int main(void) {
    uart_init(115200);
    ee_printf("Testing PWM peripheral...\n");
    int result = pwm_test();
    if (result == 0) tohost_pass();
    else             tohost_fail(result);
    return 1;
}
