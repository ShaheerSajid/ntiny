// ── L1 Instruction Cache ─────────────────────────────────────────────
// Phase 2b-ii of the bus revamp: cache hits now BYPASS the backing
// store. mem_req is only issued on a miss; on a hit the cache returns
// data from its internal arrays and the RAM access is skipped (real
// bandwidth savings on hot loops + tight icache regions).
//
// Compared to Phase 2a (which forwarded every request to RAM and just
// filled words on the side), 2b-ii is the first version where the cache
// actually saves RAM port-A traffic.
//
// Pipeline contract is UNCHANGED from 2a:
//   - cpu_ready_o = mem_ready_i (always 1 here; never stalls).
//   - cpu_rvalid_o asserts 1 cycle after acceptance, the same SRAM-
//     style timing the fetch pipeline already expects.
//
// Why no stalling FSM / multi-beat fill in this commit: the producer
// (`core_top.sv`) relies on the cache being able to accept a request
// every cycle to drive the inflight_vaddr_q ↔ rdata alignment that
// gives correct {word, vaddr} buffer entries for the very first fetch
// at reset deassert. Real multi-beat fills with a stalling slave need
// a producer-side "first fetch pending" register to keep the master
// re-issuing the reset PC across the stall window — that lands later
// (Phase 3 sub-step), together with the AXI burst master where the
// burst geometry actually matters.
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

// ── Memory-side req ──────────────────────────────────────────────────
// 2b-ii change: skip the mem_req when this cycle's CPU request is a
// hit AND the cache isn't being invalidated this cycle. The flush_i
// guard MUST keep mem_req=1 during a FENCE.I cycle even if the cache
// would have hit: hit_r is also gated to 0 by ~flush_i below, so
// without forwarding to RAM the master would see neither hit_r nor
// mem_rvalid_i — a silently dropped fetch. (That regression panicked
// Linux init at flush_icache_pte during set_pte_range, mirroring
// Phase 2a's "exitcode=0xb" race.)
assign mem_req_o   = cpu_req_i & (~hit | flush_i);
assign mem_addr_o  = cpu_addr_i;
assign cpu_ready_o = mem_ready_i;

// ── Hit-side response (1-cycle pipeline matching SRAM timing) ────────
// hit_r captures whether THIS request was a hit, so next cycle we know
// to route cache data instead of mem data. cache_rdata_r samples the
// hit-way data array unconditionally; it's only consumed on hit_r=1.
logic                  hit_r;
logic [DATA_WIDTH-1:0] cache_rdata_r;

always_ff @(posedge clk_i) begin
    hit_r         <= cpu_req_i & hit & ~flush_i;
    cache_rdata_r <= data[hit_way_id][addr_index][addr_word_off];
end

// Output: cache data on hit_r, RAM data on miss. cpu_rvalid_o is
// hit_r OR mem_rvalid_i so the master sees a valid response in both
// cases.
assign cpu_rdata_o  = hit_r ? cache_rdata_r : mem_rdata_i;
assign cpu_rvalid_o = hit_r | mem_rvalid_i;

// ── Miss fill pipeline (single-word, registered to align with RAM) ───
// Unchanged from 2a: each miss response installs the responded word
// into the picked way; the rest of the line stays invalid until those
// words get touched. Multi-beat line fills are deferred to a later
// phase where the AXI master path makes burst geometry meaningful.
logic                      fill_pending_r;
logic [TAG_BITS-1:0]       fill_tag_r;
logic [INDEX_BITS-1:0]     fill_index_r;
logic [WORD_OFF_BITS-1:0]  fill_word_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        fill_pending_r <= 1'b0;
    end else begin
        // Track misses (where we actually issued mem_req). On hit we
        // intentionally don't fill (the word is already cached) so
        // fill_pending_r stays 0 and we don't double-install.
        fill_pending_r <= cpu_req_i & ~hit & ~flush_i;
        fill_tag_r     <= addr_tag;
        fill_index_r   <= addr_index;
        fill_word_r    <= addr_word_off;
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
        if (line_valid[w][fill_index_r] && tags[w][fill_index_r] == fill_tag_r) begin
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
    end else if (fill_pending_r && mem_rvalid_i) begin
        automatic logic [WAY_BITS-1:0] install_way =
            install_tag_match ? install_tag_match_way : repl_ptr[fill_index_r];

        if (!install_tag_match) begin
            // New tag in this set — evict the way picked by repl_ptr,
            // invalidate all its words, then install the requested one.
            tags[install_way][fill_index_r] <= fill_tag_r;
            for (int x = 0; x < WORDS_PER_LINE; x++) begin
                word_valid[install_way][fill_index_r][x] <= 1'b0;
            end
            // Bump round-robin pointer.
            repl_ptr[fill_index_r] <= install_way + 1'b1;
        end

        line_valid[install_way][fill_index_r]                 <= 1'b1;
        word_valid[install_way][fill_index_r][fill_word_r]    <= 1'b1;
        data      [install_way][fill_index_r][fill_word_r]    <= mem_rdata_i;
    end
end

endmodule
