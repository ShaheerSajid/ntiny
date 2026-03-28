#include "uart_test.h"
#include "gpio.h"
#include "timer.h"
#include "ee_printf.h"
static volatile uint32_t *m_uart = (volatile uint32_t *)UART_BASE_ADDR;


int uart_test()
{
    #ifdef Peak_poke 
    return uart_peak_poke_test();
    #endif

    #ifdef loopback 
    return uart_loopback_test();
    #endif

    #ifdef fucntional 
    return uart_fucntional_test();
    #endif

}

#ifdef Peak_poke
/**
* Uart test: Poking and peaking uart registers \n
*/
int uart_peak_poke_test ()
{
    gpio_mode(0,1);
    for (int i =0; i<5; i++)
    {
        gpio_write_pin(1,1);
        delay_ms(500);
        gpio_write_pin(1,0);
        delay_ms(500);
    }

    // testing registers write/read fucntionality

    for (int i = 0; i<32; i++) // setting every single bits of the register and conforming it
    {
        poke_reg(m_uart,U_baudrate/4,1<<i);
        
        if (peak_reg(m_uart,U_baudrate/4)!= (1<<i))
            {
                gpio_mode(7,1);
                gpio_write_pin(7,1);    // error signal
                return 1;
            }
    }
      
    // test completed successfully 
    gpio_mode(1,1);
    gpio_write_pin(1,1); 
    uart_init(115200);
    return 0;
}
#endif


#ifdef loopback
/**
* Uart test: loop back test \n
*/
int uart_loopback_test ()
{
    uart_init(115200);
    // loop back test 
    char *send_message ="Ntiny is alive. :-)";
    char *recv_message ;
    for (uint8_t i = 0; i<strlen(send_message); i++)
        {
            uart_putc(send_message[i]);
            recv_message[i]=uart_getchar();
            if (send_message[i] != recv_message[i])
            {
                return 1;
            }
        }
    // test completed sucessfully
    return 0;
}

#endif


#ifdef fucntional
/**
* Uart test: fucntional test \n
*/
int uart_fucntional_test ()
{
    // Testing Tranmsit fucntionality
    uart_puts("Ntiny is alive. :-)\n");
    uart_puts("UART transmit fucntion is working..\n");
    uart_puts("Checking UART recieve fucntionality..\n");
    uart_puts ("Enter the following numbers \n");


    // Testing Recieve functionality
    int x;
    for (int i =0 ; i<9 ; i++)
    {  
        ee_printf("%d  ",i);
        while (!uart_haschar());
        x = uart_getchar();
        uart_putc((char)x);
        uart_puts("\n");  
    }
    // test completed sucessfully
    return 0;
}
#endif