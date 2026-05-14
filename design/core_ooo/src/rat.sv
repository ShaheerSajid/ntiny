// Register Alias Table (RAT) — int rename map.
//
// 32 entries, one per architectural integer register. Each entry is
// either:
//   {busy=0}          — the latest value lives in the arch regfile
//   {busy=1, rob_idx} — the latest producer is still in flight at
//                       ROB[rob_idx]
//
// x0 is hardwired clear — never busy, tag always 0.
//
// Ports:
//   - 2 read (rs1/rs2) — combinational
//   - 1 write — dispatch sets `rd → {1, alloc_idx}`
//   - 1 conditional-clear — commit clears the entry *only if* it
//     still points at the retiring ROB index. If a younger dispatch
//     has already overwritten the mapping, the clear is a no-op.
//   - 1 selective flush — on taken branches, clears only entries
//     whose tag falls in the squashed range (flush_after_idx, tail).
//     Entries pointing to older-than-branch in-flight producers
//     survive. M3 replaces this with snapshot-restore.
//
// Same-cycle resolution: if a commit clear and a dispatch write hit
// the same arch reg in the same cycle, dispatch wins (it's the newer
// producer). The always_ff orders clear-before-write to make this fall
// out naturally.
//
// Branch flush is *selective*: only entries whose tag falls in the
// squashed range (flush_after_idx, tail) get cleared. Entries pointing
// to producers older than (or equal to) the branch survive — those
// ROB slots will commit normally and their results aren't lost.
// (Wholesale flush would clobber the in-flight older-producer map and
//  force dispatch to read a stale arch regfile.)

import common_pkg::*;
import core_ooo_pkg::*;

module rat
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    input  logic                        flush_i,
    // Squash-range bounds for selective flush. `flush_after_idx_i` is
    // the surviving branch's ROB idx (its mapping is kept); entries
    // pointing strictly into (flush_after_idx, tail) are cleared.
    input  logic [OOO_ROB_IDX_W-1:0]    flush_after_idx_i,
    input  logic [OOO_ROB_IDX_W-1:0]    flush_tail_i,

    // Reads (combinational)
    input  logic [4:0]                  rs1_addr_i,
    input  logic [4:0]                  rs2_addr_i,
    output logic                        rs1_busy_o,
    output logic [OOO_ROB_IDX_W-1:0]    rs1_rob_idx_o,
    output logic                        rs2_busy_o,
    output logic [OOO_ROB_IDX_W-1:0]    rs2_rob_idx_o,

    // Dispatch write
    input  logic                        write_en_i,
    input  logic [4:0]                  write_addr_i,
    input  logic [OOO_ROB_IDX_W-1:0]    write_rob_idx_i,

    // Commit conditional-clear
    input  logic                        clear_en_i,
    input  logic [4:0]                  clear_addr_i,
    input  logic [OOO_ROB_IDX_W-1:0]    clear_check_idx_i
);

    logic                       busy_q [0:31];
    logic [OOO_ROB_IDX_W-1:0]   tag_q  [0:31];

    // ── reads ────────────────────────────────────────────────
    assign rs1_busy_o    = (rs1_addr_i == 5'd0) ? 1'b0 : busy_q[rs1_addr_i];
    assign rs1_rob_idx_o = tag_q[rs1_addr_i];
    assign rs2_busy_o    = (rs2_addr_i == 5'd0) ? 1'b0 : busy_q[rs2_addr_i];
    assign rs2_rob_idx_o = tag_q[rs2_addr_i];

    // ── writes / clears ─────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < 32; i++) begin
                busy_q[i] <= 1'b0;
                tag_q[i]  <= '0;
            end
        end else begin
            // Selective flush — clear entries whose tag falls in the
            // squashed range (flush_after_idx, flush_tail). Runs in
            // parallel with commit-clear: they touch disjoint entries
            // (flush targets younger-than-branch; commit drains head),
            // so combining them in one cycle is safe.
            if (flush_i) begin
                for (int i = 0; i < 32; i++) begin
                    automatic logic [OOO_ROB_IDX_W-1:0] d_tag;
                    automatic logic [OOO_ROB_IDX_W-1:0] d_tail;
                    d_tag  = tag_q[i]     - flush_after_idx_i - 1'b1;
                    d_tail = flush_tail_i - flush_after_idx_i - 1'b1;
                    if (busy_q[i] && (d_tag < d_tail)) busy_q[i] <= 1'b0;
                end
            end

            // Commit conditional-clear (only if entry still points
            // at the retiring slot; a younger dispatch may have moved
            // the mapping in the meantime).
            if (clear_en_i && clear_addr_i != 5'd0
                && busy_q[clear_addr_i]
                && tag_q[clear_addr_i] == clear_check_idx_i) begin
                busy_q[clear_addr_i] <= 1'b0;
            end

            // Dispatch write — newer producer; overrides clear in
            // the same cycle if both hit the same addr. (Dispatch is
            // gated off on flush at the top, so no conflict there.)
            if (write_en_i && write_addr_i != 5'd0) begin
                busy_q[write_addr_i] <= 1'b1;
                tag_q[write_addr_i]  <= write_rob_idx_i;
            end
        end
    end

endmodule
