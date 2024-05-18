import common_pkg::*;
import core_pkg::*;

module alu
		(
			input logic clk_i,
			input logic	reset_i,
			input logic	stall_i,
      input logic flush_i,
			input logic [31:0] a_i,
			input logic [31:0] b_i,
			input logic [31:0] c_i,
			input alu_op_e alu_op_i,
			input mul_op_e mul_op_i,
			input bit_op_e bit_op_i,
			input float_op_e float_op_i,
			input roundmode_e roundmode_i,
			output onebit_sig_e alu_stall_o,
			output logic [31:0] result_o,
			output float_status_e float_status_o
		);

	logic [31:0] int_result;
	logic [31:0] mul_result;
	logic [31:0] bit_result;
	
	//M-extension
	wire logic [31:0] div_out, divu_out, rem_out, remu_out;
	wire logic div_start;
	wire logic div_valid;
	wire logic div_sign;
	wire logic [31:0]mulh_res;
	wire logic [31:0]mulhu_res;
	wire logic [31:0]mulhsu_res;
	
	assign div_start = (mul_op_i == DIV) || (mul_op_i == REM) || (mul_op_i == DIVU) || (mul_op_i == REMU);
	assign div_sign = (mul_op_i == DIV) || (mul_op_i == REM);

	divider divider_inst
		(
			.clk_i(clk_i),
			.stall_i(stall_i),
			.reset_i(reset_i),
      .flush_i(flush_i),
			.sign_i(div_sign),
			.start_i(div_start),
			.dividend_i(a_i),
			.divider_i(b_i),
			.quotient_o(div_out),
			.remainder_o(rem_out),
			.valid_o(div_valid)
		);

	assign mulh_res = ($signed({{32{a_i[31]}},a_i})*$signed({{32{b_i[31]}},b_i}))>>32;
	assign mulhu_res = ({32'd0,a_i}*{32'd0,b_i})>>32;
	assign mulhsu_res = ($signed({{32{a_i[31]}},a_i})*$signed({32'd0,b_i}))>>32;

	always_comb
	begin
		case(mul_op_i)
			MUL:	mul_result = $signed(a_i)*$signed(b_i);//mul
			MULH:	mul_result = mulh_res;//mulh
			MULHSU:	mul_result = mulhsu_res;//mulhsu
			MULHU:	mul_result = mulhu_res;//mulhu
			DIV:	mul_result = div_out;//div
			DIVU:	mul_result = div_out;//divu
			REM:	mul_result = rem_out;//rem
			REMU:	mul_result = rem_out;//remu
			default:mul_result = 0;
		endcase
	end


	//I-Extension
	always_comb
	begin
		case (alu_op_i)
			ADD:	int_result = a_i+b_i;//add
			SUB:	int_result = a_i-b_i;//sub
			SLL:	int_result = a_i<<b_i[4:0];//sll
			SLT:	int_result = ($signed(a_i)<$signed(b_i));//slt
			SLTU:	int_result = (a_i<b_i);//sltu
			XOR:	int_result = a_i^b_i;//xor
			SRL:	int_result = a_i>>b_i[4:0];//srl
			SRA:	int_result = $signed(a_i)>>>b_i[4:0];//srai
			OR:		int_result = a_i|b_i;//or
			AND:	int_result = a_i&b_i;//and
			PASS:	int_result = b_i;
			default:int_result = 0;
		endcase	
	end

	//bit extension zba_zbb
	logic[31:0]	out_sh1_add_o,
				out_sh2_add_o,
				out_sh3_add_o,
				out_clz_o,
				out_ctz_o,
				out_andn_o,
				out_orn_o,
				out_xnor_o,
				out_orc_o,
				out_rev8_o,
				out_cpop_o,
				out_min_o,
				out_max_o,
				out_minu_o,
				out_maxu_o,
				out_sextb_o,
				out_sexth_o,
				out_zexth_o,
				out_rol_o,
				out_ror_o;

	zba_zbb zba_zbb_inst
	(
		.in1_i(a_i),
		.in2_i(b_i), 
		.out_sh1_add_o(out_sh1_add_o),
		.out_sh2_add_o(out_sh2_add_o),
		.out_sh3_add_o(out_sh3_add_o),
		.out_clz_o(out_clz_o),
		.out_ctz_o(out_ctz_o),
		.out_andn_o(out_andn_o),
		.out_orn_o(out_orn_o),
		.out_xnor_o(out_xnor_o),
		.out_orc_o(out_orc_o),
		.out_rev8_o(out_rev8_o),
		.out_cpop_o(out_cpop_o),
		.out_min_o(out_min_o),
		.out_max_o(out_max_o),
		.out_minu_o(out_minu_o),
		.out_maxu_o(out_maxu_o),
		.out_sextb_o(out_sextb_o),
		.out_sexth_o(out_sexth_o),
		.out_zexth_o(out_zexth_o),
		.out_rol_o(out_rol_o),
		.out_ror_o(out_ror_o)
	);

	always_comb
	begin
		case(bit_op_i)
			SH1ADD:	bit_result = out_sh1_add_o;
			SH2ADD:	bit_result = out_sh2_add_o;
			SH3ADD:	bit_result = out_sh3_add_o;
			ANDN:	bit_result = out_andn_o;
			ORN:	bit_result = out_orn_o;
			XNOR:	bit_result = out_xnor_o;
			CLZ:	bit_result = out_clz_o;
			CTZ:	bit_result = out_ctz_o;
			CPOP:	bit_result = out_cpop_o;
			MAX:	bit_result = out_max_o;
			MAXU:	bit_result = out_maxu_o;
			MIN:	bit_result = out_min_o;
			MINU:	bit_result = out_minu_o;
			SEXTB:	bit_result = out_sextb_o;
			SEXTH:	bit_result = out_sexth_o;
			ZEXTH:	bit_result = out_zexth_o;
			ROL:	bit_result = out_rol_o;
			ROR,RORI:	bit_result = out_ror_o;
			ORCB:	bit_result = out_orc_o;
			REV8:	bit_result = out_rev8_o;
			default	:	bit_result = 0;
		endcase
	end

	/////////////////////////////////////////floating point
	//fpu adapter and control
	logic [31:0] fpu_result;
	logic fpu_stall;

`ifdef FPU
  
	typedef enum logic [3:0] {
	FMADD, FNMSUB, FADD, FMUL,     // ADDMUL operation group
	FDIV, FSQRT,                   // DIVSQRT operation group
	FSGNJ, FMINMAX, FCMP, FCLASSIFY, // NONCOMP operation group
	F2F, F2I, I2F, CPKAB, CPKCD  // CONV operation group
	} operation_e;

	logic [2:0][31:0] fpu_operands;

	operation_e fp_op;
	logic fp_op_mod;
	logic fpu_valid;
	logic in_valid;
	logic in_ready;


	always_comb
	begin
		case(float_op_i)
			FMADDS, FMSUBS:				fp_op = FMADD;
			FNMSUBS, FNMADDS:			fp_op = FNMSUB;
			FADDS, FSUBS:				fp_op = FADD;
			FMULS:						fp_op = FMUL;
			FDIVS:						fp_op = FDIV;
			FSQRTS:						fp_op = FSQRT;
			FSGNJS, FSGNJNS, 
			FSGNJXS, FMVXW, FMVWX:		fp_op = FSGNJ;
			FMINS, FMAXS:				fp_op = FMINMAX;
			FCVTWS, FCVTWUS:			fp_op = F2I;
			FEQS, FLTS,FLES:			fp_op = FCMP;
			FCLASSS:					fp_op = FCLASSIFY;
			FCVTSW,FCVTSWU:				fp_op = I2F;
			default:					fp_op = FADD;
		endcase

		case(float_op_i)
			FMSUBS, FNMADDS, FSUBS,
			FCVTWUS, FCVTSWU:	fp_op_mod = 1'b1;
			default: 			fp_op_mod = 1'b0;
		endcase

		case(float_op_i)
			FADDS,FSUBS:begin
							fpu_operands[0] = 0;
							fpu_operands[1] = a_i;
							fpu_operands[2] = b_i;
						end
			default:	begin
							fpu_operands[0] = a_i;
							fpu_operands[1] = b_i;
							fpu_operands[2] = c_i;
						end
		endcase
	end
//control fsm
//1. assert valid
//2. check ready
//3. deassert valid
//4. wait for out ready
//5. go to 1

	enum logic {FP_IDLE, FP_ACCESS} p_state, n_state;
	always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i)
			p_state <= FP_IDLE;
		else
			p_state <= n_state;
	end
	always_comb
	begin
		case(p_state)
			FP_IDLE: n_state = (float_op_i != NO_FP_OP)? FP_ACCESS : FP_IDLE;
			FP_ACCESS: n_state = fpu_valid? FP_IDLE : FP_ACCESS;
		endcase
	end
	assign in_valid = (p_state == FP_IDLE) && (n_state == FP_ACCESS);
	assign fpu_stall = (float_op_i != NO_FP_OP) & (~fpu_valid);

	fpnew_top fpu_inst
	(
		.clk_i(clk_i),
		.rst_ni(~reset_i),
		//  signals
		.operands_i(fpu_operands),
		.rnd_mode_i((float_op_i == FMVXW || float_op_i == FMVWX)? RUP : roundmode_i),
		.op_i(fp_op),
		.op_mod_i(fp_op_mod),
		.src_fmt_i(3'd0),
		.dst_fmt_i(3'd0),
		.int_fmt_i(2'd2),
		.vectorial_op_i(1'b0),
		.tag_i(1'b0),
		//  Handshake
		.in_valid_i(in_valid),
		.in_ready_o(in_ready),
		.flush_i(1'b0),
		//  signals
		.result_o(fpu_result),
		.status_o(float_status_o),
		.tag_o(),
		//  handshake
		.out_valid_o(fpu_valid),
		.out_ready_i(1'b1),
		// Indication of valid data in flight
		.busy_o()
	);
`else
  assign fpu_stall = 1'b0;
  assign fpu_result = 32'd0;
  assign float_status_o = 'd0;
`endif
	///////////////////////////////////////////////////////////////////////


	//output mux
	always_comb
	begin
		if(alu_op_i != NO_ALU_OP)
			result_o = int_result;
		else if(mul_op_i != NO_MUL_OP)
			result_o = mul_result;
		else if(bit_op_i != NO_BIT_OP)
			result_o = bit_result;
		else if(float_op_i != NO_FP_OP)
			result_o = fpu_result;
		else
			result_o = 0;
	end

	assign alu_stall_o = onebit_sig_e'((div_start & (~div_valid)) || fpu_stall);

endmodule


