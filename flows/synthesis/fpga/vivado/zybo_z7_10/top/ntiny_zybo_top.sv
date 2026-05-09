// ntiny FPGA wrapper for Zybo Z7-10 (XC7Z010-1CLG400C).
//
// Wraps soc_top with board-level IO. PL-only — does not use the
// Zynq PS, so DDR/Ethernet/USB are not available. Linux requires
// >=128 MB RAM (PS DDR via AXI HP); this skeleton ships PL BRAM
// only, sized by RAM_SIZE_BYTES in mem_map.svh — adequate for
// bare-metal demos. Linux-on-FPGA is gated on bus revamp Phase 3
// (AXI4 master).
//
// IO map:
//   sysclk_i   K17  125 MHz on-board oscillator
//   rst_btn_i  K18  BTN0 (active-high)
//   led_o[3:0] M14/M15/G14/D18  LD0..LD3
//   sw_i[3:0]  G15/P15/W13/T16  SW0..SW3
//   uart_tx_o  V12  Pmod JE pin 1
//   uart_rx_i  W16  Pmod JE pin 2
//
// Unused soc_top peripherals (SPI, I2C, PWM, JTAG TAP) are tied
// off here. Re-expose them by adding ports + XDC mappings.

`timescale 1ns/10ps

module ntiny_zybo_top (
    input  logic        sysclk_i,
    input  logic        rst_btn_i,

    output logic [3:0]  led_o,
    input  logic [3:0]  sw_i,

    output logic        uart_tx_o,
    input  logic        uart_rx_i
);

    // ── Reset synchroniser ──────────────────────────────────
    // BTN0 is active-high. Synchronise to sysclk_i and hold for
    // a few cycles after deassertion so all submodules see a
    // clean reset edge.
    logic [3:0] rst_sync_q;
    logic       reset_active;

    always_ff @(posedge sysclk_i) begin
        rst_sync_q <= {rst_sync_q[2:0], rst_btn_i};
    end
    assign reset_active = rst_sync_q[3];

    // ── soc_top peripheral wiring ───────────────────────────
    logic [31:0] gpio_oen, gpio_o, gpio_i;

    // GPIO[3:0] drive LEDs; gpio_i[3:0] read switches.
    assign led_o = gpio_o[3:0];
    assign gpio_i = {28'b0, sw_i};

    // SPI / I2C / PWM / JTAG — tied off (no XDC mapping).
    logic        spi_mosi, spi_sck;
    logic [7:0]  spi_ss;
    logic        i2c_scl_o, i2c_scl_oen;
    logic        i2c_sda_o, i2c_sda_oen;
    logic        pwm1h, pwm1l, pwm2h, pwm2l;
    logic        jtag_tdo;

    soc_top u_soc_top (
        .clk_i           (sysclk_i),
        .reset_i         (reset_active),

        // UART
        .tx_o            (uart_tx_o),
        .rx_i            (uart_rx_i),

        // SPI (unused on board)
        .mosi_o          (spi_mosi),
        .miso_i          (1'b0),
        .SCK_o           (spi_sck),
        .slave_select_o  (spi_ss),

        // I2C (unused on board) — feedback-loop the open-drain
        // tristate so the controller sees the line it's driving.
        .scl_pad_i       (i2c_scl_oen ? 1'b1 : i2c_scl_o),
        .scl_pad_o       (i2c_scl_o),
        .scl_padoen_o    (i2c_scl_oen),
        .sda_pad_i       (i2c_sda_oen ? 1'b1 : i2c_sda_o),
        .sda_pad_o       (i2c_sda_o),
        .sda_padoen_o    (i2c_sda_oen),

        // GPIO
        .gpio_oen        (gpio_oen),
        .gpio_o          (gpio_o),
        .gpio_i          (gpio_i),

        // PWM (unused)
        .pwm1_h_o        (pwm1h),
        .pwm1_l_o        (pwm1l),
        .pwm2_h_o        (pwm2h),
        .pwm2_l_o        (pwm2l),

        // JTAG TAP (unused — tie off)
        .tms_i           (1'b0),
        .tck_i           (1'b0),
        .tdi_i           (1'b0),
        .tdo_o           (jtag_tdo)
    );

endmodule
