#include "tohost.h"
#include "ee_printf.h"
#include "uart.h"
#include "i2c_test.h"

int main(void) {
    uart_init(115200);
    ee_printf("Testing I2C peripheral...\n");
    int result = i2c_test();
    if (result == 0) tohost_pass();
    else             tohost_fail(result);
    return 1;
}
