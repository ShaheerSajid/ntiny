// OoO core v1 — decode
//
// M0 scope: RV32I only. Produces a uop_t consumed by rename/dispatch.
// M2 extends to RV32M, M5 to F, M6 to B.
//
// The existing design/core/control_path/src/decoder.sv covers all of
// I/M/F/A/B/Zicsr/Zifencei plus C — much of that machinery is
// re-derivable here, but the OoO datapath needs a different output
// shape (a single uop_t instead of the in-order ctrl_bus). For now,
// pattern-match minimally; widen as milestones land.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module decode
(
    input  logic [31:0]     instr_i,
    input  logic [31:0]     pc_i,
    input  onebit_sig_e     valid_i,
    output uop_t            uop_o
);

    // TODO(M0): replace this stub with the real RV32I decode.
    // Initial implementation should cover: LUI, AUIPC, JAL, JALR, BRANCH
    // (all 6), LOAD (lb/lh/lw/lbu/lhu), STORE (sb/sh/sw), OP_I (8 ops),
    // OP_R (8 ops), MISC_MEM (fence as nop for now), CSR (defer to M7).

    always_comb begin
        uop_o            = '0;
        uop_o.pc         = pc_i;
        uop_o.instr      = instr_i;
        uop_o.valid      = valid_i;
        uop_o.illegal    = TRUE;   // until M0 decode is filled in
        uop_o.fu         = FU_NONE;
        uop_o.alu_op     = NO_ALU_OP;
        uop_o.bit_op     = NO_BIT_OP;
        uop_o.mul_op     = NO_MUL_OP;
        uop_o.br_cond    = NO_CONDITION;
        uop_o.ls_width   = NO_WIDTH;
        uop_o.mem_unsigned = FALSE;
        uop_o.has_rs1    = FALSE;
        uop_o.has_rs2    = FALSE;
        uop_o.has_rd     = FALSE;
        uop_o.rs1        = instr_i[19:15];
        uop_o.rs2        = instr_i[24:20];
        uop_o.rd         = instr_i[11:7];
        uop_o.uses_imm   = FALSE;
        uop_o.uses_pc    = FALSE;
        uop_o.imm        = 32'b0;
    end

endmodule
