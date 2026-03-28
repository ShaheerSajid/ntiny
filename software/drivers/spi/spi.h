#ifndef __SPI_H__
#define __SPI_H__

#include <stdint.h>


//-----------------------------------------------------------------
// Variables:
//-----------------------------------------------------------------
/*
const uint8_t SPI_MODE0 = 0x00; ///<  CPOL: 0  CPHA: 0
const uint8_t SPI_MODE1 = 0x01; ///<  CPOL: 0  CPHA: 1
const uint8_t SPI_MODE2 = 0x10; ///<  CPOL: 1  CPHA: 0
const uint8_t SPI_MODE3 = 0x11; ///<  CPOL: 1  CPHA: 1
*/

//-----------------------------------------------------------------
// Prototypes:
//-----------------------------------------------------------------
void 	  spi_set_sck_ratio(uint8_t ratio);
void      spi_init( int cpol, int cpha, int lsb_first );
void      spi_cs(uint32_t value);
uint8_t   spi_sendrecv(uint8_t ch);
void      spi_readblock(uint8_t *ptr, int length);
void      spi_writeblock(char *ptr );


#endif
