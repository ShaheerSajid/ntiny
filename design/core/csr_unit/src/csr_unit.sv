

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

///////Interrupt Signals
  input interrupt_valid_i,
  input [31:0]ecause_i,
  input [31:0]epc_i,
  input [31:0]interrupt_src_i,
  input ret_i,

  output [31:0]ip_o,
  output [31:0]ie_o,
  output [31:0]vec_o,
  output [31:0]status_o,
  output [31:0]epc_o,


	output logic [31:0]csr_value_o
	);

	logic [4:0] _FFLAGS;
	logic [2:0] _FRM;
	logic [31:0] _FCSR;
	logic [31:0] _MSTATUS;
	logic [31:0] _MISA;
	logic [31:0] _MEDELEG;
  logic [31:0] _MIDELEG;
	logic [31:0] _MIE;
	logic [31:0] _MTVEC;
	logic [31:0] _MCOUNTEREN;
	logic [31:0] _MSTATUSH;
	logic [31:0] _MSCRATCH;
	logic [31:0] _MEPC;
	logic [31:0] _MCAUSE;
	logic [31:0] _MTVAL;
	logic [31:0] _MIP;
	logic [31:0] _MCYCLE;
	logic [31:0] _MINSTRET;
	logic [31:0] _MCYCLEH;
	logic [31:0] _MINSTRETH;
	logic [31:0] _MCOUNTINHIBIT;
	logic [31:0] _DCSR;
	logic [31:0] _DPC;
	

	logic FFLAGS_sel;
	logic FRM_sel;
	logic FCSR_sel;
	logic MSTATUS_sel;
	logic MISA_sel;
	logic MIE_sel;
	logic MTVEC_sel;
	logic MEDELEG_sel;
	logic MIDELEG_sel;
	logic MCOUNTEREN_sel;
	logic MSTATUSH_sel;
	logic MSCRATCH_sel;
	logic MEPC_sel;
	logic MCAUSE_sel;
	logic MTVAL_sel;
	logic MIP_sel;
	logic MCYCLE_sel;
	logic MINSTRET_sel;
	logic MCYCLEH_sel;
	logic MINSTRETH_sel;
	logic MCOUNTINHIBIT_sel;
	logic DCSR_sel;
	logic DPC_sel;

	logic [31:0]csr_data;
	logic [31:0]csr_fcsr_writedata;
	logic [63:0]csr_cycle_update;
	logic [63:0]csr_time_update;
	logic [63:0]csr_instret_update;
  logic mie_bit;

	//select logic
	//user
	//assign FFLAGS_sel 		  = csr_addr_i == FFLAGS;//URW
	//assign FRM_sel 				  = csr_addr_i == FRM;//URW
	//assign FCSR_sel 			  = (csr_addr_i == FCSR) | FRM_sel | FFLAGS_sel;//URW
	//machine
	assign MSTATUS_sel 			= csr_addr_i == MSTATUS;//MRW
	//assign MISA_sel 			  = csr_addr_i == MISA;//MRW
	//assign MEDELEG_sel			= csr_addr_i == MEDELEG;//MRW
	//assign MIDELEG_sel			= csr_addr_i == MIDELEG;//MRW
	assign MIE_sel 				  = csr_addr_i == MIE;//MRW
	assign MTVEC_sel 			  = csr_addr_i == MTVEC;//MRW
	//assign MCOUNTEREN_sel 	= csr_addr_i == MCOUNTEREN;//MRW
	//assign MSTATUSH_sel 		= csr_addr_i == MSTATUSH;//MRW
	//assign MSCRATCH_sel 		= csr_addr_i == MSCRATCH;//MRW
	assign MEPC_sel 			  = csr_addr_i == MEPC;//MRW
	assign MCAUSE_sel 			= csr_addr_i == MCAUSE;//MRW
	//assign MTVAL_sel 			  = csr_addr_i == MTVAL;//MRW
	assign MIP_sel				  = csr_addr_i == MIP;//MRW
	assign MCYCLE_sel 			= csr_addr_i == MCYCLE;//MRW
	assign MINSTRET_sel 		= csr_addr_i == MINSTRET;//MRW
	assign MCYCLEH_sel 			= csr_addr_i == MCYCLEH;//MRW
	assign MINSTRETH_sel 		= csr_addr_i == MINSTRETH;//MRW
	assign MCOUNTINHIBIT_sel= csr_addr_i == MCOUNTINHIBIT;//MRW
	//assign DCSR_sel 			  = csr_addr_i == DCSR;//DRW
	//assign DPC_sel 				  = csr_addr_i == DPC;//DRW


	//csr writedata logic
	assign csr_data = (csr_use_immediate_i == TRUE)?imm_i : reg_i;
	//assign _FFLAGS = {float_status_i.NV, float_status_i.DZ, float_status_i.OF, float_status_i.UF, float_status_i.NX};
	//assign _FRM = roundmode_i;
	//assign roundmode_o = roundmode_e'(_FCSR[7:5]);
	//assign csr_fcsr_writedata = FFLAGS_sel? {_FCSR[31:5], csr_data[4:0]} : FRM_sel? {_FCSR[31:8], csr_data[2:0], _FCSR[4:0]} : csr_data;
	assign csr_cycle_update = (!_MCOUNTINHIBIT[0] && !stop_counters_i)? {_MCYCLEH,_MCYCLE} + 1 : {_MCYCLEH,_MCYCLE};
	assign csr_instret_update = (!_MCOUNTINHIBIT[2] && csr_instret_trigger_i && !stop_counters_i)? {_MINSTRETH,_MINSTRET} + 1 : {_MINSTRETH,_MINSTRET};
  assign mie_bit = interrupt_valid_i? 1'b0 : ret_i | _MSTATUS[3];
	//csr registers
/*	csr_register_32 #(32'h0)		csr_fcsr		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(FCSR_sel),	
														.wdata(csr_fcsr_writedata),.update(float_valid_i? {_FCSR[31:5], _FFLAGS} : _FCSR), .csr(_FCSR));*/
	/*
	--  revisionCode        : 4'h1;
	--  manufacturersIdCode : 11'h60;
	--  deviceIdCode        : 16'h0786;
	--  order MSB .. LSB -> [4 bit version or revision] [16 bit part number] [11 bit manufacturer id] [value of 1'b1 in LSB]
	--  bank  = man >> 7
	--  offset = man&0x7F
	*/													
/*	csr_register_32 #(32'h40001126)	csr_misa			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MISA_sel),		
															.wdata(csr_data),.update(_MISA), .csr(_MISA));*/
	csr_register_32 #(32'h0)		csr_mcycle			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLE_sel),	
															.wdata(csr_data),.update(csr_cycle_update[31:0]), .csr(_MCYCLE));
	csr_register_32 #(32'h0)		csr_minstret		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRET_sel),	
															.wdata(csr_data),.update(csr_instret_update[31:0]), .csr(_MINSTRET));
/*	csr_register_32 #(32'h0)		csr_medeleg			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MEDELEG_sel),	
															.wdata(csr_data),.update(_MEDELEG), .csr(_MEDELEG));
	csr_register_32 #(32'h0)		csr_mideleg			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIDELEG_sel),	
															.wdata(csr_data),.update(_MIDELEG), .csr(_MIDELEG));*/
	csr_register_32 #(32'h0)		csr_mcycleh			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLEH_sel),	
															.wdata(csr_data),.update(csr_cycle_update[63:32]), .csr(_MCYCLEH));
	csr_register_32 #(32'h0)		csr_minstreth		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRETH_sel),	
															.wdata(csr_data),.update(csr_instret_update[63:32]), .csr(_MINSTRETH));
/*	csr_register_32 #(32'h0)		csr_mcounteren		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCOUNTEREN_sel),	
															.wdata(csr_data),.update(_MCOUNTEREN), .csr(_MCOUNTEREN));*/
	csr_register_32 #(32'h0)		csr_mcounterinhibit	(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCOUNTINHIBIT_sel),	
															.wdata(csr_data),.update(_MCOUNTINHIBIT), .csr(_MCOUNTINHIBIT));
	csr_register_32 #(32'h0)		csr_mstatus			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSTATUS_sel),	
															.wdata(csr_data),.update({_MSTATUS[31:4], mie_bit,_MSTATUS[2:0]}), .csr(_MSTATUS));
/*	csr_register_32 #(32'h0)		csr_mstatush		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSTATUSH_sel),	
															.wdata(csr_data),.update(_MSTATUSH), .csr(_MSTATUSH));*/
	csr_register_32 #(32'h0)		csr_mie				(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIE_sel),	
															.wdata(csr_data),.update(_MIE), .csr(_MIE));														
	csr_register_32 #(32'h0)		csr_mip				(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIP_sel),	
															.wdata(csr_data),.update(interrupt_src_i), .csr(_MIP));
	csr_register_32 #(32'h0)		csr_mtvec			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVEC_sel),	
															.wdata(csr_data),.update(_MTVEC), .csr(_MTVEC)); 
	csr_register_32 #(32'h0)		csr_mepc			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MEPC_sel),	
															.wdata(csr_data),.update(interrupt_valid_i? epc_i : _MEPC), .csr(_MEPC));
	csr_register_32 #(32'h0)		csr_mcause			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCAUSE_sel),	
															.wdata(csr_data),.update(interrupt_valid_i? ecause_i : _MCAUSE), .csr(_MCAUSE));
/*	csr_register_32 #(32'h0)		csr_mtval			(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVAL_sel),	
															.wdata(csr_data),.update(_MTVAL), .csr(_MTVAL));
	csr_register_32 #(32'h0)		csr_mscratch		(.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSCRATCH_sel),	
															.wdata(csr_data),.update(_MSCRATCH), .csr(_MSCRATCH));*/
	

	always_comb
    begin 
		case (csr_addr_i) 
			//FFLAGS:			  csr_value_o = _FCSR[4:0];
			//FRM:			    csr_value_o = _FCSR[7:5];
			//FCSR: 			  csr_value_o = _FCSR;
			CYCLE:			  csr_value_o = _MCYCLE;
			TIME:			    csr_value_o = 0;
			INSTRET:		  csr_value_o = _MINSTRET;
			CYCLEH:			  csr_value_o = _MCYCLEH;
			TIMEH:			  csr_value_o = 0;
			INSTRETH:		  csr_value_o = _MINSTRETH;
			//MVENDORID:	  csr_value_o = 32'h486;
			//MEDELEG:		  csr_value_o = _MEDELEG;
			//MIDELEG:		  csr_value_o = _MIDELEG;
			MSTATUS:		  csr_value_o = _MSTATUS;
			MISA:			    csr_value_o = 32'h40001106;//_MISA;
			MIE:			    csr_value_o = _MIE;
			MTVEC:			  csr_value_o = _MTVEC;
			//MCOUNTEREN:	  csr_value_o = _MCOUNTEREN;
			//MSTATUSH:		  csr_value_o = _MSTATUSH;
			//MSCRATCH:		  csr_value_o = _MSCRATCH;
			MEPC:			    csr_value_o = _MEPC;
			MCAUSE:			  csr_value_o = _MCAUSE;
			//MTVAL:			  csr_value_o = _MTVAL;
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
