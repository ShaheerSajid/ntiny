

`define U_RX    8'h0

    `define U_RX_DATA_DEFAULT    0
    `define U_RX_DATA_B          0
    `define U_RX_DATA_T          7
    `define U_RX_DATA_W          8
    `define U_RX_DATA_R          7:0

`define U_TX    8'h4

    `define U_TX_DATA_DEFAULT    0
    `define U_TX_DATA_B          0
    `define U_TX_DATA_T          7
    `define U_TX_DATA_W          8
    `define U_TX_DATA_R          7:0

`define U_STATUS    8'h8

    `define U_STATUS_IE      4
    `define U_STATUS_IE_DEFAULT    0
    `define U_STATUS_IE_B          4
    `define U_STATUS_IE_T          4
    `define U_STATUS_IE_W          1
    `define U_STATUS_IE_R          4:4

    `define U_STATUS_TXFULL      3
    `define U_STATUS_TXFULL_DEFAULT    0
    `define U_STATUS_TXFULL_B          3
    `define U_STATUS_TXFULL_T          3
    `define U_STATUS_TXFULL_W          1
    `define U_STATUS_TXFULL_R          3:3

    `define U_STATUS_TXEMPTY      2
    `define U_STATUS_TXEMPTY_DEFAULT    0
    `define U_STATUS_TXEMPTY_B          2
    `define U_STATUS_TXEMPTY_T          2
    `define U_STATUS_TXEMPTY_W          1
    `define U_STATUS_TXEMPTY_R          2:2

    `define U_STATUS_RXFULL      1
    `define U_STATUS_RXFULL_DEFAULT    0
    `define U_STATUS_RXFULL_B          1
    `define U_STATUS_RXFULL_T          1
    `define U_STATUS_RXFULL_W          1
    `define U_STATUS_RXFULL_R          1:1

    `define U_STATUS_RXVALID      0
    `define U_STATUS_RXVALID_DEFAULT    0
    `define U_STATUS_RXVALID_B          0
    `define U_STATUS_RXVALID_T          0
    `define U_STATUS_RXVALID_W          1
    `define U_STATUS_RXVALID_R          0:0

`define U_CONTROL    8'hc

    `define U_CONTROL_IE      4
    `define U_CONTROL_IE_DEFAULT    0
    `define U_CONTROL_IE_B          4
    `define U_CONTROL_IE_T          4
    `define U_CONTROL_IE_W          1
    `define U_CONTROL_IE_R          4:4

    `define U_CONTROL_RST_RX      1
    `define U_CONTROL_RST_RX_DEFAULT    0
    `define U_CONTROL_RST_RX_B          1
    `define U_CONTROL_RST_RX_T          1
    `define U_CONTROL_RST_RX_W          1
    `define U_CONTROL_RST_RX_R          1:1

    `define U_CONTROL_RST_TX      0
    `define U_CONTROL_RST_TX_DEFAULT    0
    `define U_CONTROL_RST_TX_B          0
    `define U_CONTROL_RST_TX_T          0
    `define U_CONTROL_RST_TX_W          1
    `define U_CONTROL_RST_TX_R          0:0
    
`define U_BAUDRATE          5'h10
