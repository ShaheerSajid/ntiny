// ── Redirect Arbiter ─────────────────────────────────────────────────────
// Phase 1 of the fetch / c_controller / interrupt / stall revamp.
// See docs/fetch_revamp_plan.md §4.1 (spec) and §9 (migration).
//
// PURPOSE
//   Single combinational point that decides what address the next fetch
//   should go to. The eventual goal is to replace the per-source bypass
//   mux mess in core_top.sv (pc_sel, pc_in, ret_pulse PC bypass,
//   refetch_after_trap, etc.) with one well-defined arbitration step.
//
// PHASE 1 STATUS
//   This module is INSTANTIATED IN PARALLEL with the existing pc_sel /
//   pc_in logic in core_top.sv. Its outputs are observation-only — no
//   functional path consumes them. SVA assertions in core_top.sv cross-
//   check the outputs against the existing pc_sel/pc_in cycle-by-cycle.
//   Once the assertions hold across a full RISCOF + Linux run, Phase 4
//   will switch the program counter to consume this module's outputs and
//   delete the legacy pc_sel mux.
//
// LEVEL vs PULSE NOTE
//   The xRET path here uses ret_valid_i (level — high while xRET is in
//   ID), NOT the ret_fire/sret_fire one-shot pulses from privilege_unit.
//   This is intentional for Phase 1: the existing pc_sel logic uses
//   ret_valid (via ret_valid_valid), so the SVA cross-check requires the
//   arbiter to use the same level signal to hold cycle-by-cycle. Phase 4
//   will switch to pulse semantics when the FIU FSM becomes the
//   authoritative consumer.
//
// PRIORITY (matches existing pc_sel logic in core_top.sv lines 413-421):
//   debug > trap > branch > xret > none
//
//   Reset is intentionally NOT handled here — the existing program_counter
//   has its own reset path to a default vector, and the SVA cross-check is
//   gated `disable iff (reset_i)`. Phase 4 will add reset handling when
//   the arbiter becomes the sole owner of fetch_pc.

module redirect_arbiter
    import core_pkg::*;
(
    // ── Sources (level signals matching existing pc_sel logic) ──────────
    input  logic        debug_resume_i,    // resumeack_o (level pulse)
    input  logic        trap_valid_i,      // interrupt_valid (level)
    input  logic        branch_taken_i,    // bpu_mispredict (level)
    input  logic        ret_valid_i,       // ret_valid (level, while xRET in ID)
    input  logic        sret_select_i,     // 1 = SRET (use sepc), 0 = MRET (use mepc)

    // ── Targets ─────────────────────────────────────────────────────────
    input  logic [31:0] handler_addr_i,    // mtvec/stvec base + cause*4
    input  logic [31:0] branch_target_i,
    input  logic [31:0] sepc_i,
    input  logic [31:0] mepc_i,
    input  logic [31:0] dpc_i,

    // ── Outputs ─────────────────────────────────────────────────────────
    output logic            redirect_valid_o,
    output logic [31:0]     redirect_target_o,
    output redirect_kind_e  redirect_kind_o
);

    always_comb begin
        // Default: no redirect, fetch advances pc+4
        redirect_valid_o  = 1'b0;
        redirect_target_o = 32'b0;
        redirect_kind_o   = RDR_NONE;

        if (debug_resume_i) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = dpc_i;
            redirect_kind_o   = RDR_DEBUG;
        end else if (trap_valid_i) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = handler_addr_i;
            redirect_kind_o   = RDR_TRAP;
        end else if (branch_taken_i) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = branch_target_i;
            redirect_kind_o   = RDR_BRANCH;
        end else if (ret_valid_i) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = sret_select_i ? sepc_i : mepc_i;
            redirect_kind_o   = RDR_XRET;
        end
    end

endmodule
