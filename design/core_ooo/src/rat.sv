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
//   - 1 flush — wipes all busy bits in one cycle. At M1 this is used
//     on taken branches; M3 replaces with snapshot-restore.
//
// Same-cycle resolution: if a commit clear and a dispatch write hit
// the same arch reg in the same cycle, dispatch wins (it's the newer
// producer). The always_ff orders clear-before-write to make this fall
// out naturally.

import common_pkg::*;
import core_ooo_pkg::*;

module rat
(
    input  logic                        clk_i,
    input  logic                        reset_i,
    input  logic                        flush_i,

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
        end else if (flush_i) begin
            for (int i = 0; i < 32; i++) busy_q[i] <= 1'b0;
        end else begin
            // Commit conditional-clear (only if entry still points
            // at the retiring slot; a younger dispatch may have moved
            // the mapping in the meantime).
            if (clear_en_i && clear_addr_i != 5'd0
                && busy_q[clear_addr_i]
                && tag_q[clear_addr_i] == clear_check_idx_i) begin
                busy_q[clear_addr_i] <= 1'b0;
            end

            // Dispatch write — newer producer; overrides clear in
            // the same cycle if both hit the same addr.
            if (write_en_i && write_addr_i != 5'd0) begin
                busy_q[write_addr_i] <= 1'b1;
                tag_q[write_addr_i]  <= write_rob_idx_i;
            end
        end
    end

endmodule
