// Reorder Buffer (ROB) — 16 entries, in-order alloc + retire.
//
// At M2 the ROB is *control-only* — operand state moved out to
// per-FU RS banks ([rs.sv](rs.sv)). The ROB tracks:
//   busy / ready / illegal flags
//   the uop's metadata (has_rd, rd, pc, fu, ...) for commit
//   the result value (filled by CDB writeback)
//
// Pointers (modulo OOO_ROB_DEPTH):
//   head — oldest in-flight; commit drains here
//   tail — next free slot; dispatch allocates here
//
// (issue_ptr from M1 is gone — issue scheduling is the RS's job now.)
//
// Branch flush squashes entries strictly between flush_after_idx_i
// and tail. The branch itself keeps its slot and commits normally.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module rob
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    // Taken-branch squash. Strictly-younger entries (excl. branch
    // slot at flush_after_idx_i, excl. tail) get busy <= 0.
    input  logic                        flush_younger_i,
    input  logic [OOO_ROB_IDX_W-1:0]    flush_after_idx_i,

    // ── allocate (dispatch) ──────────────────────────────────
    input  logic                        alloc_en_i,
    output logic [OOO_ROB_IDX_W-1:0]    alloc_idx_o,
    output logic                        full_o,
    input  uop_t                        alloc_uop_i,

    // ── peek (combinational read of any entry, for dispatch wakeup) ──
    input  logic [OOO_ROB_IDX_W-1:0]    peek1_idx_i,
    output logic                        peek1_ready_o,
    output logic [31:0]                 peek1_result_o,
    input  logic [OOO_ROB_IDX_W-1:0]    peek2_idx_i,
    output logic                        peek2_ready_o,
    output logic [31:0]                 peek2_result_o,

    // ── writeback (2-wide CDB) ───────────────────────────────
    input  logic                        wb1_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb1_idx_i,
    input  logic [31:0]                 wb1_result_i,
    input  logic                        wb2_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb2_idx_i,
    input  logic [31:0]                 wb2_result_i,

    // ── commit (head, drain when ready) ──────────────────────
    output logic                        commit_valid_o,
    output logic [OOO_ROB_IDX_W-1:0]    commit_idx_o,
    output uop_t                        commit_uop_o,
    output logic [31:0]                 commit_result_o,
    input  logic                        commit_consume_i,

    // Expose tail for the RS squash range computation in top.
    output logic [OOO_ROB_IDX_W-1:0]    tail_o,
    // Expose head so the top can gate STORE execution on
    // "at ROB head" — stores must not fire speculatively.
    output logic [OOO_ROB_IDX_W-1:0]    head_o
);

    typedef struct packed {
        logic                        busy;
        logic                        ready;
        uop_t                        uop;
        logic [31:0]                 result;
    } slot_t;

    slot_t                       entry_q [0:OOO_ROB_DEPTH-1];
    logic [OOO_ROB_IDX_W-1:0]    head_q;
    logic [OOO_ROB_IDX_W-1:0]    tail_q;
    logic [OOO_ROB_IDX_W:0]      count_q;

    assign full_o      = (count_q == OOO_ROB_DEPTH[OOO_ROB_IDX_W:0]);
    assign alloc_idx_o = tail_q;
    assign tail_o      = tail_q;
    assign head_o      = head_q;

    // ── peek (combinational) ─────────────────────────────────
    assign peek1_ready_o  = entry_q[peek1_idx_i].ready & entry_q[peek1_idx_i].busy;
    assign peek1_result_o = entry_q[peek1_idx_i].result;
    assign peek2_ready_o  = entry_q[peek2_idx_i].ready & entry_q[peek2_idx_i].busy;
    assign peek2_result_o = entry_q[peek2_idx_i].result;

    // ── commit view (from head) ──────────────────────────────
    wire slot_t hslot = entry_q[head_q];
    assign commit_valid_o  = hslot.busy & hslot.ready;
    assign commit_idx_o    = head_q;
    assign commit_uop_o    = hslot.uop;
    assign commit_result_o = hslot.result;

    // ── sequential update ────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < OOO_ROB_DEPTH; i++) entry_q[i] <= '0;
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end else begin
            // CDB writeback — record result + mark ready.
            if (wb1_en_i) begin
                entry_q[wb1_idx_i].result <= wb1_result_i;
                entry_q[wb1_idx_i].ready  <= 1'b1;
            end
            if (wb2_en_i) begin
                entry_q[wb2_idx_i].result <= wb2_result_i;
                entry_q[wb2_idx_i].ready  <= 1'b1;
            end

            // Alloc — caller gates on flush.
            if (alloc_en_i) begin
                entry_q[tail_q].busy   <= 1'b1;
                entry_q[tail_q].ready  <= 1'b0;
                entry_q[tail_q].uop    <= alloc_uop_i;
                entry_q[tail_q].result <= '0;
                tail_q <= tail_q + 1'b1;
            end

            // Commit — drain head when ready.
            if (commit_consume_i) begin
                entry_q[head_q].busy <= 1'b0;
                head_q <= head_q + 1'b1;
            end

            // Flush younger — keep [head..flush_after_idx], squash
            // strictly younger entries.
            if (flush_younger_i) begin
                for (int k = 0; k < OOO_ROB_DEPTH; k++) begin
                    if (k < ((tail_q - flush_after_idx_i - 1'b1)
                              & {OOO_ROB_IDX_W{1'b1}})) begin
                        entry_q[(flush_after_idx_i + 1'b1
                                  + k[OOO_ROB_IDX_W-1:0])].busy <= 1'b0;
                    end
                end
                tail_q <= flush_after_idx_i + 1'b1;
                count_q <= (({1'b0, flush_after_idx_i} - {1'b0, head_q})
                            & {1'b0, {OOO_ROB_IDX_W{1'b1}}}) + 1'b1
                            - (commit_consume_i ? 1'b1 : 1'b0);
            end else begin
                unique case ({alloc_en_i, commit_consume_i})
                    2'b10: count_q <= count_q + 1'b1;
                    2'b01: count_q <= count_q - 1'b1;
                    default: count_q <= count_q;
                endcase
            end
        end
    end

endmodule
