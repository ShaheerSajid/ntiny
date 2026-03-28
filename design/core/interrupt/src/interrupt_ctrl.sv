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

  // synchronous exception sources
  input ecall_i,
  input ebreak_i,
  input misalign_load_i,
  input misalign_store_i,
  input [31:0] pc_ie_i,
  input [31:0] fault_addr_i,

  output trap_valid_o,
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
logic external_valid;
logic software_valid;
logic timer_valid;
logic async_valid;

assign external_valid = ip_i[11] & ie_i[11];
assign software_valid = ip_i[3] & ie_i[3];
assign timer_valid    = ip_i[7] & ie_i[7];
assign async_valid    = (external_valid | software_valid | timer_valid) & status_i[3];

// sync exceptions (always taken, independent of MIE)
logic sync_exception;
assign sync_exception = misalign_load_i | misalign_store_i | ecall_i | ebreak_i;

// priority: misalign (IE, earlier in program order) > ecall/ebreak (ID) > async interrupts
always_comb begin
  if (misalign_load_i) begin
    cause_code   = 8'd4;
    epc_out      = pc_ie_i;
    mtval_out    = fault_addr_i;
    is_interrupt = 1'b0;
  end else if (misalign_store_i) begin
    cause_code   = 8'd6;
    epc_out      = pc_ie_i;
    mtval_out    = fault_addr_i;
    is_interrupt = 1'b0;
  end else if (ecall_i) begin
    cause_code   = 8'd11;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b0;
  end else if (ebreak_i) begin
    cause_code   = 8'd3;
    epc_out      = pc_i;
    mtval_out    = pc_i;
    is_interrupt = 1'b0;
  end else if (external_valid) begin
    cause_code   = 8'd11;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (software_valid) begin
    cause_code   = 8'd3;
    epc_out      = pc_i;
    mtval_out    = 32'h0;
    is_interrupt = 1'b1;
  end else if (timer_valid) begin
    cause_code   = 8'd7;
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

// MTVEC: vectored mode only for interrupts, exceptions always use BASE
wire [31:0] base_addr = {vec_i[31:2], 2'b00};
assign handler_addr_o = (vec_i[0] && is_interrupt) ? (base_addr + {24'b0, cause_code, 2'b00}) : base_addr;

assign interrupt_src_o = {20'd0,ext_itr_i,3'b000,timer_itr_i,3'b000,soft_itr_i,3'b000};

endmodule
