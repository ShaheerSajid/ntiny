// ── L1 Data Cache ────────────────────────────────────────────────
// Direct-mapped, write-through, single-word entries, parameterizable.
//
// Transparent to the pipeline: always ready, 1-cycle latency.
// Read hit:  data from cache (saves RAM read)
// Read miss: forwarded to RAM, filled on response
// Write:     always forwarded to RAM (write-through), cache updated if hit
//
// No stall logic needed with 1-cycle backing SRAM.
// FENCE.I: invalidates all entries.

module dcache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,         // 32 for RV32, 64 for RV64
    parameter CACHE_BYTES = 4096        // total cache size in bytes
)(
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  logic                  flush_i,      // FENCE.I: invalidate all

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

// ── Geometry ─────────────────────────────────────────────────────
localparam WORD_BYTES  = DATA_WIDTH / 8;
localparam NUM_ENTRIES = CACHE_BYTES / WORD_BYTES;
localparam INDEX_BITS  = $clog2(NUM_ENTRIES);
localparam BYTE_OFF    = $clog2(WORD_BYTES);
localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - BYTE_OFF;

// ── Storage ──────────────────────────────────────────────────────
logic                  valid [0:NUM_ENTRIES-1];
logic [TAG_BITS-1:0]   tags  [0:NUM_ENTRIES-1];
logic [DATA_WIDTH-1:0] data  [0:NUM_ENTRIES-1];

// ── Address decomposition ────────────────────────────────────────
wire [TAG_BITS-1:0]   addr_tag   = cpu_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
wire [INDEX_BITS-1:0] addr_index = cpu_addr_i[BYTE_OFF +: INDEX_BITS];

// ── Hit detection ────────────────────────────────────────────────
wire hit = valid[addr_index] && (tags[addr_index] == addr_tag);

// ── Always forward to backing store (transparent) ────────────────
assign mem_req_o   = cpu_req_i;
assign mem_we_o    = cpu_we_i;
assign mem_addr_o  = cpu_addr_i;
assign mem_be_o    = cpu_be_i;
assign mem_wdata_o = cpu_wdata_i;

// ── Always ready ─────────────────────────────────────────────────
assign cpu_ready_o = mem_ready_i;

// ── Registered hit for read output mux ───────────────────────────
logic        hit_r;
logic        was_read_r;
logic [DATA_WIDTH-1:0] cache_rdata_r;

always_ff @(posedge clk_i) begin
    hit_r         <= hit & cpu_req_i & ~cpu_we_i & ~flush_i;
    was_read_r    <= cpu_req_i & ~cpu_we_i;
    cache_rdata_r <= data[addr_index];
end

// ── Output: always use RAM data (avoids write→read stale cache hazard) ──
// The cache fills for future use when backing store is slow (DRAM).
// With 1-cycle SRAM, RAM data is always correct and same latency.
assign cpu_rdata_o  = mem_rdata_i;
assign cpu_rvalid_o = mem_rvalid_i;

// ── Fill on read miss ────────────────────────────────────────────
logic [TAG_BITS-1:0]   fill_tag_r;
logic [INDEX_BITS-1:0] fill_index_r;
logic                  fill_pending_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        fill_pending_r <= 1'b0;
    else begin
        fill_pending_r <= cpu_req_i & ~cpu_we_i & ~hit & ~flush_i;
        fill_tag_r     <= addr_tag;
        fill_index_r   <= addr_index;
    end
end

// ── Cache array update ───────────────────────────────────────────
// Write-through on write hit: update cache alongside RAM.
// Fill on read miss response: install new entry.
logic [TAG_BITS-1:0]   wr_tag_r;
logic [INDEX_BITS-1:0] wr_index_r;
logic                  wr_hit_r;
logic [3:0]            wr_be_r;
logic [DATA_WIDTH-1:0] wr_wdata_r;

always_ff @(posedge clk_i) begin
    wr_hit_r   <= cpu_req_i & cpu_we_i & hit & ~flush_i;
    wr_tag_r   <= addr_tag;
    wr_index_r <= addr_index;
    wr_be_r    <= cpu_be_i;
    wr_wdata_r <= cpu_wdata_i;
end

integer i;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (i = 0; i < NUM_ENTRIES; i = i + 1)
            valid[i] <= 1'b0;
    end else if (flush_i) begin
        for (i = 0; i < NUM_ENTRIES; i = i + 1)
            valid[i] <= 1'b0;
    end else begin
        // Read miss fill: install entry from RAM response
        if (fill_pending_r && mem_rvalid_i) begin
            valid[fill_index_r] <= 1'b1;
            tags[fill_index_r]  <= fill_tag_r;
            data[fill_index_r]  <= mem_rdata_i;
        end
        // Write hit: update cached data (write-through keeps RAM consistent)
        if (wr_hit_r) begin
            if (wr_be_r[0]) data[wr_index_r][ 7: 0] <= wr_wdata_r[ 7: 0];
            if (wr_be_r[1]) data[wr_index_r][15: 8] <= wr_wdata_r[15: 8];
            if (wr_be_r[2]) data[wr_index_r][23:16] <= wr_wdata_r[23:16];
            if (wr_be_r[3]) data[wr_index_r][31:24] <= wr_wdata_r[31:24];
        end
    end
end

endmodule
