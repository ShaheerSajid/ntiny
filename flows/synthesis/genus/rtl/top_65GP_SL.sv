module top
(
	input 	clk_i,
	input 	reset_i,
	
	input 	uart_rx_i,
	output 	uart_tx_o,

	output 	spi_mosi_o,
	input 	spi_miso_i,
	output	spi_sck_o,
	output 	spi_ss_o,

	inout 	i2c_scl_io,
	inout 	i2c_sda_io,

	inout 	[15:0] gpio_io,
	
	output 	pwm0_o,
	output 	pwm1_o,
	
	input 	jtag_tck_i,
	input 	jtag_tms_i,
	input 	jtag_tdi_i,
	output 	jtag_tdo_o 
);


logic [13:0] address_a_sig;
logic [12:0] address_b_sig;
logic [3:0] byteena_a_sig;
logic [3:0] byteena_b_sig;
logic  clock_a_sig;
logic  clock_b_sig;
logic [31:0] data_a_sig;
logic [31:0] data_b_sig;
logic  enable_a_sig;
logic  enable_b_sig;
logic  wren_a_sig;
logic  wren_b_sig;
logic [31:0] q_a_sig;
logic [31:0] q_b_sig;
logic [31:0] q_boot_sig;

logic tx;
logic rx;
logic mosi;
logic miso;
logic sck;
logic ss;
logic scl_pad_i;
logic scl_pad_o;
logic scl_padoen_o;
logic sda_pad_i;
logic sda_pad_o;
logic sda_padoen_o;
logic [15:0]gpio_oen;
logic [15:0]gpio_o;
logic [15:0]gpio_i;
logic pwm0;
logic pwm1;
logic jtag_tck_ii;
logic tms;
logic tdi;
logic tdo;
logic reset_ii,clk_ii;

mem mem_inst
	(
		.address_a	(address_a_sig) ,	// input [14:0] address_a_sig
		.address_b	(address_b_sig) ,	// input [14:0] address_b_sig
		.byteena_a	(byteena_a_sig) ,	// input [3:0] byteena_a_sig
		.byteena_b	(byteena_b_sig) ,	// input [3:0] byteena_b_sig
		.clock_a	(clock_a_sig) ,	// input  clock_a_sig
		.clock_b	(clock_b_sig) ,	// input  clock_b_sig
		.data_a		(data_a_sig) ,	// input [31:0] data_a_sig
		.data_b		(data_b_sig) ,	// input [31:0] data_b_sig
		.enable_a	(enable_a_sig) ,	// input  enable_a_sig
		.enable_b	(enable_b_sig) ,	// input  enable_b_sig
		.wren_a		(wren_a_sig) ,	// input  wren_a_sig
		.wren_b		(wren_b_sig) ,	// input  wren_b_sig
		.q_a		(q_a_sig) ,	// output [31:0] q_a_sig
		.q_b		(q_b_sig) 	// output [31:0] q_b_sig
	);

arm_boot arm_boot_inst 
	(
		.Q(q_boot_sig),
		.CLK(clock_a_sig),
		.CEN(~enable_a_sig),
		.A(address_a_sig),
		.EMA(0)
	);

soc_top soc_top_inst
	(
		.clk_i			(clk_ii) ,	// input  clk_i_sig
		.reset_i		(reset_ii) ,	// input  reset_i_sig
		//imem
		.address_a_o	(address_a_sig) ,	// output [14:0] address_a_sig
		.address_b_o	(address_b_sig) ,	// output [14:0] address_b_sig
		.byteena_a_o	(byteena_a_sig) ,	// output [3:0] byteena_a_sig
		.byteena_b_o	(byteena_b_sig) ,	// output [3:0] byteena_b_sig
		.clock_a_o		(clock_a_sig) ,	// output  clock_a_sig
		.clock_b_o		(clock_b_sig) ,	// output  clock_b_sig
		.data_a_o		(data_a_sig) ,	// output [31:0] data_a_sig
		.data_b_o		(data_b_sig) ,	// output [31:0] data_b_sig
		.enable_a_o		(enable_a_sig) ,	// output  enable_a_sig
		.enable_b_o		(enable_b_sig) ,	// output  enable_b_sig
		.wren_a_o		(wren_a_sig) ,	// output  wren_a_sig
		.wren_b_o		(wren_b_sig) ,	// output  wren_b_sig
		.q_a_i			(q_a_sig) ,	// input [31:0] q_a_sig
		.q_b_i			(q_b_sig) ,	// input [31:0] q_b_sig
		.q_boot_i		(q_boot_sig),

		//uart
		.tx_o			(tx) ,	// output  tx_sig
		.rx_i			(rx) ,	// input  rx_sig
		// spi
		.mosi_o        	(mosi),
		.miso_i        	(miso),
		.SCK_o         	(sck),
		.slave_select_o	(ss),
		//i2c
		.scl_pad_i		(scl_pad_i),
		.scl_pad_o		(scl_pad_o),
		.scl_padoen_o	(scl_padoen_o),
		.sda_pad_i		(sda_pad_i),
		.sda_pad_o		(sda_pad_o),
		.sda_padoen_o	(sda_padoen_o),
		//gpio
		.gpio_oen		(gpio_oen),
		.gpio_o			(gpio_o),
		.gpio_i			(gpio_i),
		//pwm
		.pwm1_h_o      	(pwm0),
		.pwm1_l_o       (pwm1),

		// jtag
		.tck_i			(jtag_tck_ii) ,	// input  TCK_sig
		.tms_i			(tms) ,	// input  TMS_sig
		.tdi_i			(tdi) ,	// input  TDI_sig
		.tdo_o			(tdo)	// output  TDO_sig	
	);


PDUW04DGZ_G clk_cell //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(
	.I(),
	.OEN(1),
	.PAD(clk_i),
	.C(clk_ii),
	.REN(1)	
);
PDUW04DGZ_G tck_cell //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(
	.I(),
	.OEN(1),
	.PAD(jtag_tck_i),
	.C(jtag_tck_ii),
	.REN(1)	
);

PDDW04DGZ_G reset_cell //PDDW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(
	.I(),
	.OEN(1),
	.PAD(reset_i),
	.C(reset_ii),
	.REN(1)	
);

PCORNER_G p_tr();
PCORNER_G p_tl();
PCORNER_G p_br();
PCORNER_G p_bl();
PVDD1DGZ_G vdd_inst0();
PVSS1DGZ_G vss_inst0();
PVDD1DGZ_G vdd_inst1();
PVSS1DGZ_G vss_inst1();
PVDD1DGZ_G vdd_inst2();
PVSS1DGZ_G vss_inst2();
PVDD1DGZ_G vdd_inst3();
PVSS1DGZ_G vss_inst3();

PVDD2DGZ_G vddpst_inst0();
PVSS2DGZ_G vsspst_inst0();
PVDD2DGZ_G vddpst_inst1();
PVSS2DGZ_G vsspst_inst1();
PVDD2DGZ_G vddpst_inst3();
PVSS2DGZ_G vsspst_inst3();
PVSS2DGZ_G vsspst_inst4();
PVDD2POC_G vdd2poc_inst();

PAD50GU_SL p1();
PAD50GU_SL p2();
PAD50GU_SL p3();
PAD50GU_SL p4();
PAD50GU_SL p5();
PAD50GU_SL p6();
PAD50GU_SL p7();
PAD50GU_SL p8();
PAD50GU_SL p9();
PAD50GU_SL p10();
PAD50GU_SL p11();
PAD50GU_SL p12();
PAD50GU_SL p13();
PAD50GU_SL p14();
PAD50GU_SL p15();
PAD50GU_SL p16();
PAD50GU_SL p17();
PAD50GU_SL p18();
PAD50GU_SL p19();
PAD50GU_SL p20();
PAD50GU_SL p21();
PAD50GU_SL p22();
PAD50GU_SL p23();
PAD50GU_SL p24();
PAD50GU_SL p25();
PAD50GU_SL p26();
PAD50GU_SL p27();
PAD50GU_SL p28();
PAD50GU_SL p29();
PAD50GU_SL p30();
PAD50GU_SL p31();
PAD50GU_SL p32();
PAD50GU_SL p33();
PAD50GU_SL p34();
PAD50GU_SL p35();
PAD50GU_SL p36();
PAD50GU_SL p37();
PAD50GU_SL p38();
PAD50GU_SL p39();
PAD50GU_SL p40();
PAD50GU_SL p41();
PAD50GU_SL p42();
PAD50GU_SL p43();
PAD50GU_SL p44();
PAD50GU_SL p45();
PAD50GU_SL p46();
PAD50GU_SL p47();
PAD50GU_SL p48();

PDUW04DGZ_G uart_tx //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(tx),.OEN(0),.PAD(uart_tx_o),.C(),.REN(1)
);
PDUW04DGZ_G uart_rx //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(),.OEN(1),.PAD(uart_rx_i),.C(rx),.REN(1)
);
PDUW04DGZ_G spi_miso //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(),.OEN(1),.PAD(spi_miso_i),.C(miso),.REN(1)
);
PDUW04DGZ_G spi_mosi //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(mosi),.OEN(0),.PAD(spi_mosi_o),.C(),.REN(1)
);
PDUW04DGZ_G spi_sck //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(sck),.OEN(0),.PAD(spi_sck_o),.C(),.REN(1)
);
PDUW04DGZ_G spi_ss //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(ss),.OEN(0),.PAD(spi_ss_o),.C(),.REN(1)
);
PDUW04DGZ_G i2c_scl //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(scl_pad_o),.OEN(scl_padoen_o),.PAD(i2c_scl_io),.C(scl_pad_i),.REN(1)
);
PDUW04DGZ_G i2c_sda //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(sda_pad_o),.OEN(sda_padoen_o),.PAD(i2c_sda_io),.C(sda_pad_i),.REN(1)
);
PDUW04DGZ_G gpio_0 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[0]),.OEN(~gpio_oen[0]),.PAD(gpio_io[0]),.C(gpio_i[0]),.REN(1)
);
PDUW04DGZ_G gpio_1 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[1]),.OEN(~gpio_oen[1]),.PAD(gpio_io[1]),.C(gpio_i[1]),.REN(1)
);
PDUW04DGZ_G gpio_2 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[2]),.OEN(~gpio_oen[2]),.PAD(gpio_io[2]),.C(gpio_i[2]),.REN(1)
);
PDUW04DGZ_G gpio_3 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[3]),.OEN(~gpio_oen[3]),.PAD(gpio_io[3]),.C(gpio_i[3]),.REN(1)
);
PDUW04DGZ_G gpio_4 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[4]),.OEN(~gpio_oen[4]),.PAD(gpio_io[4]),.C(gpio_i[4]),.REN(1)
);
PDUW04DGZ_G gpio_5 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[5]),.OEN(~gpio_oen[5]),.PAD(gpio_io[5]),.C(gpio_i[5]),.REN(1)
);
PDUW04DGZ_G gpio_6 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[6]),.OEN(~gpio_oen[6]),.PAD(gpio_io[6]),.C(gpio_i[6]),.REN(1)
);
PDUW04DGZ_G gpio_7 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[7]),.OEN(~gpio_oen[7]),.PAD(gpio_io[7]),.C(gpio_i[7]),.REN(1)
);
PDUW04DGZ_G gpio_8 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[8]),.OEN(~gpio_oen[8]),.PAD(gpio_io[8]),.C(gpio_i[8]),.REN(1)
);
PDUW04DGZ_G gpio_9 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[9]),.OEN(~gpio_oen[9]),.PAD(gpio_io[9]),.C(gpio_i[9]),.REN(1)
);
PDUW04DGZ_G gpio_10 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[10]),.OEN(~gpio_oen[10]),.PAD(gpio_io[10]),.C(gpio_i[10]),.REN(1)
);
PDUW04DGZ_G gpio_11 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[11]),.OEN(~gpio_oen[11]),.PAD(gpio_io[11]),.C(gpio_i[11]),.REN(1)
);
PDUW04DGZ_G gpio_12 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[12]),.OEN(~gpio_oen[12]),.PAD(gpio_io[12]),.C(gpio_i[12]),.REN(1)
);
PDUW04DGZ_G gpio_13 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[13]),.OEN(~gpio_oen[13]),.PAD(gpio_io[13]),.C(gpio_i[13]),.REN(1)
);
PDUW04DGZ_G gpio_14 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[14]),.OEN(~gpio_oen[14]),.PAD(gpio_io[14]),.C(gpio_i[14]),.REN(1)
);
PDUW04DGZ_G gpio_15 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(gpio_o[15]),.OEN(~gpio_oen[15]),.PAD(gpio_io[15]),.C(gpio_i[15]),.REN(1)
);
/*
genvar i;
generate
	for(i = 0; i < 32; i=i+1)
		begin : gpio_gen
			PDUW04DGZ_G gpio_15 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
			(
				.I(gpio_o[i]),
				.OEN(~gpio_oen[i]),
				.PAD(gpio_io[i]),
				.C(gpio_i[i]),
				.REN(1)
			);
		end : gpio_gen
endgenerate
*/
PDUW04DGZ_G pwm_0 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(pwm0),.OEN(0),.PAD(pwm0_o),.C(),.REN(1)
);
PDUW04DGZ_G pwm_1 //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(pwm1),.OEN(0),.PAD(pwm1_o),.C(),.REN(1)
);
PDUW04DGZ_G jtag_tms //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(),.OEN(1),.PAD(jtag_tms_i),.C(tms),.REN(1)
);
PDUW04DGZ_G jtag_tdi //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(),.OEN(1),.PAD(jtag_tdi_i),.C(tdi),.REN(1)
);
PDUW04DGZ_G jtag_tdo //PDUW04DGZ_G (I,DS,OEN,PAD,C,REN,IE);
(.I(tdo),.OEN(0),.PAD(jtag_tdo_o),.C(),.REN(1)
);
endmodule
