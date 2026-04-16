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

	// Zbs — single-bit ops. Uses rs1 as in1 and b_i[4:0] as shift amount
	// (already correctly muxed by the decoder/forwarding for both reg and
	// imm forms — imm shamt sits in b_i[4:0]).
	logic [31:0] out_bclr_o, out_bext_o, out_binv_o, out_bset_o;
	zbs zbs_inst (
		.in1_i   (a_i),
		.shamt_i (b_i[4:0]),
		.bclr_o  (out_bclr_o),
		.bext_o  (out_bext_o),
		.binv_o  (out_binv_o),
		.bset_o  (out_bset_o)
	);

	// Zbc — carry-less multiply (single-cycle XOR tree).
	logic [63:0] clmul_result;
	clmul clmul_inst (
		.in1_i    (a_i),
		.in2_i    (b_i),
		.result_o (clmul_result)
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
			// Zbs (reg + imm forms share datapath)
			BCLR, BCLRI: bit_result = out_bclr_o;
			BEXT, BEXTI: bit_result = out_bext_o;
			BINV, BINVI: bit_result = out_binv_o;
			BSET, BSETI: bit_result = out_bset_o;
			// Zbc
			CLMUL:  bit_result = clmul_result[31:0];
			CLMULH: bit_result = clmul_result[63:32];
			CLMULR: bit_result = clmul_result[62:31];
			default	:	bit_result = 0;
		endcase
	end

	/////////////////////////////////////////floating point
	//fpu adapter and control
	logic [31:0] fpu_result;
	logic fpu_stall;

`ifdef FPU

	// FMVXW/FMVWX are raw bit moves — bypass the FPU entirely
	logic fpu_bypass;
	assign fpu_bypass = (float_op_i == FMVXW) || (float_op_i == FMVWX);

	// Map core_pkg::float_op_e → fp_pkg::float_op_e + op_modify[1:0]
	fp_pkg::float_op_e fp_op;
	logic [1:0] fp_op_modify;

	always_comb begin
		case (float_op_i)
			FMADDS:   begin fp_op = fp_pkg::FMADD; fp_op_modify = 2'b00; end
			FMSUBS:   begin fp_op = fp_pkg::FMADD; fp_op_modify = 2'b01; end
			FNMSUBS:  begin fp_op = fp_pkg::FMADD; fp_op_modify = 2'b10; end
			FNMADDS:  begin fp_op = fp_pkg::FMADD; fp_op_modify = 2'b11; end
			FADDS:    begin fp_op = fp_pkg::FADD;  fp_op_modify = 2'b00; end
			FSUBS:    begin fp_op = fp_pkg::FADD;  fp_op_modify = 2'b01; end
			FMULS:    begin fp_op = fp_pkg::FMUL;  fp_op_modify = 2'b00; end
			FDIVS:    begin fp_op = fp_pkg::FDIV;  fp_op_modify = 2'b00; end
			FSQRTS:   begin fp_op = fp_pkg::FDIV;  fp_op_modify = 2'b01; end
			FSGNJS:   begin fp_op = fp_pkg::FSGNJ; fp_op_modify = 2'b00; end
			FSGNJNS:  begin fp_op = fp_pkg::FSGNJ; fp_op_modify = 2'b01; end
			FSGNJXS:  begin fp_op = fp_pkg::FSGNJ; fp_op_modify = 2'b10; end
			FMINS:    begin fp_op = fp_pkg::FMIN;  fp_op_modify = 2'b00; end
			FMAXS:    begin fp_op = fp_pkg::FMAX;  fp_op_modify = 2'b00; end
			FCVTWS:   begin fp_op = fp_pkg::F2I;   fp_op_modify = 2'b01; end // signed
			FCVTWUS:  begin fp_op = fp_pkg::F2I;   fp_op_modify = 2'b00; end // unsigned
			FEQS:     begin fp_op = fp_pkg::FCMP;  fp_op_modify = 2'b01; end // eq
			FLTS:     begin fp_op = fp_pkg::FCMP;  fp_op_modify = 2'b10; end // lt
			FLES:     begin fp_op = fp_pkg::FCMP;  fp_op_modify = 2'b00; end // le
			FCLASSS:  begin fp_op = fp_pkg::FCLASS;fp_op_modify = 2'b00; end
			FCVTSW:   begin fp_op = fp_pkg::I2F;   fp_op_modify = 2'b01; end // signed
			FCVTSWU:  begin fp_op = fp_pkg::I2F;   fp_op_modify = 2'b00; end // unsigned
			default:  begin fp_op = fp_pkg::NO_FP_OP; fp_op_modify = 2'b00; end
		endcase
	end

	// NaN-box 32-bit operands to 64-bit (RISC-V ISA §11.2)
	wire [63:0] fpu_a = {32'hFFFF_FFFF, a_i};
	wire [63:0] fpu_b = {32'hFFFF_FFFF, b_i};
	wire [63:0] fpu_c = {32'hFFFF_FFFF, c_i};

	// Handshake FSM: start pulse, stall until valid, flush-safe drain
	logic fpu_valid;
	logic fpu_ready;
	logic fpu_start;

	enum logic [1:0] {FP_IDLE, FP_BUSY, FP_DRAIN} fp_state, fp_next;

	always_ff @(posedge clk_i or posedge reset_i) begin
		if (reset_i)
			fp_state <= FP_IDLE;
		else
			fp_state <= fp_next;
	end

	always_comb begin
		case (fp_state)
			FP_IDLE:  fp_next = fpu_start ? FP_BUSY : FP_IDLE;
			FP_BUSY:  fp_next = fpu_valid ? FP_IDLE :
			                    flush_i   ? FP_DRAIN : FP_BUSY;
			FP_DRAIN: fp_next = fpu_valid ? FP_IDLE : FP_DRAIN;
			default:  fp_next = FP_IDLE;
		endcase
	end

	assign fpu_start = (fp_state == FP_IDLE) && (float_op_i != NO_FP_OP)
	                   && !fpu_bypass && fpu_ready && !flush_i;
	assign fpu_stall = (float_op_i != NO_FP_OP) && !fpu_bypass
	                   && !(fp_state == FP_BUSY && fpu_valid);

	// PakFPU instance
	logic [63:0] fpu_result_64;
	fp_pkg::status_t fpu_flags;

	fp_top #(
		.FP_FORMAT  (fp_pkg::FP32),
		.INT_FORMAT (fp_pkg::INT32),
		.RISCV_MODE (1'b1)
	) fpu_inst (
		.clk_i      (clk_i),
		.rst_i      (~reset_i),      // PakFPU uses active-low reset
		.start_i    (fpu_start),
		.ready_o    (fpu_ready),
		.a_i        (fpu_a),
		.b_i        (fpu_b),
		.c_i        (fpu_c),
		.rnd_i      (fp_pkg::roundmode_e'(roundmode_i)),
		.op_i       (fp_op),
		.op_modify_i(fp_op_modify),
		.result_o   (fpu_result_64),
		.valid_o    (fpu_valid),
		.flags_o    (fpu_flags)
	);

	// Result: bypass for FMVXW/FMVWX, lower 32 bits for FPU results
	assign fpu_result = fpu_bypass ? a_i : fpu_result_64[31:0];

	// Convert fp_pkg::status_t → core_pkg::float_status_e
	assign float_status_o = fpu_bypass ? '0 : '{
		NV: onebit_sig_e'(fpu_flags.NV),
		DZ: onebit_sig_e'(fpu_flags.DZ),
		OF: onebit_sig_e'(fpu_flags.OF),
		UF: onebit_sig_e'(fpu_flags.UF),
		NX: onebit_sig_e'(fpu_flags.NX)
	};

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


