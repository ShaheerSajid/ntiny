

#ifndef __UART__DEFS_H__
#define __UART__DEFS_H__


#define UART_BASE_ADDR  0x00100000


#define U_RX          0x0
    #define U_RX_DATA_SHIFT                  0
    #define U_RX_DATA_MASK                   0xff

#define U_TX          0x4
    #define U_TX_DATA_SHIFT                  0
    #define U_TX_DATA_MASK                   0xff

#define U_STATUS      0x8
    #define U_STATUS_IE                      4
    #define U_STATUS_IE_SHIFT                4
    #define U_STATUS_IE_MASK                 0x1

    #define U_STATUS_TXFULL                  3
    #define U_STATUS_TXFULL_SHIFT            3
    #define U_STATUS_TXFULL_MASK             0x1

    #define U_STATUS_TXEMPTY                 2
    #define U_STATUS_TXEMPTY_SHIFT           2
    #define U_STATUS_TXEMPTY_MASK            0x1

    #define U_STATUS_RXFULL                  1
    #define U_STATUS_RXFULL_SHIFT            1
    #define U_STATUS_RXFULL_MASK             0x1

    #define U_STATUS_RXVALID                 0
    #define U_STATUS_RXVALID_SHIFT           0
    #define U_STATUS_RXVALID_MASK            0x1

#define U_CONTROL     0xc
    #define U_CONTROL_IE                     4
    #define U_CONTROL_IE_SHIFT               4
    #define U_CONTROL_IE_MASK                0x1

    #define U_CONTROL_RST_RX                 1
    #define U_CONTROL_RST_RX_SHIFT           1
    #define U_CONTROL_RST_RX_MASK            0x1

    #define U_CONTROL_RST_TX                 0
    #define U_CONTROL_RST_TX_SHIFT           0
    #define U_CONTROL_RST_TX_MASK            0x1
#define U_baudrate    0x10

#endif