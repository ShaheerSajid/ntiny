module gpio_top
(
		clk_i,
		resetn_i,
		address_i,
		writedata_i,
		write_i,
		readdata_o,
		read_i,
		chipselect_i,
		
		gpio_oen,
		gpio_i,
		gpio_o,
		interrupt_reg
);


// signals for connecting to the Avalon fabric
input logic 						clk_i;
input logic							resetn_i;
input logic 						write_i;
input logic 						read_i;
input logic 						chipselect_i;
input logic 			[31:0]		writedata_i;
input logic 			[2:0]		address_i;
output logic		 	[31:0]		readdata_o;
output	logic 			[31:0]		interrupt_reg;
output logic 			[31:0] 		gpio_oen;
output logic 			[31:0] 		gpio_o;
input logic 			[31:0] 		gpio_i;



//var logic [31:0] module_var logic[0:1];//DDR,POUT,PIN
//var logic[31:0] data_out;


	///// memory mapped registers
	var logic	[31:0]	DDR;		// data direction var logicister   1--> output logic, 0--> input logic
	var logic 	[31:0]	Dout;		// output logic Data value(from processor) 
	var logic	[31:0]	Din;		// input logic data value(to processor)
	var logic 	[7:0]	cmd;		// command var logicisters.   0th bit --> clear output logic data(active high). 1st bit --> clear DDR var logic register (active high).
												//	2nd bit --> softreset GPIO
												//  5th --> intr_en
	// cmd[4:3] 
	// 00 -> posedge edge intr     01 -> neg edge intr    10 -> pos level intr   01 -> neg level intr


	wire logic[31:0] in;



	///// internal registers

	var logic  [31:0] temp_in;


// implement tristate logic to set GPIO as input logic or output logic
/// output logic logic of tristate
/*
integer i;
genvar gi;
generate
  for (gi=0; gi<32; gi=gi+1) begin : genbit
    assign gpio_io[gi] = DDR[gi]? Dout[gi]: 1'bz;
  end
endgenerate
// input logic logic for tristate
assign in = gpio_io;
*/
assign in = gpio_i;
assign gpio_o = Dout;
assign gpio_oen = DDR;
// Read or Write the internal var logicisters
always_ff@(posedge clk_i or posedge resetn_i)
begin
	//Din <= in;
	if(resetn_i) // reset asynchronous
		begin
			DDR		<=	32'b0;			// address 0   	(0x00)
			Dout	<=	32'b0;			// address 1	(0x04)
			//Din		<=	32'b0;			// address 2	(0x08)
			cmd		<=	8'b0;			// address 3	(0x0a)
			
		end
	else if (cmd[0])	/// reset Data out var logicister
		begin
			Dout	<=	32'b0;	// reset only output logic data var logicister (from processor)
			cmd		<= 	8'b0;	// reset command var logicister after excuting command
		end
	else if (cmd[1])	//// reset Data Direction var logicister
		begin
			DDR		<=  32'b0;	// reset Data direction var logicister ( to input logic)
			cmd		<=	8'b0;	// reset command var logicister after excuting command
		end
	else if (cmd[2]) //
		begin
			DDR		<=	32'b0;			// address 0   	(0x00)
			Dout	<=	32'b0;			// address 1	(0x04)
			//Din		<=	32'b0;			// address 2	(0x08)
			cmd		<=	8'b0;			// address 3	(0x0a)
			
		end
	else if(write_i & chipselect_i)
		begin 
		case (address_i)
		3'd0:	DDR		<=	writedata_i;		// set DDR var logicister
		3'd1:	Dout	<=	writedata_i;		// set Data out value (from  processor)
		3'd3:	cmd		<=	writedata_i[7:0];	// set command var logicister value	
		endcase
		end
	else if (read_i & chipselect_i)
		begin
		case (address_i)
		3'd0:	readdata_o		<=	DDR;		// Read DDR var logicister
		3'd1:	readdata_o		<=	Dout;		// Read Data_out var logic
		3'd2:	readdata_o		<=	in;		// Read Data_in value to processor
		3'd3:	readdata_o		<=	cmd;	// set command var logicister value	
		endcase
		end
	 
	//////////////////////////////////////////////////////////////
	 // perform Commands given from processor via cmd var logicister //
	//////////////////////////////////////////////////////////////
	
	 	
	
	// write the input logic vlaue(state) present on GPIO to Din var logicister	
end

/////

	always_ff @( posedge clk_i or posedge resetn_i ) begin : temp_in_loigc
		if (resetn_i)
			temp_in		<=	32'b0;
		else
			temp_in		<=	in;
	end
	integer i;
	always_ff @( posedge clk_i or posedge resetn_i ) begin : interrupt_reg_logic
		if (resetn_i)
			interrupt_reg	<=	32'b0;
		else begin 
			for (i = 0 ; i < 32; i = i + 1) begin : intr_logic
				if (~DDR[i] & cmd[5]) begin // if gpio is input and intr is enabled
					case (cmd[4:3])	// 
					2'd0:	interrupt_reg[i]	<= in[i] & (~temp_in[i]);		// posedge 
					2'd1:	interrupt_reg[i]	<= ~in[i] & (temp_in[i]);		// negedge 
					2'd2:	interrupt_reg[i]	<= in[i];		// pos level
					2'd3:	interrupt_reg[i]	<= ~in[i];		// neg level				
					endcase
				end
				else 
					interrupt_reg[i] <= 1'b0;
			end
		end


	end

endmodule
