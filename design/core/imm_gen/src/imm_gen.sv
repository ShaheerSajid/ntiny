import common_pkg::*;
import core_pkg::*;

module imm_gen
(
  input logic[31:0]instruction_i,
  input imm_sel_e imm_sel_i,
  output var logic[31:0]imm_o
);

always_comb
  begin
    case (imm_sel_i)
      I_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31:20]};
      S_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31:25],instruction_i[11:7]};
      B_imm: imm_o = {{20{instruction_i[31]}},instruction_i[31],instruction_i[7],instruction_i[30:25],instruction_i[11:8]};
      J_imm: imm_o = {{12{instruction_i[31]}},instruction_i[31], instruction_i[19:12],instruction_i[20],instruction_i[30:21]};
		  U_imm: imm_o = {{instruction_i[31:12]},12'b000000000000};
      CSR_imm: imm_o = {27'b000000000000000000000000000, {instruction_i[19:15]}};
		  default: imm_o = 0;
    endcase
  end
endmodule
