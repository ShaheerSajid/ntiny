#ifndef __UART__DEFS_H__
#define __UART__DEFS_H__

#include "mem_map.h"

/* Phase 2b peripheral standardisation: ntiny UART matches sifive,uart0
 * register layout (mirrors design/uncore/uart/src/uart_defs.sv).
 * Offsets are byte-addresses; index the (uint32_t *) base by offset/4. */

#define U_TXDATA   0x00      /* W: data; R: bit 31 = full flag      */
#define U_RXDATA   0x04      /* R: bit 31 = empty, [7:0] = data     */
#define U_TXCTRL   0x08      /* bit 0 = txen, bit 1 = nstop         */
#define U_RXCTRL   0x0C      /* bit 0 = rxen                        */
#define U_IE       0x10
#define U_IP       0x14
#define U_DIV      0x18

#define U_TXDATA_FULL_BIT    (1u << 31)
#define U_RXDATA_EMPTY_BIT   (1u << 31)
#define U_TXCTRL_TXEN        (1u << 0)
#define U_RXCTRL_RXEN        (1u << 0)
#define U_IE_TXWM            (1u << 0)
#define U_IE_RXWM            (1u << 1)

#endif
