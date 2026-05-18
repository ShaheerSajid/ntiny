import common_pkg::*;
import core_pkg::*;

// ── Trap Controller ─────────────────────────────────────────────────────────
// Centralises all exception detection, interrupt qualification, prioritisation,
// delegation, and handler address selection.
//
// Exception detection (misalign, page fault gating) is done here — core_top
// passes raw pipeline state and MMU signals, not pre-computed exception flags.
//
module interrupt_ctrl (
    input clk_i,
    input rst_i,

    // ── Async interrupt sources ─────────────────────────────────────────
    // ext_itr_i (MEIP) drives interrupt_src_o[11]. SEIP HW driving lives
    // in csr_unit (where it's ORed into mip[9] for reads + ip_o), so the
    // ip_i input here already reflects PLIC ctx-1 assertions and the
    // existing s_external_valid logic works unchanged.
    input ext_itr_i,
    input timer_itr_i,
    input soft_itr_i,

    // ── CSR state ───────────────────────────────────────────────────────
    input [31:0] ip_i,
    input [31:0] ie_i,
    input [31:0] vec_i,
    input [31:0] status_i,

    // ── Program counters ────────────────────────────────────────────────
    input [31:0] pc_id_i,              // ID-stage PC (from aligner — 0 when buffer empty)
    input [31:0] pc_ie_i,              // IE-stage PC
    input [31:0] pc_out_i,             // fetch PC (next instruction address)

    // ── Privilege and delegation ────────────────────────────────────────
    input [1:0]  priv_i,
    input [31:0] medeleg_i,
    input [31:0] mideleg_i,

    // ── ID-stage exception sources (raw, gated here) ────────────────────
    input        ecall_raw_i,          // ctrl_bus_if_id.ecall
    input        ebreak_raw_i,         // ctrl_bus_if_id.ebreak
    input        illegal_insn_i,       // from privilege_unit (already computed)
    input        insn_valid_id_i,      // from hazard_unit
    input        debug_ebreak_i,       // dcsr[15] — ebreak enters debug, not trap
    input        branch_taken_i,       // IE-stage branch MISPREDICT (= bpu_mispredict)
    // Architectural direction from branch_comp at IE: 1 = the IE
    // instruction is a branch/jump that IS taking this cycle
    // (BRANCH+condition-met, or JUMP/JUMP_R unconditionally).
    // Async-trap epc must use the recovery target whenever a branch
    // commits, mispredicted or not. See docs/bugs/.
    input        branch_taken_h_i,
    // Architecturally correct sepc target across all four
    // predict×direction combinations:
    //   pred=T, actual=NT          -> fall-through (predicted_pc_ie)
    //   pred=T, actual=T (wrong)   -> taken target
    //   pred=NT, actual=T          -> taken target
    //   pred=T, actual=T (correct) -> taken target (branch_target_address)
    input [31:0] branch_recovery_target_i,

    // ── IE-stage CSR invalid (unimplemented CSR accessed) ────────────────
    input                ie_csr_invalid_i,

    // ── IE-stage signals for misalign detection ─────────────────────────
    input mem_op_e       ie_mem_op_i,
    input load_store_width_e ie_ls_width_i,
    input amo_op_e       ie_amo_op_i,
    input [1:0]          ie_addr_lsb_i,    // alu_result[1:0]
    input [31:0]         ie_fault_addr_i,  // alu_result (full address for mtval)
    input                amo_in_progress_i,
    // amo_unit.active_o — high in AMO_READ/AMO_WRITE (mid-bus, uncommitted).
    // Low in IDLE and DONE.
    input                amo_active_i,
    // amo_unit.pending_o — high in IDLE while an AMO at IE is waiting
    // to start. flush_i blocks the IDLE→READ transition on async-trap,
    // and without this signal async_use_ie misses the squashed-AMO
    // case. Goes 0 in DONE so already-committed AMOs are skipped, not
    // re-executed. See docs/bugs/.
    input                amo_pending_i,
    // mmu_d_stall — PTW walk in flight for an IE-stage load/store.
    // d_xlat_pending suppresses dmem_port.we so the store has not
    // committed yet; sepc must point at the load/store so it
    // re-executes after sret.
    input                mmu_d_stall_i,

    // ── IE-stage uncommitted indicator ──────────────────────────────────
    // High when the IE-stage instruction has not yet committed (multi-
    // cycle op like AMO/MUL/DIV/PTW still working). Used to choose
    // pc_ie vs pc_id for async-trap epc.
    input                ie_stall_i,

    // ── IE-stage instruction length ─────────────────────────────────────
    // 1 = 16-bit compressed insn at IE, 0 = 32-bit. Used by
    // pc_for_async's pc_id=0 fallback to compute pc_ie + insn_len so
    // a "skip" sepc lands on the right next-PC for both RVC and
    // RV32 instructions.
    input                c_valid_ie_i,

    // ── MMU page faults ─────────────────────────────────────────────────
    input        insn_page_fault_i,    // registered mmu_i_fault_r
    input [31:0] insn_fault_addr_i,    // registered mmu_i_fault_addr_r
    input        data_page_fault_i,    // mmu_d_fault (combinational)
    input        data_fault_is_store_i,// d_store_for_mmu
    input [31:0] data_fault_addr_i,    // mmu_d_fault_addr

    // ── PMP access faults ───────────────────────────────────────────────
    input        insn_access_fault_i,     // registered mmu_i_access_fault_r
    input [31:0] insn_access_fault_addr_i,
    input        data_access_fault_i,     // mmu_d_access_fault (combinational)
    input        data_access_fault_is_store_i,
    input [31:0] data_access_fault_addr_i,

    // ── Outputs ─────────────────────────────────────────────────────────
    output       trap_valid_o,
    output       trap_to_s_o,
    output       async_trap_o,      // async interrupt (not sync exception)
    output [31:0] handler_addr_o,
    output [31:0] ecause_o,
    output [31:0] epc_o,
    output [31:0] mtval_o,
    output [31:0] interrupt_src_o,
    // Exception side-effect: suppress memory op on misalign
    output       exception_from_ie_o,

    // ── Phase 4 trap revamp: level-signal interrupt pending feeds ──
    // wb_trap_unit (resolves at IWB).  These do NOT depend on the IE
    // pipeline state — they're purely "is there an enabled, pending
    // interrupt for the current priv that the current global IE allows".
    // Cause encoding matches the legacy ecause (cause_code field).
    output       interrupt_pending_o,
    output [4:0] interrupt_cause_o,
    output       interrupt_to_s_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Misaligned access detection (IE stage)
// ═══════════════════════════════════════════════════════════════════════════
// HW misaligned access confirmed NOT the cause of bad_page (same error
// with SW emulation). Re-enable HW support for performance.
wire misalign_load  = 1'b0;  // handled in HW (core2avl)
wire misalign_store = 1'b0;  // handled in HW (core2avl)
wire misalign_amo = (ie_amo_op_i != NO_AMO_OP) && |ie_addr_lsb_i && !amo_in_progress_i;

// Forward declaration of ie_csr_illegal — its driver is later in the
// file at its natural point (with the rest of the IE-stage exception
// aggregation) so this only suppresses Synth 8-6901.
wire ie_csr_illegal;

assign exception_from_ie_o = misalign_amo | ie_csr_illegal;

// ═══════════════════════════════════════════════════════════════════════════
// ID-stage exception gating (only fire on valid, non-illegal instructions)
// ═══════════════════════════════════════════════════════════════════════════
// Suppress ID-stage sync exceptions when an IE-stage branch is
// mispredicting (~branch_taken_i): the ID insn is on the wrong-path
// fall-through and will be flushed by the redirect, so its
// ebreak/ecall/illegal must not fire a trap.
wire ecall_valid   = ecall_raw_i  & ~illegal_insn_i & insn_valid_id_i & ~branch_taken_i;
wire ebreak_valid  = ebreak_raw_i & ~debug_ebreak_i & ~illegal_insn_i & insn_valid_id_i & ~branch_taken_i;
wire illegal_valid = illegal_insn_i & insn_valid_id_i & ~branch_taken_i;

// ═══════════════════════════════════════════════════════════════════════════
// Page fault separation (load vs store)
// ═══════════════════════════════════════════════════════════════════════════
wire load_page_fault  = data_page_fault_i & ~data_fault_is_store_i;
wire store_page_fault = data_page_fault_i &  data_fault_is_store_i;

// PMP access fault separation (load vs store)
wire load_access_fault  = data_access_fault_i & ~data_access_fault_is_store_i;
wire store_access_fault = data_access_fault_i &  data_access_fault_is_store_i;

// ═══════════════════════════════════════════════════════════════════════════
// PC for exception: instruction faults use saved fault address
// ═══════════════════════════════════════════════════════════════════════════
wire [31:0] pc_for_id = insn_page_fault_i  ? insn_fault_addr_i :
                        insn_access_fault_i ? insn_access_fault_addr_i : pc_id_i;

// ═══════════════════════════════════════════════════════════════════════════
// PC capture for async-trap epc (sepc/mepc)
// ═══════════════════════════════════════════════════════════════════════════
// Picking the right epc on an async interrupt is delicate because
// the pipeline has multiple in-flight instructions and we must
// resume in a way that:
//   - doesn't double-execute anything that already retired
//   - doesn't skip anything that was squashed before commit
//   - lands on the architecturally-correct PC, not a wrong-path PC
//
// The four conditions and their epc choice (priority order):
//
//   1. async_use_branch — IE-stage branch/jump is committing this
//      cycle. Use brcvr (branch_recovery_target_i) which collapses
//      all four predict×direction combinations into the architecturally
//      correct next-PC.
//        branch_taken_i    = mispredict (pred≠actual)
//        branch_taken_h_i  = correctly-predicted TAKEN (no mispredict
//                            but branch IS taking)
//      OR'd together to catch any branch that's committing.
//
//   2. async_use_ie — IE-stage op is uncommitted (memory not yet
//      written, regfile not yet updated). Use pc_ie so the op
//      re-executes after sret. Three contributors:
//        amo_active_i    = AMO in READ/WRITE phase (mid-bus FSM)
//        mmu_d_stall_i   = PTW walking for an IE load/store (d_xlat_pending
//                          suppresses dmem_port.we → store uncommitted)
//        amo_pending_i   = AMO at IE in IDLE waiting to start (flush_i
//                          blocked the IDLE→READ transition; amo_active
//                          stays 0 across the squash but the AMO never
//                          ran, so re-execute is required)
//      Notably DONE-state AMOs are NOT in this list — their memory
//      write already committed; re-executing would double-decrement.
//
//   3. pc_id_i if non-zero — the ID-stage instruction is about to
//      enter IE; resuming there skips the just-retired IE op exactly
//      once.
//
//   4. pc_ie_i + insn_len if non-zero — ID is empty (post-redirect /
//      post-context-switch); fall back to "next PC after the IE op".
//      Insn-length-aware via c_valid_ie_i so RVC + RV32 both work.
//
//   5. pc_out_i — last resort right after wb_xret_fire when the whole
//      pipeline is empty; pc_out_i holds the xret target latched on
//      the xret commit cycle.
wire async_use_branch = branch_taken_i | branch_taken_h_i;
wire async_use_ie     = amo_active_i | mmu_d_stall_i | amo_pending_i;
// Insn-length-aware "next-PC of Z" for the pc_id=0 fallback.
// When the ID stage is empty (post-redirect / post-context-switch),
// pc_id is held at 0 and the legacy fallback used pc_ie raw —
// re-executing Z after sret. Use pc_ie + insn_len so we correctly
// skip Z (which has already retired through IMEM/IWB by the time
// the trap commits, in the non-AMO/non-PTW case).
wire [31:0] pc_ie_next   = pc_ie_i + (c_valid_ie_i ? 32'd2 : 32'd4);
wire [31:0] pc_for_async = async_use_branch    ? branch_recovery_target_i :
                           async_use_ie        ? pc_ie_i :
                           (pc_id_i != 32'h0)  ? pc_id_i :
                           (pc_ie_i != 32'h0)  ? pc_ie_next :
                                                 pc_out_i;

// Phase 4.14b (Bug 29): PC for IE-stage synchronous data faults.
// When a DTLB miss triggers a PTW walk, ie_stall holds pc_ie at the
// faulting load/store. But on the exact cycle mmu_d_stall drops and
// the fault fires, the IE wall may clear pc_ie to 0 (interrupt_valid
// flush).
//
// Bug 29b: the original fallback `pc_out_i` is the FETCH-stage PC
// (several instructions ahead of IE) — NOT the faulting load's PC.
// Using it as sepc causes the kernel to return past the faulting load,
// which never re-executes, and the same address re-faults from a
// later instruction → infinite page-fault loop.
//
// Fix: latch pc_ie_i into a holding register whenever it's non-zero
// (= a real instruction is in IE, not a bubble). This register
// survives through the PTW stall and is available as a fallback
// when the fault fires with pc_ie already cleared to 0.
logic [31:0] pc_ie_saved_q;
always_ff @(posedge clk_i or posedge rst_i) begin
    if (rst_i)
        pc_ie_saved_q <= 32'h0;
    else if (pc_ie_i != 32'h0)
        pc_ie_saved_q <= pc_ie_i;
end
wire [31:0] pc_for_ie = (pc_ie_i != 32'h0) ? pc_ie_i : pc_ie_saved_q;

// Page fault address: data fault has priority over instruction fault
wire [31:0] page_fault_addr = data_page_fault_i ? data_fault_addr_i : insn_fault_addr_i;

// ═══════════════════════════════════════════════════════════════════════════
// Async interrupt qualification
// ═══════════════════════════════════════════════════════════════════════════
// M-mode interrupt pending & enabled
wire external_valid   = ip_i[11] & ie_i[11];
wire software_valid   = ip_i[3]  & ie_i[3];
wire timer_valid      = ip_i[7]  & ie_i[7];
// S-mode interrupt pending & enabled
wire s_external_valid = ip_i[9]  & ie_i[9];
wire s_software_valid = ip_i[1]  & ie_i[1];
wire s_timer_valid    = ip_i[5]  & ie_i[5];

// Global interrupt enable
wire m_ie_global = (priv_i < 2'b11) || status_i[3];
wire s_ie_global = (priv_i < 2'b01) || (priv_i == 2'b01 && status_i[1]);

wire m_async_valid = (external_valid | software_valid | timer_valid) & m_ie_global;
wire s_async_valid = (s_external_valid | s_software_valid | s_timer_valid) & s_ie_global;

// Phase 4.16: defer the async trap when the pipeline is in a "drain"
// gap with no instruction at IE or ID but the fetch path has unretired
// instructions in flight. Smoking gun: post-WFI return path c.jr ra
// retires, then PC redirects back to default_idle_call's csrrsi at
// c01c31da, but the timer fires before csrrsi reaches IE/ID. With
// pc_id=pc_ie=0, the legacy fallback used pc_out_i = c01c31de (the
// fetch-stage PC, AHEAD of the in-flight csrrsi) as epc, which made
// the kernel resume PAST csrrsi. SIE never got set → do_idle's
// SIE-check WARN_ON fired.
//
// Holding async_valid until pc_id or pc_ie populates lets the
// pipeline finish draining; the trap then captures pc_id (= csrrsi's
// PC) and the kernel correctly re-executes csrrsi after sret.
//
// Holding the async pending is harmless: the level-signal interrupt
// stays asserted until the kernel handles it, so we just delay
// commitment by 1-2 cycles. xret/sret post-commit fetch (the original
// reason for pc_out_i fallback in Phase 4.13c) still works because
// pc_id eventually populates from the post-xret fetch.
wire pipeline_has_target = (pc_id_i != 32'h0) || (pc_ie_i != 32'h0);
wire async_valid   = (m_async_valid | s_async_valid) & pipeline_has_target;

// IE-stage CSR invalid: unimplemented CSR accessed → illegal instruction from IE
// Safe without stale_ie guard: stale instructions have csr_cmd=NOP, so CSR unit
// won't flag invalid for them.
assign ie_csr_illegal = ie_csr_invalid_i;

// Sync exception aggregate
wire sync_exception = misalign_load | misalign_store | misalign_amo |
                      ecall_valid | ebreak_valid | illegal_valid |
                      ie_csr_illegal |
                      insn_page_fault_i | load_page_fault | store_page_fault |
                      insn_access_fault_i | load_access_fault | store_access_fault;

// Ecall cause depends on current privilege level
logic [7:0] ecall_cause;
always_comb begin
    case (priv_i)
        2'b00:   ecall_cause = 8'd8;
        2'b01:   ecall_cause = 8'd9;
        default: ecall_cause = 8'd11;
    endcase
end

// ═══════════════════════════════════════════════════════════════════════════
// Exception/interrupt priority and cause/epc/mtval selection
// ═══════════════════════════════════════════════════════════════════════════
// Priority: IE exceptions (older) > IF/ID exceptions > async interrupts
logic [7:0]  cause_code;
logic        is_interrupt;
logic [31:0] epc_out;
logic [31:0] mtval_out;

always_comb begin
    // IE-stage data access faults (PMP) — highest priority
    if (load_access_fault) begin
        cause_code = 8'd5;  epc_out = pc_for_ie; mtval_out = data_access_fault_addr_i; is_interrupt = 1'b0;
    end else if (store_access_fault) begin
        cause_code = 8'd7;  epc_out = pc_for_ie; mtval_out = data_access_fault_addr_i; is_interrupt = 1'b0;
    end else if (load_page_fault) begin
        cause_code = 8'd13; epc_out = pc_for_ie; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (store_page_fault) begin
        cause_code = 8'd15; epc_out = pc_for_ie; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (misalign_load) begin
        cause_code = 8'd4;  epc_out = pc_for_ie; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (misalign_store || misalign_amo) begin
        cause_code = 8'd6;  epc_out = pc_for_ie; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (ie_csr_illegal) begin
        cause_code = 8'd2;  epc_out = pc_for_ie; mtval_out = 32'h0; is_interrupt = 1'b0;
    // IF/ID-stage instruction access fault (PMP) — before page fault
    end else if (insn_access_fault_i) begin
        cause_code = 8'd1;  epc_out = pc_for_id; mtval_out = insn_access_fault_addr_i; is_interrupt = 1'b0;
    end else if (insn_page_fault_i) begin
        cause_code = 8'd12; epc_out = pc_for_id; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (illegal_valid) begin
        cause_code = 8'd2;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (ecall_valid) begin
        cause_code = ecall_cause; epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (ebreak_valid) begin
        // Per spec mtval-on-breakpoint is implementation-defined (0 or the
        // breakpoint VA). Spike writes 0; matching that lets RISCOF's
        // arch_test M-mode handler short-circuit to cleanup_epilogs on a
        // tval∉code-segment check (otherwise the handler resumes past
        // EBREAK and the test_A_res writes diverge from the reference).
        cause_code = 8'd3;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (external_valid && m_ie_global) begin
        cause_code = 8'd11; epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (software_valid && m_ie_global) begin
        cause_code = 8'd3;  epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (timer_valid && m_ie_global) begin
        cause_code = 8'd7;  epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_external_valid && s_ie_global) begin
        cause_code = 8'd9;  epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_software_valid && s_ie_global) begin
        cause_code = 8'd1;  epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_timer_valid && s_ie_global) begin
        cause_code = 8'd5;  epc_out = pc_for_async; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else begin
        cause_code = 8'd0;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Outputs
// ═══════════════════════════════════════════════════════════════════════════
assign trap_valid_o = sync_exception | async_valid;
assign async_trap_o = async_valid;
assign epc_o        = epc_out;
assign ecause_o     = {is_interrupt ? 24'h800000 : 24'h0, cause_code};
assign mtval_o      = mtval_out;

// ── Trap delegation ─────────────────────────────────────────────────────
logic delegate_to_s;
always_comb begin
    if (priv_i == 2'b11)
        delegate_to_s = 1'b0;
    else if (is_interrupt)
        delegate_to_s = mideleg_i[cause_code[4:0]];
    else
        delegate_to_s = medeleg_i[cause_code[4:0]];
end
assign trap_to_s_o = delegate_to_s;

// ── Handler address ─────────────────────────────────────────────────────
wire [31:0] base_addr = {vec_i[31:2], 2'b00};
// cause_code is 8 bits (always < 64 in practice), shift up by 2 →
// max 10 bits used. Pad to 32 explicitly (was 24'b0 + 8 + 2 = 34 bits,
// truncation warned by Verilator).
assign handler_addr_o = (vec_i[0] && is_interrupt) ? (base_addr + {22'b0, cause_code, 2'b00}) : base_addr;

assign interrupt_src_o = {20'd0, ext_itr_i, 3'b000, timer_itr_i, 3'b000, soft_itr_i, 3'b000};

// ═══════════════════════════════════════════════════════════════════════════
// Phase 4 trap revamp: pure level-signal interrupt outputs
// ═══════════════════════════════════════════════════════════════════════════
// These do NOT depend on the IE pipeline state (no sync_exception
// arbitration, no insn_valid_id gate). They report "is there an
// enabled, pending interrupt waiting for the current priv level"
// — wb_trap_unit at IWB will combine this with insn_valid_iwb_i to
// decide whether to fire it on the carrier instruction.
//
// Cause encoding mirrors the legacy ecause_o[4:0] (IRQ bits dropped):
//   M-ext = 11, M-soft = 3, M-timer = 7
//   S-ext = 9,  S-soft = 1, S-timer = 5
// Priority order matches the legacy precedence (M before S, ext before
// soft before timer within each priv).
logic [4:0] async_cause_only;
logic       async_to_s_only;
always_comb begin
    async_cause_only = 5'd0;
    async_to_s_only  = 1'b0;
    if (external_valid && m_ie_global) begin
        async_cause_only = 5'd11;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[11];
    end else if (software_valid && m_ie_global) begin
        async_cause_only = 5'd3;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[3];
    end else if (timer_valid && m_ie_global) begin
        async_cause_only = 5'd7;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[7];
    end else if (s_external_valid && s_ie_global) begin
        async_cause_only = 5'd9;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[9];
    end else if (s_software_valid && s_ie_global) begin
        async_cause_only = 5'd1;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[1];
    end else if (s_timer_valid && s_ie_global) begin
        async_cause_only = 5'd5;
        async_to_s_only  = (priv_i != 2'b11) && mideleg_i[5];
    end
end
assign interrupt_pending_o = async_valid;
assign interrupt_cause_o   = async_cause_only;
assign interrupt_to_s_o    = async_to_s_only;

endmodule
