// OoO core v1 — top
//
// Port list matches design/core/core_top/src/core_top.sv so the SoC
// can swap cores by parameter. Debug (JTAG) and abstract-memory-access
// ports are tied off at M0 — they come back in once there's a reason.
//
// At M0 this top is a *skeleton* — the IF/ID/EX/WB datapath is stubbed.
// Filling in the in-order RV32I path is the rest of M0's work.

import common_pkg::*;
import core_pkg::*;
import debug_pkg::*;
import core_ooo_pkg::*;

module core_ooo_top
(
    input  logic            clk_i,
    input  logic            reset_i,

    mem_bus.master          imem_port,
    mem_bus.master          dmem_port,

    output onebit_sig_e     resumeack_o,
    output onebit_sig_e     running_o,
    output onebit_sig_e     halted_o,

    input  onebit_sig_e     haltreq_i,
    input  onebit_sig_e     resumereq_i,

    input  onebit_sig_e     ar_en_i,
    input  onebit_sig_e     ar_wr_i,
    input  [15:0]           ar_ad_i,
    output onebit_sig_e     ar_done_o,
    input  [31:0]           ar_di_i,
    output logic [31:0]     ar_do_o,

    input  onebit_sig_e     am_en_i,
    input  onebit_sig_e     am_wr_i,
    input  [3:0]            am_st_i,
    input  [31:0]           am_ad_i,
    input  [31:0]           am_di_i,
    output [31:0]           am_do_o,
    output onebit_sig_e     am_done_o,

    input  ext_itr_i,
    input  s_ext_itr_i,
    input  timer_itr_i,
    input  soft_itr_i,
    input  [63:0]           mtime_i,

    output logic            fence_i_o
);

    // ── debug / abstract / fence: tied off at M0 ───────────────
    assign resumeack_o = FALSE;
    assign running_o   = TRUE;
    assign halted_o    = FALSE;
    assign ar_done_o   = TRUE;
    assign ar_do_o     = 32'b0;
    assign am_done_o   = TRUE;
    assign am_do_o     = 32'b0;
    assign fence_i_o   = 1'b0;

    // ── reset PC ───────────────────────────────────────────────
    // TODO(M0): pull from a mem_map.svh-style constant once the new
    // core picks up the SoC's reset vector.
    localparam logic [31:0] RESET_PC = 32'h0000_0000;

    // ── front-end ──────────────────────────────────────────────
    logic [31:0]   if_instr;
    logic [31:0]   if_pc;
    onebit_sig_e   if_valid;

    fetch fetch_inst (
        .clk_i         (clk_i),
        .reset_i       (reset_i),
        .reset_pc_i    (RESET_PC),
        .stall_i       (1'b0),         // TODO(M0): wire dispatch stall
        .redirect_i    (1'b0),         // TODO(M3): branch redirect
        .redirect_pc_i (32'b0),
        .imem_port     (imem_port),
        .instr_o       (if_instr),
        .pc_o          (if_pc),
        .valid_o       (if_valid)
    );

    // ── decode ─────────────────────────────────────────────────
    uop_t id_uop;

    decode decode_inst (
        .instr_i (if_instr),
        .pc_i    (if_pc),
        .valid_i (if_valid),
        .uop_o   (id_uop)
    );

    // ── regfile (integer arch state) ───────────────────────────
    // TODO(M0): wire rs1/rs2 reads from id_uop, rd writeback from EX.
    logic [31:0] rf_rdataA, rf_rdataB;
    logic [31:0] wb_data;
    logic [4:0]  wb_rd;
    onebit_sig_e wb_wen;

    reg_file #(.ZERO_REG(1)) int_rf_inst (
        .clk_i     (clk_i),
        .reset_i   (reset_i),
        .stall_i   (1'b0),
        .write_i   (wb_wen == TRUE),
        .wraddr_i  (wb_rd),
        .wrdata_i  (wb_data),
        .rdaddra_i (id_uop.rs1),
        .rdaddrb_i (id_uop.rs2),
        .rdaddrc_i (5'd0),
        .rddataa_o (rf_rdataA),
        .rddatab_o (rf_rdataB),
        .rddatac_o ()
    );

    // ── execute (M0: single in-order FU) ───────────────────────
    execute execute_inst (
        .clk_i    (clk_i),
        .reset_i  (reset_i),
        .uop_i    (id_uop),
        .opA_i    (rf_rdataA),
        .opB_i    (rf_rdataB),
        .issue_i  (id_uop.valid),
        .result_o (wb_data),
        .rd_o     (wb_rd),
        .wen_o    (wb_wen),
        .ready_o  ()
    );

    // ── dmem: tied off at M0 (no loads/stores yet) ─────────────
    // TODO(M0): wire up the LSQ stub once decode supports LOAD/STORE.
    assign dmem_port.req   = 1'b0;
    assign dmem_port.we    = 1'b0;
    assign dmem_port.addr  = 32'b0;
    assign dmem_port.be    = 4'b0;
    assign dmem_port.wdata = 32'b0;

    // ── interrupts / mtime: unused at M0 ───────────────────────
    // (referenced to silence lint until M7 wires them in)
    wire _unused = &{1'b0, ext_itr_i, s_ext_itr_i, timer_itr_i,
                     soft_itr_i, |mtime_i, haltreq_i, resumereq_i,
                     ar_en_i, ar_wr_i, |ar_ad_i, |ar_di_i,
                     am_en_i, am_wr_i, |am_st_i, |am_ad_i, |am_di_i,
                     1'b0};

endmodule
