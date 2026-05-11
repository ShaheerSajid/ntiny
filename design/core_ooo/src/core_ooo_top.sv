// OoO core v1 — top
//
// Port list matches design/core/core_top/src/core_top.sv so the SoC
// can swap cores by parameter. Debug / abstract-memory ports tied off
// at M0 — wired in later when there's a reason.
//
// M0 datapath: 2-stage in-order pipeline.
//   IF       — fetch.sv drives imem; on rvalid emits {pc, instr, valid}
//   ID/EX    — decode.sv → regfile reads → execute.sv (ALU + branch
//              resolution + address gen) and memunit.sv for LOAD/STORE
//   WB       — synchronous regfile write driven by ALU path (same
//              cycle as EX) or by memunit's load_valid (multi-cycle
//              later). The two writeback sources are temporally
//              disjoint in the in-order pipeline.
//
// Rename/ROB/RS/LSQ land in M1+.

import common_pkg::*;
import core_pkg::*;
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
    // TODO: route from SoC's mem_map once the new core is plumbed in.
    localparam logic [31:0] RESET_PC = 32'h0000_0000;

    // ── pipeline-wide nets ─────────────────────────────────────
    logic         fetch_stall;
    logic         redirect;
    logic [31:0]  redirect_pc;

    // ── IF ─────────────────────────────────────────────────────
    logic [31:0]  if_instr;
    logic [31:0]  if_pc;
    onebit_sig_e  if_valid;

    fetch fetch_inst (
        .clk_i         (clk_i),
        .reset_i       (reset_i),
        .reset_pc_i    (RESET_PC),
        .stall_i       (fetch_stall),
        .redirect_i    (redirect),
        .redirect_pc_i (redirect_pc),
        .imem_port     (imem_port),
        .instr_o       (if_instr),
        .pc_o          (if_pc),
        .valid_o       (if_valid)
    );

    // ── ID ─────────────────────────────────────────────────────
    uop_t id_uop;

    decode decode_inst (
        .instr_i (if_instr),
        .pc_i    (if_pc),
        .valid_i (if_valid),
        .uop_o   (id_uop)
    );

    // ── arch regfile (integer) ─────────────────────────────────
    logic [31:0]  rf_rdataA, rf_rdataB;
    logic [31:0]  wb_data;
    logic [4:0]   wb_rd;
    onebit_sig_e  wb_wen;

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

    // ── EX (ALU + branch + address gen) ────────────────────────
    logic [31:0]  ex_alu_result;
    logic [4:0]   ex_rd;
    onebit_sig_e  ex_int_wen;
    onebit_sig_e  ex_alu_busy;
    logic [31:0]  ex_mem_addr;
    logic [31:0]  ex_store_data;

    // EX issues only when memunit is IDLE (in-order semantics: a pending
    // LOAD/STORE must complete before the next op enters EX).
    onebit_sig_e  mem_busy;
    onebit_sig_e  ex_issue;
    assign ex_issue = onebit_sig_e'(if_valid == TRUE && mem_busy == FALSE);

    execute execute_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i),
        .stall_i      (1'b0),
        .flush_i      (1'b0),
        .uop_i        (id_uop),
        .rs1_val_i    (rf_rdataA),
        .rs2_val_i    (rf_rdataB),
        .issue_i      (ex_issue),
        .alu_result_o (ex_alu_result),
        .rd_o         (ex_rd),
        .int_wen_o    (ex_int_wen),
        .alu_busy_o   (ex_alu_busy),
        .mem_addr_o   (ex_mem_addr),
        .store_data_o (ex_store_data),
        .redirect_o   (redirect),
        .redirect_pc_o(redirect_pc)
    );

    // ── memunit (LOAD/STORE) ───────────────────────────────────
    wire         is_mem    = (id_uop.fu == FU_LOAD) || (id_uop.fu == FU_STORE);
    onebit_sig_e mem_kick;
    assign mem_kick = onebit_sig_e'(is_mem
                                    && ex_issue == TRUE
                                    && id_uop.illegal == FALSE);

    logic [31:0]  mem_load_data;
    logic [4:0]   mem_load_rd;
    onebit_sig_e  mem_load_valid;

    memunit memunit_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i),
        .flush_i        (1'b0),
        .kick_i         (mem_kick),
        .fu_i           (id_uop.fu),
        .addr_i         (ex_mem_addr),
        .store_data_i   (ex_store_data),
        .width_i        (id_uop.ls_width),
        .mem_unsigned_i (id_uop.mem_unsigned),
        .rd_i           (id_uop.rd),
        .dmem_port      (dmem_port),
        .load_data_o    (mem_load_data),
        .load_rd_o      (mem_load_rd),
        .load_valid_o   (mem_load_valid),
        .busy_o         (mem_busy)
    );

    // ── writeback mux ──────────────────────────────────────────
    // ALU path and LOAD path are temporally disjoint in the in-order
    // pipeline: an ALU op completes in its EX cycle, a LOAD completes
    // some cycles after EX while fetch is stalled.
    always_comb begin
        if (mem_load_valid == TRUE) begin
            wb_wen  = TRUE;
            wb_rd   = mem_load_rd;
            wb_data = mem_load_data;
        end else if (ex_int_wen == TRUE) begin
            wb_wen  = TRUE;
            wb_rd   = ex_rd;
            wb_data = ex_alu_result;
        end else begin
            wb_wen  = FALSE;
            wb_rd   = 5'd0;
            wb_data = 32'b0;
        end
    end

    // ── fetch stall ────────────────────────────────────────────
    // Hold fetch when: starting a memory op this cycle, memunit busy,
    // or ALU multi-cycle busy (M2: div).
    assign fetch_stall = (mem_kick == TRUE)
                       || (mem_busy == TRUE)
                       || (ex_alu_busy == TRUE);

    // ── unused-input sink (lint) ───────────────────────────────
    wire _unused = &{1'b0, ext_itr_i, s_ext_itr_i, timer_itr_i, soft_itr_i,
                     |mtime_i, haltreq_i, resumereq_i,
                     ar_en_i, ar_wr_i, |ar_ad_i, |ar_di_i,
                     am_en_i, am_wr_i, |am_st_i, |am_ad_i, |am_di_i,
                     1'b0};

endmodule
