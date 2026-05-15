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
//   - snapshot/restore (M3-A) — see below.
//
// Same-cycle resolution: if a commit clear and a dispatch write hit
// the same arch reg in the same cycle, dispatch wins (newer producer).
// The combinational next-state computation handles this explicitly.
//
// ── Snapshot/restore (M3-A) ──────────────────────────────────────
// Per-branch RAT snapshots replace the wholesale "selective flush"
// that M2 used for branch recovery. The wholesale flush couldn't
// restore RAT entries that were pointing at OLDER surviving in-
// flight producers — it just cleared them, falling through to a
// stale arch regfile read.
//
// Snapshot semantics: at every branch dispatch, capture the
// post-update RAT (including the branch's own rd write, if any) into
// `snap_q[snap_take_idx_i]`. On mispredict, restore the entire RAT
// from `snap_q[snap_restore_idx_i]` in one cycle.
//
// Snapshot-while-in-flight maintenance: between take and restore,
// older committed entries clear their RAT mappings via the normal
// `clear_en_i` port. If we naively kept the snapshots frozen, a
// restore would point RAT at a *retired* (and possibly re-allocated)
// ROB slot — dead tag, no future wb to wake the dependent dispatch.
// We avoid that by mirroring every commit clear into all snapshots.
// (Cost: N_SNAPSHOTS×32 compare-and-clear per cycle. With N=4 that's
// 128 trivial compares — fine in hardware.)
//
// Same-cycle restore + commit-clear: the snapshot's NB-assigned
// clear lands at the same edge as the restore reads it, so the
// restore would see the pre-clear state. We patch this by computing
// `restored_*` combinationally with the clear applied on top of the
// snapshot we're about to read from.

import common_pkg::*;
import core_ooo_pkg::*;

module rat
#(
    parameter int N_SNAPSHOTS = 4,
    parameter int SNAP_IDX_W  = $clog2(N_SNAPSHOTS)
)
(
    input  logic                        clk_i,
    input  logic                        reset_i,

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
    input  logic [OOO_ROB_IDX_W-1:0]    clear_check_idx_i,

    // Snapshot — fires when a branch-class uop dispatches. Captures
    // the post-update RAT (including the branch's own write).
    input  logic                        snap_take_i,
    input  logic [SNAP_IDX_W-1:0]       snap_take_idx_i,

    // Restore — fires on mispredict. Loads the entire RAT from the
    // selected snapshot. Wins over a same-cycle take/write: those
    // edits would have been on a wrong-path uop anyway. A same-cycle
    // commit-clear is folded into the restored RAT.
    input  logic                        snap_restore_i,
    input  logic [SNAP_IDX_W-1:0]       snap_restore_idx_i
);

    logic                       busy_q [0:31];
    logic [OOO_ROB_IDX_W-1:0]   tag_q  [0:31];

    // Snapshot storage. N_SNAPSHOTS × 32 entries × {busy, tag}.
    logic                       snap_busy_q [0:N_SNAPSHOTS-1][0:31];
    logic [OOO_ROB_IDX_W-1:0]   snap_tag_q  [0:N_SNAPSHOTS-1][0:31];

    // ── reads ────────────────────────────────────────────────
    assign rs1_busy_o    = (rs1_addr_i == 5'd0) ? 1'b0 : busy_q[rs1_addr_i];
    assign rs1_rob_idx_o = tag_q[rs1_addr_i];
    assign rs2_busy_o    = (rs2_addr_i == 5'd0) ? 1'b0 : busy_q[rs2_addr_i];
    assign rs2_rob_idx_o = tag_q[rs2_addr_i];

    // ── combinational next-state RAT (post-clear, post-write) ──
    logic                     busy_d [0:31];
    logic [OOO_ROB_IDX_W-1:0] tag_d  [0:31];
    always_comb begin
        for (int i = 0; i < 32; i++) begin
            busy_d[i] = busy_q[i];
            tag_d[i]  = tag_q[i];
        end
        if (clear_en_i && clear_addr_i != 5'd0
            && busy_q[clear_addr_i]
            && tag_q[clear_addr_i] == clear_check_idx_i) begin
            busy_d[clear_addr_i] = 1'b0;
        end
        if (write_en_i && write_addr_i != 5'd0) begin
            busy_d[write_addr_i] = 1'b1;
            tag_d[write_addr_i]  = write_rob_idx_i;
        end
    end

    // ── restore source: snapshot at snap_restore_idx_i with the
    // same-cycle commit-clear applied on top. (The snapshot itself
    // is being NB-updated by the same clear; reading via the live
    // wires lets restore see the post-clear value in this cycle.)
    logic                     restored_busy [0:31];
    logic [OOO_ROB_IDX_W-1:0] restored_tag  [0:31];
    always_comb begin
        for (int i = 0; i < 32; i++) begin
            restored_busy[i] = snap_busy_q[snap_restore_idx_i][i];
            restored_tag[i]  = snap_tag_q[snap_restore_idx_i][i];
        end
        if (clear_en_i && clear_addr_i != 5'd0
            && snap_busy_q[snap_restore_idx_i][clear_addr_i]
            && snap_tag_q[snap_restore_idx_i][clear_addr_i] == clear_check_idx_i) begin
            restored_busy[clear_addr_i] = 1'b0;
        end
    end

    // ── writes / clears / snapshot / restore ─────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < 32; i++) begin
                busy_q[i] <= 1'b0;
                tag_q[i]  <= '0;
            end
            for (int s = 0; s < N_SNAPSHOTS; s++) begin
                for (int i = 0; i < 32; i++) begin
                    snap_busy_q[s][i] <= 1'b0;
                    snap_tag_q[s][i]  <= '0;
                end
            end
        end else begin
            // Live RAT update.
            if (snap_restore_i) begin
                for (int i = 0; i < 32; i++) begin
                    busy_q[i] <= restored_busy[i];
                    tag_q[i]  <= restored_tag[i];
                end
            end else begin
                for (int i = 0; i < 32; i++) begin
                    busy_q[i] <= busy_d[i];
                    tag_q[i]  <= tag_d[i];
                end
            end

            // Snapshot maintenance.
            // (a) Commit-clear mirrors into ALL snapshots so that
            //     subsequent restores see retired entries as cleared.
            if (clear_en_i && clear_addr_i != 5'd0) begin
                for (int s = 0; s < N_SNAPSHOTS; s++) begin
                    if (snap_busy_q[s][clear_addr_i]
                        && snap_tag_q[s][clear_addr_i] == clear_check_idx_i) begin
                        snap_busy_q[s][clear_addr_i] <= 1'b0;
                    end
                end
            end
            // (b) Snap-take captures the post-update RAT into the
            //     selected slot. Suppressed on restore (the
            //     dispatching uop is wrong-path).
            if (snap_take_i && !snap_restore_i) begin
                for (int i = 0; i < 32; i++) begin
                    snap_busy_q[snap_take_idx_i][i] <= busy_d[i];
                    snap_tag_q[snap_take_idx_i][i]  <= tag_d[i];
                end
            end
        end
    end

endmodule
