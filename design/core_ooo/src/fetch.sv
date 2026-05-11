// OoO core v1 — instruction fetch
//
// M0 scope: simple non-predicting PC, one outstanding imem request,
// 32-bit aligned (no C extension). Output is the {pc, instr, valid}
// stream consumed by decode.
//
// Branch / redirect interface lands in M3.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module fetch
(
    input  logic            clk_i,
    input  logic            reset_i,
    input  logic [31:0]     reset_pc_i,

    // backpressure from decode
    input  logic            stall_i,

    // redirect (branch mispredict, trap, fence.i). Single-source for
    // now; M3 adds the misprediction redirect channel.
    input  logic            redirect_i,
    input  logic [31:0]     redirect_pc_i,

    // instruction memory bus
    mem_bus.master          imem_port,

    // to decode
    output logic [31:0]     instr_o,
    output logic [31:0]     pc_o,
    output onebit_sig_e     valid_o
);

    // TODO(M0): full implementation — for now a placeholder PC walker
    // that issues one request per cycle and forwards rvalid → valid_o.
    logic [31:0] pc_q, pc_next;

    assign pc_next = redirect_i ? redirect_pc_i :
                     (imem_port.req & imem_port.ready) ? (pc_q + 32'd4) :
                                                          pc_q;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) pc_q <= reset_pc_i;
        else         pc_q <= pc_next;
    end

    assign imem_port.req   = ~stall_i;
    assign imem_port.we    = 1'b0;
    assign imem_port.addr  = pc_q;
    assign imem_port.be    = 4'b1111;
    assign imem_port.wdata = 32'b0;

    assign instr_o = imem_port.rdata;
    assign pc_o    = pc_q;       // TODO(M0): track PC alongside outstanding req
    assign valid_o = onebit_sig_e'(imem_port.rvalid);

endmodule
