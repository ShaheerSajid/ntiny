#ifndef NTINY_UART_H
#define NTINY_UART_H

#include <stdint.h>

void ntiny_uart_putc( char c );
void ntiny_uart_puts( const char * s );
void ntiny_uart_puthex( uint32_t v );
void ntiny_uart_putu32( uint32_t v );

#endif
