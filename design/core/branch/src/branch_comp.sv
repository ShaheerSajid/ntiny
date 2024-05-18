import common_pkg::*;
import core_pkg::*;

module branch_comp
		(
			input logic [31:0] a_i,b_i,
			input br_cond_e br_cond_i,
			input rv32_opcodes_e opcode_i,
			output onebit_sig_e branch_taken_o
		);

	onebit_sig_e brltu;
	onebit_sig_e brlt;
	onebit_sig_e breq;

	assign brltu = onebit_sig_e'(a_i<b_i);
	assign brlt = onebit_sig_e'($signed(a_i)<$signed(b_i));
	assign breq = onebit_sig_e'(a_i==b_i);


	always_comb
	begin
		case(br_cond_i)
			BEQ : branch_taken_o = onebit_sig_e'(breq);
			BNE : branch_taken_o = onebit_sig_e'(~breq);
			BLT : branch_taken_o = onebit_sig_e'(brlt);
			BGE : branch_taken_o = onebit_sig_e'(~brlt);
			BLTU: branch_taken_o = onebit_sig_e'(brltu);
			BGEU: branch_taken_o = onebit_sig_e'(~brltu);
			default: branch_taken_o = onebit_sig_e'(opcode_i == JUMP || opcode_i == JUMP_R);
		endcase
	end

endmodule

