`include "mem_map.svh"

// ── Dual-Port RAM ───────────────────────────────────────────
// Port A: instruction fetch (read-only)
// Port B: data access (read/write with byte enables)
//
// Both ports access the same memory array.
// Single-cycle latency: rvalid appears 1 cycle after req && ready.
// ready is always 1 (SRAM never stalls).
//
// For ASIC/FPGA: replace this module with a technology-specific
// dual-port SRAM wrapper using the same port interface.
//
module ram_dp #(
    parameter DEPTH    = `RAM_DEPTH,
    parameter AW       = `RAM_ADDR_WIDTH,
    parameter HEX_FILE = "ram.hex"
)(
    input logic clk_i,

    // Port A — instruction fetch (read-only)
    input  logic        pa_req_i,
    input  logic [31:0] pa_addr_i,
    output logic [31:0] pa_rdata_o,
    output logic        pa_rvalid_o,
    output logic        pa_ready_o,

    // Port B — data access (read/write)
    input  logic        pb_req_i,
    input  logic        pb_we_i,
    input  logic [31:0] pb_addr_i,
    input  logic [3:0]  pb_be_i,
    input  logic [31:0] pb_wdata_i,
    output logic [31:0] pb_rdata_o,
    output logic        pb_rvalid_o,
    output logic        pb_ready_o
);

    // ── Backing store ────────────────────────────────────────
    reg [31:0] mem [0:DEPTH-1];

    integer i;
    initial begin
        for (i = 0; i < DEPTH; i = i + 1)
            mem[i] = 32'h0;
        $readmemh(HEX_FILE, mem);
    end

    // ── Address conversion: byte address → word index ────────
    wire [AW-1:0] addr_a = pa_addr_i[AW+1:2];
    wire [AW-1:0] addr_b = pb_addr_i[AW+1:2];

    // ── Port A: read-only ────────────────────────────────────
    assign pa_ready_o = 1'b1;

    always_ff @(posedge clk_i) begin
        pa_rvalid_o <= pa_req_i;
        if (pa_req_i)
            pa_rdata_o <= mem[addr_a];
    end

    // ── Port B: read/write with byte enables ─────────────────
    assign pb_ready_o = 1'b1;

    always_ff @(posedge clk_i) begin
        pb_rvalid_o <= pb_req_i & ~pb_we_i;
        if (pb_req_i) begin
            if (pb_we_i) begin
                if (pb_be_i[0]) mem[addr_b][ 7: 0] <= pb_wdata_i[ 7: 0];
                if (pb_be_i[1]) mem[addr_b][15: 8] <= pb_wdata_i[15: 8];
                if (pb_be_i[2]) mem[addr_b][23:16] <= pb_wdata_i[23:16];
                if (pb_be_i[3]) mem[addr_b][31:24] <= pb_wdata_i[31:24];
            end else begin
                pb_rdata_o <= mem[addr_b];
            end
        end
    end

endmodule
