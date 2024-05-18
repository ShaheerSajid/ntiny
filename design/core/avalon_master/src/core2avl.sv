import common_pkg::*;
import core_pkg::*;

module core2avl
#(parameter DATA_WIDTH=32, parameter ADDR_WIDTH=32)
	(
		// core side signals
		input logic clk_i,
		input logic reset_i,
		input onebit_sig_e stall_i,
		input load_store_width_e load_store_width,
		input onebit_sig_e mem_unsigned,
		input mem_op_e mem_op,
		input logic [ADDR_WIDTH-1:0] addr_i,
		input logic [DATA_WIDTH-1:0] data2write_i,
		output logic [DATA_WIDTH-1:0] data2read_o,
		//avl signals
		input logic [DATA_WIDTH-1:0] readdata_i, 
		output logic [ADDR_WIDTH-1:0] address_o, 
		output var logic [DATA_WIDTH-1:0] writedata_o, 
		output logic [3:0] byteenable_o, 
		output onebit_sig_e read_o, 
		output onebit_sig_e write_o
	);

	wire logic [1:0] byt;
	var logic [3:0] be;
	var logic [DATA_WIDTH-1:0] q;
	var logic [DATA_WIDTH-1:0] q1;

	load_store_width_e mode_iwb;
	var logic [3:0] be_iwb;
	onebit_sig_e mem_unsigned_iwb;


	always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i)
		begin
			mode_iwb <= load_store_width_e'(2'b00);
			be_iwb <= 4'b0000;
			mem_unsigned_iwb <= FALSE;
		end
		else if(!stall_i)
		begin
			mode_iwb <= load_store_width;
			be_iwb <= be;
			mem_unsigned_iwb <= mem_unsigned;
		end
	end

	assign byt = addr_i[1:0];

	assign read_o = onebit_sig_e'(mem_op == READ);
	assign write_o = onebit_sig_e'(mem_op == WRITE);
	assign address_o = addr_i;
	assign data2read_o = q;
	assign byteenable_o = be;

	always_comb
	begin
		case(byt)
			0:writedata_o = data2write_i;
			1:writedata_o = data2write_i<<8;
			2:writedata_o = data2write_i<<16;
			3:writedata_o = data2write_i<<24;
		endcase
	end

	always_comb
	begin
		case(load_store_width)
			BYTE:	case(byt)
						0:be = 4'b0001;
						1:be = 4'b0010;
						2:be = 4'b0100;
						3:be = 4'b1000;
					endcase
			HALF:	case(byt)
						0:be = 4'b0011;
						1:be = 4'b0110;
						2:be = 4'b1100;
						3:be = 4'b0000;
					endcase
			WORD:	be = 4'b1111;
			default: be = 4'b0000;
		endcase
	end

	always_comb
	begin
		case(be_iwb)
		4'b0001: q1 = {{24{1'b0}},readdata_i[7:0]};
		4'b0010: q1 = {{24{1'b0}},readdata_i[15:8]};
		4'b0100: q1 = {{24{1'b0}},readdata_i[23:16]};
		4'b1000: q1 = {{24{1'b0}},readdata_i[31:24]};
		4'b0011: q1 = {{16{1'b0}},readdata_i[15:0]};
		4'b0110: q1 = {{16{1'b0}},readdata_i[23:8]};
		4'b1100: q1 = {{16{1'b0}},readdata_i[31:16]};
		4'b1111: q1 = readdata_i;
		default: q1 = 32'h00000000;
		endcase
	end

	always_comb
	begin
		case({mem_unsigned_iwb,mode_iwb})
		{FALSE,BYTE}:	q = {{24{q1[7]}},q1[7:0]};//lb	
		{FALSE,HALF}:	q = {{16{q1[15]}},q1[15:0]};// lh
		{FALSE,WORD}:	q = q1;//lw
		{TRUE,BYTE}: 	q = {{24{1'b0}},q1[7:0]};//lbu						
		{TRUE,HALF}: 	q = {{16{1'b0}},q1[15:0]};// lhu
		default: 		q = 0;
		endcase
	end

endmodule
