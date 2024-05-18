
`include "pkg_pwm_decodes.sv"



module pwm_top(
					
			input logic				clk_i,
			input logic				rst_i,
			input logic		[7:0]	address_i,
			input logic		[31:0]	writedata_i,
			input logic				write_i,
			output logic	[31:0]	readdata_o,
			input logic				read_i,
			input logic				chipselect_i,
			output logic 			pwm1_h_o,
			output logic 			pwm1_l_o,
			output logic 			pwm2_h_o,
			output logic 			pwm2_l_o
					
					);
// end port decleration


//////////////////////////////////////////////////////
// memory maped registers
//////////////////////////////////////////////////////

//	register for configuring prescaling of core clock
//	presacle will decrease the input frequecy from clock to (f_core/presacle_value)
var logic	[15:0]	prescaler;	


//	control register for controlling PWM modules
//	{8'b0, inverting2,inverting1,center_edge2,center_edge1,com_re2,com_re1,pwm_2_en,pwm_1_en}	
//	com_re -> complementry_redundent	
var logic 	[15:0]	control;	


var logic	[15:0]	period1;	//	register for configuring period of the pwm module 1
var logic	[15:0]	period2;	// 	register for configuring period of the pwm module 2
var logic	[15:0]	compare1;	//	register for configuring duty cycle of pwm module 1
var logic 	[15:0]	compare2;	//	register for configuring duty cycle of pwm module 2
var logic 	[15:0]	deadtime1;	//	register for configuring deadtime in complementry mode
var logic 	[15:0]	deadtime2;	//	register for configuring deadtime in complementry mode




//////////////////////////////////////////////////////
// internel registers
//////////////////////////////////////////////////////

var logic	[15:0]	clock_divider;		//	register for scaling frequency
var logic 	[15:0]	count1,count2 ;		//	register for couting 
var logic 			up_count1,up_count2;



//////////////////////////////////////////////////////
// internel wires
//////////////////////////////////////////////////////

wire logic	enable1,enable2, clk_div_count_comp;
wire logic	com_re1,com_re2, center_edge1,center_edge2, inverting1,inverting2;
wire logic	pwm1_w_r,pwm2_w_r,pwm1_w_c,pwm2_w_c;
 
///////////////////////////////////////////
// assigning wires
///////////////////////////////////////////
assign enable1 				= 	control[0];   // if pwm1  enabled
assign enable2 				=   control[1]; // if pwm2 enabled
assign clk_div_count_comp	=	(enable1|enable2) & (clock_divider==(prescaler-1));
assign com_re1  				=	control[2];	//	com_re -> complementry_redundent	
assign com_re2  				=	control[3];	//	com_re -> complementry_redundent	
assign center_edge1  		=	control[4];	
assign center_edge2  		=	control[5];	
assign inverting1 			=	control[6];
assign inverting2  			=	control[7];


//////////////////////////////////////////////////////
// registering the memroy mapped registers
//////////////////////////////////////////////////////

always_ff @( posedge clk_i or posedge rst_i ) begin : Writing_memory_mapped_registers
	if (rst_i)
	begin
		prescaler	<=	16'd49;			//	default frequecy scaler (1 KHz for with default period)
		control		<=	16'd0;
		period1		<=	16'd1023;			// default resolution of 10 bit
		period2		<=	16'd1023;
		compare1	<=	16'd511;		//	default duty cycle (50% duty cycle with default period or resolution)
		compare2	<=	16'd196;
		deadtime1	<=	16'd0;
		deadtime2	<=	16'd0;
	end
	else if (write_i&&chipselect_i)
	begin 
		case (address_i)
			`PWM_PRESCALER_REG:
				prescaler	<=	writedata_i[15:0];
			`PWM_CONTROL_REG:
				control		<=	writedata_i[15:0];
			`PWM_PERIOD1_REG:
				period1		<=	writedata_i[15:0];
			`PWM_PERIOD2_REG:
				period2		<=	writedata_i[15:0];
			`PWM_COMPARE1_REG:
				compare1	<=	writedata_i[15:0];
			`PWM_COMPARE2_REG:
				compare2	<=	writedata_i[15:0];
			`PWM_DEADTIME1_REG:
				deadtime1	<=	writedata_i[15:0];
			`PWM_DEADTIME2_REG:
				deadtime2	<=	writedata_i[15:0];
		endcase
	end
end


//////////////////////////////////////////////////////
// Reading memory mapped registers
//////////////////////////////////////////////////////

always_ff @( posedge clk_i or posedge rst_i ) begin : readblock
	
	if (rst_i)
		readdata_o	<=	32'b0;
	else if (read_i&&chipselect_i)
	begin
		case(address_i)
			`PWM_PRESCALER_REG:
				readdata_o	<=	{16'b0,prescaler};
			`PWM_CONTROL_REG:
				readdata_o	<=	{16'b0,control};
			`PWM_PERIOD1_REG:
				readdata_o	<=	{16'b0,period1};
			`PWM_PERIOD2_REG:
				readdata_o	<=	{16'b0,period2};
			`PWM_COMPARE1_REG:
				readdata_o	<=	{16'b0,compare1};
			`PWM_COMPARE2_REG:
				readdata_o	<=	{16'b0,compare2};
			`PWM_DEADTIME1_REG:
				readdata_o	<=	{16'b0,deadtime1};
			`PWM_DEADTIME2_REG:
				readdata_o	<=	{16'b0,deadtime2};
		endcase
	end
end





//////////////////////////////////////////////////////
// design logic
//////////////////////////////////////////////////////

///////////////////////////////////////////
// clock divider logic
///////////////////////////////////////////

always_ff @( posedge clk_i or posedge rst_i ) begin : Clock_divider_logic
	if (rst_i)
		clock_divider	<=	16'b0;
	else if(enable1|enable2) 
	begin
		if (clk_div_count_comp)
			clock_divider	<=	16'b0;							// if count complete roll over
		else
			clock_divider	<=	clock_divider	+	16'b1;		// continue counting
	end

end

///////////////////////////////////////////
// up counter signal
///////////////////////////////////////////

always_ff @( posedge clk_i or posedge rst_i ) begin : up_count_logic1

	if (rst_i)
		up_count1	<=	1'b1;
	else if (control[0]&&center_edge1)	// pwm1 enabled and is center aligned
	begin
		if (clk_div_count_comp) begin
			
			if(up_count1) 
				up_count1 <= (count1 == (period1-1))? (~up_count1):up_count1;
			else
				up_count1 <= (count1 == 16'b1)? (~up_count1):up_count1;
		
		end
	end		
end
always_ff @( posedge clk_i or posedge rst_i ) begin : up_count_logic2

	if (rst_i)
		up_count2	<=	1'b1;
	else if (control[1]&&center_edge2)	// pwm1 enabled and is center aligned
	begin
		if (clk_div_count_comp) begin
			if(up_count2)
				up_count2 <= (count2 == (period1-1))? (~up_count2):up_count2;
			else
				up_count2 <= (count2 == 16'b1)? (~up_count2):up_count2;
		end
			
	end		
end

///////////////////////////////////////////
// coutner
///////////////////////////////////////////

always_ff @( posedge clk_i or posedge rst_i ) begin : counter_logic1
    if (rst_i)
		count1 <= 16'b0;		// if not enable or reset
	else if(enable1) 
	begin
		if (clk_div_count_comp)	begin 
			if (center_edge1)
				count1 <= (up_count1)?count1 + 16'b1:count1 - 16'b1;
			else 	begin 
				count1 <= (count1 == (period1 - 1))? 16'b0:count1 + 16'b1;
			end
		end
	end
end

always_ff @( posedge clk_i or posedge rst_i  ) begin : counter_logic2
    if (rst_i)
		count2 <= 16'b0;		// if not enable or reset
	else if(enable2) 
	begin
		if (clk_div_count_comp)	begin 
			if (center_edge2)
					count2 <= (up_count2)?count2 + 16'b1:count2 - 16'b1;
			else 
				count2 <= (count2 == (period2 - 1))? 16'b0:count2 + 16'b1;
				
		end
	end
end


//////////////////////////////////////////////////////
// output logic
//////////////////////////////////////////////////////

	assign pwm1_w_r	=	control[0] && (count1 <= compare1);
	
	assign pwm1_w_c = 	control[0] && (~(((~center_edge1)&(count1 < deadtime1))||(count1>(compare1 - deadtime1))));
	

always_comb begin : PWM1_output_logic
	if (enable1)	begin
		if (com_re1)
		begin
			pwm1_h_o	=	(inverting1)?~pwm1_w_c:pwm1_w_c;
			pwm1_l_o	=	(inverting1)?pwm1_w_r:~pwm1_w_r;
		end
		else begin
			pwm1_h_o	=	(inverting1)?~pwm1_w_r:pwm1_w_r;
			pwm1_l_o	=	pwm1_h_o;
		end
	end
	else begin
		pwm1_h_o = 1'b0;
		pwm1_l_o = 1'b0;
	end
end

	assign pwm2_w_r	=	control[1] && (count2 <= compare2);

	assign pwm2_w_c = 	control[1] && (~(((~center_edge2)&(count2 < deadtime2))||(count2>(compare2 - deadtime2))));
	
always_comb begin : PWM2_output_logic
		if (enable2)	begin
		if (com_re2)
		begin
			pwm2_h_o	=	(inverting2)?~pwm2_w_c:pwm2_w_c;
			pwm2_l_o	=	(inverting2)?pwm2_w_r:~pwm2_w_r;
		end
		else begin
			pwm2_h_o	=	(inverting2)?~pwm2_w_r:pwm2_w_r;
			pwm2_l_o	=	pwm2_h_o;
		end
	end
	else begin
		pwm2_h_o = 1'b0;
		pwm2_l_o = 1'b0;
	end
end





endmodule
