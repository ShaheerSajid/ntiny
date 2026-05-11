// Reorder Buffer (ROB) — 16 entries, in-order alloc + retire.
//
// At M1 the ROB also stores the operand state (value + tag + ready
// per source) — i.e. it doubles as the reservation-station bank
// while there is only a single FU and in-order issue. M2 splits the
// operand state out into per-FU RS modules and the ROB shrinks back
// to control-only fields.
//
// FIFO discipline:
//   head — oldest in-flight; commit drains from here
//   tail — next free slot; dispatch allocates here
//   count — entries currently in use
//
// Ports (all bound to the same clock domain):
//   alloc       — dispatch writes a new entry at tail
//   issue       — read combinational view of head for the FU; a
//                 separate consume signal marks it as issued so
//                 the same entry isn't dispatched twice while it's
//                 still in EX (multi-cycle ops)
//   writeback   — EX/memunit drops {idx, result}; the indexed entry
//                 becomes ready, and any other entries waiting on
//                 that idx capture the value (polled CDB at M1)
//   commit      — head drains when ready; caller writes arch state
//   flush_younger — squash all non-head entries (taken-branch path)
//
// Notes:
// - Issue/commit can't fire same-cycle on the same entry: ready is
//   set at posedge after writeback, so commit_valid lags issue by
//   one cycle minimum. Caller doesn't need to interlock.
// - flush_younger keeps the head entry intact so a taken branch can
//   still retire after squashing what came behind it.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module rob
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    input  logic                        flush_younger_i,    // taken-branch squash

    // ── allocate (dispatch) ──────────────────────────────────
    input  logic                        alloc_en_i,
    output logic [OOO_ROB_IDX_W-1:0]    alloc_idx_o,
    output logic                        full_o,
    input  uop_t                        alloc_uop_i,
    input  logic [31:0]                 alloc_rs1_value_i,
    input  logic                        alloc_rs1_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs1_tag_i,
    input  logic [31:0]                 alloc_rs2_value_i,
    input  logic                        alloc_rs2_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs2_tag_i,

    // ── issue (read head combinationally) ────────────────────
    output logic                        issue_valid_o,
    output logic [OOO_ROB_IDX_W-1:0]    issue_idx_o,
    output uop_t                        issue_uop_o,
    output logic [31:0]                 issue_rs1_value_o,
    output logic [31:0]                 issue_rs2_value_o,
    input  logic                        issue_consume_i,    // mark head as issued

    // ── writeback (single producer at M1) ────────────────────
    input  logic                        wb_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb_idx_i,
    input  logic [31:0]                 wb_result_i,

    // ── commit (head, drain when ready) ──────────────────────
    output logic                        commit_valid_o,
    output logic [OOO_ROB_IDX_W-1:0]    commit_idx_o,
    output uop_t                        commit_uop_o,
    output logic [31:0]                 commit_result_o,
    input  logic                        commit_consume_i
);

    typedef struct packed {
        logic                        busy;
        logic                        issued;
        logic                        ready;
        uop_t                        uop;
        logic [31:0]                 rs1_value;
        logic                        rs1_ready;
        logic [OOO_ROB_IDX_W-1:0]    rs1_tag;
        logic [31:0]                 rs2_value;
        logic                        rs2_ready;
        logic [OOO_ROB_IDX_W-1:0]    rs2_tag;
        logic [31:0]                 result;
    } slot_t;

    slot_t                       entry_q [0:OOO_ROB_DEPTH-1];
    logic [OOO_ROB_IDX_W-1:0]    head_q;
    logic [OOO_ROB_IDX_W-1:0]    tail_q;
    logic [OOO_ROB_IDX_W:0]      count_q;

    assign full_o      = (count_q == OOO_ROB_DEPTH[OOO_ROB_IDX_W:0]);
    assign alloc_idx_o = tail_q;

    // ── issue view of head ──────────────────────────────────
    wire slot_t hslot = entry_q[head_q];
    assign issue_valid_o     = hslot.busy & ~hslot.issued
                              & hslot.rs1_ready & hslot.rs2_ready;
    assign issue_idx_o       = head_q;
    assign issue_uop_o       = hslot.uop;
    assign issue_rs1_value_o = hslot.rs1_value;
    assign issue_rs2_value_o = hslot.rs2_value;

    // ── commit view of head ─────────────────────────────────
    assign commit_valid_o  = hslot.busy & hslot.ready;
    assign commit_idx_o    = head_q;
    assign commit_uop_o    = hslot.uop;
    assign commit_result_o = hslot.result;

    // ── update sequential ───────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < OOO_ROB_DEPTH; i++) entry_q[i] <= '0;
            head_q  <= '0;
            tail_q  <= '0;
            count_q <= '0;
        end else if (flush_younger_i) begin
            // Keep head intact (it's the taken-branch entry, about
            // to commit). Squash everything else; reset tail to
            // head+1 and count to (head still busy ? 1 : 0).
            for (int i = 0; i < OOO_ROB_DEPTH; i++) begin
                if (i[OOO_ROB_IDX_W-1:0] != head_q) entry_q[i].busy <= 1'b0;
            end
            tail_q  <= head_q + 1'b1;
            count_q <= entry_q[head_q].busy ? {{(OOO_ROB_IDX_W){1'b0}}, 1'b1}
                                            : '0;
        end else begin
            // CDB-style wakeup: every busy entry whose pending tag
            // matches wb_idx captures the value this cycle. The
            // writeback target itself becomes ready.
            if (wb_en_i) begin
                for (int i = 0; i < OOO_ROB_DEPTH; i++) begin
                    if (entry_q[i].busy) begin
                        if (~entry_q[i].rs1_ready
                            && entry_q[i].rs1_tag == wb_idx_i) begin
                            entry_q[i].rs1_value <= wb_result_i;
                            entry_q[i].rs1_ready <= 1'b1;
                        end
                        if (~entry_q[i].rs2_ready
                            && entry_q[i].rs2_tag == wb_idx_i) begin
                            entry_q[i].rs2_value <= wb_result_i;
                            entry_q[i].rs2_ready <= 1'b1;
                        end
                    end
                end
                entry_q[wb_idx_i].result <= wb_result_i;
                entry_q[wb_idx_i].ready  <= 1'b1;
            end

            // Mark head as issued so multi-cycle ops aren't re-issued
            if (issue_consume_i) entry_q[head_q].issued <= 1'b1;

            // Alloc — write tail slot
            if (alloc_en_i) begin
                entry_q[tail_q].busy   <= 1'b1;
                entry_q[tail_q].issued <= 1'b0;
                entry_q[tail_q].ready  <= 1'b0;
                entry_q[tail_q].uop    <= alloc_uop_i;
                entry_q[tail_q].result <= '0;
                if (alloc_rs1_busy_i) begin
                    entry_q[tail_q].rs1_value <= '0;
                    entry_q[tail_q].rs1_tag   <= alloc_rs1_tag_i;
                    entry_q[tail_q].rs1_ready <= 1'b0;
                end else begin
                    entry_q[tail_q].rs1_value <= alloc_rs1_value_i;
                    entry_q[tail_q].rs1_tag   <= '0;
                    entry_q[tail_q].rs1_ready <= 1'b1;
                end
                if (alloc_rs2_busy_i) begin
                    entry_q[tail_q].rs2_value <= '0;
                    entry_q[tail_q].rs2_tag   <= alloc_rs2_tag_i;
                    entry_q[tail_q].rs2_ready <= 1'b0;
                end else begin
                    entry_q[tail_q].rs2_value <= alloc_rs2_value_i;
                    entry_q[tail_q].rs2_tag   <= '0;
                    entry_q[tail_q].rs2_ready <= 1'b1;
                end
                tail_q <= tail_q + 1'b1;
            end

            // Commit — dealloc head
            if (commit_consume_i) begin
                entry_q[head_q].busy <= 1'b0;
                head_q <= head_q + 1'b1;
            end

            // Count update — alloc/commit can happen same cycle
            unique case ({alloc_en_i, commit_consume_i})
                2'b10:   count_q <= count_q + 1'b1;
                2'b01:   count_q <= count_q - 1'b1;
                default: count_q <= count_q;
            endcase
        end
    end

endmodule
