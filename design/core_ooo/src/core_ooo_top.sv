// OoO core v1 — top (M3 phase A pipeline)
//
// 5 logical stages:
//
//   IF       fetch.sv → {pc, instr, valid}
//   DISPATCH decode + RAT lookup + arch-regfile read + ROB peek
//            → ROB.alloc + RS.alloc into the right bank
//            (also: snapshot RAT on branch-class dispatch)
//   ISSUE    each RS bank picks its lowest-index ready slot
//            independently
//   EX       ALU FU (ALU/branch ops) + memunit (LOAD/STORE)
//            + muldiv_unit (MUL/MULH*/DIV/REM)
//   WB       CDB-style (3-wide); all three RS banks + ROB see
//            every broadcast
//   COMMIT   ROB head when ready → arch regfile write
//
// Three RS banks:
//   alu_rs    (FU_ALU + FU_BRANCH)        → execute.sv (ALU FU)
//   lsu_rs    (FU_LOAD + FU_STORE)        → memunit.sv
//   muldiv_rs (FU_MULDIV)                 → muldiv_unit.sv
//
// M3-A — branch recovery moves from a wholesale "selective flush" of
// the RAT to per-branch RAT snapshot + restore. A small N_SNAP=4
// snapshot ring captures the post-update RAT at every branch
// dispatch; on mispredict the matching snapshot is reloaded in one
// cycle. This restores RAT entries that were pointing at OLDER
// surviving in-flight producers (the wholesale-flush version cleared
// them, falling through to a stale arch regfile — latent bug). It
// also drains any in-flight muldiv op that's younger than the
// mispredicted branch (memunit is safe via its head-gating; muldiv
// has no such gate).
//
// Next: M3-B — 2-bit BHT predictor in fetch (we currently
// predict-not-taken implicitly).

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

    // ── debug / abstract / fence: tied off ───────────────────
    assign resumeack_o = FALSE;
    assign running_o   = TRUE;
    assign halted_o    = FALSE;
    assign ar_done_o   = TRUE;
    assign ar_do_o     = 32'b0;
    assign am_done_o   = TRUE;
    assign am_do_o     = 32'b0;
    assign fence_i_o   = 1'b0;

    localparam logic [31:0] RESET_PC = 32'h0000_0000;
    localparam int ALU_RS_DEPTH = OOO_ALU_RS_DEPTH;     // 4
    localparam int LSU_RS_DEPTH = 2;                    // small for M2-A
    localparam int MD_RS_DEPTH  = OOO_MD_RS_DEPTH;      // 2

    // ── nets ─────────────────────────────────────────────────
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

    // ROB
    logic                       rob_full;
    logic [OOO_ROB_IDX_W-1:0]   rob_alloc_idx;
    logic [OOO_ROB_IDX_W-1:0]   rob_tail;
    logic [OOO_ROB_IDX_W-1:0]   rob_head;
    logic                       rob_peek1_ready, rob_peek2_ready;
    logic [31:0]                rob_peek1_result, rob_peek2_result;
    logic                       rob_commit_valid;
    logic [OOO_ROB_IDX_W-1:0]   rob_commit_idx;
    uop_t                       rob_commit_uop;
    logic [31:0]                rob_commit_result;

    // ALU RS
    logic                                 alu_rs_full;
    logic                                 alu_rs_issue_valid;
    uop_t                                 alu_rs_issue_uop;
    logic [OOO_ROB_IDX_W-1:0]             alu_rs_issue_rob_idx;
    logic [31:0]                          alu_rs_issue_rs1_val, alu_rs_issue_rs2_val;
    logic [ALU_RS_DEPTH-1:0]              alu_rs_busy_mask;
    logic [OOO_ROB_IDX_W-1:0]             alu_rs_rob_idx_of [0:ALU_RS_DEPTH-1];
    fu_type_e                             alu_rs_fu_of      [0:ALU_RS_DEPTH-1];
    logic [ALU_RS_DEPTH-1:0]              alu_rs_squash_mask;

    // LSU RS
    logic                                 lsu_rs_full;
    logic                                 lsu_rs_issue_valid;
    uop_t                                 lsu_rs_issue_uop;
    logic [OOO_ROB_IDX_W-1:0]             lsu_rs_issue_rob_idx;
    logic [31:0]                          lsu_rs_issue_rs1_val, lsu_rs_issue_rs2_val;
    logic [LSU_RS_DEPTH-1:0]              lsu_rs_busy_mask;
    logic [OOO_ROB_IDX_W-1:0]             lsu_rs_rob_idx_of [0:LSU_RS_DEPTH-1];
    fu_type_e                             lsu_rs_fu_of      [0:LSU_RS_DEPTH-1];
    logic [LSU_RS_DEPTH-1:0]              lsu_rs_squash_mask;
    logic [LSU_RS_DEPTH-1:0]              lsu_rs_block_mask;

    // MULDIV RS
    logic                                 md_rs_full;
    logic                                 md_rs_issue_valid;
    uop_t                                 md_rs_issue_uop;
    logic [OOO_ROB_IDX_W-1:0]             md_rs_issue_rob_idx;
    logic [31:0]                          md_rs_issue_rs1_val, md_rs_issue_rs2_val;
    logic [MD_RS_DEPTH-1:0]               md_rs_busy_mask;
    logic [OOO_ROB_IDX_W-1:0]             md_rs_rob_idx_of [0:MD_RS_DEPTH-1];
    fu_type_e                             md_rs_fu_of      [0:MD_RS_DEPTH-1];
    logic [MD_RS_DEPTH-1:0]               md_rs_squash_mask;

    // FU outputs
    onebit_sig_e                alu_wb_en;
    logic [OOO_ROB_IDX_W-1:0]   alu_wb_idx;
    logic [31:0]                alu_wb_result;
    onebit_sig_e                ex_alu_busy;
    logic [31:0]                ex_mem_addr, ex_store_data;
    logic                       ex_redirect;
    logic [31:0]                ex_redirect_pc;

    onebit_sig_e                mem_busy;
    onebit_sig_e                mem_done;
    logic [OOO_ROB_IDX_W-1:0]   mem_done_idx;
    logic [31:0]                mem_done_result;

    onebit_sig_e                md_busy;
    onebit_sig_e                md_done;
    logic [OOO_ROB_IDX_W-1:0]   md_done_idx;
    logic [31:0]                md_done_result;

    // Commit
    onebit_sig_e                commit_wb_wen;
    logic [4:0]                 commit_wb_rd;
    logic [31:0]                commit_wb_data;
    logic                       commit_consume;

    // Dispatch routing
    logic                       dispatch_en;        // any dispatch this cycle
    logic                       dispatch_to_alu_rs;
    logic                       dispatch_to_lsu_rs;
    logic                       dispatch_to_md_rs;
    logic                       alloc_rs1_busy_to_rs;
    logic                       alloc_rs2_busy_to_rs;
    logic [31:0]                alloc_rs1_value, alloc_rs2_value;

    // Pipeline-wide control
    logic                       fetch_stall;
    logic                       flush_younger;

    // ── M3-A snapshot ring ───────────────────────────────────
    // One snapshot per in-flight branch. With N_SNAP=4 the ring
    // covers up to 4 nested branches; a 5th branch dispatch stalls
    // until an older one resolves or commits. Branchy code averages
    // ~3 in-flight branches at ROB_DEPTH=16, so 4 has headroom.
    localparam int N_SNAP     = 4;
    localparam int SNAP_IDX_W = $clog2(N_SNAP);

    logic [SNAP_IDX_W-1:0]      snap_head_q;     // oldest in-flight branch's slot
    logic [SNAP_IDX_W-1:0]      snap_tail_q;     // next free slot
    logic [SNAP_IDX_W:0]        snap_count_q;    // 0..N_SNAP

    // rob_idx → snap_idx map. Set when a branch dispatches; read
    // when EX resolves a mispredict (ALU FU is the branch resolver).
    logic [SNAP_IDX_W-1:0]      snap_of_rob [0:OOO_ROB_DEPTH-1];

    logic                       snap_full;
    logic                       snap_take;
    logic [SNAP_IDX_W-1:0]      snap_take_idx;
    logic                       snap_restore;
    logic [SNAP_IDX_W-1:0]      snap_restore_idx;

    // Branch-class uop = anything that can mispredict at v1. All
    // FU_BRANCH ops qualify (conditional branches, JAL, JALR — fetch
    // doesn't predict jumps so they look like always-mispredicts).
    logic                       is_branch_class;

    // ── M3-A muldiv flush gating ─────────────────────────────
    // Drain a YOUNGER muldiv op when an older branch mispredicts.
    // memunit doesn't need this — it's head-gated and its in-flight
    // op is by construction the oldest in the ROB.
    logic [OOO_ROB_IDX_W-1:0]   md_op_rob_idx;
    logic                       md_unit_flush;

    // ── IF ───────────────────────────────────────────────────
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

    // ── DECODE ───────────────────────────────────────────────
    decode decode_inst (
        .instr_i (if_instr),
        .pc_i    (if_pc),
        .valid_i (if_valid),
        .uop_o   (id_uop)
    );

    // ── RAT ──────────────────────────────────────────────────
    rat #(
        .N_SNAPSHOTS (N_SNAP)
    ) rat_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .rs1_addr_i         (id_uop.rs1),
        .rs2_addr_i         (id_uop.rs2),
        .rs1_busy_o         (rat_rs1_busy),
        .rs1_rob_idx_o      (rat_rs1_idx),
        .rs2_busy_o         (rat_rs2_busy),
        .rs2_rob_idx_o      (rat_rs2_idx),
        .write_en_i         (dispatch_en && id_uop.has_rd == TRUE),
        .write_addr_i       (id_uop.rd),
        .write_rob_idx_i    (rob_alloc_idx),
        .clear_en_i         (commit_consume && rob_commit_uop.has_rd == TRUE),
        .clear_addr_i       (rob_commit_uop.rd),
        .clear_check_idx_i  (rob_commit_idx),
        .snap_take_i        (snap_take),
        .snap_take_idx_i    (snap_take_idx),
        .snap_restore_i     (snap_restore),
        .snap_restore_idx_i (snap_restore_idx)
    );

    // ── arch regfile ─────────────────────────────────────────
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

    // ── dispatch source resolution ───────────────────────────
    // Same pattern as M1: choose value via ROB peek (producer
    // already ready) OR via this-cycle wb (same-cycle catch) OR
    // capture tag for later wakeup. Now feeds whichever RS bank.
    // wb1=ALU, wb2=LSU, wb3=MULDIV.
    wire wb1_to_rs1 = (alu_wb_en == TRUE) && (alu_wb_idx == rat_rs1_idx);
    wire wb2_to_rs1 = (mem_done  == TRUE) && (mem_done_idx == rat_rs1_idx);
    wire wb3_to_rs1 = (md_done   == TRUE) && (md_done_idx  == rat_rs1_idx);
    wire wb1_to_rs2 = (alu_wb_en == TRUE) && (alu_wb_idx == rat_rs2_idx);
    wire wb2_to_rs2 = (mem_done  == TRUE) && (mem_done_idx == rat_rs2_idx);
    wire wb3_to_rs2 = (md_done   == TRUE) && (md_done_idx  == rat_rs2_idx);

    wire rs1_resolved_now = rat_rs1_busy
                            && (rob_peek1_ready
                                || wb1_to_rs1 || wb2_to_rs1 || wb3_to_rs1);
    wire rs2_resolved_now = rat_rs2_busy
                            && (rob_peek2_ready
                                || wb1_to_rs2 || wb2_to_rs2 || wb3_to_rs2);

    assign alloc_rs1_busy_to_rs = rat_rs1_busy && !rs1_resolved_now;
    assign alloc_rs2_busy_to_rs = rat_rs2_busy && !rs2_resolved_now;

    always_comb begin
        if (rat_rs1_busy) begin
            if      (rob_peek1_ready) alloc_rs1_value = rob_peek1_result;
            else if (wb1_to_rs1)      alloc_rs1_value = alu_wb_result;
            else if (wb2_to_rs1)      alloc_rs1_value = mem_done_result;
            else if (wb3_to_rs1)      alloc_rs1_value = md_done_result;
            else                       alloc_rs1_value = 32'b0;
        end else begin
            alloc_rs1_value = rf_rdataA;
        end
        if (rat_rs2_busy) begin
            if      (rob_peek2_ready) alloc_rs2_value = rob_peek2_result;
            else if (wb1_to_rs2)      alloc_rs2_value = alu_wb_result;
            else if (wb2_to_rs2)      alloc_rs2_value = mem_done_result;
            else if (wb3_to_rs2)      alloc_rs2_value = md_done_result;
            else                       alloc_rs2_value = 32'b0;
        end else begin
            alloc_rs2_value = rf_rdataB;
        end
    end

    // ── dispatch routing ─────────────────────────────────────
    // Route uop to its RS bank. FU_NONE / illegal still claim a ROB
    // slot (so commit can drain them) but don't go to any RS — they
    // need no execution; we'll mark them ready at dispatch via a
    // self-wb pulse so they retire next cycle.
    wire wants_alu_rs   = (id_uop.fu == FU_ALU)  || (id_uop.fu == FU_BRANCH);
    wire wants_lsu_rs   = (id_uop.fu == FU_LOAD) || (id_uop.fu == FU_STORE);
    wire wants_md_rs    = (id_uop.fu == FU_MULDIV);
    wire wants_nop_path = !wants_alu_rs && !wants_lsu_rs && !wants_md_rs;

    // Dispatch fires when: valid uop, ROB has room, target RS has
    // room (or we're on the nop path), no snapshot stall, and we're
    // not redirecting.
    wire target_rs_full = (wants_alu_rs && alu_rs_full)
                        || (wants_lsu_rs && lsu_rs_full)
                        || (wants_md_rs  && md_rs_full);

    // Snapshot stall: a branch-class uop can't dispatch when the
    // snapshot ring is full. Non-branch uops are unaffected.
    assign is_branch_class = (id_uop.valid == TRUE)
                             && (id_uop.fu == FU_BRANCH);
    wire   snap_stall      = is_branch_class && snap_full;

    assign dispatch_en = (id_uop.valid == TRUE)
                       && !rob_full
                       && !target_rs_full
                       && !snap_stall
                       && !ex_redirect;
    assign dispatch_to_alu_rs = dispatch_en && wants_alu_rs;
    assign dispatch_to_lsu_rs = dispatch_en && wants_lsu_rs;
    assign dispatch_to_md_rs  = dispatch_en && wants_md_rs;

    // Self-wb for nop-path entries: they become ready in the same
    // cycle they alloc, so they can retire the next cycle.
    wire nop_wb_en = dispatch_en && wants_nop_path;

    // ── ROB ──────────────────────────────────────────────────
    // wb1 = ALU CDB port (also carries nop-path self-wb when no
    // ALU op completed this cycle); wb2 = LSU CDB port.
    wire        rob_wb1_en     = (alu_wb_en == TRUE) || nop_wb_en;
    wire [OOO_ROB_IDX_W-1:0] rob_wb1_idx
        = (alu_wb_en == TRUE) ? alu_wb_idx : rob_alloc_idx;
    wire [31:0] rob_wb1_result
        = (alu_wb_en == TRUE) ? alu_wb_result : 32'b0;

    rob rob_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .flush_younger_i    (flush_younger),
        .flush_after_idx_i  (alu_rs_issue_rob_idx),     // ALU FU resolves branches

        .alloc_en_i         (dispatch_en),
        .alloc_idx_o        (rob_alloc_idx),
        .full_o             (rob_full),
        .alloc_uop_i        (id_uop),

        .peek1_idx_i        (rat_rs1_idx),
        .peek1_ready_o      (rob_peek1_ready),
        .peek1_result_o     (rob_peek1_result),
        .peek2_idx_i        (rat_rs2_idx),
        .peek2_ready_o      (rob_peek2_ready),
        .peek2_result_o     (rob_peek2_result),

        .wb1_en_i           (rob_wb1_en),
        .wb1_idx_i          (rob_wb1_idx),
        .wb1_result_i       (rob_wb1_result),
        .wb2_en_i           (mem_done == TRUE),
        .wb2_idx_i          (mem_done_idx),
        .wb2_result_i       (mem_done_result),
        .wb3_en_i           (md_done  == TRUE),
        .wb3_idx_i          (md_done_idx),
        .wb3_result_i       (md_done_result),

        .commit_valid_o     (rob_commit_valid),
        .commit_idx_o       (rob_commit_idx),
        .commit_uop_o       (rob_commit_uop),
        .commit_result_o    (rob_commit_result),
        .commit_consume_i   (commit_consume),

        .tail_o             (rob_tail),
        .head_o             (rob_head)
    );

    // ── ALU RS ───────────────────────────────────────────────
    rs #(.DEPTH(ALU_RS_DEPTH)) alu_rs_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .flush_all_i        (1'b0),
        .squash_mask_i      (alu_rs_squash_mask),
        .block_issue_mask_i ({ALU_RS_DEPTH{1'b0}}),

        .alloc_en_i         (dispatch_to_alu_rs),
        .full_o             (alu_rs_full),
        .alloc_uop_i        (id_uop),
        .alloc_rob_idx_i    (rob_alloc_idx),
        .alloc_rs1_value_i  (alloc_rs1_value),
        .alloc_rs1_busy_i   (alloc_rs1_busy_to_rs),
        .alloc_rs1_tag_i    (rat_rs1_idx),
        .alloc_rs2_value_i  (alloc_rs2_value),
        .alloc_rs2_busy_i   (alloc_rs2_busy_to_rs),
        .alloc_rs2_tag_i    (rat_rs2_idx),

        .wb1_en_i           (alu_wb_en == TRUE),
        .wb1_idx_i          (alu_wb_idx),
        .wb1_result_i       (alu_wb_result),
        .wb2_en_i           (mem_done  == TRUE),
        .wb2_idx_i          (mem_done_idx),
        .wb2_result_i       (mem_done_result),
        .wb3_en_i           (md_done   == TRUE),
        .wb3_idx_i          (md_done_idx),
        .wb3_result_i       (md_done_result),

        .issue_valid_o      (alu_rs_issue_valid),
        .issue_uop_o        (alu_rs_issue_uop),
        .issue_rob_idx_o    (alu_rs_issue_rob_idx),
        .issue_rs1_value_o  (alu_rs_issue_rs1_val),
        .issue_rs2_value_o  (alu_rs_issue_rs2_val),
        .issue_consume_i    (alu_rs_issue_valid),       // 1-cycle FU, always consume

        .busy_mask_o        (alu_rs_busy_mask),
        .rob_idx_of_o       (alu_rs_rob_idx_of),
        .fu_of_o            (alu_rs_fu_of)
    );

    // ── LSU RS ───────────────────────────────────────────────
    // Serialize all LSU ops at the ROB head:
    //   * STOREs must wait for head so speculation can't escape to
    //     memory (no store buffer yet).
    //   * LOADs must wait for head so they observe older stores in
    //     program order (no memory disambiguation yet — proper LSQ
    //     comes in M4).
    // The RS still does operand wakeup; only the issue-ready gate
    // is per-slot here.
    always_comb begin
        for (int i = 0; i < LSU_RS_DEPTH; i++) begin
            lsu_rs_block_mask[i] = lsu_rs_busy_mask[i]
                                   && (lsu_rs_rob_idx_of[i] != rob_head);
        end
    end

    wire lsu_rs_consume = lsu_rs_issue_valid && (mem_busy == FALSE);

    rs #(.DEPTH(LSU_RS_DEPTH)) lsu_rs_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .flush_all_i        (1'b0),
        .squash_mask_i      (lsu_rs_squash_mask),
        .block_issue_mask_i (lsu_rs_block_mask),

        .alloc_en_i         (dispatch_to_lsu_rs),
        .full_o             (lsu_rs_full),
        .alloc_uop_i        (id_uop),
        .alloc_rob_idx_i    (rob_alloc_idx),
        .alloc_rs1_value_i  (alloc_rs1_value),
        .alloc_rs1_busy_i   (alloc_rs1_busy_to_rs),
        .alloc_rs1_tag_i    (rat_rs1_idx),
        .alloc_rs2_value_i  (alloc_rs2_value),
        .alloc_rs2_busy_i   (alloc_rs2_busy_to_rs),
        .alloc_rs2_tag_i    (rat_rs2_idx),

        .wb1_en_i           (alu_wb_en == TRUE),
        .wb1_idx_i          (alu_wb_idx),
        .wb1_result_i       (alu_wb_result),
        .wb2_en_i           (mem_done  == TRUE),
        .wb2_idx_i          (mem_done_idx),
        .wb2_result_i       (mem_done_result),
        .wb3_en_i           (md_done   == TRUE),
        .wb3_idx_i          (md_done_idx),
        .wb3_result_i       (md_done_result),

        .issue_valid_o      (lsu_rs_issue_valid),
        .issue_uop_o        (lsu_rs_issue_uop),
        .issue_rob_idx_o    (lsu_rs_issue_rob_idx),
        .issue_rs1_value_o  (lsu_rs_issue_rs1_val),
        .issue_rs2_value_o  (lsu_rs_issue_rs2_val),
        .issue_consume_i    (lsu_rs_consume),

        .busy_mask_o        (lsu_rs_busy_mask),
        .rob_idx_of_o       (lsu_rs_rob_idx_of),
        .fu_of_o            (lsu_rs_fu_of)
    );

    // ── MULDIV RS ────────────────────────────────────────────
    // Single-issue FU; gate consume on !md_busy so a long DIV holds
    // its slot. Same squash semantics as ALU/LSU — entries younger
    // than a mispredicted branch get cleared by the per-slot mask.
    wire md_rs_consume = md_rs_issue_valid && (md_busy == FALSE);

    rs #(.DEPTH(MD_RS_DEPTH)) md_rs_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .flush_all_i        (1'b0),
        .squash_mask_i      (md_rs_squash_mask),
        .block_issue_mask_i ({MD_RS_DEPTH{1'b0}}),

        .alloc_en_i         (dispatch_to_md_rs),
        .full_o             (md_rs_full),
        .alloc_uop_i        (id_uop),
        .alloc_rob_idx_i    (rob_alloc_idx),
        .alloc_rs1_value_i  (alloc_rs1_value),
        .alloc_rs1_busy_i   (alloc_rs1_busy_to_rs),
        .alloc_rs1_tag_i    (rat_rs1_idx),
        .alloc_rs2_value_i  (alloc_rs2_value),
        .alloc_rs2_busy_i   (alloc_rs2_busy_to_rs),
        .alloc_rs2_tag_i    (rat_rs2_idx),

        .wb1_en_i           (alu_wb_en == TRUE),
        .wb1_idx_i          (alu_wb_idx),
        .wb1_result_i       (alu_wb_result),
        .wb2_en_i           (mem_done  == TRUE),
        .wb2_idx_i          (mem_done_idx),
        .wb2_result_i       (mem_done_result),
        .wb3_en_i           (md_done   == TRUE),
        .wb3_idx_i          (md_done_idx),
        .wb3_result_i       (md_done_result),

        .issue_valid_o      (md_rs_issue_valid),
        .issue_uop_o        (md_rs_issue_uop),
        .issue_rob_idx_o    (md_rs_issue_rob_idx),
        .issue_rs1_value_o  (md_rs_issue_rs1_val),
        .issue_rs2_value_o  (md_rs_issue_rs2_val),
        .issue_consume_i    (md_rs_consume),

        .busy_mask_o        (md_rs_busy_mask),
        .rob_idx_of_o       (md_rs_rob_idx_of),
        .fu_of_o            (md_rs_fu_of)
    );

    // ── squash-mask computation ──────────────────────────────
    // A slot is "younger than branch" if its rob_idx falls in the
    // circular range (branch_idx, tail). Branch resolution comes
    // from the ALU FU, so the branch's rob_idx is whatever the ALU
    // RS is issuing this cycle.
    function automatic logic is_younger(
        logic [OOO_ROB_IDX_W-1:0] idx,
        logic [OOO_ROB_IDX_W-1:0] after,
        logic [OOO_ROB_IDX_W-1:0] upto
    );
        logic [OOO_ROB_IDX_W-1:0] d_idx;
        logic [OOO_ROB_IDX_W-1:0] d_upto;
        d_idx  = idx  - after - 1'b1;
        d_upto = upto - after - 1'b1;
        return (d_idx < d_upto);
    endfunction

    always_comb begin
        for (int i = 0; i < ALU_RS_DEPTH; i++) begin
            alu_rs_squash_mask[i] = ex_redirect
                                    && alu_rs_busy_mask[i]
                                    && is_younger(alu_rs_rob_idx_of[i],
                                                  alu_rs_issue_rob_idx,
                                                  rob_tail);
        end
        for (int i = 0; i < LSU_RS_DEPTH; i++) begin
            lsu_rs_squash_mask[i] = ex_redirect
                                    && lsu_rs_busy_mask[i]
                                    && is_younger(lsu_rs_rob_idx_of[i],
                                                  alu_rs_issue_rob_idx,
                                                  rob_tail);
        end
        for (int i = 0; i < MD_RS_DEPTH; i++) begin
            md_rs_squash_mask[i]  = ex_redirect
                                    && md_rs_busy_mask[i]
                                    && is_younger(md_rs_rob_idx_of[i],
                                                  alu_rs_issue_rob_idx,
                                                  rob_tail);
        end
    end

    // ── EX (ALU FU) ──────────────────────────────────────────
    onebit_sig_e alu_issue_e;
    assign alu_issue_e = onebit_sig_e'(alu_rs_issue_valid);

    logic [31:0] ex_mem_addr_unused;
    logic [31:0] ex_store_data_unused;

    execute execute_inst (
        .clk_i          (clk_i),
        .reset_i        (reset_i),
        .stall_i        (1'b0),
        .flush_i        (1'b0),
        .uop_i          (alu_rs_issue_uop),
        .rs1_val_i      (alu_rs_issue_rs1_val),
        .rs2_val_i      (alu_rs_issue_rs2_val),
        .issue_idx_i    (alu_rs_issue_rob_idx),
        .issue_i        (alu_issue_e),
        .alu_wb_en_o    (alu_wb_en),
        .alu_wb_idx_o   (alu_wb_idx),
        .alu_wb_result_o(alu_wb_result),
        .alu_busy_o     (ex_alu_busy),
        .mem_addr_o     (ex_mem_addr_unused),
        .store_data_o   (ex_store_data_unused),
        .redirect_o     (ex_redirect),
        .redirect_pc_o  (ex_redirect_pc)
    );

    // ── LSU (memunit) ────────────────────────────────────────
    // LSU computes its own address gen from the LSU RS-issued op
    // (independent of the ALU FU which now only handles ALU/branch).
    wire [31:0] lsu_addr       = lsu_rs_issue_rs1_val + lsu_rs_issue_uop.alu_imm;
    wire [31:0] lsu_store_data = lsu_rs_issue_rs2_val;

    onebit_sig_e lsu_kick_e;
    assign lsu_kick_e = onebit_sig_e'(lsu_rs_consume
                                       && lsu_rs_issue_uop.illegal == FALSE);

    assign ex_mem_addr   = lsu_addr;
    assign ex_store_data = lsu_store_data;

    memunit memunit_inst (
        .clk_i             (clk_i),
        .reset_i           (reset_i),
        .flush_i           (1'b0),
        .kick_i            (lsu_kick_e),
        .fu_i              (lsu_rs_issue_uop.fu),
        .addr_i            (lsu_addr),
        .store_data_i      (lsu_store_data),
        .width_i           (lsu_rs_issue_uop.ls_width),
        .mem_unsigned_i    (lsu_rs_issue_uop.mem_unsigned),
        .rob_idx_i         (lsu_rs_issue_rob_idx),
        .dmem_port         (dmem_port),
        .op_done_o         (mem_done),
        .op_done_rob_idx_o (mem_done_idx),
        .op_done_result_o  (mem_done_result),
        .busy_o             (mem_busy)
    );

    // ── MULDIV (muldiv_unit) ─────────────────────────────────
    // Single-issue, multi-cycle. Kick fires on the cycle the MULDIV
    // RS issues a ready op; the FU then holds busy until op_done
    // pulses with the result on wb3. We don't gate kick on illegal
    // here — the decoder never marks an FU_MULDIV op illegal at M2.
    onebit_sig_e md_kick_e;
    assign md_kick_e = onebit_sig_e'(md_rs_consume);

    // Drain a younger-than-branch in-flight muldiv op on mispredict.
    // Reuses is_younger() — the branch's rob_idx is the issuing
    // ALU RS slot, which is alu_rs_issue_rob_idx.
    assign md_unit_flush = ex_redirect && (md_busy == TRUE)
                           && is_younger(md_op_rob_idx,
                                         alu_rs_issue_rob_idx,
                                         rob_tail);

    muldiv_unit muldiv_unit_inst (
        .clk_i             (clk_i),
        .reset_i           (reset_i),
        .flush_i           (md_unit_flush),
        .kick_i            (md_kick_e),
        .mul_op_i          (md_rs_issue_uop.mul_op),
        .a_i               (md_rs_issue_rs1_val),
        .b_i               (md_rs_issue_rs2_val),
        .rob_idx_i         (md_rs_issue_rob_idx),
        .op_done_o         (md_done),
        .op_done_rob_idx_o (md_done_idx),
        .op_done_result_o  (md_done_result),
        .busy_o             (md_busy),
        .op_rob_idx_o      (md_op_rob_idx)
    );

    // ── BRANCH RECOVERY ──────────────────────────────────────
    // ROB squashes [branch_idx+1..tail) on mispredict; RAT restores
    // from the snapshot taken when the branch dispatched.
    assign flush_younger    = ex_redirect;
    assign snap_restore     = ex_redirect;
    assign snap_restore_idx = snap_of_rob[alu_rs_issue_rob_idx];

    // ── M3-A snapshot ring ───────────────────────────────────
    // Take a snapshot every cycle a branch-class uop dispatches.
    // The slot used is snap_tail_q (the next free).
    assign snap_take     = dispatch_en && is_branch_class;
    assign snap_take_idx = snap_tail_q;
    assign snap_full     = (snap_count_q == N_SNAP[SNAP_IDX_W:0]);

    wire branch_committed = commit_consume
                            && (rob_commit_uop.fu == FU_BRANCH);

    // Cleaner combinational next-state for the ring pointers, with
    // restore taking precedence. The mispredicted branch keeps its
    // own snapshot — it'll commit shortly (alu wb sets ready=1
    // next cycle) and free the snapshot via the normal head++ path.
    logic [SNAP_IDX_W-1:0] snap_head_d;
    logic [SNAP_IDX_W-1:0] snap_tail_d;
    logic [SNAP_IDX_W:0]   snap_count_d;
    always_comb begin
        snap_head_d  = snap_head_q;
        snap_tail_d  = snap_tail_q;
        snap_count_d = snap_count_q;

        if (snap_restore) begin
            // tail rewinds to one past the branch's slot; branches
            // younger than this are squashed and their snapshots
            // freed. snap_take is ignored this cycle (the
            // dispatching uop is on the wrong path).
            //
            // New count = (new_tail - new_head) mod N_SNAP, with the
            // disambiguation that "delta==0 in mod arithmetic" here
            // means N_SNAP (full ring kept) — never empty, since we
            // always keep at least the mispredicting branch's
            // snapshot until it commits.
            snap_tail_d = snap_restore_idx + 1'b1;
            snap_head_d = snap_head_q + (branch_committed ? 1'b1 : 1'b0);
            begin
                automatic logic [SNAP_IDX_W-1:0] delta;
                delta = snap_tail_d - snap_head_d;       // mod N_SNAP
                snap_count_d = (delta == '0)
                               ? N_SNAP[SNAP_IDX_W:0]
                               : {1'b0, delta};
            end
        end else begin
            if (snap_take) begin
                snap_tail_d  = snap_tail_q + 1'b1;
                snap_count_d = snap_count_q + 1'b1;
            end
            if (branch_committed) begin
                snap_head_d  = snap_head_q + 1'b1;
                snap_count_d = (snap_take ? snap_count_q
                                          : (snap_count_q - 1'b1));
            end
        end
    end

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            snap_head_q  <= '0;
            snap_tail_q  <= '0;
            snap_count_q <= '0;
            for (int i = 0; i < OOO_ROB_DEPTH; i++)
                snap_of_rob[i] <= '0;
        end else begin
            snap_head_q  <= snap_head_d;
            snap_tail_q  <= snap_tail_d;
            snap_count_q <= snap_count_d;
            // snap_of_rob write — even on restore the dispatching
            // uop is wrong-path so we suppress it.
            if (snap_take && !snap_restore)
                snap_of_rob[rob_alloc_idx] <= snap_tail_q;
        end
    end

    // ── COMMIT ───────────────────────────────────────────────
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

    // ── FETCH STALL ──────────────────────────────────────────
    // Stall fetch when ROB is full, the target RS bank is full, or
    // a branch-class uop hits an exhausted snapshot ring. The bank
    // check captures FU_NONE/illegal too (those go to neither bank
    // but still need a ROB slot).
    assign fetch_stall = rob_full || target_rs_full || snap_stall;

    // ── lint sink ────────────────────────────────────────────
    wire _unused = &{1'b0, ext_itr_i, s_ext_itr_i, timer_itr_i, soft_itr_i,
                     |mtime_i, haltreq_i, resumereq_i,
                     ar_en_i, ar_wr_i, |ar_ad_i, |ar_di_i,
                     am_en_i, am_wr_i, |am_st_i, |am_ad_i, |am_di_i,
                     ex_alu_busy, |ex_mem_addr, |ex_store_data, 1'b0};

endmodule
