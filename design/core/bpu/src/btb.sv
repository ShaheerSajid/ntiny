// Branch Target Buffer — direct-mapped.
//
// Index: pc[IDX_W:1]; tag: pc[31:IDX_W+1]. Bit 1 in the index is required
// so two RVC branches in the same word don't alias.
//
// Entry: {valid, tag, target, is_uncond}.
//   is_uncond = 1 for unconditional jumps (JAL) — IF-stage predictor
//   should treat as always-taken without consulting BHT.
//   is_uncond = 0 for conditional branches.
//
// Read is combinational; update is registered.
module btb #(
    parameter int unsigned ENTRIES = 128
) (
    input  logic        clk_i,
    input  logic        reset_i,

    // Read port A — ID-stage lookup
    input  logic [31:0] pc_i,
    output logic        hit_o,
    output logic [31:0] target_o,
    output logic        is_uncond_o,
    output logic        is_compressed_o,

    // Read port B — IF-stage lower half (vaddr+0)
    input  logic [31:0] if_lo_pc_i,
    output logic        if_lo_hit_o,
    output logic [31:0] if_lo_target_o,
    output logic        if_lo_is_uncond_o,
    output logic        if_lo_is_compressed_o,

    // Read port C — IF-stage upper half (vaddr+2)
    input  logic [31:0] if_hi_pc_i,
    output logic        if_hi_hit_o,
    output logic [31:0] if_hi_target_o,
    output logic        if_hi_is_uncond_o,
    output logic        if_hi_is_compressed_o,

    // Update / allocate (IE stage)
    input  logic        update_en_i,
    input  logic [31:0] update_pc_i,
    input  logic [31:0] update_target_i,
    input  logic        update_is_uncond_i,
    input  logic        update_is_compressed_i
);

    localparam int unsigned IDX_W = $clog2(ENTRIES);
    localparam int unsigned TAG_LO = IDX_W + 1;
    localparam int unsigned TAG_W  = 32 - TAG_LO;

    typedef struct packed {
        logic               valid;
        logic               is_uncond;
        logic               is_compressed;
        logic [TAG_W-1:0]   tag;
        logic [31:0]        target;
    } btb_entry_t;

    btb_entry_t entries [0:ENTRIES-1];

    wire [IDX_W-1:0] rd_idx       = pc_i       [TAG_LO-1:1];
    wire [TAG_W-1:0] rd_tag       = pc_i       [31:TAG_LO];
    wire [IDX_W-1:0] rd_idx_if_lo = if_lo_pc_i [TAG_LO-1:1];
    wire [TAG_W-1:0] rd_tag_if_lo = if_lo_pc_i [31:TAG_LO];
    wire [IDX_W-1:0] rd_idx_if_hi = if_hi_pc_i [TAG_LO-1:1];
    wire [TAG_W-1:0] rd_tag_if_hi = if_hi_pc_i [31:TAG_LO];
    wire [IDX_W-1:0] wr_idx       = update_pc_i[TAG_LO-1:1];
    wire [TAG_W-1:0] wr_tag       = update_pc_i[31:TAG_LO];

    assign hit_o           = entries[rd_idx].valid && (entries[rd_idx].tag == rd_tag);
    assign target_o        = entries[rd_idx].target;
    assign is_uncond_o     = entries[rd_idx].is_uncond;
    assign is_compressed_o = entries[rd_idx].is_compressed;

    assign if_lo_hit_o           = entries[rd_idx_if_lo].valid
                                && (entries[rd_idx_if_lo].tag == rd_tag_if_lo);
    assign if_lo_target_o        = entries[rd_idx_if_lo].target;
    assign if_lo_is_uncond_o     = entries[rd_idx_if_lo].is_uncond;
    assign if_lo_is_compressed_o = entries[rd_idx_if_lo].is_compressed;

    assign if_hi_hit_o           = entries[rd_idx_if_hi].valid
                                && (entries[rd_idx_if_hi].tag == rd_tag_if_hi);
    assign if_hi_target_o        = entries[rd_idx_if_hi].target;
    assign if_hi_is_uncond_o     = entries[rd_idx_if_hi].is_uncond;
    assign if_hi_is_compressed_o = entries[rd_idx_if_hi].is_compressed;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < ENTRIES; i++)
                entries[i].valid <= 1'b0;
        end else if (update_en_i) begin
            entries[wr_idx].valid         <= 1'b1;
            entries[wr_idx].tag           <= wr_tag;
            entries[wr_idx].target        <= update_target_i;
            entries[wr_idx].is_uncond     <= update_is_uncond_i;
            entries[wr_idx].is_compressed <= update_is_compressed_i;
        end
    end

endmodule
