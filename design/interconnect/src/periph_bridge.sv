`include "mem_map.svh"

// ── Peripheral Bridge ───────────────────────────────────────
// Adapts a mem_bus slave port to the existing peripheral interface
// (chipsel + read/write + readdata). Preserves backward compatibility
// with all peripheral modules — no changes needed on peripheral side.
//
// Timing:
//   ready = always 1 (peripherals accept in 1 cycle)
//   rvalid = 1 cycle after accepted read (registered)
//   Read data mux uses latched chip-select
//
module periph_bridge (
    input  logic        clk_i,
    input  logic        reset_i,

    // mem_bus slave side (directly driven from D-port signals)
    input  logic        req_i,
    input  logic        we_i,
    input  logic [31:0] addr_i,
    input  logic [3:0]  be_i,
    input  logic [31:0] wdata_i,
    output logic [31:0] rdata_o,
    output logic        rvalid_o,
    output logic        ready_o,

    // Chip selects from addr_decoder (active when req targets this peripheral)
    input  logic        uart_sel_i,
    input  logic        spi_sel_i,
    input  logic        i2c_sel_i,
    input  logic        gpio_sel_i,
    input  logic        pwm_sel_i,
    input  logic        timer_sel_i,
    input  logic        crc_sel_i,
    input  logic        plic_sel_i,
    input  logic        soft_sel_i,

    // Peripheral read data inputs
    input  logic [31:0] uart_rdata_i,
    input  logic [31:0] spi_rdata_i,
    input  logic [31:0] i2c_rdata_i,
    input  logic [31:0] gpio_rdata_i,
    input  logic [31:0] pwm_rdata_i,
    input  logic [31:0] timer_rdata_i,
    input  logic [31:0] crc_rdata_i,
    input  logic [31:0] plic_rdata_i,

    // Shared outputs to peripherals
    output logic        write_o,
    output logic        read_o,
    output logic [31:0] wdata_o,

    // Individual chipselects to peripherals
    output logic        uart_chipsel_o,
    output logic        spi_chipsel_o,
    output logic        i2c_chipsel_o,
    output logic        gpio_chipsel_o,
    output logic        pwm_chipsel_o,
    output logic        timer_chipsel_o,
    output logic        crc_chipsel_o,
    output logic        plic_chipsel_o,
    output logic        soft_chipsel_o
);

    // Any peripheral selected
    wire any_periph_sel = uart_sel_i | spi_sel_i | i2c_sel_i | gpio_sel_i |
                          pwm_sel_i | timer_sel_i | crc_sel_i | plic_sel_i | soft_sel_i;

    // Always ready — peripherals are single-cycle
    assign ready_o = 1'b1;

    // Write/read gated by req + peripheral selected
    assign write_o = req_i & we_i & any_periph_sel;
    assign read_o  = req_i & ~we_i & any_periph_sel;
    assign wdata_o = wdata_i;

    // Chip selects: only assert when req is active
    assign uart_chipsel_o  = req_i & uart_sel_i;
    assign spi_chipsel_o   = req_i & spi_sel_i;
    assign i2c_chipsel_o   = req_i & i2c_sel_i;
    assign gpio_chipsel_o  = req_i & gpio_sel_i;
    assign pwm_chipsel_o   = req_i & pwm_sel_i;
    assign timer_chipsel_o = req_i & timer_sel_i;
    assign crc_chipsel_o   = req_i & crc_sel_i;
    assign plic_chipsel_o  = req_i & plic_sel_i;
    assign soft_chipsel_o  = req_i & soft_sel_i;

    // ── Read data mux (latched chip-select for 1-cycle read latency) ──
    logic [8:0] sel_r;  // registered chip-selects
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            sel_r <= 9'b0;
        else
            sel_r <= {uart_sel_i, spi_sel_i, i2c_sel_i, gpio_sel_i,
                      pwm_sel_i, timer_sel_i, crc_sel_i, plic_sel_i, soft_sel_i};
    end

    always_comb begin
        case (1'b1)
            sel_r[8]: rdata_o = uart_rdata_i;
            sel_r[7]: rdata_o = spi_rdata_i;
            sel_r[6]: rdata_o = i2c_rdata_i;
            sel_r[5]: rdata_o = gpio_rdata_i;
            sel_r[4]: rdata_o = pwm_rdata_i;
            sel_r[3]: rdata_o = timer_rdata_i;
            sel_r[2]: rdata_o = crc_rdata_i;
            sel_r[1]: rdata_o = plic_rdata_i;
            default:  rdata_o = 32'h0;
        endcase
    end

    // rvalid: 1 cycle after accepted read
    logic read_pending;
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            read_pending <= 1'b0;
        else
            read_pending <= req_i & ~we_i & any_periph_sel;
    end
    assign rvalid_o = read_pending;

endmodule
