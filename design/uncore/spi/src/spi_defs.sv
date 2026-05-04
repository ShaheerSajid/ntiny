// ── ntiny SPI register map (sifive,spi0 layout) ────────────────────
//
// Phase 2d peripheral standardisation: register offsets and bit-fields
// match the upstream Linux SiFive SPI0 driver
// (drivers/spi/spi-sifive.c) so it binds directly. ntiny implements a
// single CS line — CSDEF/CSID are 1-bit deep; FCTRL/FFMT (memory-mapped
// flash mode) are RAZ/WI in this first cut.

`define SPI_SCKDIV   8'h00
    `define SPI_SCKDIV_DIV_R     11:0
    `define SPI_SCKDIV_DIV_W     12

`define SPI_SCKMODE  8'h04
    `define SPI_SCKMODE_CPHA_B   0
    `define SPI_SCKMODE_CPOL_B   1

`define SPI_CSID     8'h10        // 1-bit (only CS0 implemented)
`define SPI_CSDEF    8'h14        // 1-bit (default level for CS0)
`define SPI_CSMODE   8'h18
    `define SPI_CSMODE_MODE_R    1:0
    `define SPI_CSMODE_AUTO      2'd0
    `define SPI_CSMODE_HOLD      2'd2
    `define SPI_CSMODE_OFF       2'd3

`define SPI_DELAY0   8'h28
`define SPI_DELAY1   8'h2c

`define SPI_FMT      8'h40
    `define SPI_FMT_PROTO_R      1:0
    `define SPI_FMT_ENDIAN_B     2
    `define SPI_FMT_DIR_B        3
    `define SPI_FMT_LEN_R        19:16

`define SPI_TXDATA   8'h48
    `define SPI_TXDATA_DATA_R    7:0
    `define SPI_TXDATA_FULL_B    31

`define SPI_RXDATA   8'h4c
    `define SPI_RXDATA_DATA_R    7:0
    `define SPI_RXDATA_EMPTY_B   31

`define SPI_TXMARK   8'h50        // 3-bit watermark threshold (FIFO depth=4)
`define SPI_RXMARK   8'h54

`define SPI_FCTRL    8'h60        // RAZ/WI (memory-mapped flash mode unimplemented)
`define SPI_FFMT     8'h64        // RAZ/WI

`define SPI_IE       8'h70
    `define SPI_IE_TXWM_B        0
    `define SPI_IE_RXWM_B        1

`define SPI_IP       8'h74
    `define SPI_IP_TXWM_B        0
    `define SPI_IP_RXWM_B        1
