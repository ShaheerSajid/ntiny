// ─────────────────────────────────────────────────────────────────────────────
// wb_trap_unit
// ─────────────────────────────────────────────────────────────────────────────
// Trap revamp Phase 4: resolve traps, interrupts, mret/sret/dret atomically
// at the IWB stage.
//
// The core idea is that detection of any non-sequential control event still
// happens at the natural stage (page fault at IF, illegal at ID, misalign at
// IE, etc.), but COMMITMENT — CSR writes, priv switch, pipeline flush, PC
// redirect — only happens when the carrier instruction reaches IWB. This
// eliminates the entire family of mret-after-csrrw / xRET-vs-PTW races we
// were chasing in Phase 3.2/3.3/3.4 because at IWB:
//
//   - any older csrrw mepc/sepc has already committed → mret/sret reads the
//     fresh CSR value
//   - IF/ID/IE/IMEM are flushed atomically as a single redirect →
//     no pc_out / pc_in / inflight_vaddr_q race
//   - the redirect target is computed from a stable, committed CSR value
//   - csr_ret_hazard, ret_pulse, etc. are no longer needed
//
// Inputs are derived from the IWB-stage register-wall view:
//   - ctrl_bus_iwb.wb_event / wb_cause / wb_tval are set at the detection
//     stage (decoder for ecall/ebreak/mret/sret, IE-side wiring for
//     misalign / dmem PMP / dmem page fault, IF-side wiring for instruction
//     page/access fault) and propagated through the pipeline.
//   - insn_valid_iwb_i is the existing pipeline-valid signal at IWB.
//   - interrupt_pending_i is the level signal from interrupt_ctrl ('any
//     enabled, pending interrupt, gated by global IE for the current priv').
//   - The CSRs that the unit needs to READ to decide priv targets and
//     redirect addresses are passed in: mstatus, mepc, sepc, mtvec, stvec,
//     dpc, medeleg, mideleg, current priv level.
//
// Outputs (all single-cycle pulses except `redirect_*` which are also
// single-cycle, latched into the redirect_arbiter the same cycle):
//   - trap_fire_o : a synchronous OR async trap is being committed this cycle
//   - xret_fire_o : an mret/sret is being committed
//   - dret_fire_o : a dret is being committed
//   - cause_o, tval_o, epc_o, trap_to_s_o : the values to write into CSRs
//   - redirect_valid_o, redirect_target_o, redirect_kind_o : drive the
//     redirect_arbiter (replaces the legacy trap/xret paths into pc_in)
//   - kill_iwb_o : suppress this cycle's writeback (no rd write, no
//     dmem write commit). Asserted when trap_fire_o or xret_fire_o or
//     dret_fire_o is high — the carrier instruction does not retire.
//
// Phase 4.2 (this commit): wb_trap_unit is instantiated in parallel with
// the legacy interrupt_ctrl/privilege_unit redirect paths. Its outputs
// are EXPOSED but NOT yet driving the arbiter or csr_unit. Phase 4.3 cuts
// the trap path over, Phase 4.4 cuts xRET / dret over and deletes
// csr_ret_hazard.
// ─────────────────────────────────────────────────────────────────────────────

import common_pkg::*;
import core_pkg::*;

module wb_trap_unit (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── IWB-stage carrier instruction view ──
    input  ctrl_bus_e   ctrl_bus_iwb_i,
    input  logic [31:0] pc_iwb_i,
    input  logic        insn_valid_iwb_i,    // !stale_iwb && !iwb_flush

    // ── Async interrupt level (from interrupt_ctrl) ──
    // Asserted when any enabled, pending, globally-unmasked interrupt
    // is waiting. Cause encoding for the winning interrupt is in
    // interrupt_cause_i (matches the legacy ecause_o[30:0] encoding).
    input  logic        interrupt_pending_i,
    input  logic [4:0]  interrupt_cause_i,
    input  logic        interrupt_to_s_i,    // delegated to S-mode?

    // ── CSR state needed to compute redirect target ──
    input  logic [31:0] mepc_i,              // for mret target
    input  logic [31:0] sepc_i,              // for sret target
    input  logic [31:0] dpc_i,               // for dret target
    input  logic [31:0] mtvec_i,             // for trap target
    input  logic [31:0] stvec_i,             // for trap target
    input  logic [31:0] medeleg_i,           // sync trap delegation
    input  logic [1:0]  priv_i,              // current privilege level

    // ── Outputs ──
    output logic        trap_fire_o,
    output logic        xret_fire_o,
    output logic        dret_fire_o,

    // CSR write port (Phase 4.3 connects this to csr_unit; Phase 4.2
    // exposes only.)
    output logic [4:0]  cause_o,
    output logic [31:0] tval_o,
    output logic [31:0] epc_o,
    output logic        trap_to_s_o,         // delegated trap (M→S)
    output logic        is_async_o,          // 1 = interrupt, 0 = sync exception

    // Redirect output (Phase 4.3 connects this into redirect_arbiter)
    output logic        redirect_valid_o,
    output logic [31:0] redirect_target_o,
    output redirect_kind_e redirect_kind_o,

    // Suppress IWB writeback (Phase 4.3 wires into the IWB writeback gates)
    output logic        kill_iwb_o
);

    // ── Tag decoding ──
    // ctrl_bus_iwb carries the wb_event tag the carrier instruction
    // produced at its detection stage. WB_NONE retire normally; WB_TRAP
    // commits a synchronous exception with the (cause, tval) the
    // detection stage tagged; WB_XRET commits an mret/sret using the
    // priv-mode-aware target select; WB_DRET commits dret.
    //
    // Async interrupts are level-sampled and committed by preempting
    // the carrier instruction (see precedence below).
    wire is_sync_trap_tag = insn_valid_iwb_i &&
                            (ctrl_bus_iwb_i.wb_event == WB_TRAP);
    wire is_xret_tag      = insn_valid_iwb_i &&
                            (ctrl_bus_iwb_i.wb_event == WB_XRET);
    wire is_dret_tag      = insn_valid_iwb_i &&
                            (ctrl_bus_iwb_i.wb_event == WB_DRET);

    // ── Async interrupt qualification ──
    // The legacy interrupt_ctrl already gates by priv / global IE / ip&ie.
    // We just need to make sure we have a real instruction at IWB to use
    // as the trap victim — async interrupts should NOT fire on bubble
    // cycles (mepc would have nothing useful to record).
    //
    // Open question from the design plan: should we hold the interrupt
    // pending when WB is bubble for many cycles? For Phase 4.2 we just
    // qualify by insn_valid_iwb_i; the bubble drains in <= 5 cycles.
    wire async_take = insn_valid_iwb_i && interrupt_pending_i;

    // ── Precedence ──
    // 1. dret_tag    (debug exit — must always go to dpc, no trap allowed)
    // 2. async_take  (interrupt preempts the carrier; carrier becomes
    //                 mepc and is squashed instead of retired)
    // 3. sync_trap   (carrier itself caused the fault)
    // 4. xret_tag    (mret/sret commit — read the now-fresh CSR)
    // 5. otherwise   (normal retirement)
    //
    // Note: in the textbook ordering, sync exceptions take priority over
    // pending interrupts on the same instruction (the spec lets the
    // implementation choose either way for sync vs async on the SAME
    // committed insn). The legacy core takes the interrupt first (see
    // interrupt_ctrl precedence) — match that for now to keep the
    // Phase 4.3 cutover bit-equivalent in regressions.

    logic do_dret;
    logic do_async;
    logic do_sync;
    logic do_xret;
    always_comb begin
        do_dret  = 1'b0;
        do_async = 1'b0;
        do_sync  = 1'b0;
        do_xret  = 1'b0;
        if (is_dret_tag) begin
            do_dret = 1'b1;
        end else if (async_take) begin
            do_async = 1'b1;
        end else if (is_sync_trap_tag) begin
            do_sync = 1'b1;
        end else if (is_xret_tag) begin
            do_xret = 1'b1;
        end
    end

    assign trap_fire_o = do_async | do_sync;
    assign xret_fire_o = do_xret;
    assign dret_fire_o = do_dret;
    assign kill_iwb_o  = do_async | do_sync | do_xret | do_dret;

    // ── CSR write payload ──
    //
    // Sync trap : cause / tval / epc come from the carrier instruction's
    //             tag.  trap_to_s comes from medeleg lookup vs cur priv.
    // Async trap: cause / tval come from interrupt_ctrl.  epc = pc_iwb.
    //             trap_to_s from mideleg via interrupt_to_s_i.
    //
    // Delegation rule (sync): trap is taken in S-mode iff
    //   (priv_i != M) && medeleg[cause]
    wire sync_deleg = (priv_i != 2'b11) &&
                       medeleg_i[ctrl_bus_iwb_i.wb_cause];

    always_comb begin
        cause_o     = 5'd0;
        tval_o      = 32'd0;
        epc_o       = pc_iwb_i;
        trap_to_s_o = 1'b0;
        is_async_o  = 1'b0;
        if (do_async) begin
            cause_o     = interrupt_cause_i;
            tval_o      = 32'd0;
            epc_o       = pc_iwb_i;
            trap_to_s_o = interrupt_to_s_i;
            is_async_o  = 1'b1;
        end else if (do_sync) begin
            cause_o     = ctrl_bus_iwb_i.wb_cause;
            tval_o      = ctrl_bus_iwb_i.wb_tval;
            epc_o       = pc_iwb_i;
            trap_to_s_o = sync_deleg;
            is_async_o  = 1'b0;
        end
    end

    // ── Redirect target ──
    //
    // Trap : mtvec or stvec, plus 4*cause for vectored mode (we drive base
    //        only here; vectoring offset is added in core_top exactly the
    //        way the legacy interrupt_ctrl did, until Phase 4.3 absorbs
    //        that math here).
    // xRET : if mret -> mepc, if sret -> sepc.  Distinction is in the
    //        ctrl_bus tag: ctrl_bus_iwb.mret / .sret are still set.
    // dret : dpc.
    always_comb begin
        redirect_valid_o  = 1'b0;
        redirect_target_o = 32'd0;
        redirect_kind_o   = RDR_NONE;
        if (do_dret) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = dpc_i;
            redirect_kind_o   = RDR_DEBUG;  // dret is a debug-exit, share kind
        end else if (do_async || do_sync) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = trap_to_s_o ? stvec_i : mtvec_i;
            redirect_kind_o   = RDR_TRAP;
        end else if (do_xret) begin
            redirect_valid_o  = 1'b1;
            redirect_target_o = (ctrl_bus_iwb_i.sret == TRUE) ? sepc_i : mepc_i;
            redirect_kind_o   = RDR_XRET;
        end
    end

endmodule
