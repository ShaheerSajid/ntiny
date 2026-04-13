// Trap Sequencer — centralized fault registration and suppression
//
// Replaces scattered registered-fault logic in core_top with a clean FSM
// that manages the lifecycle of MMU fault signals through pipeline redirects.
//
// The core problem this solves:
//   When SRET/MRET/branch redirects the PC, stale faults from the OLD fetch/
//   execute path can fire 1+ cycles later (because they're registered). These
//   stale faults corrupt trap entry by overwriting sepc/scause after the
//   redirect. Different fault types need different clearing policies:
//
//   - i_fault_r (insn page fault): clears on trap, branch, AND during SRET
//     ITLB-miss stalls (the SRET stall bug — stale S-mode fetch fault fires
//     6 cycles after SRET while waiting for U-mode target PTW)
//
//   - d_fault_r (data page fault): clears on trap ONLY. Data faults come from
//     the IE stage, not the fetch path. Branch/ret don't affect them.
//
//   - i_access_fault_r (insn PMP): clears on trap ONLY.
//   - d_access_fault_r (data PMP): clears on trap ONLY.
//
// FSM states:
//   IDLE       — normal execution, faults register normally
//   SRET_WAIT  — after SRET fires, suppress i_fault registration until
//                the ITLB resolves for the new target address

import common_pkg::*;
import core_pkg::*;

module trap_sequencer (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── Pipeline events ────────────────────────────────────────
    input  logic        interrupt_valid_i,        // trap fires (sync or async)
    input  logic        ret_valid_i,              // MRET or SRET in ID stage
    input  logic        sret_i,                   // 1 = SRET, 0 = MRET
    input  logic        ret_side_effects_done_i,  // SRET CSR side effects committed
                                                  // (priv has transitioned — any
                                                  //  new i_fault is legitimate, not
                                                  //  stale, so SRET_WAIT must release)
    input  logic        branch_taken_i,           // branch redirect
    input  logic        if_id_stall_i,            // IF/ID stall (includes ITLB miss)
    input  logic        mmu_i_stall_i,            // instruction TLB/PTW stall specifically

    // ── Raw faults from MMU (combinational) ────────────────────
    input  logic        mmu_i_fault_i,
    input  logic [31:0] mmu_i_fault_addr_i,
    input  logic        mmu_d_fault_i,
    input  logic [31:0] mmu_d_fault_addr_i,
    input  logic        mmu_d_fault_is_store_i,  // Bug 30: latch is-store flag
    input  logic        mmu_i_access_fault_i,
    input  logic [31:0] mmu_i_access_fault_addr_i,
    input  logic        mmu_d_access_fault_i,
    input  logic [31:0] mmu_d_access_fault_addr_i,

    // ── Registered faults (to interrupt_ctrl) ──────────────────
    output logic        i_fault_r_o,
    output logic [31:0] i_fault_addr_r_o,
    output logic        d_fault_r_o,
    output logic [31:0] d_fault_addr_r_o,
    output logic        d_fault_is_store_r_o,  // Bug 30: registered is-store flag
    output logic        i_access_fault_r_o,
    output logic [31:0] i_access_fault_addr_r_o,
    output logic        d_access_fault_r_o,
    output logic [31:0] d_access_fault_addr_r_o
);

    // ════════════════════════════════════════════════════════════
    // FSM
    // ════════════════════════════════════════════════════════════
    typedef enum logic [1:0] {
        IDLE,       // normal operation
        SRET_WAIT   // suppress i_fault during SRET ITLB stall
    } state_t;

    state_t state, state_next;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            state <= IDLE;
        else
            state <= state_next;
    end

    // SRET pre-commit window: from the cycle SRET enters ID until the cycle
    // it commits its CSR side effects (priv transitions). This is the only
    // window where fault suppression is needed — any fault before commit is
    // potentially stale (from the OLD privilege fetch path); any fault AFTER
    // commit is from the NEW privilege and must propagate to the kernel.
    //
    // Without the `!ret_side_effects_done_i` gate, ret_valid_i stays high
    // forever in the cold-ITLB SRET-to-U case (because the c_controller's
    // instruction_o keeps emitting SRET from stale ins_buffer after the apc
    // bypass), which makes sret_pre_commit stuck high → all faults suppressed
    // → kernel never sees the demand-page fault on the user binary's first
    // instruction → deadlock.
    wire sret_pre_commit = ret_valid_i && sret_i && !ret_side_effects_done_i;

    always_comb begin
        state_next = state;
        case (state)
            IDLE: begin
                if (sret_pre_commit)
                    // SRET in ID and CSR side effects haven't committed yet →
                    // enter suppression. Once commit fires, this guard drops
                    // and we won't re-enter even if ret_valid_i is still high
                    // due to c_controller stale state.
                    state_next = SRET_WAIT;
            end

            SRET_WAIT: begin
                if (interrupt_valid_i)
                    // Nested interrupt → abort SRET, handle trap
                    state_next = IDLE;
                else if (ret_side_effects_done_i)
                    // SRET CSR side effects committed → exit suppression so the
                    // legitimate post-commit faults (e.g. user demand-page) can
                    // propagate to the kernel.
                    state_next = IDLE;
            end

            default: state_next = IDLE;
        endcase
    end

    // ════════════════════════════════════════════════════════════
    // Clearing conditions
    // ════════════════════════════════════════════════════════════

    // All faults clear on trap (interrupt_valid)
    wire clear_on_trap = interrupt_valid_i;

    // Instruction page fault clearing — three sources, all must be gated by
    // `!ret_side_effects_done_i` so they don't permanently suppress the
    // post-commit demand-page fault:
    //
    //   1. branch / ret redirect when not stalled — gate by !committed
    //      (the redirect-clear is for stale faults from before the redirect)
    //   2. SRET_WAIT state — already gated by the FSM via sret_pre_commit
    //   3. sret_start (the dominant suppression term) — gate by !committed
    wire clear_ifault = clear_on_trap |
                        (~if_id_stall_i & (branch_taken_i | (ret_valid_i && !ret_side_effects_done_i))) |
                        (state == SRET_WAIT) |
                        sret_pre_commit;

    // Data page fault, instruction PMP, data PMP: clear on trap ONLY.
    // These come from the IE stage (not fetch path) and are not affected
    // by PC redirects from branch/ret.
    wire clear_other = clear_on_trap;

    // ════════════════════════════════════════════════════════════
    // Registered fault outputs
    // ════════════════════════════════════════════════════════════

    // Instruction page fault (cause 12)
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            i_fault_r_o      <= 1'b0;
            i_fault_addr_r_o <= 32'b0;
        end else if (clear_ifault) begin
            i_fault_r_o      <= 1'b0;
            i_fault_addr_r_o <= 32'b0;
        end else begin
            i_fault_r_o      <= mmu_i_fault_i;
            i_fault_addr_r_o <= mmu_i_fault_addr_i;
        end
    end

    // Data page fault (cause 13/15)
    // Bug 30: also latch is-store flag. interrupt_valid is gated by
    // !insn_valid_id which may delay the trap by 1+ cycles. By then
    // the IE stage can flush and d_store_for_mmu drops to 0, causing
    // the interrupt_ctrl to report cause=13 (load) instead of cause=15
    // (store). The registered flag survives until the trap fires.
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            d_fault_r_o           <= 1'b0;
            d_fault_addr_r_o      <= 32'b0;
            d_fault_is_store_r_o  <= 1'b0;
        end else if (clear_other) begin
            d_fault_r_o           <= 1'b0;
            d_fault_addr_r_o      <= 32'b0;
            d_fault_is_store_r_o  <= 1'b0;
        end else begin
            d_fault_r_o           <= mmu_d_fault_i;
            d_fault_addr_r_o      <= mmu_d_fault_addr_i;
            d_fault_is_store_r_o  <= mmu_d_fault_is_store_i;
        end
    end

    // Instruction PMP access fault (cause 1)
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            i_access_fault_r_o      <= 1'b0;
            i_access_fault_addr_r_o <= 32'b0;
        end else if (clear_other) begin
            i_access_fault_r_o      <= 1'b0;
            i_access_fault_addr_r_o <= 32'b0;
        end else begin
            i_access_fault_r_o      <= mmu_i_access_fault_i;
            i_access_fault_addr_r_o <= mmu_i_access_fault_addr_i;
        end
    end

    // Data PMP access fault (cause 5/7)
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            d_access_fault_r_o      <= 1'b0;
            d_access_fault_addr_r_o <= 32'b0;
        end else if (clear_other) begin
            d_access_fault_r_o      <= 1'b0;
            d_access_fault_addr_r_o <= 32'b0;
        end else begin
            d_access_fault_r_o      <= mmu_d_access_fault_i;
            d_access_fault_addr_r_o <= mmu_d_access_fault_addr_i;
        end
    end

endmodule
