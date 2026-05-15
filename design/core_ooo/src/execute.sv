// OoO core v1 — execute.
//
// Single combinational ALU FU. Consumes the issuing uop (op +
// operand values + ROB tag) and produces:
//   - alu_wb_en + alu_wb_idx + alu_wb_result for ALU/JAL/JALR (the
//     ALU path completes in one cycle).
//   - Address-gen + store data forwarded out (legacy port, unused
//     post-M2 — LSU has its own).
//   - Branch redirect to fetch when the prediction was wrong, NOT
//     just on every taken branch (M3-B).
//   - Branch-resolution info (resolved_o, pc, taken, target,
//     is_uncond) so the top can update the BPU.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module execute
(
    input  logic            clk_i,
    input  logic            reset_i,
    input  logic            stall_i,
    input  logic            flush_i,

    // dispatched uop + operand values + ROB tag
    input  uop_t                       uop_i,
    input  logic [31:0]                rs1_val_i,
    input  logic [31:0]                rs2_val_i,
    input  logic [OOO_ROB_IDX_W-1:0]   issue_idx_i,
    input  onebit_sig_e                issue_i,

    // writeback for ALU/JAL/JALR
    output onebit_sig_e                alu_wb_en_o,
    output logic [OOO_ROB_IDX_W-1:0]   alu_wb_idx_o,
    output logic [31:0]                alu_wb_result_o,
    output onebit_sig_e                alu_busy_o,

    // LSU address gen (legacy — unused post-M2)
    output logic [31:0]                mem_addr_o,
    output logic [31:0]                store_data_o,

    // mispredict redirect → fetch + ROB flush + RAT restore.
    // Fires only when prediction != actual outcome.
    output logic                       redirect_o,
    output logic [31:0]                redirect_pc_o,

    // BPU update — driven on every resolved branch-class op so the
    // BTB can allocate / refresh entries. The top gates update_en
    // on actual_taken (we only allocate on TAKEN outcomes).
    output logic                       branch_resolved_o,
    output logic [31:0]                branch_pc_o,
    output logic                       branch_actual_taken_o,
    output logic [31:0]                branch_actual_target_o,
    output logic                       branch_is_uncond_o
);

    // ── operand muxes ─────────────────────────────────────────
    logic [31:0] opA, opB;
    assign opA = (uop_i.uses_pc  == TRUE) ? uop_i.pc      : rs1_val_i;
    assign opB = (uop_i.uses_imm == TRUE) ? uop_i.alu_imm : rs2_val_i;

    // ── ALU ───────────────────────────────────────────────────
    onebit_sig_e   alu_stall;
    logic [31:0]   alu_result;
    float_status_e fp_status_unused;

    alu alu_inst (
        .clk_i        (clk_i),
        .reset_i      (reset_i),
        .stall_i      (stall_i),
        .flush_i      (flush_i),
        .a_i          (opA),
        .b_i          (opB),
        .c_i          (32'b0),
        .alu_op_i     (uop_i.alu_op),
        .mul_op_i     (NO_MUL_OP),
        .bit_op_i     (NO_BIT_OP),
        .float_op_i   (NO_FP_OP),
        .roundmode_i  (RNE),
        .alu_stall_o  (alu_stall),
        .result_o     (alu_result),
        .float_status_o(fp_status_unused)
    );

    assign alu_busy_o = alu_stall;

    wire is_alu_class = (uop_i.fu == FU_ALU) || (uop_i.fu == FU_BRANCH);
    assign alu_wb_en_o     = onebit_sig_e'(issue_i == TRUE
                                            && is_alu_class
                                            && uop_i.illegal == FALSE
                                            && alu_stall    == FALSE);
    assign alu_wb_idx_o    = issue_idx_i;
    assign alu_wb_result_o = alu_result;

    // ── LSU address gen (legacy) ─────────────────────────────
    assign mem_addr_o   = rs1_val_i + uop_i.alu_imm;
    assign store_data_o = rs2_val_i;

    // ── branch comparator + actual target ────────────────────
    logic cond_taken;
    always_comb begin
        unique case (uop_i.br_cond)
            BEQ:  cond_taken = (rs1_val_i == rs2_val_i);
            BNE:  cond_taken = (rs1_val_i != rs2_val_i);
            BLT:  cond_taken = ($signed(rs1_val_i) <  $signed(rs2_val_i));
            BGE:  cond_taken = ($signed(rs1_val_i) >= $signed(rs2_val_i));
            BLTU: cond_taken = (rs1_val_i <  rs2_val_i);
            BGEU: cond_taken = (rs1_val_i >= rs2_val_i);
            default: cond_taken = 1'b0;
        endcase
    end

    wire branch_taken  = (uop_i.is_branch == TRUE) && cond_taken;
    wire jump_taken    = (uop_i.is_jump == TRUE) || (uop_i.is_jalr == TRUE);
    wire actual_taken  = (issue_i == TRUE)
                         && (branch_taken || jump_taken)
                         && (uop_i.illegal == FALSE);

    wire [31:0] branch_target = uop_i.pc + uop_i.br_imm;
    wire [31:0] jalr_target   = (rs1_val_i + uop_i.br_imm) & ~32'h1;
    wire [31:0] actual_target = (uop_i.is_jalr == TRUE) ? jalr_target
                                                       : branch_target;
    wire [31:0] fall_through  = uop_i.pc + 32'd4;

    // ── prediction check ─────────────────────────────────────
    wire was_branch_class = (uop_i.fu == FU_BRANCH);
    wire pred_taken       = (uop_i.pred_taken == TRUE);
    wire pred_matches     = was_branch_class
                            && (pred_taken == actual_taken)
                            && (!actual_taken
                                || (uop_i.pred_target == actual_target));

    wire mispredict = (issue_i == TRUE) && was_branch_class
                       && (uop_i.illegal == FALSE)
                       && !pred_matches;

    assign redirect_o    = mispredict;
    assign redirect_pc_o = actual_taken ? actual_target : fall_through;

    // ── branch resolution → BPU update ───────────────────────
    assign branch_resolved_o      = (issue_i == TRUE) && was_branch_class
                                    && (uop_i.illegal == FALSE);
    assign branch_pc_o            = uop_i.pc;
    assign branch_actual_taken_o  = actual_taken;
    assign branch_actual_target_o = actual_target;
    assign branch_is_uncond_o     = (uop_i.is_jump == TRUE)
                                    || (uop_i.is_jalr == TRUE);

endmodule
