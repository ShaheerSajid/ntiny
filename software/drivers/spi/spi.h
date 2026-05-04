#ifndef __SPI_H__
#define __SPI_H__

#include <stdint.h>

/* sifive,spi0 bare-metal driver. Phase 2d standardisation.
 *
 * spi_init() programs sckdiv directly (input clock divisor); the legacy
 * spi_set_sck_ratio() shim is kept for tests that still call it.
 *
 * spi_cs(value): non-zero = assert (CSMODE=HOLD), zero = release
 * (CSMODE=OFF). The SiFive controller drives CS automatically when
 * CSMODE=AUTO; HOLD/OFF gives software explicit control. */

void     spi_init(int cpol, int cpha, int sckdiv);
void     spi_set_sck_ratio(uint8_t ratio);   /* writes SCKDIV */
void     spi_cs(uint32_t value);
uint8_t  spi_sendrecv(uint8_t ch);
void     spi_readblock(uint8_t *ptr, int length);
void     spi_writeblock(const char *ptr);

#endif
