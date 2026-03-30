

import common_pkg::*;
import core_pkg::*;

module csr_unit (
	input clk_i,
  input reset_i,

	input csr_op_e csr_cmd_i,
	input csr_reg_e csr_addr_i,
	input onebit_sig_e csr_use_immediate_i,
	input [31:0] imm_i,
	input [31:0] reg_i,

	input onebit_sig_e csr_instret_trigger_i,
	input onebit_sig_e stop_counters_i,
	input onebit_sig_e float_valid_i,
	output roundmode_e roundmode_o,
	input float_status_e float_status_i,

///////Trap Signals (interrupts + exceptions)
  input trap_valid_i,
  input [31:0]ecause_i,
  input [31:0]epc_i,
  input [31:0]mtval_i,
  input [31:0]interrupt_src_i,
  input ret_i,

  output [31:0]ip_o,
  output [31:0]ie_o,
  output [31:0]vec_o,
  output [31:0]status_o,
  output [31:0]epc_o,


	output logic [31:0]csr_value_o
	);

	logic [31:0] _MSTATUS;
	logic [31:0] _MIE;
	logic [31:0] _MTVEC;
	logic [31:0] _MEPC;
	logic [31:0] _MCAUSE;
	logic [31:0] _MTVAL;
	logic [31:0] _MSCRATCH;
	logic [31:0] _MIP;
	logic [31:0] _MCYCLE;
	logic [31:0] _MINSTRET;
	logic [31:0] _MCYCLEH;
	logic [31:0] _MINSTRETH;
	logic [31:0] _MCOUNTINHIBIT;
	logic [31:0] _FFLAGS;
	logic [31:0] _FRM;


	logic MSTATUS_sel;
	logic MIE_sel;
	logic MTVEC_sel;
	logic MEPC_sel;
	logic MCAUSE_sel;
	logic MTVAL_sel;
	logic MSCRATCH_sel;
	logic MIP_sel;
	logic MCYCLE_sel;
	logic MINSTRET_sel;
	logic MCYCLEH_sel;
	logic MINSTRETH_sel;
	logic MCOUNTINHIBIT_sel;
	logic FFLAGS_sel;
	logic FRM_sel;
	logic FCSR_sel;

	logic [31:0]csr_data;
	logic [63:0]csr_cycle_update;
	logic [63:0]csr_instret_update;

	// CSR select logic
	assign MSTATUS_sel 			= csr_addr_i == MSTATUS;
	assign MIE_sel 				  = csr_addr_i == MIE;
	assign MTVEC_sel 			  = csr_addr_i == MTVEC;
	assign MEPC_sel 			  = csr_addr_i == MEPC;
	assign MCAUSE_sel 			= csr_addr_i == MCAUSE;
	assign MTVAL_sel			  = csr_addr_i == MTVAL;
	assign MSCRATCH_sel		  = csr_addr_i == MSCRATCH;
	assign MIP_sel				  = csr_addr_i == MIP;
	assign MCYCLE_sel 			= csr_addr_i == MCYCLE;
	assign MINSTRET_sel 		= csr_addr_i == MINSTRET;
	assign MCYCLEH_sel 			= csr_addr_i == MCYCLEH;
	assign MINSTRETH_sel 		= csr_addr_i == MINSTRETH;
	assign MCOUNTINHIBIT_sel= csr_addr_i == MCOUNTINHIBIT;
	assign FFLAGS_sel       = csr_addr_i == FFLAGS;
	assign FRM_sel          = csr_addr_i == FRM;
	assign FCSR_sel         = csr_addr_i == FCSR;


	assign csr_data = (csr_use_immediate_i == TRUE)?imm_i : reg_i;
	assign csr_cycle_update = (!_MCOUNTINHIBIT[0] && !stop_counters_i)? {_MCYCLEH,_MCYCLE} + 1 : {_MCYCLEH,_MCYCLE};
	assign csr_instret_update = (!_MCOUNTINHIBIT[2] && csr_instret_trigger_i && !stop_counters_i)? {_MINSTRETH,_MINSTRET} + 1 : {_MINSTRETH,_MINSTRET};

	// MSTATUS update: trap entry saves MIE->MPIE, clears MIE, sets MPP=11;
	//                 MRET restores MIE<-MPIE, sets MPIE=1, keeps MPP=11
	wire [31:0] mstatus_trap = {_MSTATUS[31:13], 2'b11, _MSTATUS[10:8], _MSTATUS[3], _MSTATUS[6:4], 1'b0, _MSTATUS[2:0]};
	wire [31:0] mstatus_ret  = {_MSTATUS[31:13], 2'b11, _MSTATUS[10:8], 1'b1, _MSTATUS[6:4], _MSTATUS[7], _MSTATUS[2:0]};
	wire [31:0] mstatus_update = trap_valid_i ? mstatus_trap : ret_i ? mstatus_ret : _MSTATUS;

	// CSR registers
	csr_register_32 #(32'h0)		csr_mcycle			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLE_sel),
															.wdata(csr_data),.update(csr_cycle_update[31:0]), .csr(_MCYCLE));
	csr_register_32 #(32'h0)		csr_minstret		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRET_sel),
															.wdata(csr_data),.update(csr_instret_update[31:0]), .csr(_MINSTRET));
	csr_register_32 #(32'h0)		csr_mcycleh			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLEH_sel),
															.wdata(csr_data),.update(csr_cycle_update[63:32]), .csr(_MCYCLEH));
	csr_register_32 #(32'h0)		csr_minstreth		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRETH_sel),
															.wdata(csr_data),.update(csr_instret_update[63:32]), .csr(_MINSTRETH));
	csr_register_32 #(32'h0)		csr_mcounterinhibit	(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCOUNTINHIBIT_sel),
															.wdata(csr_data),.update(_MCOUNTINHIBIT), .csr(_MCOUNTINHIBIT));
	csr_register_32 #(32'h0)		csr_mstatus			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSTATUS_sel),
															.wdata(csr_data),.update(mstatus_update), .csr(_MSTATUS));
	csr_register_32 #(32'h0)		csr_mie				(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIE_sel),
															.wdata(csr_data),.update(_MIE), .csr(_MIE));
	csr_register_32 #(32'h0)		csr_mip				(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIP_sel),
															.wdata(csr_data),.update(interrupt_src_i), .csr(_MIP));
	csr_register_32 #(32'h0)		csr_mtvec			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVEC_sel),
															.wdata(csr_data),.update(_MTVEC), .csr(_MTVEC));
	csr_register_32 #(32'h0)		csr_mepc			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MEPC_sel),
															.wdata(csr_data),.update(trap_valid_i? epc_i : _MEPC), .csr(_MEPC));
	csr_register_32 #(32'h0)		csr_mcause			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCAUSE_sel),
															.wdata(csr_data),.update(trap_valid_i? ecause_i : _MCAUSE), .csr(_MCAUSE));
	csr_register_32 #(32'h0)		csr_mtval			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVAL_sel),
															.wdata(csr_data),.update(trap_valid_i? mtval_i : _MTVAL), .csr(_MTVAL));
	csr_register_32 #(32'h0)		csr_mscratch		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSCRATCH_sel),
															.wdata(csr_data),.update(_MSCRATCH), .csr(_MSCRATCH));

	// FPU CSRs: FFLAGS (accumulated exception flags), FRM (rounding mode)
	// FCSR writes update both FFLAGS and FRM simultaneously
	wire [4:0] new_fflags = {float_status_i.NV, float_status_i.DZ, float_status_i.OF, float_status_i.UF, float_status_i.NX};
	wire [31:0] fflags_accumulate = (float_valid_i == TRUE) ? (_FFLAGS | {27'b0, new_fflags}) : _FFLAGS;
	wire [31:0] fflags_wdata = FCSR_sel ? {27'b0, csr_data[4:0]} : csr_data;
	wire [31:0] frm_wdata   = FCSR_sel ? {29'b0, csr_data[7:5]} : csr_data;

	csr_register_32 #(32'h0)		csr_fflags			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(FFLAGS_sel | FCSR_sel),
														.wdata(fflags_wdata),.update(fflags_accumulate), .csr(_FFLAGS));
	csr_register_32 #(32'h0)		csr_frm				(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(FRM_sel | FCSR_sel),
														.wdata(frm_wdata),.update(_FRM), .csr(_FRM));

	assign roundmode_o = roundmode_e'(_FRM[2:0]);

	always_comb
    begin
		case (csr_addr_i)
			FFLAGS:			  csr_value_o = {27'b0, _FFLAGS[4:0]};
			FRM:			    csr_value_o = {29'b0, _FRM[2:0]};
			FCSR:			    csr_value_o = {24'b0, _FRM[2:0], _FFLAGS[4:0]};
			CYCLE:			  csr_value_o = _MCYCLE;
			TIME:			    csr_value_o = 0;
			INSTRET:		  csr_value_o = _MINSTRET;
			CYCLEH:			  csr_value_o = _MCYCLEH;
			TIMEH:			  csr_value_o = 0;
			INSTRETH:		  csr_value_o = _MINSTRETH;
			MSTATUS:		  csr_value_o = _MSTATUS;
`ifdef FPU
			MISA:			    csr_value_o = 32'h40001127; // RV32IMAFC
`else
			MISA:			    csr_value_o = 32'h40001107; // RV32IMAC
`endif
			MIE:			    csr_value_o = _MIE;
			MTVEC:			  csr_value_o = _MTVEC;
			MSCRATCH:		  csr_value_o = _MSCRATCH;
			MEPC:			    csr_value_o = _MEPC;
			MCAUSE:			  csr_value_o = _MCAUSE;
			MTVAL:			  csr_value_o = _MTVAL;
			MIP:			    csr_value_o = _MIP;
			MCYCLE:			  csr_value_o = _MCYCLE;
			MINSTRET:		  csr_value_o = _MINSTRET;
			MCYCLEH:		  csr_value_o = _MCYCLEH;
			MINSTRETH:		csr_value_o = _MINSTRETH;
			MCOUNTINHIBIT:csr_value_o = _MCOUNTINHIBIT;
			default : 		csr_value_o = 0;
		endcase
	end

//interrupt outputs
assign ip_o     = _MIP;
assign ie_o     = _MIE;
assign vec_o    = _MTVEC;
assign status_o = _MSTATUS;
assign epc_o    = _MEPC;

endmodule

module csr_register_32
 #(
		parameter DEFAULT = 32'b0
	)
	(
		input   clk_i,
        input   reset_i,
        input 	csr_op_e csr_cmd_i,
		input 	bit	enable,
		input	[31:0] 	wdata,
		input	[31:0]  update,
		output	logic[31:0]  csr
	);
	always_ff @ (posedge clk_i or posedge reset_i) begin: CSR
				if (reset_i) begin
					csr <= DEFAULT;
		end else if ((csr_cmd_i == WRITE_CSR) && enable) begin
					csr <= wdata;
		end else if ((csr_cmd_i == SET_CSR) && enable) begin
					csr <= csr | wdata;
		end else if ((csr_cmd_i == CLEAR_CSR) && enable) begin
					csr <= csr & ~wdata;
		end else begin
					csr <= update;
		end
	end
endmodule
