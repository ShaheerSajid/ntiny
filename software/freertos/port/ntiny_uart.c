/*
 * ntiny_uart.c — direct MMIO access to the sifive,uart0 at 0x10000000.
 *
 * OpenSBI's ntiny_early_init() already programmed UART_DIV/TXCTRL/RXCTRL
 * before handoff, so we only have to wait for TXDATA.full to clear and
 * write the byte. No tx/rx interrupts — the demo is poll-only.
 */

#include "ntiny_uart.h"
#include "FreeRTOS.h"
#include "task.h"

#define UART_BASE          0x10000000UL
#define UART_TXDATA        ( UART_BASE + 0x00 )
#define UART_TXDATA_FULL   ( 1u << 31 )

static inline uint32_t mmio_r( uintptr_t addr )
{
    return *( volatile uint32_t * ) addr;
}

static inline void mmio_w( uintptr_t addr, uint32_t v )
{
    *( volatile uint32_t * ) addr = v;
}

void ntiny_uart_putc( char c )
{
    while( mmio_r( UART_TXDATA ) & UART_TXDATA_FULL )
        ;
    mmio_w( UART_TXDATA, ( uint32_t )( unsigned char ) c );
}

void ntiny_uart_puts( const char * s )
{
    /* Caller may invoke from inside a task; wrap in a critical section so
     * the per-string output isn't interleaved with another task's writes.
     * (Cheap on a single hart — just toggles sstatus.SIE.) */
    portENTER_CRITICAL();
    while( *s ) {
        if( *s == '\n' )
            ntiny_uart_putc( '\r' );
        ntiny_uart_putc( *s++ );
    }
    portEXIT_CRITICAL();
}

void ntiny_uart_puthex( uint32_t v )
{
    static const char hex[] = "0123456789abcdef";
    char buf[ 9 ];
    for( int i = 0; i < 8; i++ )
        buf[ 7 - i ] = hex[ ( v >> ( i * 4 ) ) & 0xF ];
    buf[ 8 ] = 0;

    portENTER_CRITICAL();
    for( int i = 0; i < 8; i++ )
        ntiny_uart_putc( buf[ i ] );
    portEXIT_CRITICAL();
}

void ntiny_uart_putu32( uint32_t v )
{
    char buf[ 11 ];
    int  i = 10;
    buf[ i-- ] = 0;
    if( v == 0 ) {
        buf[ i-- ] = '0';
    } else {
        while( v > 0 ) {
            buf[ i-- ] = '0' + ( v % 10 );
            v /= 10;
        }
    }
    portENTER_CRITICAL();
    ntiny_uart_puts( &buf[ i + 1 ] );
    portEXIT_CRITICAL();
}
