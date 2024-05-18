import common_pkg::*;
import core_pkg::*;

module branch_target_address
		(
			input logic [31:0] pc_i,rs1_i,imm_i,
			input rv32_opcodes_e opcode_i,
			output logic [31:0] target_o
		);

	logic [31:0] alu;
	
	always_comb
	begin
		if(opcode_i == JUMP_R)
		begin
			alu = $signed(rs1_i) + $signed(imm_i);
			target_o = {alu[31:1], 1'b0};
		end
		else
		begin
			alu = $signed(pc_i) + $signed(imm_i<<1);
			target_o = alu;
		end
	end

endmodule
