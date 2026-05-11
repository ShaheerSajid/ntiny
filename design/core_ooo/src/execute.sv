// OoO core v1 — execute (M0: single in-order FU)
//
// At M0 this is one ALU FU consuming a dispatched uop, plus a branch
// comparator and a target-address adder. Produces a single-cycle
// result + branch redirect. At M2 this file splits into the FU bank
// wired to RS/CDB.
//
// Reuses design/core/alu/src/alu.sv as a black-box.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module execute
(
    input  logic            clk_i,
    input  logic            reset_i,
    input  logic            stall_i,
    input  logic            flush_i,

    // dispatched uop + read operands
    input  uop_t            uop_i,
    input  logic [31:0]     rs1_val_i,
    input  logic [31:0]     rs2_val_i,
    input  onebit_sig_e     issue_i,

    // ALU result + writeback control
    output logic [31:0]     alu_result_o,
    output logic [4:0]      rd_o,
    output onebit_sig_e     int_wen_o,        // arch regfile write enable (ALU producer)
    output onebit_sig_e     alu_busy_o,

    // address generation for LSU
    output logic [31:0]     mem_addr_o,
    output logic [31:0]     store_data_o,

    // branch resolution → fetch
    output logic            redirect_o,
    output logic [31:0]     redirect_pc_o
);

    // ── operand muxes ─────────────────────────────────────────
    logic [31:0] opA, opB;
    assign opA = (uop_i.uses_pc  == TRUE) ? uop_i.pc      : rs1_val_i;
    assign opB = (uop_i.uses_imm == TRUE) ? uop_i.alu_imm : rs2_val_i;

    // ── ALU instance (reused) ─────────────────────────────────
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

    assign alu_busy_o   = alu_stall;
    assign alu_result_o = alu_result;
    assign rd_o         = uop_i.rd;
    // FU_BRANCH writes rd for JAL/JALR (rd = pc+4, computed through ALU).
    // FU_LOAD writeback comes from memunit, not the ALU path.
    assign int_wen_o    = onebit_sig_e'(issue_i == TRUE
                                         && uop_i.has_rd == TRUE
                                         && (uop_i.fu == FU_ALU || uop_i.fu == FU_BRANCH)
                                         && uop_i.illegal == FALSE
                                         && alu_stall == FALSE);

    // ── memory address (LOAD/STORE: rs1 + imm) ────────────────
    assign mem_addr_o   = rs1_val_i + uop_i.alu_imm;
    assign store_data_o = rs2_val_i;

    // ── branch comparator + target ────────────────────────────
    logic        cond_taken;
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

    wire branch_taken = (uop_i.is_branch == TRUE) && cond_taken;
    wire jump_taken   = (uop_i.is_jump == TRUE) || (uop_i.is_jalr == TRUE);
    wire taken        = (issue_i == TRUE) && (branch_taken || jump_taken)
                         && (uop_i.illegal == FALSE);

    wire [31:0] branch_target = uop_i.pc + uop_i.br_imm;
    wire [31:0] jalr_target   = (rs1_val_i + uop_i.br_imm) & ~32'h1;

    assign redirect_o    = taken;
    assign redirect_pc_o = (uop_i.is_jalr == TRUE) ? jalr_target : branch_target;

endmodule
