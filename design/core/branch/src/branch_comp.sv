// ── Branch comparator ────────────────────────────────────────────────
// Decides whether a conditional branch is taken by comparing rs1 (a_i)
// and rs2 (b_i). Three primitive comparisons are computed once and reused:
// unsigned less-than, signed less-than, and equality; each branch
// condition is one of these (or its negation). For unconditional jumps
// (JUMP/JUMP_R) the default arm reports "taken". Pure combinational.
// See microarch doc: "Fetch front-end" / BPU.
import common_pkg::*;
import core_pkg::*;

module branch_comp
		(
			input logic [31:0] a_i,b_i,        // rs1, rs2
			input br_cond_e br_cond_i,          // branch condition (funct3)
			input rv32_opcodes_e opcode_i,      // for the unconditional-jump default
			output onebit_sig_e branch_taken_o  // 1 = branch/jump is taken
		);

	onebit_sig_e brltu;  // a < b  (unsigned)
	onebit_sig_e brlt;   // a < b  (signed)
	onebit_sig_e breq;   // a == b

	assign brltu = onebit_sig_e'(a_i<b_i);
	assign brlt = onebit_sig_e'($signed(a_i)<$signed(b_i));
	assign breq = onebit_sig_e'(a_i==b_i);


	// Map each condition to the right primitive (BGE/BNE/BGEU are negations).
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

