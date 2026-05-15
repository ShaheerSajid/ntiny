// OoO core v1 — package
//
// Sizing parameters and OoO-specific types. The rename/ROB/RS/LSQ
// types land in M1+. The uop_t here is the M0 contract between decode
// and the in-order EX stage; it will keep growing.
//
// See design/core_ooo/doc/ooo_v1_spec.md for design intent.

package core_ooo_pkg;
    import common_pkg::*;
    import core_pkg::*;

    // ── sizing ─────────────────────────────────────────────────
    localparam int OOO_ROB_DEPTH    = 16;
    localparam int OOO_ROB_IDX_W    = $clog2(OOO_ROB_DEPTH);

    localparam int OOO_LSQ_DEPTH    = 8;
    localparam int OOO_LSQ_IDX_W    = $clog2(OOO_LSQ_DEPTH);

    localparam int OOO_ALU_RS_DEPTH = 4;
    localparam int OOO_BR_RS_DEPTH  = 2;
    localparam int OOO_MD_RS_DEPTH  = 2;
    localparam int OOO_FP_RS_DEPTH  = 4;

    // ── FU type tag ───────────────────────────────────────────
    // Steers a dispatched uop to the correct RS/FU. Grows with M2/M5/M6.
    typedef enum logic [2:0] {
        FU_ALU,
        FU_BRANCH,
        FU_MULDIV,
        FU_LOAD,
        FU_STORE,
        FU_CSR,
        FU_FP,
        FU_NONE
    } fu_type_e;

    // ── decoded micro-op ──────────────────────────────────────
    typedef struct packed {
        logic [31:0]       pc;
        logic [31:0]       instr;
        fu_type_e          fu;

        alu_op_e           alu_op;
        bit_op_e           bit_op;
        mul_op_e           mul_op;
        br_cond_e          br_cond;

        load_store_width_e ls_width;
        onebit_sig_e       mem_unsigned;

        logic [4:0]        rs1;
        logic [4:0]        rs2;
        logic [4:0]        rd;
        onebit_sig_e       has_rs1;
        onebit_sig_e       has_rs2;
        onebit_sig_e       has_rd;

        // ALU operand B when uses_imm=1; otherwise rs2 value.
        logic [31:0]       alu_imm;
        onebit_sig_e       uses_imm;
        // ALU operand A is PC when uses_pc=1; otherwise rs1 value.
        onebit_sig_e       uses_pc;

        // Branch/jump target offset (B-imm / J-imm / I-imm).
        logic [31:0]       br_imm;
        onebit_sig_e       is_branch;    // conditional — taken by br_cond
        onebit_sig_e       is_jump;      // JAL — target = pc + br_imm
        onebit_sig_e       is_jalr;      // JALR — target = (rs1 + br_imm) & ~1

        // BPU prediction (M3-B). pred_taken=1 means fetch redirected
        // to pred_target on the BPU's say-so. EX compares this against
        // the actual outcome to compute mispredict.
        onebit_sig_e       pred_taken;
        logic [31:0]       pred_target;

        onebit_sig_e       valid;
        onebit_sig_e       illegal;
    } uop_t;

    // ── ROB entry (placeholder for M1) ────────────────────────
    typedef struct packed {
        onebit_sig_e busy;
        onebit_sig_e ready;
        onebit_sig_e exception;
        logic [4:0]  cause;
        logic [31:0] tval;
        logic [4:0]  rd;
        onebit_sig_e writes_int;
        onebit_sig_e writes_fp;
        logic [31:0] result;
        logic [31:0] pc;
    } rob_entry_t;

endpackage
