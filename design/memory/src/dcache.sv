// ── L1 Data Cache ────────────────────────────────────────────────────
// Phase 2a of the bus revamp: 4-way set-associative, 32-byte lines,
// VIPT geometry. Still transparent (write-through; every CPU req goes
// to backing store) and `cpu_rdata_o` is wired directly to the RAM
// response — this preserves the old dcache's invariant that the
// pipeline never sees stale cached data on a write→read hazard.
// Phase 2c flips this to write-back + read-from-cache.
//
// Geometry mirrors icache.sv (4 ways × 32 sets × 8 words/line = 4 KB).
// Per-word valid bits in each line let transparent fills install one
// word per response without invalidating the rest of the line. Write
// updates the cached word on a hit (so future Phase 2c reads-from-
// cache start coherent).
//
// FENCE.I: invalidates all entries in 1 cycle.
//
module dcache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,
    parameter CACHE_BYTES = 4096
)(
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  logic                  flush_i,

    // CPU-facing slave port
    input  logic                  cpu_req_i,
    input  logic                  cpu_we_i,
    input  logic [ADDR_WIDTH-1:0] cpu_addr_i,
    input  logic [3:0]            cpu_be_i,
    input  logic [DATA_WIDTH-1:0] cpu_wdata_i,
    output logic [DATA_WIDTH-1:0] cpu_rdata_o,
    output logic                  cpu_rvalid_o,
    output logic                  cpu_ready_o,

    // Memory-facing master port (to backing store)
    output logic                  mem_req_o,
    output logic                  mem_we_o,
    output logic [ADDR_WIDTH-1:0] mem_addr_o,
    output logic [3:0]            mem_be_o,
    output logic [DATA_WIDTH-1:0] mem_wdata_o,
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
logic [WAY_BITS-1:0]   repl_ptr   [SETS];

// ── Address decomposition ────────────────────────────────────────────
wire [TAG_BITS-1:0]      addr_tag      = cpu_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
wire [INDEX_BITS-1:0]    addr_index    = cpu_addr_i[BYTE_OFF_BITS+WORD_OFF_BITS +: INDEX_BITS];
wire [WORD_OFF_BITS-1:0] addr_word_off = cpu_addr_i[BYTE_OFF_BITS +: WORD_OFF_BITS];

// ── Hit detection ────────────────────────────────────────────────────
logic [WAYS-1:0] hit_way;
generate
    for (genvar w = 0; w < WAYS; w++) begin : gen_hit
        assign hit_way[w] = line_valid[w][addr_index]
                          & (tags[w][addr_index] == addr_tag)
                          & word_valid[w][addr_index][addr_word_off];
    end
endgenerate
wire hit = |hit_way;

logic [WAY_BITS-1:0] hit_way_id;
always_comb begin
    hit_way_id = '0;
    for (int w = 0; w < WAYS; w++) begin
        if (hit_way[w]) hit_way_id = w[WAY_BITS-1:0];
    end
end

// ── Transparent forward to backing store (writes + reads) ────────────
assign mem_req_o   = cpu_req_i;
assign mem_we_o    = cpu_we_i;
assign mem_addr_o  = cpu_addr_i;
assign mem_be_o    = cpu_be_i;
assign mem_wdata_o = cpu_wdata_i;
assign cpu_ready_o = mem_ready_i;

// Output: rdata always comes from RAM (preserves the write→read no-
// stale-data invariant from the old single-word dcache). Phase 2c
// switches to cache rdata once write-back makes the cache authoritative.
assign cpu_rdata_o  = mem_rdata_i;
assign cpu_rvalid_o = mem_rvalid_i;

// ── Read-miss fill pipe (registered to align with RAM response) ──────
logic                      fill_pending_r;
logic [TAG_BITS-1:0]       fill_tag_r;
logic [INDEX_BITS-1:0]     fill_index_r;
logic [WORD_OFF_BITS-1:0]  fill_word_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        fill_pending_r <= 1'b0;
    end else begin
        fill_pending_r <= cpu_req_i & ~cpu_we_i & ~hit & ~flush_i;
        fill_tag_r     <= addr_tag;
        fill_index_r   <= addr_index;
        fill_word_r    <= addr_word_off;
    end
end

// Install-time tag-match — see icache.sv for the long-form rationale.
// Same race here for back-to-back loads to consecutive words in the
// same line; using the latched fill_tag_match_r let two ways hold the
// same tag and hit_way_id picked the wrong one.
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

// ── Write-hit update pipe (registered so write+fill arbitrate cleanly) ─
logic                      wr_hit_r;
logic [WAY_BITS-1:0]       wr_way_r;
logic [INDEX_BITS-1:0]     wr_index_r;
logic [WORD_OFF_BITS-1:0]  wr_word_r;
logic [3:0]                wr_be_r;
logic [DATA_WIDTH-1:0]     wr_wdata_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        wr_hit_r <= 1'b0;
    end else begin
        wr_hit_r   <= cpu_req_i & cpu_we_i & hit & ~flush_i;
        wr_way_r   <= hit_way_id;
        wr_index_r <= addr_index;
        wr_word_r  <= addr_word_off;
        wr_be_r    <= cpu_be_i;
        wr_wdata_r <= cpu_wdata_i;
    end
end

// ── Cache array update + replacement ─────────────────────────────────
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
        for (int w = 0; w < WAYS; w++) begin
            for (int s = 0; s < SETS; s++) begin
                line_valid[w][s] <= 1'b0;
                for (int x = 0; x < WORDS_PER_LINE; x++) begin
                    word_valid[w][s][x] <= 1'b0;
                end
            end
        end
    end else begin
        // Read-miss fill: install word in an existing matching way or evict.
        if (fill_pending_r && mem_rvalid_i) begin
            automatic logic [WAY_BITS-1:0] install_way =
                install_tag_match ? install_tag_match_way : repl_ptr[fill_index_r];

            if (!install_tag_match) begin
                tags[install_way][fill_index_r] <= fill_tag_r;
                for (int x = 0; x < WORDS_PER_LINE; x++) begin
                    word_valid[install_way][fill_index_r][x] <= 1'b0;
                end
                repl_ptr[fill_index_r] <= install_way + 1'b1;
            end

            line_valid[install_way][fill_index_r]             <= 1'b1;
            word_valid[install_way][fill_index_r][fill_word_r] <= 1'b1;
            data      [install_way][fill_index_r][fill_word_r] <= mem_rdata_i;
        end

        // Write-hit: byte-merge into the cached word so the cache stays
        // coherent with RAM (we already wrote-through above).
        if (wr_hit_r) begin
            if (wr_be_r[0]) data[wr_way_r][wr_index_r][wr_word_r][ 7: 0] <= wr_wdata_r[ 7: 0];
            if (wr_be_r[1]) data[wr_way_r][wr_index_r][wr_word_r][15: 8] <= wr_wdata_r[15: 8];
            if (wr_be_r[2]) data[wr_way_r][wr_index_r][wr_word_r][23:16] <= wr_wdata_r[23:16];
            if (wr_be_r[3]) data[wr_way_r][wr_index_r][wr_word_r][31:24] <= wr_wdata_r[31:24];
        end
    end
end

endmodule
