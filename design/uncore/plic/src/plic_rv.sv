// ── RISC-V PLIC (Platform-Level Interrupt Controller) ────────────
// Spec-compliant, single-context (1 hart), parameterizable sources.
//
// Register map (base 0x0C00_0000):
//   0x000000 + 4*src   : source priority   (RW, 3-bit, 0=disabled)
//   0x001000            : pending bits      (RO, 1 bit per source)
//   0x002000            : enable bits       (RW, 1 bit per source)
//   0x200000            : priority threshold (RW, 3-bit)
//   0x200004            : claim/complete    (RW: read=claim, write=complete)
//
// Interrupt output (ext_irq_o): active-high, level-sensitive.
// Asserted when any enabled pending source has priority > threshold.
//
// Claim: reading 0x200004 returns highest-priority pending source ID
//        and clears its pending bit.
// Complete: writing source ID to 0x200004 re-enables that source's gateway.

module plic_rv #(
    parameter NUM_SOURCES   = 6,
    parameter PRIORITY_BITS = 3
)(
    input  logic        clk_i,
    input  logic        reset_i,

    // Bus interface
    input  logic        chipselect_i,
    input  logic        write_i,
    input  logic        read_i,
    input  logic [21:0] address_i,        // byte address within PLIC region
    input  logic [31:0] writedata_i,
    output logic [31:0] readdata_o,

    // Interrupt sources (active-high level from peripherals)
    input  logic [NUM_SOURCES-1:0] sources_i,

    // Interrupt output to core (MIP[11] MEIP)
    output logic        ext_irq_o
);

// ── Storage ──────────────────────────────────────────────────────
// Source 0 is reserved (hardwired to 0) per spec. Sources 1..NUM_SOURCES.
logic [PRIORITY_BITS-1:0] priority_reg [0:NUM_SOURCES];  // [0] unused
logic [NUM_SOURCES:0]     pending;                        // [0] unused
logic [NUM_SOURCES:0]     enable;                         // context 0 enables
logic [PRIORITY_BITS-1:0] threshold;
logic [NUM_SOURCES:0]     gateway_ready;                  // source can re-fire

// ── Address decode ───────────────────────────────────────────────
wire in_priority  = (address_i[21:12] == 10'h000);        // 0x000000-0x000FFF
wire in_pending   = (address_i[21:12] == 10'h001);        // 0x001000-0x001FFF
wire in_enable    = (address_i[21:12] == 10'h002);        // 0x002000-0x002FFF
wire in_context   = (address_i[21:12] >= 10'h200);        // 0x200000+

wire [7:0] src_index = address_i[9:2];                    // source index for priority regs
wire       is_threshold = in_context && (address_i[11:0] == 12'h000);
wire       is_claim     = in_context && (address_i[11:0] == 12'h004);

// ── Gateway: latch edge from level-sensitive sources ─────────────
// A source becomes pending when its input is high AND gateway is ready.
// Gateway blocks until the interrupt is completed.
integer gi;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (gi = 0; gi <= NUM_SOURCES; gi = gi + 1) begin
            pending[gi]       <= 1'b0;
            gateway_ready[gi] <= 1'b1;
        end
    end else begin
        for (gi = 1; gi <= NUM_SOURCES; gi = gi + 1) begin
            // Set pending on rising edge (source high + gateway ready)
            if (sources_i[gi-1] && gateway_ready[gi] && !pending[gi])
                pending[gi] <= 1'b1;
        end

        // Claim: clear pending, lock gateway
        if (chipselect_i && read_i && is_claim && claim_id != 0) begin
            pending[claim_id]       <= 1'b0;
            gateway_ready[claim_id] <= 1'b0;
        end

        // Complete: unlock gateway
        if (chipselect_i && write_i && is_claim) begin
            if (writedata_i <= NUM_SOURCES && writedata_i > 0)
                gateway_ready[writedata_i[($clog2(NUM_SOURCES+1))-1:0]] <= 1'b1;
        end
    end
end

// ── Priority arbitration: find highest-priority pending+enabled ──
logic [$clog2(NUM_SOURCES+1)-1:0] claim_id;
logic [PRIORITY_BITS-1:0]         claim_priority;

integer ai;
always_comb begin
    claim_id       = '0;
    claim_priority = '0;
    for (ai = 1; ai <= NUM_SOURCES; ai = ai + 1) begin
        if (pending[ai] && enable[ai] && (priority_reg[ai] > claim_priority)) begin
            claim_id       = ai[$clog2(NUM_SOURCES+1)-1:0];
            claim_priority = priority_reg[ai];
        end
    end
end

// ── Interrupt output: any qualified source above threshold ───────
assign ext_irq_o = (claim_priority > threshold) && (claim_id != 0);

// ── Register writes ──────────────────────────────────────────────
integer wi;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (wi = 0; wi <= NUM_SOURCES; wi = wi + 1)
            priority_reg[wi] <= '0;
        enable    <= '0;
        threshold <= '0;
    end else if (chipselect_i && write_i) begin
        if (in_priority && src_index <= NUM_SOURCES && src_index > 0)
            priority_reg[src_index] <= writedata_i[PRIORITY_BITS-1:0];
        if (in_enable)
            enable <= writedata_i[NUM_SOURCES:0];
        if (is_threshold)
            threshold <= writedata_i[PRIORITY_BITS-1:0];
        // Claim write (complete) handled above in gateway logic
    end
end

// ── Register reads ───────────────────────────────────────────────
always_comb begin
    readdata_o = 32'h0;
    if (chipselect_i && read_i) begin
        if (in_priority && src_index <= NUM_SOURCES)
            readdata_o = {29'd0, priority_reg[src_index]};
        else if (in_pending)
            readdata_o = {{(32-NUM_SOURCES-1){1'b0}}, pending};
        else if (in_enable)
            readdata_o = {{(32-NUM_SOURCES-1){1'b0}}, enable};
        else if (is_threshold)
            readdata_o = {29'd0, threshold};
        else if (is_claim)
            readdata_o = {{(32-$clog2(NUM_SOURCES+1)){1'b0}}, claim_id};
    end
end

endmodule
