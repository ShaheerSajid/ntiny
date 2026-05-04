// ── ntiny UART register definitions ─────────────────────────────
// Phase 2b peripheral standardisation: register layout matches
// SiFive UART0 (drivers/tty/serial/sifive.c, compatible "sifive,uart0").
//
// Byte offsets:
//   0x00 txdata    write data on bits [7:0]; reads return full flag in bit 31
//   0x04 rxdata    bit 31 = empty (no data); bits [7:0] = received byte
//                  reading dequeues
//   0x08 txctrl    bit 0  = txen
//                  bit 1  = nstop (0 = 1 stop bit, 1 = 2 stop bits)
//                  bit 18:16 = txcnt watermark
//   0x0C rxctrl    bit 0  = rxen
//                  bit 18:16 = rxcnt watermark
//   0x10 ie        bit 0 = txwm enable, bit 1 = rxwm enable
//   0x14 ip        bit 0 = txwm pending, bit 1 = rxwm pending
//   0x18 div       integer baud divisor: div = clk / baud

`define U_TXDATA    8'h00
`define U_RXDATA    8'h04
`define U_TXCTRL    8'h08
`define U_RXCTRL    8'h0c
`define U_IE        8'h10
`define U_IP        8'h14
`define U_DIV       8'h18

// txdata fields
`define U_TXDATA_DATA_R   7:0
`define U_TXDATA_FULL_B   31

// rxdata fields
`define U_RXDATA_DATA_R   7:0
`define U_RXDATA_EMPTY_B  31

// txctrl fields
`define U_TXCTRL_TXEN_B    0
`define U_TXCTRL_NSTOP_B   1
`define U_TXCTRL_TXCNT_R   18:16

// rxctrl fields
`define U_RXCTRL_RXEN_B    0
`define U_RXCTRL_RXCNT_R   18:16

// ie / ip fields
`define U_IE_TXWM_B   0
`define U_IE_RXWM_B   1
`define U_IP_TXWM_B   0
`define U_IP_RXWM_B   1
