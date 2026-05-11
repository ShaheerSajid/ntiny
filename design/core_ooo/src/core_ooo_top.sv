// OoO core v1 — top (M1 pipeline)
//
// 4 logical stages:
//
//   IF       fetch.sv → {pc, instr, valid}
//   DISPATCH decode.sv + RAT lookup + arch-regfile read + ROB peek
//            → ROB.alloc; RAT updated at posedge
//   ISSUE+EX+WB  ROB.issue_ptr drives execute.sv / memunit.sv;
//                ALU/branch wb fires this cycle, memunit wb fires
//                multiple cycles later via op_done
//   COMMIT   ROB head when ready → arch regfile write
//
// Branch handling (M1, pre-recovery): on taken branch at EX, redirect
// fetch AND flush all non-head ROB entries AND clear RAT busy bits.
// Same cycle, dispatch_en is suppressed so the in-flight rvalid is
// not allocated (it's on the mispredicted path).
//
// M3 replaces the wholesale RAT flush with snapshot-restore.

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

    // ── debug / abstract / fence: tied off at M1 ───────────────
    assign resumeack_o = FALSE;
    assign running_o   = TRUE;
    assign halted_o    = FALSE;
    assign ar_done_o   = TRUE;
    assign ar_do_o     = 32'b0;
    assign am_done_o   = TRUE;
    assign am_do_o     = 32'b0;
    assign fence_i_o   = 1'b0;

    localparam logic [31:0] RESET_PC = 32'h0000_0000;

    // ── nets ──────────────────────────────────────────────────
    // IF
    logic [31:0]   if_instr;
    logic [31:0]   if_pc;
    onebit_sig_e   if_valid;

    // Decode
    uop_t          id_uop;

    // RAT
    logic                       rat_rs1_busy, rat_rs2_busy;
    logic [OOO_ROB_IDX_W-1:0]   rat_rs1_idx,  rat_rs2_idx;

    // Arch regfile
    logic [31:0]                rf_rdataA, rf_rdataB;

    // Dispatch source resolution
    logic                       alloc_rs1_busy_to_rob;
    logic                       alloc_rs2_busy_to_rob;
    logic [31:0]                alloc_rs1_value;
    logic [31:0]                alloc_rs2_value;

    // ROB
    logic                       rob_full;
    logic [OOO_ROB_IDX_W-1:0]   rob_alloc_idx;
    logic                       rob_peek1_ready, rob_peek2_ready;
    logic [31:0]                rob_peek1_result, rob_peek2_result;
    logic                       rob_issue_valid;
    logic [OOO_ROB_IDX_W-1:0]   rob_issue_idx;
    uop_t                       rob_issue_uop;
    logic [31:0]                rob_issue_rs1_val, rob_issue_rs2_val;
    logic                       rob_commit_valid;
    logic [OOO_ROB_IDX_W-1:0]   rob_commit_idx;
    uop_t                       rob_commit_uop;
    logic [31:0]                rob_commit_result;

    // Issue / EX
    onebit_sig_e                alu_wb_en;
    logic [OOO_ROB_IDX_W-1:0]   alu_wb_idx;
    logic [31:0]                alu_wb_result;
    onebit_sig_e                ex_alu_busy;
    logic [31:0]                ex_mem_addr, ex_store_data;
    logic                       ex_redirect;
    logic [31:0]                ex_redirect_pc;

    // Memunit
    onebit_sig_e                mem_busy;
    onebit_sig_e                mem_done;
    logic [OOO_ROB_IDX_W-1:0]   mem_done_idx;
    logic [31:0]                mem_done_result;

    // Commit → arch regfile
    onebit_sig_e                commit_wb_wen;
    logic [4:0]                 commit_wb_rd;
    logic [31:0]                commit_wb_data;

    // Pipeline-wide control
    logic                       dispatch_en;
    logic                       issue_fire;
    logic                       commit_consume;
    logic                       fetch_stall;
    logic                       flush_younger;
    logic                       rat_flush;

    // ── IF ────────────────────────────────────────────────────
    fetch fetch_inst (
        .clk_i         (clk_i),
        .reset_i       (reset_i),
        .reset_pc_i    (RESET_PC),
        .stall_i       (fetch_stall),
        .redirect_i    (ex_redirect),
        .redirect_pc_i (ex_redirect_pc),
        .imem_port     (imem_port),
        .instr_o       (if_instr),
        .pc_o          (if_pc),
        .valid_o       (if_valid)
    );

    // ── DECODE ────────────────────────────────────────────────
    decode decode_inst (
        .instr_i (if_instr),
        .pc_i    (if_pc),
        .valid_i (if_valid),
        .uop_o   (id_uop)
    );

    // ── RAT ───────────────────────────────────────────────────
    rat rat_inst (
        .clk_i             (clk_i),
        .reset_i           (reset_i),
        .flush_i           (rat_flush),
        .rs1_addr_i        (id_uop.rs1),
        .rs2_addr_i        (id_uop.rs2),
        .rs1_busy_o        (rat_rs1_busy),
        .rs1_rob_idx_o     (rat_rs1_idx),
        .rs2_busy_o        (rat_rs2_busy),
        .rs2_rob_idx_o     (rat_rs2_idx),
        .write_en_i        (dispatch_en && id_uop.has_rd == TRUE),
        .write_addr_i      (id_uop.rd),
        .write_rob_idx_i   (rob_alloc_idx),
        .clear_en_i        (commit_consume && rob_commit_uop.has_rd == TRUE),
        .clear_addr_i      (rob_commit_uop.rd),
        .clear_check_idx_i (rob_commit_idx)
    );

    // ── arch regfile ──────────────────────────────────────────
    reg_file #(.ZERO_REG(1)) int_rf_inst (
        .clk_i     (clk_i),
        .reset_i   (reset_i),
        .stall_i   (1'b0),
        .write_i   (commit_wb_wen == TRUE),
        .wraddr_i  (commit_wb_rd),
        .wrdata_i  (commit_wb_data),
        .rdaddra_i (id_uop.rs1),
        .rdaddrb_i (id_uop.rs2),
        .rdaddrc_i (5'd0),
        .rddataa_o (rf_rdataA),
        .rddatab_o (rf_rdataB),
        .rddatac_o ()
    );

    // ── dispatch source resolution ────────────────────────────
    // If the source is renamed, prefer (a) the value via ROB peek
    // when the producer has already written back in a prior cycle,
    // or (b) wb1 / wb2 result this cycle when the producer's
    // writeback coincides with our dispatch. Otherwise capture the
    // tag and rely on the in-ROB wakeup loop.
    wire wb1_to_rs1 = (alu_wb_en == TRUE) && (alu_wb_idx == rat_rs1_idx);
    wire wb2_to_rs1 = (mem_done  == TRUE) && (mem_done_idx == rat_rs1_idx);
    wire wb1_to_rs2 = (alu_wb_en == TRUE) && (alu_wb_idx == rat_rs2_idx);
    wire wb2_to_rs2 = (mem_done  == TRUE) && (mem_done_idx == rat_rs2_idx);

    wire rs1_resolved_now = rat_rs1_busy
                            && (rob_peek1_ready || wb1_to_rs1 || wb2_to_rs1);
    wire rs2_resolved_now = rat_rs2_busy
                            && (rob_peek2_ready || wb1_to_rs2 || wb2_to_rs2);

    assign alloc_rs1_busy_to_rob = rat_rs1_busy && !rs1_resolved_now;
    assign alloc_rs2_busy_to_rob = rat_rs2_busy && !rs2_resolved_now;

    always_comb begin
        if (rat_rs1_busy) begin
            if      (rob_peek1_ready) alloc_rs1_value = rob_peek1_result;
            else if (wb1_to_rs1)      alloc_rs1_value = alu_wb_result;
            else if (wb2_to_rs1)      alloc_rs1_value = mem_done_result;
            else                       alloc_rs1_value = 32'b0;
        end else begin
            alloc_rs1_value = rf_rdataA;
        end
        if (rat_rs2_busy) begin
            if      (rob_peek2_ready) alloc_rs2_value = rob_peek2_result;
            else if (wb1_to_rs2)      alloc_rs2_value = alu_wb_result;
            else if (wb2_to_rs2)      alloc_rs2_value = mem_done_result;
            else                       alloc_rs2_value = 32'b0;
        end else begin
            alloc_rs2_value = rf_rdataB;
        end
    end

    // Dispatch fires when a valid uop is present, ROB has room, and
    // we're not redirecting (which would dispatch a mispredicted
    // instruction).
    assign dispatch_en = (id_uop.valid == TRUE) && !rob_full && !ex_redirect;

    // ── ROB ───────────────────────────────────────────────────
    rob rob_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .flush_younger_i    (flush_younger),
        .flush_after_idx_i  (rob_issue_idx),

        .alloc_en_i         (dispatch_en),
        .alloc_idx_o        (rob_alloc_idx),
        .full_o             (rob_full),
        .alloc_uop_i        (id_uop),
        .alloc_rs1_value_i  (alloc_rs1_value),
        .alloc_rs1_busy_i   (alloc_rs1_busy_to_rob),
        .alloc_rs1_tag_i    (rat_rs1_idx),
        .alloc_rs2_value_i  (alloc_rs2_value),
        .alloc_rs2_busy_i   (alloc_rs2_busy_to_rob),
        .alloc_rs2_tag_i    (rat_rs2_idx),

        .peek1_idx_i        (rat_rs1_idx),
        .peek1_ready_o      (rob_peek1_ready),
        .peek1_result_o     (rob_peek1_result),
        .peek2_idx_i        (rat_rs2_idx),
        .peek2_ready_o      (rob_peek2_ready),
        .peek2_result_o     (rob_peek2_result),

        .issue_valid_o      (rob_issue_valid),
        .issue_idx_o        (rob_issue_idx),
        .issue_uop_o        (rob_issue_uop),
        .issue_rs1_value_o  (rob_issue_rs1_val),
        .issue_rs2_value_o  (rob_issue_rs2_val),
        .issue_consume_i    (issue_fire),

        .wb1_en_i           (alu_wb_en == TRUE),
        .wb1_idx_i          (alu_wb_idx),
        .wb1_result_i       (alu_wb_result),
        .wb2_en_i           (mem_done == TRUE),
        .wb2_idx_i          (mem_done_idx),
        .wb2_result_i       (mem_done_result),

        .commit_valid_o     (rob_commit_valid),
        .commit_idx_o       (rob_commit_idx),
        .commit_uop_o       (rob_commit_uop),
        .commit_result_o    (rob_commit_result),
        .commit_consume_i   (commit_consume)
    );

    // ── ISSUE ─────────────────────────────────────────────────
    wire is_mem_issue  = (rob_issue_uop.fu == FU_LOAD) || (rob_issue_uop.fu == FU_STORE);
    wire can_issue_mem = !is_mem_issue || (mem_busy == FALSE);
    assign issue_fire  = rob_issue_valid && can_issue_mem;
    onebit_sig_e issue_fire_e;
    assign issue_fire_e = onebit_sig_e'(issue_fire);

    // ── EX ────────────────────────────────────────────────────
    execute execute_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i),
        .stall_i        (1'b0),
        .flush_i        (1'b0),
        .uop_i          (rob_issue_uop),
        .rs1_val_i      (rob_issue_rs1_val),
        .rs2_val_i      (rob_issue_rs2_val),
        .issue_idx_i    (rob_issue_idx),
        .issue_i        (issue_fire_e),
        .alu_wb_en_o    (alu_wb_en),
        .alu_wb_idx_o   (alu_wb_idx),
        .alu_wb_result_o(alu_wb_result),
        .alu_busy_o     (ex_alu_busy),
        .mem_addr_o     (ex_mem_addr),
        .store_data_o   (ex_store_data),
        .redirect_o     (ex_redirect),
        .redirect_pc_o  (ex_redirect_pc)
    );

    // ── MEMUNIT ───────────────────────────────────────────────
    onebit_sig_e mem_kick;
    assign mem_kick = onebit_sig_e'(issue_fire && is_mem_issue
                                     && rob_issue_uop.illegal == FALSE);

    memunit memunit_inst (
        .clk_i             (clk_i),
        .reset_i           (reset_i),
        .flush_i           (1'b0),
        .kick_i            (mem_kick),
        .fu_i              (rob_issue_uop.fu),
        .addr_i            (ex_mem_addr),
        .store_data_i      (ex_store_data),
        .width_i           (rob_issue_uop.ls_width),
        .mem_unsigned_i    (rob_issue_uop.mem_unsigned),
        .rob_idx_i         (rob_issue_idx),
        .dmem_port         (dmem_port),
        .op_done_o         (mem_done),
        .op_done_rob_idx_o (mem_done_idx),
        .op_done_result_o  (mem_done_result),
        .busy_o            (mem_busy)
    );

    // ── BRANCH RECOVERY ───────────────────────────────────────
    assign flush_younger = ex_redirect;
    assign rat_flush     = ex_redirect;

    // ── COMMIT ────────────────────────────────────────────────
    assign commit_consume = rob_commit_valid;

    always_comb begin
        if (rob_commit_valid && rob_commit_uop.has_rd == TRUE
            && rob_commit_uop.illegal == FALSE) begin
            commit_wb_wen  = TRUE;
            commit_wb_rd   = rob_commit_uop.rd;
            commit_wb_data = rob_commit_result;
        end else begin
            commit_wb_wen  = FALSE;
            commit_wb_rd   = 5'd0;
            commit_wb_data = 32'b0;
        end
    end

    // ── FETCH STALL ───────────────────────────────────────────
    // ROB acts as a buffer between fetch and EX, so fetch only needs
    // to stall when ROB is full. Memunit-busy / ALU-busy are absorbed
    // by issue blocking — dispatch continues filling ROB.
    assign fetch_stall = rob_full;

    // ── lint sink ─────────────────────────────────────────────
    wire _unused = &{1'b0, ext_itr_i, s_ext_itr_i, timer_itr_i, soft_itr_i,
                     |mtime_i, haltreq_i, resumereq_i,
                     ar_en_i, ar_wr_i, |ar_ad_i, |ar_di_i,
                     am_en_i, am_wr_i, |am_st_i, |am_ad_i, |am_di_i,
                     ex_alu_busy, 1'b0};

endmodule
