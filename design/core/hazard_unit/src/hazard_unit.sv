import common_pkg::*;
import core_pkg::*;

// ── Hazard Unit ─────────────────────────────────────────────────────────────
// Centralises all pipeline stall, flush, and post-trap bookkeeping that was
// previously scattered across core_top.  Pure-refactor: behaviour is identical
// to the original inline logic.
//
// Stall chain (combinational):   iwb_stall → imem_stall → ie_stall → if_id_stall
// Flush priority (combinational): based on {if_id_stall|resume|trap, ie_stall, imem_stall, iwb_stall}
// Registered state:               post_trap, refetch_after_trap, insn_valid_id
//
module hazard_unit (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── External stall sources ──────────────────────────────────────────
    input  onebit_sig_e alu_stall_i,       // MUL/DIV in progress
    input  onebit_sig_e amo_stall_i,       // atomic memory op FSM
    input  logic        misalign_stall_i,  // misaligned access in progress
    input  logic        icache_stall_i,     // I-cache fill in progress
    input  onebit_sig_e mmu_i_stall_i,     // instruction TLB / PTW
    input  onebit_sig_e mmu_d_stall_i,     // data TLB / PTW
    input  logic        pmp_d_fault_i,     // PMP data fault (stall IE 1 cycle for registered trap)
    input  logic        d_page_fault_i,    // data page fault (stall IE 1 cycle for registered trap)
    input  logic        dmem_req_i,        // data-bus request pending
    input  logic        dmem_ready_i,      // data-bus ready
    input  onebit_sig_e insert_bubble_i,   // structural hazard (stall_line)

    // ── Control-flow events ─────────────────────────────────────────────
    input  onebit_sig_e interrupt_valid_i,  // trap/interrupt firing
    input  logic        resumeack_i,        // debug resume

    // ── Phase 4 trap revamp: WB-stage event commit ──────────────────────
    // Asserted for one cycle when wb_trap_unit commits any of
    // trap / xret / dret. Triggers a 4-stage flush (IF/ID/IE/IMEM) so
    // the wrong-path instructions younger than the carrier are killed.
    // The carrier itself (in IWB) commits its CSR side effects this
    // cycle and is NOT flushed.
    input  logic        wb_event_fire_i,

    // ── Phase 3: fetch path validity / redirect ─────────────────────────
    input  logic        aligner_valid_i,    // 1 = aligner has a real ID-stage instruction
    input  logic        redirect_valid_i,   // any redirect (trap/xRET/branch/debug)

    // ── IE-stage exception flag ─────────────────────────────────────────
    input  logic        exception_from_ie_i,

    // ── Processor state ─────────────────────────────────────────────────
    input  logic        halted_i,           // debug halted (pstate == HALTED)

    // ── CSR ret-hazard detection inputs ─────────────────────────────────
    input  logic        id_mret_i,          // ctrl_bus_if_id.mret
    input  logic        id_sret_i,          // ctrl_bus_if_id.sret
    input  logic        illegal_mret_i,
    input  logic        illegal_sret_i,
    input  csr_op_e     ie_csr_op_i,        // ctrl_bus_ie.csr_op
    input  logic [11:0] ie_csr_addr_i,      // ctrl_bus_ie.csr_addr

    // ── Stall outputs ───────────────────────────────────────────────────
    output onebit_sig_e if_id_stall_o,
    output onebit_sig_e ie_stall_o,
    output onebit_sig_e imem_stall_o,
    output onebit_sig_e iwb_stall_o,

    // ── Flush outputs ───────────────────────────────────────────────────
    output onebit_sig_e ie_flush_o,
    output onebit_sig_e imem_flush_o,
    output onebit_sig_e iwb_flush_o,

    // ── Post-trap / stale ───────────────────────────────────────────────
    output logic        post_trap_o,
    output logic        stale_id_o,

    // ── Instruction validity ────────────────────────────────────────────
    output logic        insn_valid_id_o,

    // ── Fetch control ───────────────────────────────────────────────────
    output logic        refetch_after_trap_o,

    // ── CSR ret hazard ──────────────────────────────────────────────────
    output logic        csr_ret_hazard_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Stall chain (combinational)
// ═══════════════════════════════════════════════════════════════════════════
wire dmem_busy = dmem_req_i & ~dmem_ready_i;

assign iwb_stall_o  = onebit_sig_e'(1'b0);
assign imem_stall_o = onebit_sig_e'(iwb_stall_o);
assign ie_stall_o   = onebit_sig_e'(imem_stall_o | alu_stall_i | dmem_busy |
                                     amo_stall_i  | mmu_d_stall_i |
                                     misalign_stall_i | pmp_d_fault_i |
                                     d_page_fault_i);

// CSR read-after-write hazard: deprecated in Phase 4 — xRET resolves at
// IWB so by definition the older csrrw mepc/sepc has already committed.
// Tied off here; the input ports stay for the legacy interface but their
// values are ignored. Will be deleted in the Phase 4 cleanup pass.
assign csr_ret_hazard_o = 1'b0;
wire _unused_csr_ret_inputs = &{1'b0, id_mret_i, id_sret_i,
                                 illegal_mret_i, illegal_sret_i,
                                 ie_csr_op_i, ie_csr_addr_i};

// Phase 3: id_no_insn_stall is the new "ID has no real instruction"
// stall source. It fires when the compressed_aligner has nothing to
// emit (buffer empty after a redirect, or waiting for a straddled
// 32-bit's second word). It must hold the IF/ID stage so the IE wall
// does not capture the decoder's NOP-from-zero output.
wire id_no_insn_stall = ~aligner_valid_i;

assign if_id_stall_o = onebit_sig_e'(ie_stall_o | insert_bubble_i |
                                      refetch_after_trap_o | halted_i |
                                      icache_stall_i | mmu_i_stall_i |
                                      id_no_insn_stall);

// ═══════════════════════════════════════════════════════════════════════════
// Flush logic (combinational)
// ═══════════════════════════════════════════════════════════════════════════
//
// Phase 3 (branch-in-IE): wrong-path squash via direct redirect_valid_i
//
// When the branch resolves at the IE stage at cycle K, the aligner is
// already emitting the next sequential instruction (PC+4 wrong-path)
// into ctrl_bus_if_id at the SAME cycle K. Without intervention, the
// IE wall captures the wrong-path at edge K→K+1 and it executes at
// K+1, corrupting state before the redirect target arrives.
//
// The fix: OR `redirect_valid_i` (= arb_redirect_valid, combinational
// from branch_comp at IE) directly into ie_flush_o on the SAME cycle.
// The IE wall sees ie_flush=1 at cycle K and captures CTRL_BUS_NOP for
// cycle K+1, killing the wrong-path before it executes. The branch
// itself was already captured into ctrl_bus_ie at edge K-1→K and
// continues to propagate through IMEM/IWB normally (the link write,
// CSR side effects, etc. happen as expected).
//
// This must be combinational (NOT registered) because the wrong-path
// is in ID at the SAME cycle the branch is in IE — there's no 1-cycle
// gap between "branch detected" and "wrong-path entering IE".
always_comb begin
    case ({if_id_stall_o | resumeack_i | interrupt_valid_i,
           ie_stall_o, imem_stall_o, iwb_stall_o})
        4'b1000: begin
            ie_flush_o   = TRUE;
            imem_flush_o = onebit_sig_e'(exception_from_ie_i);
            iwb_flush_o  = FALSE;
        end
        4'b1100: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b010;
        4'b1110: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b001;
        default: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b000;
    endcase
    if (redirect_valid_i)
        ie_flush_o = TRUE;
    // Phase 4: when wb_trap_unit commits a trap/xret/dret in IWB, kill
    // all 4 wrong-path stages (IF via fetch_flush, ID/IE/IMEM/IWB-on-
    // next-edge via the flush bits). Note iwb_flush=1 here is safe:
    // the carrier instruction has ALREADY committed its CSR side
    // effects this cycle (combinationally — wb_trap_unit's outputs feed
    // csr_unit.ret_i / sret_i / trap_valid_i during the same clock
    // cycle). The flush only affects the NEXT IWB register-wall edge,
    // i.e. cycle K+1's ctrl_bus_iwb becomes NOP instead of the
    // wrong-path-1 that would otherwise propagate from IMEM.
    if (wb_event_fire_i) begin
        ie_flush_o   = TRUE;
        imem_flush_o = TRUE;
        iwb_flush_o  = TRUE;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Registered state
// ═══════════════════════════════════════════════════════════════════════════

// ── Post-trap: marks instruction in ID as stale after a trap fires ───────
// Lasts exactly 1 cycle: the leftover instruction in ID at trap time gets
// NOP'd when it enters IE. Must clear unconditionally (not gated by
// if_id_stall) because refetch_after_trap holds the stall high, which
// would keep post_trap set and incorrectly NOP the handler's first insn.
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        post_trap_o <= 1'b0;
    else if (interrupt_valid_i)
        post_trap_o <= 1'b1;
    else
        post_trap_o <= 1'b0;
end
assign stale_id_o = post_trap_o;

// ── Instruction validity in ID stage ─────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        insn_valid_id_o <= 1'b0;
    else if (interrupt_valid_i)
        insn_valid_id_o <= 1'b0;
    else if (!if_id_stall_o)
        insn_valid_id_o <= 1'b1;
end

// ── Refetch after trap ───────────────────────────────────────────────────
// When a trap fires, the next-cycle i_vaddr defaults to pc_in (= pc_out+4),
// which would skip the trap target's FIRST instruction. We must force i_vaddr
// to use pc_out (= the trap target itself) for one cycle so the first
// instruction of the handler actually gets fetched.
//
// This MUST fire on EVERY trap, not only traps that coincide with a stall.
// Previously gated by `interrupt_valid & if_id_stall`, which silently
// dropped handler[0] whenever the user was running smoothly when the trap
// fired — exactly the case Linux init triggers, where U-mode runs cleanly,
// takes a page fault, and the kernel's first instruction (csrrw at
// handle_exception) was being skipped, leading to handle_exception running
// the bnez first with stale tp=0 → wrong _restore_kernel_tpsp path → loop.
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        refetch_after_trap_o <= 1'b0;
    else
        refetch_after_trap_o <= interrupt_valid_i;
end

endmodule
