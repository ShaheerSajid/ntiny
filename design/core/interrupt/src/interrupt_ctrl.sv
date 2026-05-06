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
    input        branch_taken_i,       // IE-stage branch mispredict (flush incoming)
    // Where the branch should resume on async-trap epc capture. This is
    // the SAME signal core_top uses to redirect fetch on mispredict —
    //   pred=T, actual=NT  -> fall-through (predicted_pc_ie)
    //   pred=T, actual=T (wrong target) -> actual taken target
    //   pred=NT, actual=T  -> actual taken target
    // Using the raw "branch_target_address" (always the would-be taken
    // target) here was wrong for the pred=T,actual=NT case: a timer
    // interrupt firing on the same cycle as the loop-exit bne would
    // capture epc = taken target = loop top, then sret resumed inside
    // the loop instead of the fall-through, looping forever (run #2 of
    // Phase 2a, kernfs_name_hash on "cpu_slabs").
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
    // amo_unit.active_o (AMO_READ || AMO_WRITE) — true ONLY when AMO
    // is mid-bus-FSM and uncommitted. Excludes IDLE (no AMO) and DONE
    // (memory write already committed). Used to gate sepc=pc_ie for
    // re-execute on async trap so the AMO restart from scratch works
    // (amo_unit aborts to IDLE on flush_i = interrupt_valid).
    input                amo_active_i,

    // ── IE-stage uncommitted indicator ──────────────────────────────────
    // High when the IE-stage instruction has not yet committed (multi-
    // cycle op like AMO/MUL/DIV/PTW still working). Used to choose
    // pc_ie vs pc_id for async-trap epc.
    input                ie_stall_i,

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

assign exception_from_ie_o = misalign_amo | ie_csr_illegal;

// ═══════════════════════════════════════════════════════════════════════════
// ID-stage exception gating (only fire on valid, non-illegal instructions)
// ═══════════════════════════════════════════════════════════════════════════
// Phase 4.10c: suppress ID-stage sync exceptions when the IE instruction
// is a mispredicted branch. The ID instruction is on the speculative
// fall-through path and will be flushed by the branch redirect. Without
// this, ebreak/ecall/illegal in the shadow of a taken branch fires a
// trap before the branch redirect can flush it (trap > branch priority
// in the redirect arbiter). Linux BUG_ON() ebreak after c.beqz was
// firing because the ebreak was consumed before the branch resolved.
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

// PC for async interrupts: when the fetch buffer is between entries
// (aligner gap cycle), pc_id_i drops to 0 while the previous
// instruction has already moved to IE. If the interrupt fires on
// that exact gap cycle, mepc must be the IE-stage PC (the oldest
// in-flight instruction that the flush will kill) so it gets
// re-executed after mret. When pc_id IS valid, it's the ID-stage
// instruction about to enter IE — that's the standard mepc.
//
// Phase 4.13c: when BOTH pc_id_i and pc_ie_i are 0 (the cycle
// right after a wb_xret_fire — pipeline is freshly starting to
// fetch the post-xret target, no instruction has reached IE yet),
// fall back to pc_out_i which holds the xret target latched into
// program_counter on the xret commit cycle. Without this, an
// async interrupt firing one cycle after sret/mret saved mepc=0
// and the M-mode handler returned to PC=0 — causing a NULL fetch
// page fault later in S-mode.
//
// Phase 4.15: wrong-path async epc fix. When a mispredicted
// branch/jump is in IE this cycle (branch_taken_i asserted),
// pc_id_i holds the WRONG-PATH sequential next-fetch — IF hasn't
// seen the redirect yet. Using pc_id as epc would resume the
// kernel on the wrong path after sret. Smoking gun (Linux boot,
// 2026-04-28): c.j @ c0151e3c in crng_make_state was in EX with
// branch_v=1 btgt=c0151dae, but trap captured epc=c0151e3e
// (sequential past c.j) → kernel re-ran wrong path → corrupted
// callee-saved regs → BUG_ON in random.c, ra=0xffff0a00 etc.
//
// Fix v2 (2026-04-28): for IE-stage mispredicting branch/jump
// (branch_taken_i), use branch_recovery_target_i — same signal core_top
// feeds to fetch on mispredict. Was branch_target_address_i which was
// always the taken target; broken for pred=T/actual=NT. Rationale:
//
//   - The IE-stage branch's writeback (rd ← PC+4 for jal/jalr)
//     propagates through IMEM→IWB and fires normally a couple
//     cycles after the trap captures epc. So rd is already
//     written by the time the kernel reads pt_regs.
//   - If we set epc = pc_ie and re-execute the branch after
//     sret, jalr-with-rs1==rd reads a corrupted rs1 (the
//     just-written link value) and computes the wrong target.
//   - Setting epc = branch_target_address makes the kernel resume
//     AT the branch destination, exactly as if the branch had
//     executed completely. PC = target, rd = link. Effectively
//     "the branch executed once, then trapped".
//
// For non-branch IE-stage instructions, use pc_id (legacy):
// their writeback fires through IWB normally, so the kernel
// resumes past them. CSR-write commits across trap entry are
// handled by combining csr_cmd with trap entry effects in
// csr_unit (see _MSTATUS update logic).
//
// Phase 4.16 (2026-04-28): in-flight AMO must re-execute after sret.
// AMO instructions are multi-cycle in IE (FSM: IDLE→READ→WRITE→DONE).
// During those cycles, ie_stall is asserted and the AMO ctrl_bus
// holds at the IE register. If an async interrupt fires before the
// AMO reaches DONE, amo_unit gets flush_i=interrupt_valid and aborts
// (state→IDLE), so the memory write never happens. With the legacy
// epc=pc_id, sret resumes at the instruction AFTER the AMO and the
// atomic op is silently skipped. Smoking gun (Linux boot, chr_dev_init
// hang): up_write's amoadd.w at c002d600 was aborted by an M-timer
// interrupt; rwsem.count was never decremented; init then blocked
// in __down_write forever waiting for a release that already
// "happened" but had no effect.
//
// Fix: when ie_stall is asserted, the IE-stage instruction has
// NOT yet committed (AMO mid-FSM, MUL/DIV in flight, PTW pending,
// etc). On async trap, capture epc=pc_ie so it re-executes after
// sret. When ie_stall is low, the IE-stage op IS completing this
// cycle (its writeback already in flight to IMEM/IWB) — use pc_id
// so we don't double-execute. Originally tried gating on
// ie_amo_op != NO_AMO_OP, but that stayed asserted in the AMO's
// DONE cycle (memory write already committed) and caused
// double-decrement of rwsem.count, leading to a second hang
// downstream. ie_stall is exactly true while the IE op is
// uncommitted, false once it's retiring. amo_unit's reservation
// register is invalidated on flush so LR/SC pairs restart cleanly.
wire async_use_branch = branch_taken_i;
// async_use_ie originally was `ie_stall_i` (covers AMO+MUL/DIV+PTW+
// dmem_busy stalls). That gate was over-broad: when ie_stall=1 from
// dmem_busy on a normal load/store/ALU op, the IMEM-stage register-
// wall has ALREADY captured Z's exec_result via the imem_stall=0
// quirk. Setting sepc=pc_ie there made Z re-execute after sret,
// doubling its effects (e.g. mntput's `addi sp,-16` decremented sp
// by 32 → terminate_walk's `lw ra, 28(sp)` loaded ra=0xfffff000
// → crash; preempt_disable in worker boot doubled → preempt_count=2
// → "scheduling while atomic" BUG).
//
// Narrow the gate to `amo_active_i` only — `(state == AMO_READ ||
// state == AMO_WRITE)` from amo_unit. AMO is the one IE-stage op
// where amo_unit explicitly aborts to IDLE on flush, leaving the
// memory operation uncommitted; for all other ie_stall sources, Z
// has either already retired through IMEM/IWB or its rd writeback
// will not happen (so sepc=pc_id correctly skips Z one-time).
//
// Excluding DONE state matters: amo_unit's memory write is already
// committed in DONE, so re-executing would double-decrement (the
// chr_dev_init rwsem.count regression the author warned about when
// they tried the broader `ie_amo_op != NO_AMO_OP` gate).
wire async_use_ie     = amo_active_i;
wire [31:0] pc_for_async = async_use_branch    ? branch_recovery_target_i :
                           async_use_ie        ? pc_ie_i :
                           (pc_id_i != 32'h0)  ? pc_id_i :
                           (pc_ie_i != 32'h0)  ? pc_ie_i :
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
wire ie_csr_illegal = ie_csr_invalid_i;

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
        cause_code = 8'd3;  epc_out = pc_for_id; mtval_out = pc_for_id; is_interrupt = 1'b0;
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
