// ── L1 Instruction Cache ─────────────────────────────────────────────
// Direct-mapped, read-only, single-word entries, parameterizable.
//
// Transparent to the pipeline: always ready, 1-cycle latency (identical
// to the backing SRAM). On a hit, data comes from the cache tag+data
// arrays. On a miss, the request is forwarded to the backing store and
// the entry is filled simultaneously.
//
// No pipeline stall logic required — the cache is invisible to the core.
// When the backing store is slow (future DRAM), this module will need
// a fill FSM and stall output. For now, 1-cycle SRAM backing = no stalls.
//
// FENCE.I: invalidates all entries in 1 cycle.

module icache #(
    parameter ADDR_WIDTH  = 32,
    parameter DATA_WIDTH  = 32,         // 32 for RV32, 64 for RV64
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

// ── Geometry ─────────────────────────────────────────────────────
localparam WORD_BYTES = DATA_WIDTH / 8;
localparam NUM_ENTRIES = CACHE_BYTES / WORD_BYTES;            // e.g. 4096/4 = 1024
localparam INDEX_BITS  = $clog2(NUM_ENTRIES);                 // e.g. 10
localparam BYTE_OFF    = $clog2(WORD_BYTES);                  // e.g. 2
localparam TAG_BITS    = ADDR_WIDTH - INDEX_BITS - BYTE_OFF;  // e.g. 20

// ── Storage ──────────────────────────────────────────────────────
logic                  valid [0:NUM_ENTRIES-1];
logic [TAG_BITS-1:0]   tags  [0:NUM_ENTRIES-1];
logic [DATA_WIDTH-1:0] data  [0:NUM_ENTRIES-1];

// ── Address decomposition ────────────────────────────────────────
wire [TAG_BITS-1:0]   addr_tag   = cpu_addr_i[ADDR_WIDTH-1 -: TAG_BITS];
wire [INDEX_BITS-1:0] addr_index = cpu_addr_i[BYTE_OFF +: INDEX_BITS];

// ── Hit detection (combinational) ────────────────────────────────
wire hit = valid[addr_index] && (tags[addr_index] == addr_tag);

// ── Always forward to backing store ──────────────────────────────
// On a hit, the RAM access is redundant (wasted power on ASIC, fine for sim).
// On a miss, the RAM provides the data for the response AND cache fill.
// This keeps ready=1 always — the cache is transparent.
assign mem_req_o  = cpu_req_i;
assign mem_addr_o = cpu_addr_i;

// ── Always ready (1-cycle latency, like RAM) ─────────────────────
assign cpu_ready_o = mem_ready_i;   // passthrough from backing store

// ── Registered hit for output mux ────────────────────────────────
logic        hit_r;
logic [DATA_WIDTH-1:0] cache_rdata_r;

always_ff @(posedge clk_i) begin
    hit_r        <= hit & cpu_req_i & ~flush_i;
    cache_rdata_r <= data[addr_index];
end

// ── Output: select cache data on hit, RAM data on miss ───────────
assign cpu_rdata_o  = hit_r ? cache_rdata_r : mem_rdata_i;
assign cpu_rvalid_o = mem_rvalid_i;   // valid when backing store responds

// ── Fill on miss: capture RAM response into cache ────────────────
// The fill address is registered so it corresponds to the RAM response.
logic [TAG_BITS-1:0]   fill_tag_r;
logic [INDEX_BITS-1:0] fill_index_r;
logic                  fill_pending_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        fill_pending_r <= 1'b0;
    end else begin
        fill_pending_r <= cpu_req_i & ~hit & ~flush_i;
        fill_tag_r     <= addr_tag;
        fill_index_r   <= addr_index;
    end
end

// ── Cache array update ───────────────────────────────────────────
integer i;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        for (i = 0; i < NUM_ENTRIES; i = i + 1)
            valid[i] <= 1'b0;
    end else if (flush_i) begin
        for (i = 0; i < NUM_ENTRIES; i = i + 1)
            valid[i] <= 1'b0;
    end else if (fill_pending_r && mem_rvalid_i) begin
        valid[fill_index_r] <= 1'b1;
        tags[fill_index_r]  <= fill_tag_r;
        data[fill_index_r]  <= mem_rdata_i;
    end
end

endmodule
