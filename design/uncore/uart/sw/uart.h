#ifndef __UART_H__
#define __UART_H__

#include "uart_def.h"
#include <stdint.h>
/**
* Prototypes of Uart firmware \n
*/

void uart_init( uint32_t baudrate);
int  uart_putc(char c);
int  uart_haschar(void);
int  uart_getchar(void);
void uart_puts(char *data);
void uart_gets(char *data, uint8_t length);


#endif
