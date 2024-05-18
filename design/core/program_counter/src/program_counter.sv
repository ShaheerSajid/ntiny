import common_pkg::*;
import core_pkg::*;

module program_counter
#(parameter DEFAULT = 0)
(
	input logic clk_i,
	input logic reset_i,
	input logic stall_i,
	input logic [31:0]pc_in_i,
	output var logic [31:0]pc_out_o
);

always_ff@(posedge clk_i or  posedge reset_i)
begin
	if (reset_i)
		begin
			pc_out_o <= DEFAULT;
		end
	else if(!stall_i)
		begin
			pc_out_o <= pc_in_i;
		end		
end
endmodule
