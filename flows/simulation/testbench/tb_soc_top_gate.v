`timescale 1ns/10ps
module tb_top;



wire  VDD;
wire  VSS;
wire  VDDPST;
wire  VSSPST;

reg  clk_i;
reg  reset_i;

wire  uart_rx_i;
wire  uart_tx_o;

wire  spi_mosi_o;
wire  spi_miso_i;
wire  spi_sck_o;
wire  [7:0] spi_ss_o;

wire  i2c_scl_io;
wire  i2c_sda_io;

wire  [31:0] gpio_io;

wire  pwm0_o;
wire  pwm1_o;

wire  jtag_tck_i;
wire  jtag_tms_i;
wire  jtag_tdi_i;
wire  jtag_tdo_o;

initial begin
	$sdf_annotate("../synthesis/genus/work/output/top_m.sdf",tb_top.top_inst,,"sdf.log","MAXIMUM");

	$display("=====================");
	$display("Gate Level Simulation");
	$display("=====================");
	clk_i = 0;
	reset_i = 1'b1; #100 reset_i = 1'b0;
end

always 
begin 
	#10 clk_i = !clk_i;
end 
 
top top_inst
(
	/*.VDD(VDD),
	.VSS(VSS),
	.VDDPST(VDDPST),
	.VSSPST(VSSPST),
*/
	.clk_i(clk_i),
	.reset_i(reset_i),
	
	.uart_rx_i(uart_rx_i),
	.uart_tx_o(uart_tx_o),

	.spi_mosi_o(spi_mosi_o),
	.spi_miso_i(spi_miso_i),
	.spi_sck_o(spi_sck_o),
	.spi_ss_o(spi_ss_o),

	.i2c_scl_io(i2c_scl_io),
	.i2c_sda_io(i2c_sda_io),

	.gpio_io(gpio_io),
	
	.pwm0_o(pwm0_o),
	.pwm1_o(pwm1_o),
	
	.jtag_tck_i(jtag_tck_i),
	.jtag_tms_i(jtag_tms_i),
	.jtag_tdi_i(jtag_tdi_i),
	.jtag_tdo_o(jtag_tdo_o) 
);

	
	  
endmodule 
