import common_pkg::*;
import core_pkg::*;

module c_controller
(
	input clk_i,
	input reset_i,
	input onebit_sig_e stall_i,
	input onebit_sig_e flush_i,
  input interrupt_true_i,
	input pc_sel_e pc_sel_i,
	input [31:0]instruction_i,
	input onebit_sig_e branch_taken_i,
	input [31:0] branch_target_address_i,
  input [31:0] branch_addr_i,
	input [31:0] dpc_i,
  input [31:0] handler_addr_i,
  input [31:0] epc_i,

	output [31:0] instruction_addr_o,
	output logic [31:0] instruction_o,
	output [31:0] next_instruction_addr_o,
	output onebit_sig_e c_stall_o,
	output onebit_sig_e c_valid_o,
	output onebit_sig_e busy_o
);

logic [15:0] c_dec_in;
logic [15:0] ins_buffer;
logic [31:0] ins_extended;
logic [31:0] apc_in;
logic [31:0] apc_out;
bit apc_sel;
bit ins_buffer_en;

enum int unsigned {ALIGN = 0, MISALIGN = 1, BRANCH = 2} p_state, n_state;
always_comb
begin
	case(pc_sel_i)
		PC_plus_4: apc_in = apc_sel?apc_out + 2 : apc_out + 4;
		BRANCH_PC: apc_in = branch_addr_i;
    INTERRUPT: apc_in = handler_addr_i;
    RET      : apc_in = epc_i;
		BRANCH_DPC:apc_in = dpc_i;
		default:   apc_in = apc_out + 4;
	endcase
end
`ifdef DV_TRACER
program_counter #(.DEFAULT(32'h80000000)) c_program_counter_inst
`else
	`ifdef BOOT
		program_counter #(.DEFAULT(32'h80000000)) c_program_counter_inst
	`else
		program_counter #(.DEFAULT(32'h00000000)) c_program_counter_inst
	`endif
`endif
(
	.clk_i		(clk_i),
	.reset_i	(reset_i),
	.stall_i	(interrupt_true_i ? 1'b0 : stall_i || (p_state == BRANCH && instruction_i[17:16] == 2'b11)),
	.pc_in_i	(apc_in),
	.pc_out_o	(apc_out)
);

c_dec c_dec_inst
(
	.ins_16(c_dec_in),
	.ins_32(ins_extended)
);

always_ff@(posedge clk_i or posedge reset_i)
begin
		if(reset_i)
			p_state <= ALIGN;
		else if(flush_i)
			p_state <= ALIGN;
		else if(!stall_i)
			p_state <= n_state;
end
always_comb
begin
	case(p_state)
		ALIGN: 	begin
					if(instruction_i[1:0] == 2'b11 || instruction_i == 0)
					begin
						c_dec_in = 16'd0;
						instruction_o = instruction_i;
						apc_sel = 1'b0;
						ins_buffer_en = 1'b0;
						if(branch_taken_i == TRUE && branch_target_address_i[1:0] == 2'b10)
							n_state = BRANCH;
						else
							n_state = ALIGN;
						c_stall_o = FALSE;
						c_valid_o = FALSE;
					end
					else
					begin
						c_dec_in = instruction_i[15:0];
						instruction_o = ins_extended;
						apc_sel = 1'b1;
						ins_buffer_en = 1'b1;
						if(branch_taken_i == TRUE && branch_target_address_i[1:0] == 2'b10)
							n_state = BRANCH;
						else if(branch_taken_i == TRUE && (branch_target_address_i[2:0] == 3'b100 || branch_target_address_i[2:0] == 3'b000))
							n_state = ALIGN;
						else
							n_state = MISALIGN;
						c_stall_o = FALSE;
						c_valid_o = TRUE;
					end
				end
		MISALIGN:	begin
						if(ins_buffer[1:0] == 2'b11)
						begin
							c_dec_in = 16'd0;
							instruction_o = {instruction_i[15:0], ins_buffer};
							apc_sel = 1'b0;
							ins_buffer_en = 1'b1;
							if(branch_taken_i == TRUE && branch_target_address_i[1:0] == 2'b10)
								n_state = BRANCH;
							else if(branch_taken_i == TRUE && (branch_target_address_i[2:0] == 3'b100 || branch_target_address_i[2:0] == 3'b000))
								n_state = ALIGN;
							else
								n_state = MISALIGN;
							c_stall_o = FALSE;
							c_valid_o = FALSE;
						end
						else
						begin
							c_dec_in = ins_buffer;
							instruction_o = ins_extended;
							apc_sel = 1'b1;
							ins_buffer_en = 1'b0;
							if(branch_taken_i == TRUE && branch_target_address_i[1:0] == 2'b10)
								n_state = BRANCH;
							else
								n_state = ALIGN;
							c_stall_o = (branch_taken_i == TRUE)? FALSE : TRUE;
							c_valid_o = TRUE;
						end
					end
//if instruction is 16bit dont need to save it in buffer and then decode it
		BRANCH:		begin
					if(instruction_i[17:16] == 2'b11)
					begin
						c_dec_in = 16'd0;
						instruction_o = 0;
						apc_sel = 1'b0;
						ins_buffer_en = 1'b1;
						c_stall_o = FALSE;
						n_state = MISALIGN;
						c_valid_o = FALSE;
					end
					else
					begin
						c_dec_in = instruction_i[31:16];
						instruction_o = ins_extended;
						apc_sel = 1'b1;
						ins_buffer_en = 1'b0;
						c_stall_o = FALSE;
						if(branch_taken_i == TRUE && branch_target_address_i[1:0] == 2'b10)
							n_state = BRANCH;
						else 
							n_state = ALIGN;
						c_valid_o = TRUE;
					end
					end
		default:	begin
					c_dec_in = 16'd0;
					instruction_o = 0;
					apc_sel = 1'b0;
					ins_buffer_en = 1'b0;
					c_stall_o = FALSE;
					n_state = ALIGN;
					c_valid_o = FALSE;
					end
	endcase
end
assign instruction_addr_o = apc_out;
assign next_instruction_addr_o = apc_in;
assign busy_o = onebit_sig_e'(p_state == BRANCH);

always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i)
		ins_buffer <= 0;
	else if(flush_i)
		ins_buffer <= 0;
	else if(!stall_i)
		if(ins_buffer_en)
			ins_buffer <= instruction_i[31:16];
end

endmodule