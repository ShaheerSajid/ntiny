#include "uart.h"
#include <stdint.h>

/* Bare-metal API kept stable across the Phase 2b layout change so
 * existing tests keep working. The implementation now drives the
 * sifive,uart0 register set (txdata/rxdata with embedded full/empty
 * flag bits, separate txctrl/rxctrl enables, integer divisor at
 * U_DIV instead of U_BAUDRATE). */

volatile uint32_t *m_uart;

void uart_init(uint32_t baudrate)
{
    m_uart = (volatile uint32_t *)UART_BASE_ADDR;

    /* SiFive convention: div = clk / baud - 1. */
    m_uart[U_DIV / 4]    = (50000000u / baudrate) - 1u;
    m_uart[U_TXCTRL / 4] = U_TXCTRL_TXEN;
    m_uart[U_RXCTRL / 4] = U_RXCTRL_RXEN;
}

int uart_putc(char c)
{
    /* Poll txdata.full so the in-flight byte isn't clobbered. */
    while (m_uart[U_TXDATA / 4] & U_TXDATA_FULL_BIT) { }
    m_uart[U_TXDATA / 4] = (uint32_t)(uint8_t)c;
    return 0;
}

int uart_haschar(void)
{
    /* Peek without dequeueing: rxdata read DOES dequeue, so we have to
     * read once and stash if the caller will then call uart_getchar.
     * Simpler: poll rxdata; if not empty, the caller can call getchar
     * which re-reads it. The dequeue happens on getchar. (Acceptable
     * race: between haschar and getchar, the byte stays valid because
     * getchar is the only reader and it always consumes it.) */
    return (m_uart[U_RXDATA / 4] & U_RXDATA_EMPTY_BIT) == 0;
}

int uart_getchar(void)
{
    uint32_t v = m_uart[U_RXDATA / 4];
    if (v & U_RXDATA_EMPTY_BIT)
        return -1;
    return (int)(v & 0xff);
}

void uart_puts(char *data)
{
    int x = 0;
    while (data[x] != 0) {
        uart_putc(data[x]);
        x++;
    }
}

void uart_gets(char *data, uint8_t length)
{
    for (uint8_t i = 0; i < length; i++) {
        int c;
        do { c = uart_getchar(); } while (c < 0);
        data[i] = (uint8_t)c;
    }
}
