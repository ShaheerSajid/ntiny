#ifndef __SPI_DEFS_H__
#define __SPI_DEFS_H__

#include "mem_map.h"

/* sifive,spi0 register map. Phase 2d standardisation. */

#define SPI_SCKDIV         0x00
    #define SPI_SCKDIV_DIV_MASK             0xfffu

#define SPI_SCKMODE        0x04
    #define SPI_SCKMODE_CPHA_SHIFT          0
    #define SPI_SCKMODE_CPOL_SHIFT          1

#define SPI_CSID           0x10  /* 1-bit on ntiny */
#define SPI_CSDEF          0x14  /* 1-bit on ntiny */

#define SPI_CSMODE         0x18
    #define SPI_CSMODE_AUTO                 0u
    #define SPI_CSMODE_HOLD                 2u
    #define SPI_CSMODE_OFF                  3u

#define SPI_DELAY0         0x28
#define SPI_DELAY1         0x2c

#define SPI_FMT            0x40
    #define SPI_FMT_PROTO_SHIFT             0
    #define SPI_FMT_ENDIAN_SHIFT            2
    #define SPI_FMT_DIR_SHIFT               3
    #define SPI_FMT_LEN_SHIFT               16

#define SPI_TXDATA         0x48
    #define SPI_TXDATA_FULL_SHIFT           31

#define SPI_RXDATA         0x4c
    #define SPI_RXDATA_EMPTY_SHIFT          31

#define SPI_TXMARK         0x50
#define SPI_RXMARK         0x54

#define SPI_FCTRL          0x60  /* RAZ/WI on ntiny */
#define SPI_FFMT           0x64  /* RAZ/WI on ntiny */

#define SPI_IE             0x70
    #define SPI_IE_TXWM_SHIFT               0
    #define SPI_IE_RXWM_SHIFT               1

#define SPI_IP             0x74
    #define SPI_IP_TXWM_SHIFT               0
    #define SPI_IP_RXWM_SHIFT               1

#endif
