
`include "pkg_timer_decodes.sv"

module timer_top
(
		clk_i,
		stall_i,
		reset,
		address,
		writedata,
		write,
		readdata,
		read,
		chipselect,
		intr_o
);

input logic clk_i;
input logic reset;
input logic stall_i;
input logic write;
input logic read;
input logic chipselect;
input logic [31:0]writedata;
input logic [2:0]address;
output logic [31:0]readdata;
output logic intr_o;


var logic [10:0]  prescaler;	// prescaler register				// 0	0x00
var logic [31:0] count;		// register for counting			// 1    0x04	
var logic [31:0 ]compare;
							// Control and Status Register		
var logic [7:0] control_r;				// control register;	// [5'b0,en,soft_Reset] 	// 2    0x08		 
var logic [7:0] status_r;				// status register;		// [6'b0,count_complete]	// 3	0x0c

wire logic en;
var logic clock_en; 
wire logic clcok_div_count_complete;
assign en = control_r[1];
var logic [10:0]clock_divider;				// register use to perform function of prescaler

assign clcok_div_count_complete = en&&(clock_divider == prescaler);

always_ff@(posedge clk_i or posedge reset) // write divider
begin
	if(reset)										
		clock_divider <= 0;
	else if (clcok_div_count_complete)
		clock_divider <= 0;
	else if (en)
		clock_divider <= clock_divider + 1'b1;
end

always_ff @(posedge clk_i or posedge reset ) 
begin
	if (reset)
		clock_en <= 0;
	else if (~stall_i & clcok_div_count_complete)
		clock_en <= 1;
	else 
		clock_en <= 0;	
end
always_ff@(posedge clk_i or posedge reset ) //write prescalar
begin
	if(reset)										
		prescaler <= 0;
	else if(write & chipselect & address == `PRESCALAR_REG)
		prescaler <= writedata[10:0];
	
end

always_ff@(posedge clk_i or posedge reset ) /// write compare
begin
	if(reset)										
		compare <= 0;
	else if(write & chipselect & address == `COMPARE_REG)
		compare <= writedata;
end

always_ff@(posedge clk_i or posedge reset) ///write count
begin
	if(reset)										
		count <= 0;
	else if(write & chipselect & address == `COUNT_REG)
		count <= writedata;
	else if(en&&clock_en&&(count==compare))
		count <= 0;	
	else if (en&&clock_en)
		count <= count + 1;
end

always_ff@(posedge clk_i or posedge reset ) //write control
begin
	if(reset)										
		control_r <= 0;
	else if(write & chipselect & address == `CONTROL_REG)
		control_r <= writedata[7:0];
end

always_ff@(posedge clk_i or posedge reset ) //read mux
begin
	if (reset)
		readdata <= 32'b0;
	else if(read & chipselect)
		case(address)
			`PRESCALAR_REG:	readdata <= prescaler;
			`COUNT_REG:		readdata <= count;
			`CONTROL_REG:	readdata <= {24'd0,control_r};
			`STATUS_REG:	readdata <= {24'd0,status_r};
			`COMPARE_REG: 	readdata <= compare;
			default : 		readdata <= 32'b0;
		endcase
end

always_ff@(posedge clk_i or posedge reset) //status_r 
begin
	if(reset)										
		status_r <= 0;
	else if(clock_en && count == compare && (compare != 0))
		status_r <= {6'd0,1'b1};
	else if(read & chipselect & address == `STATUS_REG)
		status_r <= 0;
	else
		status_r <= status_r;
end

assign intr_o		=	clock_en && count == compare && (compare != 0);

endmodule
