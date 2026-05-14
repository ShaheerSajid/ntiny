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

    // 1-entry skid buffer: latches the (instr, pc) of a fresh rvalid
    // when downstream is stalling so we don't drop the in-flight
    // instruction. Was a real bug in M2-A — small RS depths cause
    // back-pressure that M1 (16-deep ROB only) never triggered.
    logic [31:0] buf_instr_q;
    logic [31:0] buf_pc_q;
    logic        buf_valid_q;

    wire fresh_valid = imem_port.rvalid & ~squash_next_q;
    wire issue       = imem_port.req & imem_port.ready;

    // Don't issue a new fetch while the buffer is holding one — that
    // would overwrite imem.rdata mid-handshake.
    assign imem_port.req   = ~stall_i & ~buf_valid_q;
    assign imem_port.we    = 1'b0;
    assign imem_port.addr  = pc_q;
    assign imem_port.be    = 4'b1111;
    assign imem_port.wdata = 32'b0;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            pc_q           <= reset_pc_i;
            pc_in_flight_q <= reset_pc_i;
            squash_next_q  <= 1'b0;
            buf_instr_q    <= '0;
            buf_pc_q       <= '0;
            buf_valid_q    <= 1'b0;
        end else begin
            if (redirect_i)         pc_q <= redirect_pc_i;
            else if (issue)         pc_q <= pc_q + 32'd4;

            if (issue) pc_in_flight_q <= pc_q;

            squash_next_q <= redirect_i & ~squash_next_q;

            // Skid: capture on (fresh_valid && stall && !buffered),
            // drain when downstream consumes (!stall), invalidate on
            // redirect.
            if (redirect_i) begin
                buf_valid_q <= 1'b0;
            end else if (!buf_valid_q && fresh_valid && stall_i) begin
                buf_instr_q <= imem_port.rdata;
                buf_pc_q    <= pc_in_flight_q;
                buf_valid_q <= 1'b1;
            end else if (buf_valid_q && !stall_i) begin
                buf_valid_q <= 1'b0;
            end
        end
    end

    assign instr_o = buf_valid_q ? buf_instr_q     : imem_port.rdata;
    assign pc_o    = buf_valid_q ? buf_pc_q        : pc_in_flight_q;
    assign valid_o = onebit_sig_e'(buf_valid_q | fresh_valid);

endmodule
