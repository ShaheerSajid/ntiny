// ── L1 Instruction Cache ─────────────────────────────────────────────
// Phase 2b-iii: STALLING single-outstanding slave (variable RAM latency).
//
// Earlier (2b-ii) the cache was transparent: cpu_ready_o = mem_ready_i,
// mem_addr_o = cpu_addr_i (combinational), and the hit/miss response was
// derived from the LIVE cpu_addr_i. That silently assumes RAM returns
// rvalid exactly 1 cycle after the request, with ready hard-1. Under
// +RAM_RANDOM_DELAY (and any real AXI/DRAM slave) RAM port-A `ready`
// drops and `rvalid` lags several cycles. During that window the master
// has already advanced cpu_addr_i to the next fetch, so the transparent
// cache returned the WRONG-OFFSET word (e.g. for a fetch of 0x..404 it
// returned the word at 0x..408). That double-executed a branch target
// and corrupted beq/bne/blt/cj signatures.
//
// New contract (proper OBI-style single-outstanding slave):
//   - cpu_ready_o is HIGH only when the cache can accept a NEW request
//     this cycle (IDLE, not flushing, no RAM response still outstanding).
//     While a miss fill is in flight cpu_ready_o is LOW so the master
//     holds (addr, req) stable — the producer's inflight_vaddr_q latches
//     on (req & ready) and so stays pinned to the in-flight fetch.
//   - The fill address is CAPTURED (fill_{tag,index,word,addr}_q) at the
//     accept-of-miss edge and used for the RAM request, the install slot,
//     and the response — never the drifting live cpu_addr_i.
//   - cpu_rvalid_o pulses exactly once per accepted request, carrying the
//     data for THAT request: hit → 1-cycle registered cache word; miss →
//     mem_rdata_i when the captured fill completes.
// Under always-ready RAM (baseline) a miss simply takes 1 stall cycle;
// hits are still accept-every-cycle, 1-cycle latency — same as 2b-ii.
//
// Geometry (unchanged from 2a):
//   CACHE_BYTES    = 4096
//   WAYS           = 4
//   LINE_BYTES     = 32  → 8 words per line
//   BYTES_PER_WAY  = 1024 → 32 sets per way
//
// Address layout (32-bit byte address):
//   [31 .. 10]  tag      (22 bits)
//   [ 9 ..  5]  index    ( 5 bits)
//   [ 4 ..  2]  word-off ( 3 bits)
//   [ 1 ..  0]  byte-off ( 2 bits, ignored — word-aligned)
//
// Per-word valid bits inside each line let single-word fills install
// only the word that was responded; siblings in the same line stay
// invalid until they're touched (so a hit requires both line_valid and
// word_valid).
//
// Replacement: round-robin per set.
//
// FENCE.I: invalidates all entries in 1 cycle.
//
module icache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter CACHE_BYTES = 4096
)(
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  logic                  flush_i,      // FENCE.I: invalidate all

    // CPU-facing slave port
    input  logic                  cpu_req_i,
    input  logic [ADDR_WIDTH-1:0] cpu_addr_i,
    output logic [DATA_WIDTH-1:0] cpu_rdata_o,
    output logic                  cpu_rvalid_o,
    output logic                  cpu_ready_o,

    // Memory-facing master port (to backing store)
    output logic                  mem_req_o,
    output logic [ADDR_WIDTH-1:0] mem_addr_o,
    input  logic [DATA_WIDTH-1:0] mem_rdata_i,
    input  logic                  mem_rvalid_i,
    input  logic                  mem_ready_i
);

// ── Geometry ─────────────────────────────────────────────────────────
localparam int WAYS           = 4;
localparam int LINE_BYTES     = 32;
localparam int WORD_BYTES     = DATA_WIDTH / 8;
localparam int WORDS_PER_LINE = LINE_BYTES / WORD_BYTES;          // 8
localparam int BYTES_PER_WAY  = CACHE_BYTES / WAYS;               // 1024
localparam int SETS           = BYTES_PER_WAY / LINE_BYTES;       // 32

localparam int BYTE_OFF_BITS  = $clog2(WORD_BYTES);               // 2
localparam int WORD_OFF_BITS  = $clog2(WORDS_PER_LINE);           // 3
localparam int INDEX_BITS     = $clog2(SETS);                     // 5
localparam int TAG_BITS       = ADDR_WIDTH - INDEX_BITS - WORD_OFF_BITS - BYTE_OFF_BITS; // 22
localparam int WAY_BITS       = $clog2(WAYS);                     // 2

// ── Storage ──────────────────────────────────────────────────────────
logic                  line_valid [WAYS][SETS];
logic                  word_valid [WAYS][SETS][WORDS_PER_LINE];
logic [TAG_BITS-1:0]   tags       [WAYS][SETS];
logic [DATA_WIDTH-1:0] data       [WAYS][SETS][WORDS_PER_LINE];

// Round-robin replacement pointer per set.
logic [WAY_BITS-1:0]   repl_ptr   [SETS];

// ── Address decomposition (combinational) ────────────────────────────
wire [TAG_BITS-1:0]      addr_tag      = cpu_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
wire [INDEX_BITS-1:0]    addr_index    = cpu_addr_i[BYTE_OFF_BITS+WORD_OFF_BITS +: INDEX_BITS];
wire [WORD_OFF_BITS-1:0] addr_word_off = cpu_addr_i[BYTE_OFF_BITS +: WORD_OFF_BITS];

// ── Hit detection across 4 ways (combinational) ──────────────────────
logic [WAYS-1:0] hit_way;
generate
    for (genvar w = 0; w < WAYS; w++) begin : gen_hit
        assign hit_way[w] = line_valid[w][addr_index]
                          & (tags[w][addr_index] == addr_tag)
                          & word_valid[w][addr_index][addr_word_off];
    end
endgenerate
wire hit = |hit_way;

// Hit-way one-hot → binary (only one can be set since tags are unique per set).
logic [WAY_BITS-1:0] hit_way_id;
always_comb begin
    hit_way_id = '0;
    for (int w = 0; w < WAYS; w++) begin
        if (hit_way[w]) hit_way_id = w[WAY_BITS-1:0];
    end
end

// ── Stalling single-outstanding FSM ──────────────────────────────────
typedef enum logic [0:0] { S_IDLE, S_FILL } state_e;
state_e                    state_q;

// Captured fill request (latched at accept-of-miss; used for the RAM
// request, the install slot, and the response — never live cpu_addr_i).
logic [TAG_BITS-1:0]       fill_tag_q;
logic [INDEX_BITS-1:0]     fill_index_q;
logic [WORD_OFF_BITS-1:0]  fill_word_q;
logic [ADDR_WIDTH-1:0]     fill_addr_q;     // word-aligned RAM address
logic                      fill_live_q;     // fill still wanted (cleared by FENCE.I)

// A RAM read has been accepted (mem_req & mem_ready) and its rvalid has
// not yet arrived. Tracked across states so an abandoned (flushed) fill's
// response is swallowed before a new fill can issue — keeps the RAM port
// strictly single-outstanding.
logic                      mem_outstanding_q;

// Hit response register (1-cycle, matches the old SRAM timing).
logic                      resp_valid_q;
logic [DATA_WIDTH-1:0]     resp_data_q;

// Accept a new CPU request only when idle, not flushing, and no RAM
// response is still pending. While S_FILL the master is held (ready=0)
// and must keep (addr, req) stable.
assign cpu_ready_o = (state_q == S_IDLE) & ~flush_i & ~mem_outstanding_q;

wire accept      = cpu_req_i & cpu_ready_o;
wire accept_hit  = accept & hit;
wire accept_miss = accept & ~hit;

// Issue the RAM request on the accept-of-miss cycle (so always-ready RAM
// keeps the same miss latency as 2b-ii) and keep re-driving it while the
// fill is in flight until the slave accepts it. Never more than one RAM
// read outstanding.
assign mem_req_o  = (accept_miss | (state_q == S_FILL & fill_live_q))
                    & ~mem_outstanding_q;
assign mem_addr_o = (state_q == S_FILL) ? fill_addr_q
                                        : {cpu_addr_i[ADDR_WIDTH-1:2], 2'b00};

// The RAM accepted our read this cycle.
wire mem_launch = mem_req_o & mem_ready_i;

// Response: hit → registered cache word; miss → mem_rdata for the captured
// fill. The two never collide because S_FILL holds cpu_ready=0, so no hit
// can be accepted while a fill (and its rvalid) is in flight.
assign cpu_rvalid_o = resp_valid_q | (state_q == S_FILL & fill_live_q & mem_rvalid_i);
assign cpu_rdata_o  = resp_valid_q ? resp_data_q : mem_rdata_i;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        state_q           <= S_IDLE;
        fill_live_q       <= 1'b0;
        mem_outstanding_q <= 1'b0;
        resp_valid_q      <= 1'b0;
    end else begin
        resp_valid_q <= 1'b0;     // 1-cycle hit-response pulse default

        // RAM single-outstanding tracking.
        if (mem_launch)        mem_outstanding_q <= 1'b1;
        else if (mem_rvalid_i) mem_outstanding_q <= 1'b0;

        unique case (state_q)
            S_IDLE: begin
                if (accept_hit) begin
                    resp_valid_q <= 1'b1;
                    resp_data_q  <= data[hit_way_id][addr_index][addr_word_off];
                end else if (accept_miss) begin
                    state_q      <= S_FILL;
                    fill_live_q  <= 1'b1;
                    fill_tag_q   <= addr_tag;
                    fill_index_q <= addr_index;
                    fill_word_q  <= addr_word_off;
                    fill_addr_q  <= {cpu_addr_i[ADDR_WIDTH-1:2], 2'b00};
                end
            end
            S_FILL: begin
                // FENCE.I abandons the in-flight fill; the core flushes +
                // redirects on the same event, so its inflight_q is already
                // cleared and no cpu_rvalid is owed. Any RAM read already
                // launched is still drained via mem_outstanding_q below.
                if (flush_i) fill_live_q <= 1'b0;

                if (fill_live_q & ~flush_i & mem_rvalid_i) begin
                    // Wanted response arrived → install (below) + return.
                    state_q <= S_IDLE;
                end else if (!(fill_live_q & ~flush_i)) begin
                    // Abandoned fill: return to IDLE once the RAM port is
                    // drained (rvalid for an already-launched read, or no
                    // read launched at all this/last cycle).
                    if (mem_rvalid_i || (~mem_outstanding_q & ~mem_launch))
                        state_q <= S_IDLE;
                end
            end
        endcase
    end
end

// Install-time tag-match — see the 2a hotfix commit (23c222e) for the
// long-form rationale. Computed combinationally against the *current*
// cache state so back-to-back fills for consecutive words in the same
// line slot into the way the previous fill just allocated rather than
// picking a new way (avoids the two-ways-same-tag Linux-init bug).
logic                  install_tag_match;
logic [WAY_BITS-1:0]   install_tag_match_way;
always_comb begin
    install_tag_match     = 1'b0;
    install_tag_match_way = '0;
    for (int w = 0; w < WAYS; w++) begin
        if (line_valid[w][fill_index_q] && tags[w][fill_index_q] == fill_tag_q) begin
            install_tag_match     = 1'b1;
            install_tag_match_way = w[WAY_BITS-1:0];
        end
    end
end

// ── Cache array update + replacement bookkeeping ─────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (int w = 0; w < WAYS; w++) begin
            for (int s = 0; s < SETS; s++) begin
                line_valid[w][s] <= 1'b0;
                for (int x = 0; x < WORDS_PER_LINE; x++) begin
                    word_valid[w][s][x] <= 1'b0;
                end
            end
        end
        for (int s = 0; s < SETS; s++) repl_ptr[s] <= '0;
    end else if (flush_i) begin
        // FENCE.I: invalidate every line. Word_valid bits are gated by
        // line_valid in the hit check, so clearing line_valid is
        // sufficient — we also clear word_valid for cleanliness.
        for (int w = 0; w < WAYS; w++) begin
            for (int s = 0; s < SETS; s++) begin
                line_valid[w][s] <= 1'b0;
                for (int x = 0; x < WORDS_PER_LINE; x++) begin
                    word_valid[w][s][x] <= 1'b0;
                end
            end
        end
    end else if (state_q == S_FILL && fill_live_q && mem_rvalid_i) begin
        automatic logic [WAY_BITS-1:0] install_way =
            install_tag_match ? install_tag_match_way : repl_ptr[fill_index_q];

        if (!install_tag_match) begin
            // New tag in this set — evict the way picked by repl_ptr,
            // invalidate all its words, then install the requested one.
            tags[install_way][fill_index_q] <= fill_tag_q;
            for (int x = 0; x < WORDS_PER_LINE; x++) begin
                word_valid[install_way][fill_index_q][x] <= 1'b0;
            end
            // Bump round-robin pointer.
            repl_ptr[fill_index_q] <= install_way + 1'b1;
        end

        line_valid[install_way][fill_index_q]                 <= 1'b1;
        word_valid[install_way][fill_index_q][fill_word_q]    <= 1'b1;
        data      [install_way][fill_index_q][fill_word_q]    <= mem_rdata_i;
    end
end

endmodule
