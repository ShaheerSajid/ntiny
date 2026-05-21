// ── L1 Instruction Cache ─────────────────────────────────────────────
// Phase 2a of the bus revamp: 4-way set-associative, 32-byte lines,
// VIPT geometry. Still transparent to the pipeline — every request is
// forwarded to the backing store and the cache fills the responded word
// on the side. Real cache benefit (hit returns without touching RAM)
// arrives in Phase 2b with the multi-beat fill FSM.
//
// Geometry:
//   CACHE_BYTES = 4096
//   WAYS         = 4
//   LINE_BYTES   = 32  → 8 words per line
//   BYTES_PER_WAY = 1024 → 32 sets per way
//
// Address layout (32-bit byte address):
//   [31 .. 10]  tag      (22 bits)
//   [ 9 ..  5]  index    ( 5 bits)
//   [ 4 ..  2]  word-off ( 3 bits)
//   [ 1 ..  0]  byte-off ( 2 bits, ignored — word-aligned)
//
// Word-level valid bits inside each line let the transparent fill
// (one word per response) install only the responded word; siblings in
// the same line stay invalid until they're touched. Once the fill FSM
// in 2b can refill a full line, we can drop the per-word vector and
// use line-level valid only.
//
// Replacement: round-robin per set (one 2-bit FIFO pointer per set).
//
// FENCE.I: invalidates all entries in 1 cycle.
//
module icache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter CACHE_BYTES = 4096        // total cache size in bytes
)(
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  logic                  flush_i,      // FENCE.I: invalidate all

    // CPU-facing slave port (directly replaces RAM interface)
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

// ── Storage (per way × per set) ──────────────────────────────────────
logic                  line_valid [WAYS][SETS];                          // line in this way is allocated
logic                  word_valid [WAYS][SETS][WORDS_PER_LINE];          // per-word valid
logic [TAG_BITS-1:0]   tags       [WAYS][SETS];
logic [DATA_WIDTH-1:0] data       [WAYS][SETS][WORDS_PER_LINE];

// Round-robin replacement pointer per set
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

// ── Transparent forward to backing store ─────────────────────────────
// Same pattern as the old icache: every request goes to RAM. Phase 2b
// short-circuits this on hit.
assign mem_req_o   = cpu_req_i;
assign mem_addr_o  = cpu_addr_i;
assign cpu_ready_o = mem_ready_i;

// ── Register the hit path so cache data appears the same cycle the
//    backing store would have responded (1-cycle latency for both). ──
logic                    hit_r;
logic [DATA_WIDTH-1:0]   cache_rdata_r;

always_ff @(posedge clk_i) begin
    hit_r         <= hit & cpu_req_i & ~flush_i;
    cache_rdata_r <= data[hit_way_id][addr_index][addr_word_off];
end

// Output: cache data on hit, RAM data on miss.
assign cpu_rdata_o  = hit_r ? cache_rdata_r : mem_rdata_i;
assign cpu_rvalid_o = mem_rvalid_i;

// ── Pending fill (1-cycle pipeline to align RAM response with cache) ─
logic                      fill_pending_r;
logic [TAG_BITS-1:0]       fill_tag_r;
logic [INDEX_BITS-1:0]     fill_index_r;
logic [WORD_OFF_BITS-1:0]  fill_word_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        fill_pending_r <= 1'b0;
    end else begin
        fill_pending_r <= cpu_req_i & ~hit & ~flush_i;
        fill_tag_r     <= addr_tag;
        fill_index_r   <= addr_index;
        fill_word_r    <= addr_word_off;
    end
end

// Install-time tag-match (re-checked against current cache state, NOT
// latched at request time). Latching the match at request time made
// back-to-back fills for consecutive words in the same line race: the
// second fill would still see "no matching tag" because the first
// fill's install hadn't committed yet, and would allocate the same
// tag in a SECOND way — leaving two ways holding the same tag and
// hit_way_id picking the wrong one on subsequent hits, returning
// stale data and panicking Linux init. Computing this here closes
// the race because the always_ff that uses it commits AFTER any
// install from this very cycle is visible in the storage arrays.
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
        // line_valid in the hit check, so just clearing line_valid is
        // sufficient — but we clear word_valid too for cleanliness.
        for (int w = 0; w < WAYS; w++) begin
            for (int s = 0; s < SETS; s++) begin
                line_valid[w][s] <= 1'b0;
                for (int x = 0; x < WORDS_PER_LINE; x++) begin
                    word_valid[w][s][x] <= 1'b0;
                end
            end
        end
    end else if (fill_pending_r && mem_rvalid_i) begin
        // Pick the way to install in. install_tag_match is computed
        // combinationally from the *current* cache state above, so a
        // back-to-back fill for the same line slots into the way the
        // previous fill just allocated rather than picking a new way.
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
