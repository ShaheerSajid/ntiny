// OoO core v1 — Branch Prediction Unit (M3-B).
//
// M3-B scope: BTB-only, always-taken-on-hit. No history (BHT/gshare),
// no RAS. Effective for loops (the dominant branch pattern in our
// directed tests + the rv32im suite); if-then-else mispredict rate
// is whatever the BTB hit rate happens to be — we'll add a 2-bit
// BHT in M3-C if traces show the win is material.
//
// Direct-mapped BTB:
//   ENTRIES = 64
//   Index   = pc[7:2]
//   Tag     = pc[31:8]
//   Entry   = {valid, tag, target, is_uncond}
//
// One read port (consulted at fetch on each cycle's pc_q) and one
// write port (driven from EX whenever a branch resolves taken;
// allocates a fresh entry or overwrites a stale one).
//
// Update policy: write on every TAKEN resolved branch. NT outcomes
// don't allocate (no point storing "predicts NT" — fall-through is
// the default for misses). When an existing BTB entry's branch
// resolves NT, we leave the entry alone (a future taken outcome
// will refresh it). Trade-off: ping-ponging entries on alternating
// outcomes; acceptable at v1.

import common_pkg::*;
import core_ooo_pkg::*;

module bpu_ooo
#(
    parameter int ENTRIES = 64,
    parameter int IDX_W   = $clog2(ENTRIES),
    parameter int TAG_LO  = IDX_W + 2,
    parameter int TAG_W   = 32 - TAG_LO
)
(
    input  logic            clk_i,
    input  logic            reset_i,

    // Read — fetch consults this combinationally on every cycle.
    input  logic [31:0]     lookup_pc_i,
    output logic            pred_valid_o,    // BTB hit
    output logic            pred_taken_o,    // hit AND we predict taken
    output logic [31:0]     pred_target_o,

    // Update — driven from EX when a branch resolves taken.
    input  logic            update_en_i,
    input  logic [31:0]     update_pc_i,
    input  logic [31:0]     update_target_i,
    input  logic            update_is_uncond_i
);

    typedef struct packed {
        logic               valid;
        logic               is_uncond;
        logic [TAG_W-1:0]   tag;
        logic [31:0]        target;
    } btb_entry_t;

    btb_entry_t entry_q [0:ENTRIES-1];

    // ── read port ────────────────────────────────────────────
    wire [IDX_W-1:0] rd_idx = lookup_pc_i[TAG_LO-1:2];
    wire [TAG_W-1:0] rd_tag = lookup_pc_i[31:TAG_LO];

    wire hit = entry_q[rd_idx].valid && (entry_q[rd_idx].tag == rd_tag);

    assign pred_valid_o  = hit;
    assign pred_taken_o  = hit;                      // always-taken-on-hit
    assign pred_target_o = entry_q[rd_idx].target;

    // ── write port ───────────────────────────────────────────
    wire [IDX_W-1:0] wr_idx = update_pc_i[TAG_LO-1:2];
    wire [TAG_W-1:0] wr_tag = update_pc_i[31:TAG_LO];

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < ENTRIES; i++) begin
                entry_q[i].valid <= 1'b0;
            end
        end else if (update_en_i) begin
            entry_q[wr_idx].valid     <= 1'b1;
            entry_q[wr_idx].tag       <= wr_tag;
            entry_q[wr_idx].target    <= update_target_i;
            entry_q[wr_idx].is_uncond <= update_is_uncond_i;
        end
    end

endmodule
