module de10nano(

	//////////// ARDUINO //////////
	inout 		    [15:0]		ARDUINO_IO,
	inout 		          		ARDUINO_RESET_N,

	//////////// CLOCK //////////
	input 		          		FPGA_CLK1_50,
	input 		          		FPGA_CLK2_50,
	input 		          		FPGA_CLK3_50,

	//////////// KEY //////////
	input 		     [1:0]		KEY,

	//////////// LED //////////
	output		     [7:0]		LED,

	//////////// SW //////////
	input 		     [3:0]		SW,

	//////////// GPIO_0, GPIO connect to GPIO Default //////////
	inout 		    [35:0]		GPIO_0,

	//////////// GPIO_1, GPIO connect to GPIO Default //////////
	inout 		    [35:0]		GPIO_1
);



//=======================================================
//  REG/WIRE declarations
//=======================================================
	
	wire scl_pad_i;
	wire scl_pad_o;
	wire scl_padoen_o;
	wire sda_pad_i;
	wire sda_pad_o;
	wire sda_padoen_o;



	wire [31:0]num;
	wire [14:0] address_a_sig;
	wire [14:0] address_b_sig;
	wire [3:0] byteena_a_sig;
	wire [3:0] byteena_b_sig;
	wire  clock_a_sig;
	wire  clock_b_sig;
	wire [31:0] data_a_sig;
	wire [31:0] data_b_sig;
	wire  enable_a_sig;
	wire  enable_b_sig;
	wire  wren_a_sig;
	wire  wren_b_sig;
	wire [31:0] q_a_sig;
	wire [31:0] q_b_sig;

	// GPIO 
	wire [15:0]	gpio_en;
	wire [15:0]	gpio_o;
	wire [15:0]	gpio_i;
	
	
	
//=======================================================
//  Structural coding
//=======================================================
	
	
	

	mem mem_inst
	(
		.address_a(address_a_sig) ,	// input [14:0] address_a_sig
		.address_b(address_b_sig) ,	// input [14:0] address_b_sig
		.byteena_a(byteena_a_sig) ,	// input [3:0] byteena_a_sig
		.byteena_b(byteena_b_sig) ,	// input [3:0] byteena_b_sig
		.clock_a(clock_a_sig) ,	// input  clock_a_sig
		.clock_b(clock_b_sig) ,	// input  clock_b_sig
		.data_a(data_a_sig) ,	// input [31:0] data_a_sig
		.data_b(data_b_sig) ,	// input [31:0] data_b_sig
		.enable_a(enable_a_sig) ,	// input  enable_a_sig
		.enable_b(enable_b_sig) ,	// input  enable_b_sig
		.wren_a(wren_a_sig) ,	// input  wren_a_sig
		.wren_b(wren_b_sig) ,	// input  wren_b_sig
		.q_a(q_a_sig) ,	// output [31:0] q_a_sig
		.q_b(q_b_sig) 	// output [31:0] q_b_sig
	);

		
	soc_top soc_top_inst
	(
		.clk_i(FPGA_CLK1_50) ,	// input  clk_i_sig
		.reset_i(~KEY[0]) ,	// input  reset_i_sig
		//imem
		.address_a_o(address_a_sig) ,	// output [14:0] address_a_sig
		.address_b_o(address_b_sig) ,	// output [14:0] address_b_sig
		.byteena_a_o(byteena_a_sig) ,	// output [3:0] byteena_a_sig
		.byteena_b_o(byteena_b_sig) ,	// output [3:0] byteena_b_sig
		.clock_a_o(clock_a_sig) ,	// output  clock_a_sig
		.clock_b_o(clock_b_sig) ,	// output  clock_b_sig
		.data_a_o(data_a_sig) ,	// output [31:0] data_a_sig
		.data_b_o(data_b_sig) ,	// output [31:0] data_b_sig
		.enable_a_o(enable_a_sig) ,	// output  enable_a_sig
		.enable_b_o(enable_b_sig) ,	// output  enable_b_sig
		.wren_a_o(wren_a_sig) ,	// output  wren_a_sig
		.wren_b_o(wren_b_sig) ,	// output  wren_b_sig
		.q_a_i(q_a_sig) ,	// input [31:0] q_a_sig
		.q_b_i(q_b_sig) ,	// input [31:0] q_b_sig

		//uart
		.tx_o(GPIO_0[5]) ,	// output  tx_sig
		.rx_i(GPIO_0[4]) ,	// input  rx_sig
	
		// spi
		.mosi_o        (ARDUINO_IO[6]),
		.miso_i        (ARDUINO_IO[5]),
		.SCK_o         (ARDUINO_IO[3]),
		.slave_select_o(ARDUINO_IO[4]),
		//i2c

		.scl_pad_i(scl_pad_i),
		.scl_pad_o(scl_pad_o),
		.scl_padoen_o(scl_padoen_o),
		.sda_pad_i(sda_pad_i),
		.sda_pad_o(sda_pad_o),
		.sda_padoen_o(sda_padoen_o),
		
		//gpio
		.gpio_oen(gpio_en),
		.gpio_o(gpio_o),
		.gpio_i(gpio_i),
		//pwm
		.pwm1_h_o   (GPIO_0[23]),
		.pwm1_l_o   (GPIO_0[24]),
		.pwm2_h_o	(GPIO_1[23]),
		.pwm2_l_o	(GPIO_1[24]),


		// jtag
		.tck_i(GPIO_0[31]) ,	// input  TCK_sig
		.tms_i(GPIO_0[29]) ,	// input  TMS_sig
		.tdi_i(GPIO_0[35]) ,	// input  TDI_sig
		.tdo_o(GPIO_0[33])	// output  TDO_sig
		
	);
	//
	
	assign ARDUINO_IO[2] = scl_padoen_o?1'bz:scl_pad_o;
	assign scl_pad_i = ARDUINO_IO[2];
	
	assign ARDUINO_IO[1] = sda_padoen_o?1'bz:sda_pad_o;
	assign sda_pad_i = ARDUINO_IO[1];

	assign GPIO_0[34] = 1'b0;
	genvar i;
	generate  
		for ( i = 0; i<16; i=i+1) begin : generate_1
			assign GPIO_1[i] = gpio_en[i] ? gpio_o[i]: 1'bz;
			assign gpio_i[i] = GPIO_1[i];
		end
	endgenerate
endmodule