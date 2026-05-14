// Reservation Station — parameterized, per-FU.
//
// At M2 the operand state moves out of the ROB into per-FU RS banks.
// Each bank:
//   - Accepts one dispatch per cycle (alloc to first free slot).
//   - Wakes up on the CDB (2 wb ports broadcast across all banks).
//   - Picks the lowest-index ready slot for issue each cycle.
//   - Frees the slot on issue_consume.
//   - Flushes slots whose ROB tag is strictly younger than a
//     mispredicted branch (top computes the predicate; we just clear
//     a per-slot mask).
//
// Scheduling at M2 step A: lowest-index-ready. A real age-ordered
// scheduler is straightforward to add later by stamping an alloc
// timestamp; not needed for the M0/M1 sanity battery to stay green.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module rs
#(
    parameter int DEPTH    = 4,
    parameter int IDX_W    = $clog2(DEPTH)
)
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    input  logic                        flush_all_i,             // full reset on traps (M7)

    // Per-slot squash. Top computes which slots are younger than a
    // mispredicted branch and asserts the corresponding mask bits.
    input  logic [DEPTH-1:0]            squash_mask_i,

    // Per-slot issue gate. When bit i is set, slot i is excluded
    // from the issue-ready set even if all operands are present.
    // Used to hold stores in the LSU RS until they reach the ROB
    // head (commit-time store discipline). ALU RS ties this to 0.
    input  logic [DEPTH-1:0]            block_issue_mask_i,

    // ── alloc ────────────────────────────────────────────────
    input  logic                        alloc_en_i,
    output logic                        full_o,
    input  uop_t                        alloc_uop_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rob_idx_i,
    input  logic [31:0]                 alloc_rs1_value_i,
    input  logic                        alloc_rs1_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs1_tag_i,
    input  logic [31:0]                 alloc_rs2_value_i,
    input  logic                        alloc_rs2_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs2_tag_i,

    // ── CDB wakeup (3 broadcast ports) ───────────────────────
    // wb1=ALU FU, wb2=LSU FU, wb3=MULDIV FU. All three banks see
    // every port; a slot's tag matches at most one in any cycle.
    input  logic                        wb1_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb1_idx_i,
    input  logic [31:0]                 wb1_result_i,
    input  logic                        wb2_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb2_idx_i,
    input  logic [31:0]                 wb2_result_i,
    input  logic                        wb3_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb3_idx_i,
    input  logic [31:0]                 wb3_result_i,

    // ── issue (read combinationally; consume to free) ────────
    output logic                        issue_valid_o,
    output uop_t                        issue_uop_o,
    output logic [OOO_ROB_IDX_W-1:0]    issue_rob_idx_o,
    output logic [31:0]                 issue_rs1_value_o,
    output logic [31:0]                 issue_rs2_value_o,
    input  logic                        issue_consume_i,

    // Expose busy mask so top can compute squash_mask_i based on
    // each slot's rob_idx without re-implementing storage here.
    output logic [DEPTH-1:0]            busy_mask_o,
    output logic [OOO_ROB_IDX_W-1:0]    rob_idx_of_o [0:DEPTH-1],
    // Per-slot fu type — top uses this to gate stores on
    // "at ROB head" via block_issue_mask_i.
    output fu_type_e                    fu_of_o      [0:DEPTH-1]
);

    typedef struct packed {
        logic                        busy;
        uop_t                        uop;
        logic [OOO_ROB_IDX_W-1:0]    rob_idx;
        logic [31:0]                 rs1_value;
        logic                        rs1_ready;
        logic [OOO_ROB_IDX_W-1:0]    rs1_tag;
        logic [31:0]                 rs2_value;
        logic                        rs2_ready;
        logic [OOO_ROB_IDX_W-1:0]    rs2_tag;
    } slot_t;

    slot_t entry_q [0:DEPTH-1];

    // ── busy / ready vectors + expose busy & rob_idx ─────────
    logic [DEPTH-1:0] busy_vec;
    logic [DEPTH-1:0] ready_vec;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            busy_vec[i]  = entry_q[i].busy;
            ready_vec[i] = entry_q[i].busy
                          & entry_q[i].rs1_ready
                          & entry_q[i].rs2_ready
                          & ~block_issue_mask_i[i];
        end
    end
    assign busy_mask_o = busy_vec;
    generate
        for (genvar gi = 0; gi < DEPTH; gi++) begin : g_idx_expose
            assign rob_idx_of_o[gi] = entry_q[gi].rob_idx;
            assign fu_of_o[gi]      = entry_q[gi].uop.fu;
        end
    endgenerate

    assign full_o = &busy_vec;

    // ── alloc pointer = lowest-index free slot ───────────────
    logic [IDX_W-1:0] alloc_idx;
    logic             alloc_idx_valid;
    always_comb begin
        alloc_idx       = '0;
        alloc_idx_valid = 1'b0;
        for (int i = 0; i < DEPTH; i++) begin
            if (!busy_vec[i] && !alloc_idx_valid) begin
                alloc_idx       = i[IDX_W-1:0];
                alloc_idx_valid = 1'b1;
            end
        end
    end

    // ── issue selection = lowest-index ready slot ────────────
    logic [IDX_W-1:0] issue_idx;
    logic             issue_idx_valid;
    always_comb begin
        issue_idx       = '0;
        issue_idx_valid = 1'b0;
        for (int i = 0; i < DEPTH; i++) begin
            if (ready_vec[i] && !issue_idx_valid) begin
                issue_idx       = i[IDX_W-1:0];
                issue_idx_valid = 1'b1;
            end
        end
    end

    assign issue_valid_o     = issue_idx_valid;
    assign issue_uop_o       = entry_q[issue_idx].uop;
    assign issue_rob_idx_o   = entry_q[issue_idx].rob_idx;
    assign issue_rs1_value_o = entry_q[issue_idx].rs1_value;
    assign issue_rs2_value_o = entry_q[issue_idx].rs2_value;

    // ── sequential update ────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < DEPTH; i++) entry_q[i] <= '0;
        end else if (flush_all_i) begin
            for (int i = 0; i < DEPTH; i++) entry_q[i].busy <= 1'b0;
        end else begin
            // Per-slot squash from younger-than-branch mask
            for (int i = 0; i < DEPTH; i++) begin
                if (squash_mask_i[i]) entry_q[i].busy <= 1'b0;
            end

            // CDB wakeup — both ports
            if (wb1_en_i) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_q[i].busy) begin
                        if (~entry_q[i].rs1_ready
                            && entry_q[i].rs1_tag == wb1_idx_i) begin
                            entry_q[i].rs1_value <= wb1_result_i;
                            entry_q[i].rs1_ready <= 1'b1;
                        end
                        if (~entry_q[i].rs2_ready
                            && entry_q[i].rs2_tag == wb1_idx_i) begin
                            entry_q[i].rs2_value <= wb1_result_i;
                            entry_q[i].rs2_ready <= 1'b1;
                        end
                    end
                end
            end
            if (wb2_en_i) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_q[i].busy) begin
                        if (~entry_q[i].rs1_ready
                            && entry_q[i].rs1_tag == wb2_idx_i) begin
                            entry_q[i].rs1_value <= wb2_result_i;
                            entry_q[i].rs1_ready <= 1'b1;
                        end
                        if (~entry_q[i].rs2_ready
                            && entry_q[i].rs2_tag == wb2_idx_i) begin
                            entry_q[i].rs2_value <= wb2_result_i;
                            entry_q[i].rs2_ready <= 1'b1;
                        end
                    end
                end
            end
            if (wb3_en_i) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_q[i].busy) begin
                        if (~entry_q[i].rs1_ready
                            && entry_q[i].rs1_tag == wb3_idx_i) begin
                            entry_q[i].rs1_value <= wb3_result_i;
                            entry_q[i].rs1_ready <= 1'b1;
                        end
                        if (~entry_q[i].rs2_ready
                            && entry_q[i].rs2_tag == wb3_idx_i) begin
                            entry_q[i].rs2_value <= wb3_result_i;
                            entry_q[i].rs2_ready <= 1'b1;
                        end
                    end
                end
            end

            // Issue consume — free the selected slot
            if (issue_consume_i && issue_idx_valid) begin
                entry_q[issue_idx].busy <= 1'b0;
            end

            // Alloc — caller gates on full / squash
            if (alloc_en_i && alloc_idx_valid) begin
                entry_q[alloc_idx].busy    <= 1'b1;
                entry_q[alloc_idx].uop     <= alloc_uop_i;
                entry_q[alloc_idx].rob_idx <= alloc_rob_idx_i;
                if (alloc_rs1_busy_i) begin
                    entry_q[alloc_idx].rs1_value <= '0;
                    entry_q[alloc_idx].rs1_tag   <= alloc_rs1_tag_i;
                    entry_q[alloc_idx].rs1_ready <= 1'b0;
                end else begin
                    entry_q[alloc_idx].rs1_value <= alloc_rs1_value_i;
                    entry_q[alloc_idx].rs1_tag   <= '0;
                    entry_q[alloc_idx].rs1_ready <= 1'b1;
                end
                if (alloc_rs2_busy_i) begin
                    entry_q[alloc_idx].rs2_value <= '0;
                    entry_q[alloc_idx].rs2_tag   <= alloc_rs2_tag_i;
                    entry_q[alloc_idx].rs2_ready <= 1'b0;
                end else begin
                    entry_q[alloc_idx].rs2_value <= alloc_rs2_value_i;
                    entry_q[alloc_idx].rs2_tag   <= '0;
                    entry_q[alloc_idx].rs2_ready <= 1'b1;
                end
            end
        end
    end

endmodule
