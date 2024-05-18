#include "uart.h"
#include <stdint.h>

/**
* Local variables... \n Base address of UART Pheripheral
*/
volatile uint32_t *m_uart;

/**
* uart_init: Initialise UART peripheral \n
* Inputs Baudrate i.e. 9600, 115200 etc \n
* Ouput void
*/
void uart_init(uint32_t buadrate)           
{
    uint32_t cfg = 0;
    m_uart = (volatile uint32_t *)UART_BASE_ADDR;

    // Soft reset
    cfg += (1 << U_CONTROL_RST_RX_SHIFT);
    cfg += (1 << U_CONTROL_RST_TX_SHIFT);
    cfg += (1 << U_CONTROL_IE_SHIFT);

   //m_uart[U_CONTROL/4]  = cfg;
    m_uart[U_CONTROL/4]  = cfg;
    m_uart[U_baudrate/4] = (50000000/buadrate) -1;
}

/**
* uart_putc: Polled putchar\n
* Input c \n
* Output int\n
* This fucntion will send charater c through uart\n
* return 0 on successful execution of fucntion\n
*/
int uart_putc(char c)
{
    // While TX FIFO full

   //m_uart[U_TX/4] = c;
    //volatile uint32_t	*sim_uart	= 	(volatile uint32_t*)0x820000;
     m_uart = (volatile uint32_t *)UART_BASE_ADDR;
    //*sim_uart = c;

    m_uart[U_TX/4] = c;
    #ifndef VERILATOR
     while (m_uart[U_STATUS/4] & (1 << U_STATUS_TXFULL_SHIFT)){

    }
    #endif
    return 0;
}

/**
* uart_haschar:\n
* Output int\n
* return 1 if recieved data on uart\n
* else return 0\n
*/ 
int uart_haschar(void)
{
	return (m_uart[U_STATUS/4] & (1 << U_STATUS_RXVALID_SHIFT)) != 0;
}

/**
* uart_getchar: Read character from UART\n
* Input void\n
* Output int\n
* return charater if recieved \n
* else return -1\n
*/ 
int uart_getchar(void)
{
    if (uart_haschar()){
        return (uint8_t)m_uart[U_RX/4];
        }
    else
        return -1;
}

/**
* uart_print_string: \n
* Input pointer to array.\n
* Will send the string (array of char) through uart\n
*/ 
void uart_puts(char *data)
{
	int x = 0;
	while (data[x] != 0)
		{
			uart_putc(data[x]);
			x++;
		}
}
 
/**
* uart_scan_string: \n
* Input pointer to array.\n
* Will recieve the string (array of char) through uart\n
*/ 
void uart_gets(char *data, uint8_t length)
{
    for (uint8_t i = 0; i<length ; i++)
        {
            while(!uart_haschar());                     // wait while  data is recieved
            *(data + i) = (uint8_t)m_uart[U_RX/4];      // read the recieved data

        }

}
  
