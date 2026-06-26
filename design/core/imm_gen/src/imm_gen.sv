// ── Immediate generator ──────────────────────────────────────────────
// Pulls the immediate out of a 32-bit instruction and sign-extends it to
// 32 bits. The instruction encoding scatters the immediate bits across
// different fields depending on the format, so a single mux on imm_sel_i
// (set by the decoder) picks the right gather pattern. Pure combinational.
// See microarch doc: "Decode and execute datapath" -> imm_gen.
import common_pkg::*;
import core_pkg::*;

module imm_gen
(
  input logic[31:0]instruction_i, // the instruction word to extract from
  input imm_sel_e imm_sel_i,      // which format to decode (from decoder)
  output var logic[31:0]imm_o     // sign-extended 32-bit immediate
);

// Each case re-orders the scattered immediate bits into a contiguous value.
// instruction_i[31] is the immediate's sign bit in every format except U/CSR,
// so it is replicated to fill the upper bits (sign extension).
always_comb
  begin
    case (imm_sel_i)
      // I-type (loads, ALU-immediate, JALR): imm[11:0] = bits [31:20]
      I_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31:20]};
      // S-type (stores): imm[11:5]=[31:25], imm[4:0]=[11:7]
      S_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31:25],instruction_i[11:7]};
      // B-type (branches): imm[12|10:5|4:1|11], bit 0 is implicit 0
      B_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31],instruction_i[7],instruction_i[30:25],instruction_i[11:8]};
      // J-type (JAL): imm[20|10:1|11|19:12], bit 0 is implicit 0
      J_imm: imm_o = {{12{instruction_i[31]}},instruction_i[31], instruction_i[19:12],instruction_i[20],instruction_i[30:21]};
      // U-type (LUI/AUIPC): imm[31:12] in place, low 12 bits zero (no sign-extend)
		  U_imm: imm_o = {{instruction_i[31:12]},12'b000000000000};
      // CSR immediate: 5-bit zimm in rs1 field [19:15], zero-extended
      CSR_imm: imm_o = {27'b000000000000000000000000000, {instruction_i[19:15]}};
		  default: imm_o = 0;
    endcase
  end
endmodule
