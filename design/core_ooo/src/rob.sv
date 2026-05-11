// Reorder Buffer (ROB) — 16 entries, in-order alloc + retire.
//
// At M1 the ROB also stores the operand state (value + tag + ready
// per source) — i.e. it doubles as the reservation-station bank
// while there is only a single FU and in-order issue. M2 splits the
// operand state into per-FU RS modules.
//
// Three pointers (all modulo OOO_ROB_DEPTH):
//   head       — oldest in-flight; commit drains from here
//   issue_ptr  — oldest *non-issued* entry; issue fires from here
//   tail       — next free slot; dispatch allocates here
//
// head ≤ issue_ptr ≤ tail at all times. Separating issue_ptr from
// head is what makes IPC≥1 with in-order commit: one cycle can
// issue entry I while committing entry I-1.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module rob
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    // Squash entries strictly younger than flush_after_idx_i (the
    // branch's ROB slot). The branch itself survives and commits.
    input  logic                        flush_younger_i,
    input  logic [OOO_ROB_IDX_W-1:0]    flush_after_idx_i,

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

    // ── peek (combinational read of any entry, for dispatch wakeup) ──
    input  logic [OOO_ROB_IDX_W-1:0]    peek1_idx_i,
    output logic                        peek1_ready_o,
    output logic [31:0]                 peek1_result_o,
    input  logic [OOO_ROB_IDX_W-1:0]    peek2_idx_i,
    output logic                        peek2_ready_o,
    output logic [31:0]                 peek2_result_o,

    // ── issue (read combinationally from issue_ptr) ──────────
    output logic                        issue_valid_o,
    output logic [OOO_ROB_IDX_W-1:0]    issue_idx_o,
    output uop_t                        issue_uop_o,
    output logic [31:0]                 issue_rs1_value_o,
    output logic [31:0]                 issue_rs2_value_o,
    input  logic                        issue_consume_i,

    // ── writeback — 2 ports at M1 (ALU + LSU). A single-cycle
    //    ALU op can complete the same cycle a multi-cycle memory
    //    op finishes; both have to land in the ROB without dropping
    //    one. M2's CDB will subsume this with proper arbitration.
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
    logic [OOO_ROB_IDX_W-1:0]    issue_ptr_q;
    logic [OOO_ROB_IDX_W-1:0]    tail_q;
    logic [OOO_ROB_IDX_W:0]      count_q;

    assign full_o      = (count_q == OOO_ROB_DEPTH[OOO_ROB_IDX_W:0]);
    assign alloc_idx_o = tail_q;

    // ── peek (combinational) ─────────────────────────────────
    assign peek1_ready_o  = entry_q[peek1_idx_i].ready & entry_q[peek1_idx_i].busy;
    assign peek1_result_o = entry_q[peek1_idx_i].result;
    assign peek2_ready_o  = entry_q[peek2_idx_i].ready & entry_q[peek2_idx_i].busy;
    assign peek2_result_o = entry_q[peek2_idx_i].result;

    // ── issue view (from issue_ptr) ──────────────────────────
    wire slot_t islot = entry_q[issue_ptr_q];
    assign issue_valid_o     = islot.busy & ~islot.issued
                              & islot.rs1_ready & islot.rs2_ready;
    assign issue_idx_o       = issue_ptr_q;
    assign issue_uop_o       = islot.uop;
    assign issue_rs1_value_o = islot.rs1_value;
    assign issue_rs2_value_o = islot.rs2_value;

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
            head_q      <= '0;
            issue_ptr_q <= '0;
            tail_q      <= '0;
            count_q     <= '0;
        end else begin
            // CDB-style wakeup — both wb ports broadcast. Each
            // waiting source captures from whichever port matches
            // its tag this cycle.
            if (wb1_en_i) begin
                for (int i = 0; i < OOO_ROB_DEPTH; i++) begin
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
                entry_q[wb1_idx_i].result <= wb1_result_i;
                entry_q[wb1_idx_i].ready  <= 1'b1;
            end
            if (wb2_en_i) begin
                for (int i = 0; i < OOO_ROB_DEPTH; i++) begin
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
                entry_q[wb2_idx_i].result <= wb2_result_i;
                entry_q[wb2_idx_i].ready  <= 1'b1;
            end

            // Mark issuing entry as issued (so it isn't re-fired
            // while multi-cycle ops sit in EX / memunit).
            if (issue_consume_i) begin
                entry_q[issue_ptr_q].issued <= 1'b1;
                issue_ptr_q                  <= issue_ptr_q + 1'b1;
            end

            // Alloc — caller gates this on flush via dispatch_en.
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

            // Commit — applies even on flush cycle. Caller drives
            // commit_consume_i = commit_valid_o; commit_valid_o
            // requires .ready which can't fire same cycle as flush
            // (ready becomes 1 at the posedge that latches wb).
            if (commit_consume_i) begin
                entry_q[head_q].busy <= 1'b0;
                head_q <= head_q + 1'b1;
            end

            // Flush younger: squash entries strictly between
            // flush_after_idx and tail (exclusive of branch, exclusive
            // of tail). Keeps [head..flush_after_idx] intact so the
            // branch commits normally. Caller gates alloc on flush so
            // the alloc block above didn't fire this cycle.
            if (flush_younger_i) begin
                for (int k = 0; k < OOO_ROB_DEPTH; k++) begin
                    if (k < ((tail_q - flush_after_idx_i - 1'b1)
                              & {OOO_ROB_IDX_W{1'b1}})) begin
                        entry_q[(flush_after_idx_i + 1'b1
                                  + k[OOO_ROB_IDX_W-1:0])].busy <= 1'b0;
                    end
                end
                tail_q      <= flush_after_idx_i + 1'b1;
                issue_ptr_q <= flush_after_idx_i + 1'b1;
                // Count = entries kept (head..branch inclusive), minus
                // one if commit also fires same cycle.
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
