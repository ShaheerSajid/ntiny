import common_pkg::*;
import core_pkg::*;

module interrupt_ctrl
(
	input clk_i,
  input rst_i,

  //interrupt sources
  input ext_itr_i,
  input timer_itr_i,
  input soft_itr_i,

  input [31:0]ip_i,
  input [31:0]ie_i,
  input [31:0]vec_i,
  input [31:0]status_i,
  input [31:0]pc_i,

  // privilege and delegation
  input [1:0]  priv_i,
  input [31:0] medeleg_i,
  input [31:0] mideleg_i,

  // synchronous exception sources
  input ecall_i,
  input ebreak_i,
  input illegal_insn_i,
  input misalign_load_i,
  input misalign_store_i,
  input misalign_amo_i,
  // page faults from MMU
  input insn_page_fault_i,
  input load_page_fault_i,
  input store_page_fault_i,
  input [31:0] page_fault_addr_i,
  input [31:0] pc_ie_i,
  input [31:0] fault_addr_i,

  output trap_valid_o,
  output trap_to_s_o,
  output [31:0]handler_addr_o,
  output [31:0]ecause_o,
  output [31:0]epc_o,
  output [31:0]mtval_o,
  output [31:0]interrupt_src_o

);

logic [7:0] cause_code;
logic is_interrupt;
logic [31:0] epc_out;
logic [31:0] mtval_out;

// async interrupt qualification
// M-mode interrupts: MEIP(11), MSIP(3), MTIP(7)
// S-mode interrupts: SEIP(9), SSIP(1), STIP(5)
logic external_valid;
logic software_valid;
logic timer_valid;
logic s_external_valid;
logic s_software_valid;
logic s_timer_valid;
logic async_valid;

// M-mode interrupt pending & enabled
assign external_valid = ip_i[11] & ie_i[11];
assign software_valid = ip_i[3] & ie_i[3];
assign timer_valid    = ip_i[7] & ie_i[7];

// S-mode interrupt pending & enabled
assign s_external_valid = ip_i[9] & ie_i[9];
assign s_software_valid = ip_i[1] & ie_i[1];
assign s_timer_valid    = ip_i[5] & ie_i[5];

// Global interrupt enable:
// - M-mode interrupts taken when priv < M, or priv==M && MIE
// - S-mode interrupts taken when priv < S, or priv==S && SIE
logic m_ie_global;
logic s_ie_global;
assign m_ie_global = (priv_i < 2'b11) || status_i[3];  // MIE
assign s_ie_global = (priv_i < 2'b01) || (priv_i == 2'b01 && status_i[1]);  // SIE

logic m_async_valid;
logic s_async_valid;
assign m_async_valid = (external_valid | software_valid | timer_valid) & m_ie_global;
assign s_async_valid = (s_external_valid | s_software_valid | s_timer_valid) & s_ie_global;
assign async_valid   = m_async_valid | s_async_valid;

// sync exceptions (always taken, independent of interrupt enables)
logic sync_exception;
assign sync_exception = misalign_load_i | misalign_store_i | misalign_amo_i |
                         ecall_i | ebreak_i | illegal_insn_i |
                         insn_page_fault_i | load_page_fault_i | store_page_fault_i;

// Ecall cause depends on current privilege level
logic [7:0] ecall_cause;
always_comb begin
  case (priv_i)
    2'b00:   ecall_cause = 8'd8;   // ecall from U-mode
    2'b01:   ecall_cause = 8'd9;   // ecall from S-mode
    default: ecall_cause = 8'd11;  // ecall from M-mode
  endcase
end

// priority: page faults > misalign > illegal > ecall/ebreak > interrupts
always_comb begin
  if (insn_page_fault_i) begin
    cause_code   = 8'd12;  // instruction page fault
    epc_out      = pc_i;
    mtval_out    = page_fault_addr_i;
    is_interrupt = 1'b0;
  end else if (load_page_fault_i) begin
    cause_code   = 8'd13;  // load page fault
    epc_out      = pc_ie_i;
    mtval_out    = page_fault_addr_i;
    is_interrupt = 1'b0;
  end else if (store_page_fault_i) begin
    cause_code   = 8'd15;  // store/AMO page fault
    epc_out      = pc_ie_i;
    mtval_out    = page_fault_addr_i;
    is_interrupt = 1'b0;
  end else if (misalign_load_i) begin
    cause_code   = 8'd4;
    epc_out      = pc_ie_i;
    mtval_out    = fault_addr_i;
    is_interrupt = 1'b0;
  end else if (misalign_store_i || misalign_amo_i) begin
    cause_code   = 8'd6;  // store/AMO address misaligned
    epc_out      = pc_ie_i;
    mtval_out    = fault_addr_i;
    is_interrupt = 1'b0;
  end else if (illegal_insn_i) begin
    cause_code   = 8'd2;  // illegal instruction
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b0;
  end else if (ecall_i) begin
    cause_code   = ecall_cause;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b0;
  end else if (ebreak_i) begin
    cause_code   = 8'd3;
    epc_out      = pc_i;
    mtval_out    = pc_i;
    is_interrupt = 1'b0;
  end else if (external_valid && m_ie_global) begin
    cause_code   = 8'd11;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (software_valid && m_ie_global) begin
    cause_code   = 8'd3;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (timer_valid && m_ie_global) begin
    cause_code   = 8'd7;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (s_external_valid && s_ie_global) begin
    cause_code   = 8'd9;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (s_software_valid && s_ie_global) begin
    cause_code   = 8'd1;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (s_timer_valid && s_ie_global) begin
    cause_code   = 8'd5;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else begin
    cause_code   = 8'd0;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b0;
  end
end

assign trap_valid_o = sync_exception | async_valid;
assign epc_o    = epc_out;
assign ecause_o = {is_interrupt ? 24'h800000 : 24'h0, cause_code};
assign mtval_o  = mtval_out;

// ── Trap delegation ──────────────────────────────────────────
// Delegate to S-mode when: priv < M, and the cause bit is set in medeleg/mideleg
// M-mode traps are never delegated.
logic delegate_to_s;
always_comb begin
  if (priv_i == 2'b11) begin
    // Traps from M-mode always go to M-mode
    delegate_to_s = 1'b0;
  end else if (is_interrupt) begin
    delegate_to_s = mideleg_i[cause_code[4:0]];
  end else begin
    delegate_to_s = medeleg_i[cause_code[4:0]];
  end
end

assign trap_to_s_o = delegate_to_s;

// ── Handler address ──────────────────────────────────────────
// vec_i is already selected (mtvec or stvec) by CSR unit based on trap_to_s
wire [31:0] base_addr = {vec_i[31:2], 2'b00};
assign handler_addr_o = (vec_i[0] && is_interrupt) ? (base_addr + {24'b0, cause_code, 2'b00}) : base_addr;

assign interrupt_src_o = {20'd0,ext_itr_i,3'b000,timer_itr_i,3'b000,soft_itr_i,3'b000};

endmodule
