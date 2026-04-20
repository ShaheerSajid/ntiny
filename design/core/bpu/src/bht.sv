// Branch History Table — gshare bimodal (2-bit saturating counter table
// indexed by PC XOR Global History Register).
//
// Index: (pc[GHR_W+1:2]) ^ GHR  (PC-derived bits XORed with last GHR_W
//        outcomes of branches). Captures correlation between nearby
//        conditional branches.
// GHR  : right-shift register, MSB = newest taken/not-taken outcome.
// Encoding: 2'b00 strong NT, 2'b01 weak NT, 2'b10 weak T, 2'b11 strong T.
// Reset: counters init to 2'b01 (weak NT), GHR to 0.
//
// The GHR is updated at IE on every conditional-branch resolve. On
// mispredict the GHR is left as-is — the polluted bit is overwritten by
// the next correctly-resolved branch and the BHT counters self-correct.
module bht #(
    parameter int unsigned ENTRIES = 1024,
    parameter int unsigned GHR_W   = 8
) (
    input  logic        clk_i,
    input  logic        reset_i,

    // Read port A — ID-stage lookup
    input  logic [31:0] pc_if_i,
    output logic        pred_taken_o,

    // Read port B — IF-stage lower half (vaddr+0)
    input  logic [31:0] if_lo_pc_i,
    output logic        if_lo_pred_taken_o,

    // Read port C — IF-stage upper half (vaddr+2)
    input  logic [31:0] if_hi_pc_i,
    output logic        if_hi_pred_taken_o,

    // Update port (IE stage)
    input  logic        update_en_i,
    input  logic [31:0] update_pc_i,
    input  logic        update_taken_i
);

    localparam int unsigned IDX_W = $clog2(ENTRIES);

    logic [1:0]       counters [0:ENTRIES-1];
    logic [GHR_W-1:0] ghr_q;

    // PC-derived bits (skip [1:0] alignment): take low IDX_W bits starting
    // at bit 2. XOR the bottom GHR_W of those with the GHR.
    wire [IDX_W-1:0] pc_idx_rd     = pc_if_i    [IDX_W+1:2];
    wire [IDX_W-1:0] pc_idx_rd_lo  = if_lo_pc_i [IDX_W+1:2];
    wire [IDX_W-1:0] pc_idx_rd_hi  = if_hi_pc_i [IDX_W+1:2];
    wire [IDX_W-1:0] pc_idx_wr     = update_pc_i[IDX_W+1:2];
    wire [IDX_W-1:0] ghr_ext       = {{(IDX_W-GHR_W){1'b0}}, ghr_q};
    wire [IDX_W-1:0] rd_idx        = pc_idx_rd    ^ ghr_ext;
    wire [IDX_W-1:0] rd_idx_if_lo  = pc_idx_rd_lo ^ ghr_ext;
    wire [IDX_W-1:0] rd_idx_if_hi  = pc_idx_rd_hi ^ ghr_ext;
    wire [IDX_W-1:0] wr_idx        = pc_idx_wr    ^ ghr_ext;

    assign pred_taken_o       = counters[rd_idx][1];
    assign if_lo_pred_taken_o = counters[rd_idx_if_lo][1];
    assign if_hi_pred_taken_o = counters[rd_idx_if_hi][1];

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < ENTRIES; i++)
                counters[i] <= 2'b01;
            ghr_q <= '0;
        end else if (update_en_i) begin
            // Update saturating counter
            if (update_taken_i) begin
                if (counters[wr_idx] != 2'b11)
                    counters[wr_idx] <= counters[wr_idx] + 2'b01;
            end else begin
                if (counters[wr_idx] != 2'b00)
                    counters[wr_idx] <= counters[wr_idx] - 2'b01;
            end
            // Shift outcome into GHR (newest at LSB, oldest drops off MSB).
            ghr_q <= {ghr_q[GHR_W-2:0], update_taken_i};
        end
    end

endmodule
