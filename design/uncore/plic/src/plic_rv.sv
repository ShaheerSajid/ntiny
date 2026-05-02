// ── RISC-V PLIC (Platform-Level Interrupt Controller) ────────────
// Spec-compliant, NUM_CONTEXTS=2 (1 hart × {M-mode, S-mode}),
// parameterizable sources.
//
// Register map (base 0x0C00_0000):
//   0x000004 + 4*src       : source priority (RW, 3-bit, 0=disabled)
//   0x001000               : pending bits (RO, 1 bit per source)
//   0x002000 + ctx*0x80    : enable bits for context (RW)
//   0x200000 + ctx*0x1000  : priority threshold for context (RW)
//   0x200004 + ctx*0x1000  : claim/complete (RW; read=claim, write=complete)
//
// Contexts:
//   ctx 0 = hart 0 / M-mode → drives ext_irq_m_o (MEIP)
//   ctx 1 = hart 0 / S-mode → drives ext_irq_s_o (SEIP)
//
// Phase 1.5 of peripheral standardisation: the previous single-context
// PLIC made Linux (S-mode) NULL-deref inside plic_irq_enable the moment
// any peripheral driver requested an IRQ — there was nowhere to register
// an S-mode handler.

module plic_rv #(
    parameter NUM_SOURCES   = 6,
    parameter PRIORITY_BITS = 3,
    parameter NUM_CONTEXTS  = 2
)(
    input  logic        clk_i,
    input  logic        reset_i,

    input  logic        chipselect_i,
    input  logic        write_i,
    input  logic        read_i,
    input  logic [21:0] address_i,
    input  logic [31:0] writedata_i,
    output logic [31:0] readdata_o,

    input  logic [NUM_SOURCES-1:0] sources_i,

    output logic        ext_irq_m_o,   // MEIP for hart 0
    output logic        ext_irq_s_o    // SEIP for hart 0
);

// ── Storage ──────────────────────────────────────────────────────
logic [PRIORITY_BITS-1:0] priority_reg [0:NUM_SOURCES];          // [0] unused
logic [NUM_SOURCES:0]     pending;                                // [0] unused
logic [NUM_SOURCES:0]     enable     [0:NUM_CONTEXTS-1];          // per context
logic [PRIORITY_BITS-1:0] threshold  [0:NUM_CONTEXTS-1];
logic [NUM_SOURCES:0]     gateway_ready;                          // shared (PLIC spec)

// ── Address decode ───────────────────────────────────────────────
wire in_priority   = (address_i[21:12] == 10'h000);
wire in_pending    = (address_i[21:12] == 10'h001);
wire in_enable     = (address_i[21:12] == 10'h002);
wire in_context    = (address_i[21:12] >= 10'h200) &&
                     (address_i[21:12] <  10'h200 + NUM_CONTEXTS);

wire [7:0] src_index    = address_i[9:2];
wire       is_threshold = in_context && (address_i[11:0] == 12'h000);
wire       is_claim     = in_context && (address_i[11:0] == 12'h004);

// Enable is striped at 0x80 per context: addr[11:7] = ctx within enable region.
// We only need bit [7] for NUM_CONTEXTS=2.
wire [$clog2(NUM_CONTEXTS)-1:0] ctx_e = address_i[7];
// Context within the threshold/claim region: addr[21:12] - 0x200.
wire [$clog2(NUM_CONTEXTS)-1:0] ctx_c = address_i[12];

// ── Gateway: latch edge from level-sensitive sources ─────────────
integer gi;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (gi = 0; gi <= NUM_SOURCES; gi = gi + 1) begin
            pending[gi]       <= 1'b0;
            gateway_ready[gi] <= 1'b1;
        end
    end else begin
        for (gi = 1; gi <= NUM_SOURCES; gi = gi + 1) begin
            if (sources_i[gi-1] && gateway_ready[gi] && !pending[gi])
                pending[gi] <= 1'b1;
        end

        // Claim from any context: clear pending, lock gateway. Only one
        // context can win the claim at a time because the bus is single-
        // master from the core; subsequent reads won't double-claim.
        if (chipselect_i && read_i && is_claim && claim_id[ctx_c] != 0) begin
            pending[claim_id[ctx_c]]       <= 1'b0;
            gateway_ready[claim_id[ctx_c]] <= 1'b0;
        end

        // Complete: unlock gateway. Spec allows complete from either context.
        if (chipselect_i && write_i && is_claim) begin
            if (writedata_i <= NUM_SOURCES && writedata_i > 0)
                gateway_ready[writedata_i[($clog2(NUM_SOURCES+1))-1:0]] <= 1'b1;
        end
    end
end

// ── Per-context priority arbitration ─────────────────────────────
logic [$clog2(NUM_SOURCES+1)-1:0] claim_id       [0:NUM_CONTEXTS-1];
logic [PRIORITY_BITS-1:0]         claim_priority [0:NUM_CONTEXTS-1];

integer ai, ci;
always_comb begin
    for (ci = 0; ci < NUM_CONTEXTS; ci = ci + 1) begin
        claim_id[ci]       = '0;
        claim_priority[ci] = '0;
        for (ai = 1; ai <= NUM_SOURCES; ai = ai + 1) begin
            if (pending[ai] && enable[ci][ai] &&
                (priority_reg[ai] > claim_priority[ci])) begin
                claim_id[ci]       = ai[$clog2(NUM_SOURCES+1)-1:0];
                claim_priority[ci] = priority_reg[ai];
            end
        end
    end
end

assign ext_irq_m_o = (claim_priority[0] > threshold[0]) && (claim_id[0] != 0);
assign ext_irq_s_o = (claim_priority[1] > threshold[1]) && (claim_id[1] != 0);

// ── Register writes ──────────────────────────────────────────────
integer wi, wci;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (wi = 0; wi <= NUM_SOURCES; wi = wi + 1)
            priority_reg[wi] <= '0;
        for (wci = 0; wci < NUM_CONTEXTS; wci = wci + 1) begin
            enable[wci]    <= '0;
            threshold[wci] <= '0;
        end
    end else if (chipselect_i && write_i) begin
        if (in_priority && src_index <= NUM_SOURCES && src_index > 0)
            priority_reg[src_index] <= writedata_i[PRIORITY_BITS-1:0];
        if (in_enable)
            enable[ctx_e] <= writedata_i[NUM_SOURCES:0];
        if (is_threshold)
            threshold[ctx_c] <= writedata_i[PRIORITY_BITS-1:0];
        // Claim write (complete) handled in gateway logic above.
    end
end

// ── Register reads ───────────────────────────────────────────────
always_ff @(posedge clk_i) begin
    if (chipselect_i && read_i) begin
        if (in_priority && src_index <= NUM_SOURCES)
            readdata_o <= {29'd0, priority_reg[src_index]};
        else if (in_pending)
            readdata_o <= {{(32-NUM_SOURCES-1){1'b0}}, pending};
        else if (in_enable)
            readdata_o <= {{(32-NUM_SOURCES-1){1'b0}}, enable[ctx_e]};
        else if (is_threshold)
            readdata_o <= {29'd0, threshold[ctx_c]};
        else if (is_claim)
            readdata_o <= {{(32-$clog2(NUM_SOURCES+1)){1'b0}}, claim_id[ctx_c]};
        else
            readdata_o <= 32'h0;
    end
end

endmodule
