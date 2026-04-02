// ── RISC-V Integer Divider ───────────────────────────────────────────────────
// Restoring binary division with LZC-based early termination.
// Processes one bit per cycle from MSB of the dividend downward, skipping
// leading zeros via the lzc module.
//
// Latency: max(3, significant_bits) cycles  (e.g., 3 cycles for dividend <= 7)
// Special cases per RISC-V spec (handled at load time, 0 extra cycles):
//   - Divide by zero:    quotient = all-ones,  remainder = dividend
//   - Signed overflow:   quotient = -2^31,     remainder = 0
//
module divider (
    input  logic        clk_i,
    input  logic        reset_i,
    input  logic        stall_i,
    input  logic        flush_i,
    input  logic        sign_i,     // 1 = signed (DIV/REM), 0 = unsigned (DIVU/REMU)
    input  logic        start_i,
    input  logic [31:0] dividend_i,
    input  logic [31:0] divider_i,

    output logic [31:0] quotient_o,
    output logic [31:0] remainder_o,
    output logic        valid_o
);

// ── Absolute values for signed division ─────────────────────────────────
wire n_neg = sign_i & dividend_i[31];
wire d_neg = sign_i & divider_i[31];
wire [31:0] abs_n = n_neg ? (~dividend_i + 1'b1) : dividend_i;
wire [31:0] abs_d = d_neg ? (~divider_i  + 1'b1) : divider_i;

// ── Special cases ───────────────────────────────────────────────────────
wire div_by_zero = (divider_i == 0);
wire signed_ovf  = sign_i && (dividend_i == 32'h80000000) && (divider_i == 32'hFFFFFFFF);

// ── LZC for early termination ───────────────────────────────────────────
wire [4:0] lzc_cnt;
wire       lzc_zero;
lzc #(.WIDTH(32)) div_lzc (
    .a_i    (abs_n),
    .cnt_o  (lzc_cnt),
    .zero_o (lzc_zero)
);
wire [5:0] sig_bits = lzc_zero ? 6'd3 : (6'd32 - {1'b0, lzc_cnt});
wire [5:0] init_n   = (div_by_zero || signed_ovf || sig_bits < 6'd3) ? 6'd3 : sig_bits;

// ── Datapath registers ──────────────────────────────────────────────────
logic [31:0] N;          // dividend (abs)
logic [31:0] D;          // divisor (abs)
logic [31:0] Q;          // quotient accumulator
logic [31:0] R;          // running remainder
logic [31:0] N_r, D_r;   // original (signed) operands for output sign fixup
logic [5:0]  n;          // iteration counter (counts down to 0)
logic        loaded;     // operands have been loaded

wire ready = (n == 0);

// ── Restoring division iteration (combinational) ────────────────────────
wire        N_bit   = N[n - 1'b1];                    // current dividend bit
wire [31:0] r_shift = {R[30:0], N_bit};                // shift remainder, bring in bit
wire        r_geq_d = (r_shift >= D);                  // trial subtraction
wire [31:0] r_next  = r_geq_d ? (r_shift - D) : r_shift;
wire [31:0] q_bit   = r_geq_d ? (32'd1 << (n - 1'b1)) : 32'd0;

// ── Sequential logic ────────────────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        n <= 0; Q <= 0; R <= 0; N <= 0; D <= 0;
        N_r <= 0; D_r <= 0; loaded <= 1'b0;
    end else if (flush_i) begin
        n <= 0; Q <= 0; R <= 0; N <= 0; D <= 0;
        N_r <= 0; D_r <= 0; loaded <= 1'b0;
    end else if (!stall_i) begin
        if (!start_i || ready) begin
            // Idle: preload iteration count for next start
            n <= init_n;
            Q <= 0; R <= 0; N <= 0; D <= 0;
            N_r <= 0; D_r <= 0; loaded <= 1'b0;
        end else if (!loaded) begin
            // First cycle: load absolute operands, save originals
            n      <= init_n;
            Q      <= 0;
            R      <= 0;
            N      <= abs_n;
            D      <= abs_d;
            N_r    <= dividend_i;
            D_r    <= divider_i;
            loaded <= 1'b1;
        end else begin
            // Iterate: one bit per cycle
            n <= n - 1'b1;
            R <= r_next;
            Q <= Q | q_bit;
        end
    end
end

// ── Output with sign correction and RISC-V special cases ────────────────
wire neg_q = sign_i & (N_r[31] ^ D_r[31]);
wire neg_r = sign_i & N_r[31];

always_comb begin
    if (div_by_zero) begin
        quotient_o  = 32'hFFFFFFFF;
        remainder_o = N_r;
    end else if (signed_ovf) begin
        quotient_o  = 32'h80000000;
        remainder_o = 32'h0;
    end else begin
        quotient_o  = neg_q ? (~Q + 1'b1) : Q;
        remainder_o = neg_r ? (~R + 1'b1) : R;
    end
end

assign valid_o = ready;

endmodule
