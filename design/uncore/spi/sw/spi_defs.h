

#ifndef __SPI_DEFS_H__
#define __SPI_DEFS_H__

#define SPI_BASE_ADDR     0x1000000

#define SPI_DGIER         0x1c
    #define SPI_DGIER_GIE                        31
    #define SPI_DGIER_GIE_SHIFT                  31
    #define SPI_DGIER_GIE_MASK                   0x1

#define SPI_IPISR         0x20
    #define SPI_IPISR_TX_EMPTY                   2
    #define SPI_IPISR_TX_EMPTY_SHIFT             2
    #define SPI_IPISR_TX_EMPTY_MASK              0x1

#define SPI_IPIER         0x28
    #define SPI_IPIER_TX_EMPTY                   2
    #define SPI_IPIER_TX_EMPTY_SHIFT             2
    #define SPI_IPIER_TX_EMPTY_MASK              0x1

#define SPI_SRR           0x40
    #define SPI_SRR_RESET_SHIFT                  0
    #define SPI_SRR_RESET_MASK                   0xffffffff

#define SPI_CR            0x60
    #define SPI_CR_LOOP                          0
    #define SPI_CR_LOOP_SHIFT                    0
    #define SPI_CR_LOOP_MASK                     0x1

    #define SPI_CR_SPE                           1
    #define SPI_CR_SPE_SHIFT                     1
    #define SPI_CR_SPE_MASK                      0x1

    #define SPI_CR_MASTER                        2
    #define SPI_CR_MASTER_SHIFT                  2
    #define SPI_CR_MASTER_MASK                   0x1

    #define SPI_CR_CPOL                          3
    #define SPI_CR_CPOL_SHIFT                    3
    #define SPI_CR_CPOL_MASK                     0x1

    #define SPI_CR_CPHA                          4
    #define SPI_CR_CPHA_SHIFT                    4
    #define SPI_CR_CPHA_MASK                     0x1

    #define SPI_CR_TXFIFO_RST                    5
    #define SPI_CR_TXFIFO_RST_SHIFT              5
    #define SPI_CR_TXFIFO_RST_MASK               0x1

    #define SPI_CR_RXFIFO_RST                    6
    #define SPI_CR_RXFIFO_RST_SHIFT              6
    #define SPI_CR_RXFIFO_RST_MASK               0x1

    #define SPI_CR_MANUAL_SS                     7
    #define SPI_CR_MANUAL_SS_SHIFT               7
    #define SPI_CR_MANUAL_SS_MASK                0x1

    #define SPI_CR_TRANS_INHIBIT                 8
    #define SPI_CR_TRANS_INHIBIT_SHIFT           8
    #define SPI_CR_TRANS_INHIBIT_MASK            0x1

    #define SPI_CR_LSB_FIRST                     9
    #define SPI_CR_LSB_FIRST_SHIFT               9
    #define SPI_CR_LSB_FIRST_MASK                0x1

#define SPI_SR            0x64
    #define SPI_SR_RX_EMPTY                      0
    #define SPI_SR_RX_EMPTY_SHIFT                0
    #define SPI_SR_RX_EMPTY_MASK                 0x1

    #define SPI_SR_RX_FULL                       1
    #define SPI_SR_RX_FULL_SHIFT                 1
    #define SPI_SR_RX_FULL_MASK                  0x1

    #define SPI_SR_TX_EMPTY                      2
    #define SPI_SR_TX_EMPTY_SHIFT                2
    #define SPI_SR_TX_EMPTY_MASK                 0x1

    #define SPI_SR_TX_FULL                       3
    #define SPI_SR_TX_FULL_SHIFT                 3
    #define SPI_SR_TX_FULL_MASK                  0x1

#define SPI_DTR           0x68
    #define SPI_DTR_DATA_SHIFT                   0
    #define SPI_DTR_DATA_MASK                    0xff

#define SPI_DRR           0x6c
    #define SPI_DRR_DATA_SHIFT                   0
    #define SPI_DRR_DATA_MASK                    0xff

#define SPI_SSR           0x70
    #define SPI_SSR_VALUE_SHIFT                  0
    #define SPI_SSR_VALUE_MASK                   0xff
#define SPI_CLK_RATIO     0x74
    
#endif