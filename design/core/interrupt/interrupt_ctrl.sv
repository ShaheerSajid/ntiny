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

  
  output interrupt_valid_o,
  output [31:0]handler_addr_o,
  output [31:0]ecause_o,
  output [31:0]epc_o,
  output [31:0]interrupt_src_o

);

/*
External = 11
Software = 3
Timer = 7
*/
logic [7:0] excpetion_code;
//check for interrupts
logic external_valid;
logic software_valid;
logic timer_valid;

assign external_valid = ip_i[11] & ie_i[11];
assign software_valid = ip_i[3] & ie_i[3];
assign timer_valid    = ip_i[7] & ie_i[7];

//generate address and valid
always_comb begin
  if(external_valid)
    excpetion_code = 8'd11;
  else if(software_valid)
    excpetion_code = 8'd3;
  else if(timer_valid)
    excpetion_code = 8'd7;
  else
    excpetion_code = 8'd0;
end

assign interrupt_valid_o = (external_valid | software_valid | timer_valid) & status_i[3];
assign epc_o = pc_i;
assign ecause_o = {24'h800000, excpetion_code};
assign handler_addr_o = (vec_i[0])?  vec_i[31:2] : vec_i[31:2] + (excpetion_code << 2);

assign interrupt_src_o = {20'd0,ext_itr_i,3'b000,timer_itr_i,3'b000,soft_itr_i,3'b000};

endmodule
