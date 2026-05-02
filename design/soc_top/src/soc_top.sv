`timescale 1ns/10ps
`include "mem_map.svh"
import common_pkg::*;
import debug_pkg::*;
import core_pkg::*;

//`define BOOT
//`define DV_TRACER
//`define FPU

module soc_top
(

    input clk_i,
    input reset_i,

    //peripherals
    //uart
    output 					tx_o,
    input 					rx_i,
    //spi
    output 					mosi_o,
    input 					miso_i,
    output 					SCK_o,
    output 			[7:0] 	slave_select_o,
    //i2c
    input  					scl_pad_i,
    output 					scl_pad_o,
    output 					scl_padoen_o,
    input  					sda_pad_i,
    output 					sda_pad_o,
    output 					sda_padoen_o,
    //gpio
   	output			[31:0] 	gpio_oen,
	output			[31:0] 	gpio_o,
	input 			[31:0] 	gpio_i,
    // PWM
  	output logic 			pwm1_h_o,
	output logic 			pwm1_l_o,
	output logic 			pwm2_h_o,
	output logic 			pwm2_l_o,

	input tms_i,
	input tck_i,
	input tdi_i,
	output tdo_o
);


    // ── Internal bus instances ───────────────────────────────
    mem_bus imem_bus();   // instruction port: core → RAM port A
    mem_bus dmem_bus();   // data port: core → address decoder → RAM/periph

    // ── Address decoder outputs ─────────────────────────────
    logic ram_sel, boot_sel, tohost_sel;
    logic uart_sel, spi_sel, i2c_sel, gpio_sel;
    logic pwm_sel, timer_sel, crc_sel;
    logic clint_sel, plic_sel, soft_sel;

    addr_decoder addr_decoder_inst (
        .addr_i     (dmem_bus.addr),
        .ram_sel_o  (ram_sel),
        .boot_sel_o (boot_sel),
        .uart_sel_o (uart_sel),
        .spi_sel_o  (spi_sel),
        .i2c_sel_o  (i2c_sel),
        .gpio_sel_o (gpio_sel),
        .pwm_sel_o  (pwm_sel),
        .timer_sel_o(timer_sel),
        .crc_sel_o  (crc_sel),
        .clint_sel_o(clint_sel),
        .plic_sel_o (plic_sel),
        .soft_sel_o (soft_sel),
        .tohost_sel_o(tohost_sel)
    );

    // ── Peripheral read data wires ──────────────────────────
    wire [31:0] timer_readdata;
    wire [31:0] gpio_readdata;
    wire [31:0] uart_readdata;
    wire [31:0] spi_readdata;
    wire [31:0] i2c_readdata;
    wire [31:0] pwm_readdata;
    wire [31:0] plic_readdata;
    wire [31:0] clint_readdata;
    wire [31:0] crc_readdata;

    // ── Peripheral bridge ───────────────────────────────────
    logic        periph_write, periph_read;
    logic [31:0] periph_wdata;
    logic        periph_ready;
    logic [31:0] periph_rdata;
    logic        periph_rvalid;
    logic        uart_chipsel, spi_chipsel, i2c_chipsel, gpio_chipsel;
    logic        pwm_chipsel, timer_chipsel, crc_chipsel;
    logic        plic_chipsel, clint_chipsel, soft_chipsel;

    periph_bridge periph_bridge_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i),
        // mem_bus slave side
        .req_i          (dmem_bus.req & ~ram_sel & ~tohost_sel & ~boot_sel),
        .we_i           (dmem_bus.we),
        .addr_i         (dmem_bus.addr),
        .be_i           (dmem_bus.be),
        .wdata_i        (dmem_bus.wdata),
        .rdata_o        (periph_rdata),
        .rvalid_o       (periph_rvalid),
        .ready_o        (periph_ready),
        // Chip selects
        .uart_sel_i     (uart_sel),
        .spi_sel_i      (spi_sel),
        .i2c_sel_i      (i2c_sel),
        .gpio_sel_i     (gpio_sel),
        .pwm_sel_i      (pwm_sel),
        .timer_sel_i    (timer_sel),
        .crc_sel_i      (crc_sel),
        .plic_sel_i     (plic_sel),
        .clint_sel_i    (clint_sel),
        .soft_sel_i     (soft_sel),
        // Peripheral read data
        .uart_rdata_i   (uart_readdata),
        .spi_rdata_i    (spi_readdata),
        .i2c_rdata_i    (i2c_readdata),
        .gpio_rdata_i   (gpio_readdata),
        .pwm_rdata_i    (pwm_readdata),
        .timer_rdata_i  (timer_readdata),
        .crc_rdata_i    (crc_readdata),
        .plic_rdata_i   (plic_readdata),
        .clint_rdata_i  (clint_readdata),
        // Shared outputs
        .write_o        (periph_write),
        .read_o         (periph_read),
        .wdata_o        (periph_wdata),
        // Chipselects to peripherals
        .uart_chipsel_o (uart_chipsel),
        .spi_chipsel_o  (spi_chipsel),
        .i2c_chipsel_o  (i2c_chipsel),
        .gpio_chipsel_o (gpio_chipsel),
        .pwm_chipsel_o  (pwm_chipsel),
        .timer_chipsel_o(timer_chipsel),
        .crc_chipsel_o  (crc_chipsel),
        .plic_chipsel_o (plic_chipsel),
        .clint_chipsel_o(clint_chipsel),
        .soft_chipsel_o (soft_chipsel)
    );

    // ── L1 Caches + Unified Dual-Port RAM ─────────────────────
    // I-Cache: imem_bus → icache → RAM Port A
    // D-Cache: dmem_bus (ram_sel) → dcache → RAM Port B
    // Peripherals bypass D-cache entirely.
    logic fence_i_wire;

    // I-Cache ↔ RAM Port A wires
    logic        ic_mem_req;
    logic [31:0] ic_mem_addr;
    logic [31:0] ic_mem_rdata;
    logic        ic_mem_rvalid;
    logic        ic_mem_ready;

    icache #(
        .ADDR_WIDTH  (32),
        .DATA_WIDTH  (32),
        .CACHE_BYTES (4096)
    ) icache_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i),
        .flush_i      (fence_i_wire),
        // CPU-facing (from core imem_port)
        .cpu_req_i    (imem_bus.req),
        .cpu_addr_i   (imem_bus.addr),
        .cpu_rdata_o  (imem_bus.rdata),
        .cpu_rvalid_o (imem_bus.rvalid),
        .cpu_ready_o  (imem_bus.ready),
        // Memory-facing (to RAM Port A)
        .mem_req_o    (ic_mem_req),
        .mem_addr_o   (ic_mem_addr),
        .mem_rdata_i  (ic_mem_rdata),
        .mem_rvalid_i (ic_mem_rvalid),
        .mem_ready_i  (ic_mem_ready)
    );

    // D-Cache ↔ RAM Port B wires
    logic        dc_mem_req;
    logic        dc_mem_we;
    logic [31:0] dc_mem_addr;
    logic [3:0]  dc_mem_be;
    logic [31:0] dc_mem_wdata;
    logic [31:0] dc_mem_rdata;
    logic        dc_mem_rvalid;
    logic        dc_mem_ready;

    // D-Cache CPU-side outputs
    logic [31:0] dc_cpu_rdata;
    logic        dc_cpu_rvalid;
    logic        dc_cpu_ready;

    dcache #(
        .ADDR_WIDTH  (32),
        .DATA_WIDTH  (32),
        .CACHE_BYTES (4096)
    ) dcache_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i),
        .flush_i      (fence_i_wire),
        // CPU-facing (from core dmem_port, gated by ram_sel)
        .cpu_req_i    (dmem_bus.req & ram_sel),
        .cpu_we_i     (dmem_bus.we),
        .cpu_addr_i   (dmem_bus.addr),
        .cpu_be_i     (dmem_bus.be),
        .cpu_wdata_i  (dmem_bus.wdata),
        .cpu_rdata_o  (dc_cpu_rdata),
        .cpu_rvalid_o (dc_cpu_rvalid),
        .cpu_ready_o  (dc_cpu_ready),
        // Memory-facing (to RAM Port B)
        .mem_req_o    (dc_mem_req),
        .mem_we_o     (dc_mem_we),
        .mem_addr_o   (dc_mem_addr),
        .mem_be_o     (dc_mem_be),
        .mem_wdata_o  (dc_mem_wdata),
        .mem_rdata_i  (dc_mem_rdata),
        .mem_rvalid_i (dc_mem_rvalid),
        .mem_ready_i  (dc_mem_ready)
    );

    // Unified Dual-Port RAM
    ram_dp #(
        .DEPTH    (`RAM_DEPTH),
        .HEX_FILE ("ram.hex")
    ) ram_inst (
        .clk_i       (clk_i),
        // Port A — I-Cache fills (read-only)
        .pa_req_i    (ic_mem_req),
        .pa_addr_i   (ic_mem_addr),
        .pa_rdata_o  (ic_mem_rdata),
        .pa_rvalid_o (ic_mem_rvalid),
        .pa_ready_o  (ic_mem_ready),
        // Port B — D-Cache fills + write-through
        .pb_req_i    (dc_mem_req),
        .pb_we_i     (dc_mem_we),
        .pb_addr_i   (dc_mem_addr),
        .pb_be_i     (dc_mem_be),
        .pb_wdata_i  (dc_mem_wdata),
        .pb_rdata_o  (dc_mem_rdata),
        .pb_rvalid_o (dc_mem_rvalid),
        .pb_ready_o  (dc_mem_ready)
    );

    // ── D-port read data mux ────────────────────────────────
    // Select read data from D-Cache or peripheral bridge
    logic ram_sel_r;
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            ram_sel_r <= 1'b0;
        else
            ram_sel_r <= ram_sel;
    end

    assign dmem_bus.rdata  = ram_sel_r ? dc_cpu_rdata  : periph_rdata;
    assign dmem_bus.rvalid = ram_sel_r ? dc_cpu_rvalid : periph_rvalid;
    assign dmem_bus.ready  = ram_sel   ? dc_cpu_ready  : periph_ready;

    // ── Debug signals ───────────────────────────────────────
    onebit_sig_e ar_en, ar_wr;
    logic [15:0] ar_ad;
    onebit_sig_e ar_done;
    logic [31:0] ar_di, ar_do;
    onebit_sig_e am_en, am_wr;
    logic [3:0]  am_st;
    logic [31:0] am_ad, am_di, am_do;
    onebit_sig_e am_done;
    onebit_sig_e ndmreset;
    onebit_sig_e resumeack, running, halted;
    onebit_sig_e haltreq, resumereq;

    // ── Interrupt signals ───────────────────────────────────
    logic timer_interrupt;
    logic ext_interrupt;     // MEIP (PLIC ctx 0)
    logic s_ext_interrupt;   // SEIP (PLIC ctx 1)
    logic soft_intr;
    logic i2c_interrupt;
    logic spi_interrupt;
    logic uart_tx_interrupt;
    logic uart_rx_interrupt;
    logic [31:0] gpio_itr_sig;
    logic [1:0] gpio_interrupt;

    // ── Core ────────────────────────────────────────────────
    core_top core_top_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i | ndmreset),
        .imem_port      (imem_bus),
        .dmem_port      (dmem_bus),

        .resumeack_o    (resumeack),
        .running_o      (running),
        .halted_o       (halted),
        .haltreq_i      (haltreq),
        .resumereq_i    (resumereq),

        .ar_en_i        (ar_en),
        .ar_wr_i        (ar_wr),
        .ar_ad_i        (ar_ad),
        .ar_done_o      (ar_done),
        .ar_di_i        (ar_do),
        .ar_do_o        (ar_di),

        .am_en_i        (am_en),
        .am_wr_i        (am_wr),
        .am_st_i        (am_st),
        .am_ad_i        (am_ad),
        .am_di_i        (am_do),
        .am_do_o        (am_di),
        .am_done_o      (am_done),

        .ext_itr_i      (ext_interrupt),
        .s_ext_itr_i    (s_ext_interrupt),
        .timer_itr_i    (timer_interrupt),
        .soft_itr_i     (soft_intr),
        .mtime_i        (clint_mtime),
        .fence_i_o      (fence_i_wire)
    );

    // ── Debug module ────────────────────────────────────────
    debug_top debug_top_inst (
        .tms_i      (tms_i),
        .tck_i      (tck_i),
        .trstn_i    (~reset_i),
        .tdi_i      (tdi_i),
        .tdo_o      (tdo_o),

        .rst_i      (reset_i),
        .clk_i      (clk_i),

        .resumeack_i(resumeack),
        .running_i  (running),
        .halted_i   (halted),
        .haltreq_o  (haltreq),
        .resumereq_o(resumereq),
        .ndmreset_o (ndmreset),

        .ar_en_o    (ar_en),
        .ar_wr_o    (ar_wr),
        .ar_ad_o    (ar_ad),
        .ar_done_i  (ar_done),
        .ar_di_i    (ar_di),
        .ar_do_o    (ar_do),

        .am_en_o    (am_en),
        .am_wr_o    (am_wr),
        .am_st_o    (am_st),
        .am_ad_o    (am_ad),
        .am_di_i    (am_di),
        .am_do_o    (am_do),
        .am_done_i  (am_done)
    );

    // ── Peripherals ─────────────────────────────────────────

    // Address slices for peripherals
    wire [2:0] timer_addr = dmem_bus.addr[4:2];
    wire [2:0] gpio_addr  = dmem_bus.addr[3:2];
    wire [7:0] spi_addr   = dmem_bus.addr[7:0];
    wire [7:0] i2c_addr   = dmem_bus.addr[7:0];
    wire [7:0] pwm_addr   = dmem_bus.addr[7:2];
    wire [2:0] crc_addr   = dmem_bus.addr[4:2];

    // (plic_addr removed — new PLIC uses full address)

    logic timer_periph_irq;  // general-purpose timer interrupt (routed to PLIC, not MIP[7])
    timer_top timer_inst (
        .clk_i      (clk_i),
        .stall_i    (1'b0),
        .reset      (reset_i | ndmreset),
        .address    (timer_addr),
        .writedata  (dmem_bus.wdata),
        .write      (periph_write),
        .readdata   (timer_readdata),
        .read       (periph_read),
        .chipselect (timer_chipsel),
        .intr_o     (timer_periph_irq)  // no longer drives MIP[7]; CLINT does
    );

    gpio_top gpio_inst (
        .clk_i          (clk_i),
        .resetn_i       (reset_i | ndmreset),
        .address_i      (gpio_addr),
        .writedata_i    (dmem_bus.wdata),
        .write_i        (periph_write),
        .readdata_o     (gpio_readdata),
        .read_i         (periph_read),
        .chipselect_i   (gpio_chipsel),
        .gpio_oen       (gpio_oen),
        .gpio_i         (gpio_i),
        .gpio_o         (gpio_o),
        .interrupt_reg  (gpio_itr_sig)
    );

    uart_top uart_inst (
        .clk_i          (clk_i),
        .rst_i          (reset_i | ndmreset),
        .address_i      (dmem_bus.addr),
        .writedata_i    (dmem_bus.wdata),
        .write_i        (periph_write & uart_chipsel),
        .readdata_o     (uart_readdata),
        .read_i         (periph_read & uart_chipsel),
        .chipselect_i   (uart_chipsel),
        .rx_i           (rx_i),
        .tx_o           (tx_o),
        .tx_intr_o      (uart_tx_interrupt),
        .rx_intr_o      (uart_rx_interrupt)
    );

    spi_top spi_inst (
        .clk_i          (clk_i),
        .rst_i          (reset_i | ndmreset),
        .write_i        (periph_write & spi_chipsel),
        .read_i         (periph_read & spi_chipsel),
        .chipselect_i   (spi_chipsel),
        .writedata_i    (dmem_bus.wdata),
        .address_i      ({24'd0, dmem_bus.addr[7:0]}),
        .readdata_o     (spi_readdata),
        .spi_cs_o       (slave_select_o),
        .spi_miso_i     (miso_i),
        .spi_mosi_o     (mosi_o),
        .intr_o         (spi_interrupt),
        .spi_clk_o      (SCK_o)
    );

    i2c_top i2c_inst (
        .clk_i          (clk_i),
        .rstn_i         (reset_i | ndmreset),
        .avl_addr       (i2c_addr),
        .avl_wdata      (dmem_bus.wdata),
        .avl_write      (periph_write & i2c_chipsel),
        .avl_chipsel    (i2c_chipsel),
        .avl_rdata      (i2c_readdata),
        .interrupt_o    (i2c_interrupt),
        .scl_pad_i      (scl_pad_i),
        .scl_pad_o      (scl_pad_o),
        .scl_padoen_o   (scl_padoen_o),
        .sda_pad_i      (sda_pad_i),
        .sda_pad_o      (sda_pad_o),
        .sda_padoen_o   (sda_padoen_o),
        .test           ()
    );

    pwm_top pwm_inst (
        .clk_i          (clk_i),
        .rst_i          (reset_i | ndmreset),
        .address_i      (pwm_addr),
        .writedata_i    (dmem_bus.wdata),
        .write_i        (periph_write & pwm_chipsel),
        .readdata_o     (pwm_readdata),
        .read_i         (periph_read & pwm_chipsel),
        .chipselect_i   (pwm_chipsel),
        .pwm1_h_o       (pwm1_h_o),
        .pwm1_l_o       (pwm1_l_o),
        .pwm2_h_o       (pwm2_h_o),
        .pwm2_l_o       (pwm2_l_o)
    );

    crc_avalon_wrap crc_avalon_wrap_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i | ndmreset),
        .write_i        (periph_write),
        .read_i         (periph_read),
        .chipselect_i   (crc_chipsel),
        .writedata_i    (dmem_bus.wdata),
        .address_i      (crc_addr),
        .readdata_o     (crc_readdata)
    );

    // ── CLINT (Core Local Interruptor) ────────────────────────
    // Drives timer_interrupt (MTIP) and soft_intr (MSIP).
    // Replaces the old software interrupt register.
    logic clint_timer_irq, clint_soft_irq;
    logic [63:0] clint_mtime;

    clint clint_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i | ndmreset),
        .chipselect_i (clint_chipsel),
        .write_i      (periph_write),
        .read_i       (periph_read),
        .address_i    (dmem_bus.addr[15:0]),
        .writedata_i  (dmem_bus.wdata),
        .readdata_o   (clint_readdata),
        .timer_irq_o  (clint_timer_irq),
        .soft_irq_o   (clint_soft_irq),
        .mtime_o      (clint_mtime)
    );

    // CLINT drives M-mode timer and software interrupts to the core
    assign timer_interrupt = clint_timer_irq;
    assign soft_intr       = clint_soft_irq;

    // ── PLIC (spec-compliant, memory-mapped claim/complete) ──
    assign gpio_interrupt = gpio_itr_sig[3:2];

    plic_rv #(
        .NUM_SOURCES   (6),
        .PRIORITY_BITS (3)
    ) plic_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i | ndmreset),
        .chipselect_i (plic_chipsel),
        .write_i      (periph_write),
        .read_i       (periph_read),
        .address_i    (dmem_bus.addr[21:0]),
        .writedata_i  (dmem_bus.wdata),
        .readdata_o   (plic_readdata),
        // Sources: 1=uart_rx, 2=uart_tx, 3=spi, 4=i2c, 5=gpio[0], 6=gpio[1]
        .sources_i    ({gpio_interrupt, i2c_interrupt, spi_interrupt,
                        uart_tx_interrupt, uart_rx_interrupt}),
        .ext_irq_m_o  (ext_interrupt),
        .ext_irq_s_o  (s_ext_interrupt)
    );

endmodule
