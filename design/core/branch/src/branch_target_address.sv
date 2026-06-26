// ── Branch / jump target address ─────────────────────────────────────
// Computes the destination address of a branch, JAL or JALR. Two cases:
//   JALR (JUMP_R): target = (rs1 + imm) with bit 0 cleared (ISA-required).
//   everything else (branch / JAL): target = pc + (imm << 1), i.e. a
//     PC-relative offset. The imm here is the raw B/J immediate so it is
//     shifted left by one to form the byte offset.
// Pure combinational. See microarch doc: "Fetch front-end" / BPU.
import common_pkg::*;
import core_pkg::*;

module branch_target_address
		(
			input logic [31:0] pc_i,rs1_i,imm_i, // PC, rs1 (for JALR), immediate
			input rv32_opcodes_e opcode_i,        // distinguishes JALR from the rest
			output logic [31:0] target_o          // computed target address
		);

	logic [31:0] alu;

	always_comb
	begin
		if(opcode_i == JUMP_R)
		begin
			// JALR: register-relative, force the low bit to 0 per the ISA.
			alu = $signed(rs1_i) + $signed(imm_i);
			target_o = {alu[31:1], 1'b0};
		end
		else
		begin
			// Branch / JAL: PC-relative; imm is the raw value, <<1 for bytes.
			alu = $signed(pc_i) + $signed(imm_i<<1);
			target_o = alu;
		end
	end

endmodule
