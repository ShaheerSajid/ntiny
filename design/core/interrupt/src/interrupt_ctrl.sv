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

    // ── IE-stage CSR invalid (unimplemented CSR accessed) ────────────────
    input                ie_csr_invalid_i,

    // ── IE-stage signals for misalign detection ─────────────────────────
    input mem_op_e       ie_mem_op_i,
    input load_store_width_e ie_ls_width_i,
    input amo_op_e       ie_amo_op_i,
    input [1:0]          ie_addr_lsb_i,    // alu_result[1:0]
    input [31:0]         ie_fault_addr_i,  // alu_result (full address for mtval)
    input                amo_in_progress_i,

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
wire [31:0] pc_for_async = (pc_id_i != 32'h0) ? pc_id_i :
                           (pc_ie_i != 32'h0) ? pc_ie_i :
                                                pc_out_i;

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
wire async_valid   = m_async_valid | s_async_valid;

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
        cause_code = 8'd5;  epc_out = pc_ie_i; mtval_out = data_access_fault_addr_i; is_interrupt = 1'b0;
    end else if (store_access_fault) begin
        cause_code = 8'd7;  epc_out = pc_ie_i; mtval_out = data_access_fault_addr_i; is_interrupt = 1'b0;
    end else if (load_page_fault) begin
        cause_code = 8'd13; epc_out = pc_ie_i; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (store_page_fault) begin
        cause_code = 8'd15; epc_out = pc_ie_i; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (misalign_load) begin
        cause_code = 8'd4;  epc_out = pc_ie_i; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (misalign_store || misalign_amo) begin
        cause_code = 8'd6;  epc_out = pc_ie_i; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (ie_csr_illegal) begin
        cause_code = 8'd2;  epc_out = pc_ie_i; mtval_out = 32'h0; is_interrupt = 1'b0;
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
assign handler_addr_o = (vec_i[0] && is_interrupt) ? (base_addr + {24'b0, cause_code, 2'b00}) : base_addr;

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
