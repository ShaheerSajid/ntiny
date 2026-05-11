// OoO core v1 — instruction fetch
//
// M0 scope: non-predicting PC, single outstanding imem request,
// 32-bit aligned. Issues a req every cycle (unless stalled), latches
// the in-flight PC, squashes one rvalid following a redirect.
//
// Branch / redirect interface is driven by EX in M0; replaced by a
// proper BPU + recovery path in M3.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module fetch
(
    input  logic            clk_i,
    input  logic            reset_i,
    input  logic [31:0]     reset_pc_i,

    // backpressure from downstream
    input  logic            stall_i,

    // redirect — branch mispredict / trap / fence.i
    input  logic            redirect_i,
    input  logic [31:0]     redirect_pc_i,

    // instruction memory bus
    mem_bus.master          imem_port,

    // to decode
    output logic [31:0]     instr_o,
    output logic [31:0]     pc_o,
    output onebit_sig_e     valid_o
);

    logic [31:0] pc_q;
    logic [31:0] pc_in_flight_q;
    logic        squash_next_q;

    wire issue = imem_port.req & imem_port.ready;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            pc_q           <= reset_pc_i;
            pc_in_flight_q <= reset_pc_i;
            squash_next_q  <= 1'b0;
        end else begin
            // PC update — redirect wins, otherwise advance on accept
            if (redirect_i)               pc_q <= redirect_pc_i;
            else if (issue && ~stall_i)   pc_q <= pc_q + 32'd4;

            // Track PC of the in-flight request so we can pair pc↔instr
            // when rvalid arrives a cycle later.
            if (issue) pc_in_flight_q <= pc_q;

            // The cycle following a redirect, any returning rvalid is
            // for the pre-redirect PC and must be squashed.
            squash_next_q <= redirect_i;
        end
    end

    assign imem_port.req   = ~stall_i;
    assign imem_port.we    = 1'b0;
    assign imem_port.addr  = pc_q;
    assign imem_port.be    = 4'b1111;
    assign imem_port.wdata = 32'b0;

    assign instr_o = imem_port.rdata;
    assign pc_o    = pc_in_flight_q;
    assign valid_o = onebit_sig_e'(imem_port.rvalid & ~squash_next_q);

endmodule
