`timescale 1ns/10ps
module avalon_interconnect(
	input clk_i,
	input stall_i,
	input [31:0] avalon_addr_i, 
	input [31:0] mem_readdata_i,
	input [31:0] imem_readdata_i,	
	input [31:0] timer_readdata_i,
	input [31:0] gpio_readdata_i,
	input [31:0] uart_readdata_i,	
	input [31:0] spi_readdata_i,	
	input [31:0] i2c_readdata_i,
	input [31:0] pwm_readdata_i,
  input [31:0] plic_readdata_i,
  input [31:0] crc_readdata_i,

	output [11:0] mem_addr_o,
	output [13:0] imem_addr_o,
	output [2:0] gpio_addr_o,
	//output [1:0] uart_addr_o,
	output [2:0] timer_addr_o, 
	output [7:0] spi_addr_o, 
	output [7:0] i2c_addr_o,
	output [7:0] pwm_addr_o,
  output [1:0] plic_addr_o,
  output [2:0] crc_addr_o,

	output mem_chipsel_o,
	output imem_chipsel_o,
	output timer_chipsel_o,
	output gpio_chipsel_o,
	output uart_chipsel_o,
	output spi_chipsel_o,
	output i2c_chipsel_o,
	output pwm_chipsel_o,
  output soft_chipsel_o,
  output plic_chipsel_o,
  output crc_chipsel_o,
	output var logic[31:0] data_out_o
);

	var logic mem_chipsel_reg;
	var logic imem_chipsel_reg;
	var logic timer_chipsel_reg;
	var logic gpio_chipsel_reg;
	var logic uart_chipsel_reg;
	var logic spi_chipsel_reg;
	var logic i2c_chipsel_reg;
	var logic pwm_chipsel_reg;
  var logic plic_chipsel_reg;
  var logic crc_chipsel_reg;

	assign timer_addr_o = avalon_addr_i[4:0]>>2;
	//assign uart_addr_o = avalon_addr_i[3:0]>>2;
	assign gpio_addr_o	= avalon_addr_i[3:0]>>2;
	assign mem_addr_o 	= avalon_addr_i[13:0]>>2;
	assign imem_addr_o 	= avalon_addr_i[15:0]>>2;
	assign spi_addr_o 	= avalon_addr_i[7:0];
	assign i2c_addr_o 	= avalon_addr_i[7:0];
	assign pwm_addr_o 	= avalon_addr_i[7:0]>>2;
  assign plic_addr_o  = avalon_addr_i[3:0]>>2;
  assign crc_addr_o   = avalon_addr_i[4:0]>>2;

  assign soft_chipsel_o  = (avalon_addr_i == 32'h4000000);
  assign crc_chipsel_o   = (avalon_addr_i >= 32'h80000   && avalon_addr_i <= 32'h8001F);
	assign timer_chipsel_o = (avalon_addr_i >= 32'h200000  && avalon_addr_i <= 32'h200010);
	assign uart_chipsel_o  = (avalon_addr_i >= 32'h100000  && avalon_addr_i <= 32'h100010);
	assign gpio_chipsel_o  = (avalon_addr_i >= 32'h400000  && avalon_addr_i <= 32'h40000F);
  assign plic_chipsel_o  = (avalon_addr_i >= 32'h800000  && avalon_addr_i <= 32'h80000F);
	assign spi_chipsel_o   = (avalon_addr_i >= 32'h1000000 && avalon_addr_i <= 32'h10000ff);
	assign i2c_chipsel_o   = (avalon_addr_i >= 32'h2000000 && avalon_addr_i <= 32'h20000ff);
	assign pwm_chipsel_o   = (avalon_addr_i >= 32'h2001000 && avalon_addr_i <= 32'h2001fff);
	assign mem_chipsel_o   = (avalon_addr_i >= 32'h00010000   && avalon_addr_i <= 32'h00012000);
	assign imem_chipsel_o  = (avalon_addr_i >= 32'h00000000   && avalon_addr_i <= 32'h00008000) || //sel imem
                           (avalon_addr_i >= 32'h80000000   && avalon_addr_i <= 32'h80000200); //sel boot

	always_ff@(posedge clk_i)
	begin
		if(~stall_i)
		begin
			gpio_chipsel_reg 	<= gpio_chipsel_o;
			timer_chipsel_reg 	<= timer_chipsel_o;
			uart_chipsel_reg 	<= uart_chipsel_o;
			mem_chipsel_reg 	<= mem_chipsel_o;
			imem_chipsel_reg 	<= imem_chipsel_o;
			spi_chipsel_reg 	<= spi_chipsel_o;
			i2c_chipsel_reg 	<= i2c_chipsel_o;
			pwm_chipsel_reg 	<= pwm_chipsel_o;
      plic_chipsel_reg  <= plic_chipsel_o;
      crc_chipsel_reg   <= crc_chipsel_o;
	
		end
	end

	always_comb 
	begin
		case ({imem_chipsel_reg,mem_chipsel_reg,uart_chipsel_reg,timer_chipsel_reg,gpio_chipsel_reg,spi_chipsel_reg,i2c_chipsel_reg,pwm_chipsel_reg,plic_chipsel_reg,crc_chipsel_reg})
			10'b1000000000:  data_out_o = imem_readdata_i;
			10'b0100000000:  data_out_o = mem_readdata_i;
			10'b0010000000:  data_out_o = uart_readdata_i;
			10'b0001000000:  data_out_o = timer_readdata_i;
			10'b0000100000:  data_out_o = gpio_readdata_i;
			10'b0000010000:  data_out_o = spi_readdata_i;
			10'b0000001000:  data_out_o = i2c_readdata_i;
			10'b0000000100:  data_out_o = pwm_readdata_i;
      10'b0000000010:  data_out_o = plic_readdata_i;
      10'b0000000001:  data_out_o = crc_readdata_i;
			default:   	  data_out_o = 0;
		endcase
	end
endmodule
