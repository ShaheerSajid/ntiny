// OoO core v1 — instruction fetch
//
// M0 scope: non-predicting PC, single outstanding imem request,
// 32-bit aligned. Issues a req every cycle (unless stalled), latches
// the in-flight PC, squashes one rvalid following a redirect.
//
// M3-B adds the BPU. Each cycle we look up the next-to-fetch PC in
// the BTB; on hit we redirect pc_q to the predicted target and
// stamp the in-flight uop with {pred_taken=1, pred_target}. On miss
// pc_q advances normally (predict-not-taken default).
//
// EX-side branch redirect (mispredict) still wins over BPU (it
// arrives via redirect_i and is one-cycle-late on the prediction).

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

    // BPU lookup interface (M3-B). Top instantiates the BPU and
    // wires it through fetch.
    output logic [31:0]     bpu_lookup_pc_o,
    input  logic            bpu_pred_valid_i,
    input  logic            bpu_pred_taken_i,
    input  logic [31:0]     bpu_pred_target_i,

    // instruction memory bus
    mem_bus.master          imem_port,

    // to decode
    output logic [31:0]     instr_o,
    output logic [31:0]     pc_o,
    output onebit_sig_e     valid_o,
    // BPU prediction stamped on the in-flight uop
    output logic            pred_taken_o,
    output logic [31:0]     pred_target_o
);

    logic [31:0] pc_q;
    logic [31:0] pc_in_flight_q;
    logic        squash_next_q;

    // Skid buffer (carries instr+pc+pred when downstream stalls).
    logic [31:0] buf_instr_q;
    logic [31:0] buf_pc_q;
    logic        buf_pred_taken_q;
    logic [31:0] buf_pred_target_q;
    logic        buf_valid_q;

    // BPU prediction stamped on the in-flight fetch (latched in
    // parallel with pc_in_flight_q).
    logic        pred_taken_q;
    logic [31:0] pred_target_q;

    wire fresh_valid = imem_port.rvalid & ~squash_next_q;
    wire issue       = imem_port.req & imem_port.ready;

    assign imem_port.req   = ~stall_i & ~buf_valid_q;
    assign imem_port.we    = 1'b0;
    assign imem_port.addr  = pc_q;
    assign imem_port.be    = 4'b1111;
    assign imem_port.wdata = 32'b0;

    // BPU lookup happens combinationally on the cycle's pc_q.
    assign bpu_lookup_pc_o = pc_q;
    wire bpu_predicts_taken = bpu_pred_valid_i & bpu_pred_taken_i;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            pc_q              <= reset_pc_i;
            pc_in_flight_q    <= reset_pc_i;
            squash_next_q     <= 1'b0;
            pred_taken_q      <= 1'b0;
            pred_target_q     <= '0;
            buf_instr_q       <= '0;
            buf_pc_q          <= '0;
            buf_pred_taken_q  <= 1'b0;
            buf_pred_target_q <= '0;
            buf_valid_q       <= 1'b0;
        end else begin
            // PC update precedence: EX redirect > BPU predict > +4.
            if (redirect_i) begin
                pc_q <= redirect_pc_i;
            end else if (issue) begin
                pc_q <= bpu_predicts_taken ? bpu_pred_target_i
                                           : (pc_q + 32'd4);
            end

            // Latch in-flight PC + the prediction we made for it.
            if (issue) begin
                pc_in_flight_q <= pc_q;
                pred_taken_q   <= bpu_predicts_taken;
                pred_target_q  <= bpu_pred_target_i;
            end

            squash_next_q <= redirect_i & ~squash_next_q;

            // Skid: capture {instr,pc,pred} on (fresh_valid && stall
            // && !buffered); drain when downstream consumes;
            // invalidate on redirect.
            if (redirect_i) begin
                buf_valid_q <= 1'b0;
            end else if (!buf_valid_q && fresh_valid && stall_i) begin
                buf_instr_q       <= imem_port.rdata;
                buf_pc_q          <= pc_in_flight_q;
                buf_pred_taken_q  <= pred_taken_q;
                buf_pred_target_q <= pred_target_q;
                buf_valid_q       <= 1'b1;
            end else if (buf_valid_q && !stall_i) begin
                buf_valid_q <= 1'b0;
            end
        end
    end

    assign instr_o       = buf_valid_q ? buf_instr_q       : imem_port.rdata;
    assign pc_o          = buf_valid_q ? buf_pc_q          : pc_in_flight_q;
    assign valid_o       = onebit_sig_e'(buf_valid_q | fresh_valid);
    assign pred_taken_o  = buf_valid_q ? buf_pred_taken_q  : pred_taken_q;
    assign pred_target_o = buf_valid_q ? buf_pred_target_q : pred_target_q;

endmodule
