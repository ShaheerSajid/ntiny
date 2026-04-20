// Branch Prediction Unit — BHT (gshare) + BTB (with is_compressed marker
// for IF-stage straddle handling).
//
// Three read ports:
//   - Port A (pc_id_i)      : ID-stage lookup — current fallback path.
//   - Port B (if_lo_pc_i)   : IF-stage lower-half (vaddr+0).
//   - Port C (if_hi_pc_i)   : IF-stage upper-half (vaddr+2).
// All reads are combinational; BHT counters / BTB entries are shared state
// (single FF array, multi-read). Update port remains single-ported (IE).
//
// RAS lives in core_top because it needs decoded inst_type at ID.
module bpu (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── Read port A — ID-stage ──────────────────────────────────────
    input  logic [31:0] pc_id_i,
    output logic        pred_taken_o,
    output logic        pred_valid_o,
    output logic [31:0] pred_target_o,
    output logic        pred_is_compressed_o,

    // ── Read port B — IF-stage lower half (vaddr+0) ─────────────────
    input  logic [31:0] if_lo_pc_i,
    output logic        if_lo_pred_taken_o,
    output logic        if_lo_pred_valid_o,
    output logic [31:0] if_lo_pred_target_o,
    output logic        if_lo_pred_is_compressed_o,

    // ── Read port C — IF-stage upper half (vaddr+2) ─────────────────
    input  logic [31:0] if_hi_pc_i,
    output logic        if_hi_pred_taken_o,
    output logic        if_hi_pred_valid_o,
    output logic [31:0] if_hi_pred_target_o,
    output logic        if_hi_pred_is_compressed_o,

    // Update — IE stage
    input  logic        update_en_i,
    input  logic [31:0] update_pc_i,
    input  logic        update_taken_i,
    input  logic [31:0] update_target_i,
    input  logic        update_btb_alloc_i,
    input  logic        update_is_uncond_i,
    input  logic        update_is_compressed_i
);

    wire        bht_pred;
    wire        bht_pred_if_lo;
    wire        bht_pred_if_hi;

    wire        btb_hit;
    wire [31:0] btb_target;
    wire        btb_is_uncond;
    wire        btb_is_compressed;

    wire        btb_if_lo_hit;
    wire [31:0] btb_if_lo_target;
    wire        btb_if_lo_is_uncond;
    wire        btb_if_lo_is_compressed;

    wire        btb_if_hi_hit;
    wire [31:0] btb_if_hi_target;
    wire        btb_if_hi_is_uncond;
    wire        btb_if_hi_is_compressed;

    bht #(.ENTRIES(1024)) bht_inst (
        .clk_i              (clk_i),
        .reset_i            (reset_i),
        .pc_if_i            (pc_id_i),
        .pred_taken_o       (bht_pred),
        .if_lo_pc_i         (if_lo_pc_i),
        .if_lo_pred_taken_o (bht_pred_if_lo),
        .if_hi_pc_i         (if_hi_pc_i),
        .if_hi_pred_taken_o (bht_pred_if_hi),
        .update_en_i        (update_en_i),
        .update_pc_i        (update_pc_i),
        .update_taken_i     (update_taken_i)
    );

    btb #(.ENTRIES(128)) btb_inst (
        .clk_i                  (clk_i),
        .reset_i                (reset_i),

        .pc_i                   (pc_id_i),
        .hit_o                  (btb_hit),
        .target_o               (btb_target),
        .is_uncond_o            (btb_is_uncond),
        .is_compressed_o        (btb_is_compressed),

        .if_lo_pc_i             (if_lo_pc_i),
        .if_lo_hit_o            (btb_if_lo_hit),
        .if_lo_target_o         (btb_if_lo_target),
        .if_lo_is_uncond_o      (btb_if_lo_is_uncond),
        .if_lo_is_compressed_o  (btb_if_lo_is_compressed),

        .if_hi_pc_i             (if_hi_pc_i),
        .if_hi_hit_o            (btb_if_hi_hit),
        .if_hi_target_o         (btb_if_hi_target),
        .if_hi_is_uncond_o      (btb_if_hi_is_uncond),
        .if_hi_is_compressed_o  (btb_if_hi_is_compressed),

        .update_en_i            (update_btb_alloc_i),
        .update_pc_i            (update_pc_i),
        .update_target_i        (update_target_i),
        .update_is_uncond_i     (update_is_uncond_i),
        .update_is_compressed_i (update_is_compressed_i)
    );

    assign pred_valid_o         = btb_hit;
    assign pred_taken_o         = btb_hit && (btb_is_uncond || bht_pred);
    assign pred_target_o        = btb_target;
    assign pred_is_compressed_o = btb_is_compressed;

    assign if_lo_pred_valid_o         = btb_if_lo_hit;
    assign if_lo_pred_taken_o         = btb_if_lo_hit
                                     && (btb_if_lo_is_uncond || bht_pred_if_lo);
    assign if_lo_pred_target_o        = btb_if_lo_target;
    assign if_lo_pred_is_compressed_o = btb_if_lo_is_compressed;

    assign if_hi_pred_valid_o         = btb_if_hi_hit;
    assign if_hi_pred_taken_o         = btb_if_hi_hit
                                     && (btb_if_hi_is_uncond || bht_pred_if_hi);
    assign if_hi_pred_target_o        = btb_if_hi_target;
    assign if_hi_pred_is_compressed_o = btb_if_hi_is_compressed;

endmodule
