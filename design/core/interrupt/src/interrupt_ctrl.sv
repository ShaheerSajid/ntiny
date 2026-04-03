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
    input [31:0] pc_id_i,              // ID-stage PC
    input [31:0] pc_ie_i,              // IE-stage PC

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

    // ── Outputs ─────────────────────────────────────────────────────────
    output       trap_valid_o,
    output       trap_to_s_o,
    output [31:0] handler_addr_o,
    output [31:0] ecause_o,
    output [31:0] epc_o,
    output [31:0] mtval_o,
    output [31:0] interrupt_src_o,
    // Exception side-effect: suppress memory op on misalign
    output       exception_from_ie_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Misaligned access detection (IE stage)
// ═══════════════════════════════════════════════════════════════════════════
// Load/store misalignment is handled in hardware (core2avl splits into two
// aligned transactions). Only AMO misalignment still traps (RV spec requires
// aligned AMOs).
wire misalign_load  = 1'b0;  // handled in HW
wire misalign_store = 1'b0;  // handled in HW
wire misalign_amo = (ie_amo_op_i != NO_AMO_OP) && |ie_addr_lsb_i && !amo_in_progress_i;

assign exception_from_ie_o = misalign_amo | ie_csr_illegal;

// ═══════════════════════════════════════════════════════════════════════════
// ID-stage exception gating (only fire on valid, non-illegal instructions)
// ═══════════════════════════════════════════════════════════════════════════
wire ecall_valid   = ecall_raw_i  & ~illegal_insn_i & insn_valid_id_i;
wire ebreak_valid  = ebreak_raw_i & ~debug_ebreak_i & ~illegal_insn_i & insn_valid_id_i;
wire illegal_valid = illegal_insn_i & insn_valid_id_i;

// ═══════════════════════════════════════════════════════════════════════════
// Page fault separation (load vs store)
// ═══════════════════════════════════════════════════════════════════════════
wire load_page_fault  = data_page_fault_i & ~data_fault_is_store_i;
wire store_page_fault = data_page_fault_i &  data_fault_is_store_i;

// ═══════════════════════════════════════════════════════════════════════════
// PC for exception: instruction faults use saved fault address
// ═══════════════════════════════════════════════════════════════════════════
wire [31:0] pc_for_id = insn_page_fault_i ? insn_fault_addr_i : pc_id_i;

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
                      insn_page_fault_i | load_page_fault | store_page_fault;

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
    if (load_page_fault) begin
        cause_code = 8'd13; epc_out = pc_ie_i; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (store_page_fault) begin
        cause_code = 8'd15; epc_out = pc_ie_i; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (misalign_load) begin
        cause_code = 8'd4;  epc_out = pc_ie_i; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (misalign_store || misalign_amo) begin
        cause_code = 8'd6;  epc_out = pc_ie_i; mtval_out = ie_fault_addr_i; is_interrupt = 1'b0;
    end else if (ie_csr_illegal) begin
        cause_code = 8'd2;  epc_out = pc_ie_i; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (insn_page_fault_i) begin
        cause_code = 8'd12; epc_out = pc_for_id; mtval_out = page_fault_addr; is_interrupt = 1'b0;
    end else if (illegal_valid) begin
        cause_code = 8'd2;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (ecall_valid) begin
        cause_code = ecall_cause; epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end else if (ebreak_valid) begin
        cause_code = 8'd3;  epc_out = pc_for_id; mtval_out = pc_for_id; is_interrupt = 1'b0;
    end else if (external_valid && m_ie_global) begin
        cause_code = 8'd11; epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (software_valid && m_ie_global) begin
        cause_code = 8'd3;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (timer_valid && m_ie_global) begin
        cause_code = 8'd7;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_external_valid && s_ie_global) begin
        cause_code = 8'd9;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_software_valid && s_ie_global) begin
        cause_code = 8'd1;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else if (s_timer_valid && s_ie_global) begin
        cause_code = 8'd5;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b1;
    end else begin
        cause_code = 8'd0;  epc_out = pc_for_id; mtval_out = 32'h0; is_interrupt = 1'b0;
    end
end

// ═══════════════════════════════════════════════════════════════════════════
// Outputs
// ═══════════════════════════════════════════════════════════════════════════
assign trap_valid_o = sync_exception | async_valid;
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

endmodule
