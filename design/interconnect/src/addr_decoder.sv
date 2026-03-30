`include "mem_map.svh"

// ── Address Decoder ─────────────────────────────────────────
// Pure combinational: takes a 32-bit byte address and produces
// one-hot chip-selects for each slave region.
//
module addr_decoder (
    input  logic [31:0] addr_i,

    output logic        ram_sel_o,
    output logic        boot_sel_o,
    output logic        uart_sel_o,
    output logic        spi_sel_o,
    output logic        i2c_sel_o,
    output logic        gpio_sel_o,
    output logic        pwm_sel_o,
    output logic        timer_sel_o,
    output logic        crc_sel_o,
    output logic        clint_sel_o,
    output logic        plic_sel_o,
    output logic        soft_sel_o,
    output logic        tohost_sel_o
);

    // RAM:   0x8000_0000 .. RAM_END   (addr[31] == 1)
    assign ram_sel_o    = (addr_i >= `RAM_BASE)  && (addr_i <= `RAM_END);

    // Boot:  0x0000_1000 .. BOOT_END
    assign boot_sel_o   = (addr_i >= `BOOT_BASE) && (addr_i <= `BOOT_END);

    // Peripherals at 0x1000_xxxx — decode addr[19:16]
    wire periph_region = (addr_i[31:20] == 12'h100);
    assign uart_sel_o   = periph_region && (addr_i[19:16] == 4'h0);
    assign spi_sel_o    = periph_region && (addr_i[19:16] == 4'h1);
    assign i2c_sel_o    = periph_region && (addr_i[19:16] == 4'h2);
    assign gpio_sel_o   = periph_region && (addr_i[19:16] == 4'h3);
    assign pwm_sel_o    = periph_region && (addr_i[19:16] == 4'h4);
    assign timer_sel_o  = periph_region && (addr_i[19:16] == 4'h5);
    assign crc_sel_o    = periph_region && (addr_i[19:16] == 4'h6);
    assign soft_sel_o   = periph_region && (addr_i[19:16] == 4'h7);

    // CLINT: 0x0200_0000 .. 0x0200_FFFF
    assign clint_sel_o  = (addr_i[31:16] == 16'h0200);

    // PLIC:  0x0C00_0000 .. 0x0DFF_FFFF
    assign plic_sel_o   = (addr_i[31:25] == 7'b0000_110);

    // tohost: 0x0F00_0000 (single word)
    assign tohost_sel_o = (addr_i == `TOHOST_ADDR);

endmodule
