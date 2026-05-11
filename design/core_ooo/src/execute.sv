// OoO core v1 — execute (M0: single in-order FU)
//
// At M0 this is one ALU FU consuming a dispatched uop directly and
// producing {result, ready} in one cycle. At M2 this file splits into
// the FU bank wired to the RS/CDB fabric.
//
// Reuses design/core/alu/src/alu.sv as a black-box instantiation when
// the body is filled in (TODO M0).

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module execute
(
    input  logic            clk_i,
    input  logic            reset_i,

    // dispatched uop + read operands
    input  uop_t            uop_i,
    input  logic [31:0]     opA_i,
    input  logic [31:0]     opB_i,
    input  onebit_sig_e     issue_i,

    // result
    output logic [31:0]     result_o,
    output logic [4:0]      rd_o,
    output onebit_sig_e     wen_o,
    output onebit_sig_e     ready_o
);

    // TODO(M0): instantiate `alu` (and later: zba_zbb, zbs, clmul,
    // divider, multiplier). For now a pass-through ADD so the
    // skeleton can be linted end-to-end.
    always_comb begin
        result_o = opA_i + opB_i;
        rd_o     = uop_i.rd;
        wen_o    = onebit_sig_e'(issue_i == TRUE && uop_i.has_rd == TRUE);
        ready_o  = issue_i;
    end

endmodule
