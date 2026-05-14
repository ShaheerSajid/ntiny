// OoO core v1 — MUL/DIV functional unit (M2 phase B).
//
// Single-issue, multi-cycle. Mirrors memunit's protocol so the top
// can wire it the same way:
//   kick_i pulse latches the op + rob_idx; busy_o stays high until
//   the result is ready; op_done_o pulses for one cycle with the
//   result + rob_idx that the CDB then broadcasts.
//
// MUL/MULH/MULHU/MULHSU — combinational, but registered through one
// pipeline cycle so the FU has uniform "one op in flight" semantics
// (1-cycle latency from kick to op_done).
//
// DIV/DIVU/REM/REMU — wraps the existing `divider` (restoring,
// LZC-early-termination, max(3, N) cycles). The divider's start_i is
// held high through the iteration and dropped the cycle after we
// capture valid_o, so the divider preloads cleanly for the next op.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module muldiv_unit
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    input  logic                        flush_i,

    // dispatch
    input  onebit_sig_e                 kick_i,
    input  mul_op_e                     mul_op_i,
    input  logic [31:0]                 a_i,            // rs1 value
    input  logic [31:0]                 b_i,            // rs2 value
    input  logic [OOO_ROB_IDX_W-1:0]    rob_idx_i,

    // completion → CDB
    output onebit_sig_e                 op_done_o,
    output logic [OOO_ROB_IDX_W-1:0]    op_done_rob_idx_o,
    output logic [31:0]                 op_done_result_o,
    output onebit_sig_e                 busy_o
);

    // ── classify the op (held) ───────────────────────────────
    function automatic logic is_div_class(mul_op_e op);
        return (op == DIV) || (op == DIVU) || (op == REM) || (op == REMU);
    endfunction
    function automatic logic is_mul_class(mul_op_e op);
        return (op == MUL) || (op == MULH) || (op == MULHU) || (op == MULHSU);
    endfunction

    // ── state ────────────────────────────────────────────────
    typedef enum logic [1:0] { IDLE, MUL_REG, DIV_RUN, DONE } state_e;
    state_e                       state_q;
    mul_op_e                      op_q;
    logic [31:0]                  a_q, b_q;
    logic [OOO_ROB_IDX_W-1:0]     rob_idx_q;
    logic [31:0]                  result_q;
    logic                         op_done_q;

    // ── combinational MUL paths (mirror alu.sv) ──────────────
    wire [63:0] mul_full      = $signed(a_q) * $signed(b_q);
    wire [63:0] mulh_full     = $signed({{32{a_q[31]}}, a_q})
                                * $signed({{32{b_q[31]}}, b_q});
    wire [63:0] mulhu_full    = {32'd0, a_q} * {32'd0, b_q};
    wire [63:0] mulhsu_full   = $signed({{32{a_q[31]}}, a_q})
                                * $signed({32'd0, b_q});

    logic [31:0] mul_result;
    always_comb begin
        unique case (op_q)
            MUL:    mul_result = mul_full[31:0];
            MULH:   mul_result = mulh_full[63:32];
            MULHU:  mul_result = mulhu_full[63:32];
            MULHSU: mul_result = mulhsu_full[63:32];
            default: mul_result = 32'b0;
        endcase
    end

    // ── DIVIDER instance ─────────────────────────────────────
    // start_i held high in DIV_RUN; drops the cycle after we see
    // valid_o, so the divider's "!start_i || ready" branch preloads
    // for the next op without a self-restart.
    wire        div_start = (state_q == DIV_RUN);
    wire        div_sign  = (op_q == DIV) || (op_q == REM);
    wire [31:0] div_q;
    wire [31:0] div_r;
    wire        div_valid;

    divider divider_inst (
        .clk_i      (clk_i),
        .reset_i    (reset_i),
        .stall_i    (1'b0),
        .flush_i    (flush_i),
        .sign_i     (div_sign),
        .start_i    (div_start),
        .dividend_i (a_q),
        .divider_i  (b_q),
        .quotient_o (div_q),
        .remainder_o(div_r),
        .valid_o    (div_valid)
    );

    // valid_o is also high when n==0 in idle, so we only treat it
    // as "done" while we're actually running.
    wire div_done = (state_q == DIV_RUN) && div_valid
                    && !(op_q == NO_MUL_OP);

    logic [31:0] div_result_sel;
    always_comb begin
        unique case (op_q)
            DIV, DIVU: div_result_sel = div_q;
            REM, REMU: div_result_sel = div_r;
            default:   div_result_sel = 32'b0;
        endcase
    end

    // ── FSM ──────────────────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            state_q   <= IDLE;
            op_q      <= NO_MUL_OP;
            a_q       <= '0;
            b_q       <= '0;
            rob_idx_q <= '0;
            result_q  <= '0;
            op_done_q <= FALSE;
        end else if (flush_i) begin
            // M2 phase B: muldiv ops are int producers, but the top
            // gates kick on RS issue which is itself flushed by
            // squash_mask. Still, drain the in-flight op on flush.
            state_q   <= IDLE;
            op_done_q <= FALSE;
        end else begin
            op_done_q <= FALSE;          // default: no pulse
            unique case (state_q)
                IDLE: if (kick_i == TRUE) begin
                    op_q      <= mul_op_i;
                    a_q       <= a_i;
                    b_q       <= b_i;
                    rob_idx_q <= rob_idx_i;
                    if (is_mul_class(mul_op_i)) begin
                        state_q <= MUL_REG;
                    end else if (is_div_class(mul_op_i)) begin
                        state_q <= DIV_RUN;
                    end else begin
                        // shouldn't happen: dispatch only kicks when
                        // op is a real M-ext op. Treat as no-op.
                        state_q   <= DONE;
                        result_q  <= '0;
                        op_done_q <= TRUE;
                    end
                end

                MUL_REG: begin
                    result_q  <= mul_result;
                    op_done_q <= TRUE;
                    state_q   <= DONE;
                end

                DIV_RUN: if (div_done) begin
                    result_q  <= div_result_sel;
                    op_done_q <= TRUE;
                    state_q   <= DONE;
                end

                DONE: begin
                    // Single cycle for the wb pulse to land in CDB
                    // consumers. Releasing back to IDLE here means
                    // the next kick can fire one cycle after op_done.
                    state_q <= IDLE;
                end
            endcase
        end
    end

    // ── outputs ──────────────────────────────────────────────
    assign op_done_o         = onebit_sig_e'(op_done_q);
    assign op_done_rob_idx_o = rob_idx_q;
    assign op_done_result_o  = result_q;
    assign busy_o            = onebit_sig_e'(state_q != IDLE);

endmodule
