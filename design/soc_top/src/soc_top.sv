`timescale 1ns/10ps
import common_pkg::*;
import debug_pkg::*;
import core_pkg::*;

//`define BOOT
//`define DV_TRACER
//`define FPU

module soc_top
(

    input clk_i,
    input reset_i,

    //imem
	output logic [13:0]  address_a_o,
	output logic [11:0]  address_b_o,
	output logic [3:0]  byteena_a_o,
	output logic [3:0]  byteena_b_o,
	output logic clock_a_o,
	output logic clock_b_o,
	output logic [31:0]  data_a_o,
	output logic [31:0]  data_b_o,
	output logic enable_a_o,
	output logic enable_b_o,
	output logic wren_a_o,
	output logic wren_b_o,
	input	[31:0]  q_a_i,
	input	[31:0]  q_b_i,
	input [31:0]  q_boot_i,



    //peripherals
    //uart
    output 					tx_o,
    input 					rx_i,
    //spi
    output 					mosi_o,
    input 					miso_i,
    output 					SCK_o,
    output 			[7:0] 	slave_select_o,
    //i2c
    input  					scl_pad_i,
    output 					scl_pad_o,
    output 					scl_padoen_o,
    input  					sda_pad_i,
    output 					sda_pad_o,
    output 					sda_padoen_o,
    //gpio
   	output			[31:0] 	gpio_oen,
	output			[31:0] 	gpio_o,
	input 			[31:0] 	gpio_i,
    // PWM
  	output logic 			pwm1_h_o,
	output logic 			pwm1_l_o,
	output logic 			pwm2_h_o,
	output logic 			pwm2_l_o,

	input tms_i,
	input tck_i,
	input tdi_i,
	output tdo_o
);


		/////////////////////////////////////
	
		wire logic [31:0]timer_readdata;
		wire logic [31:0]gpio_readdata;
		wire logic [31:0]mem_readdata;
		wire logic [31:0]imem_readdata;
		wire logic [31:0]uart_readdata;
		wire logic [31:0]spi_readdata;
		wire logic [31:0]i2c_readdata;
		wire logic [31:0]pwm_readdata;
		wire logic [14:0]mem_addr;
		wire logic [14:0]imem_addr;
		wire logic [2:0]timer_addr;
		wire logic [2:0] gpio_addr;
		wire logic [7:0] spi_addr;
		wire logic [7:0] i2c_addr;
		wire logic [7:0] pwm_addr;
		wire logic timer_chipsel;
		wire logic mem_chipsel;
		wire logic imem_chipsel;
		wire logic gpio_chipsel;
		wire logic uart_chipsel;
		wire logic spi_chipsel;
		wire logic i2c_chipsel;
		wire logic pwm_chipsel;
		
		onebit_sig_e ar_en;
		onebit_sig_e ar_wr;
		logic [15:0] ar_ad;
		onebit_sig_e ar_done;
		logic [31:0] ar_di;
		logic [31:0] ar_do;
		onebit_sig_e am_en;
		onebit_sig_e am_wr;
		logic [3:0]  am_st;
		logic [31:0] am_ad;
		logic [31:0] am_di;
		logic [31:0] am_do;
		onebit_sig_e am_done;

		onebit_sig_e ndmreset;
		onebit_sig_e resumeack;
		onebit_sig_e running;
		onebit_sig_e halted;
		onebit_sig_e haltreq;
		onebit_sig_e resumereq;

    logic timer_interrupt;
    logic ext_interrupt;
    logic soft_intr;
    logic soft_chipsel;

    logic i2c_interrupt;
    logic spi_interrupt;
    logic uart_tx_interrupt;
    logic uart_rx_interrupt;
    logic [31:0] gpio_itr_sig;
    logic [1:0] gpio_interrupt;

    logic plic_chipsel;
    logic [31:0]plic_readdata;
    logic [1:0]plic_addr;

    logic plic_claim;
    logic plic_complete;

    logic crc_chipsel;
    logic [31:0]crc_readdata;
    logic [2:0]crc_addr;


		IBus ibus();
		DBus dbus();

    //Instruction port

		//access fsm
		logic sel_dbus;
		assign sel_dbus = imem_chipsel & (dbus.write | dbus.read);
		logic spc_en;
		logic data_en;
		logic [31:0] data;
		logic [31:0] spc;
		always_ff@(posedge clk_i or  posedge reset_i)
		begin
			if(reset_i)
				spc <= 0;
			else if(spc_en)
				spc <= (ibus.address>>2) - 1;
		end
		always_ff@(posedge clk_i or  posedge reset_i)
		begin
			if(reset_i)
				data <= 0;
			else if(data_en)
				data <= dbus.address[31]? q_boot_i : q_a_i;
		end

		enum logic [1:0] {S0,S1,S2,S3} pstate, nstate;
		always_ff@(posedge clk_i or  posedge reset_i)
		begin
			if(reset_i)
				pstate <= S0;
			else
				pstate <= nstate;
		end
		always_comb
		begin
			case(pstate)
				S0: begin
						address_a_o 	= ibus.address>>2;
						byteena_a_o 	= 4'd0;
						data_a_o 		= 0;
						enable_a_o 		= ~(ibus.enable);
						wren_a_o 		= 1'b0;
						nstate 			= sel_dbus? S1 : S0;
						dbus.stall 		= sel_dbus;
						spc_en 			= sel_dbus;
						data_en 		= 1'b0;
					end
				S1: begin
						address_a_o 	= imem_addr;
						byteena_a_o 	= dbus.byteenable;
						data_a_o 		= dbus.writedata;
						enable_a_o 		= 1'b1;
						wren_a_o 		= dbus.write;
						nstate 			= S2;
						dbus.stall 		= 1'b1;
						spc_en 			= 1'b0;
						data_en 		= 1'b0;
					end
				S2: begin
						address_a_o 	= spc;
						byteena_a_o 	= 4'd0;
						data_a_o 		= 0;
						enable_a_o 		= 1'b1;
						wren_a_o 		= 1'b0;
						nstate 			= S3;
						dbus.stall 		= 1'b1;
						spc_en 			= 1'b0;
						data_en			= 1'b1;
					end
				S3: begin
						address_a_o 	= ibus.address>>2;
						byteena_a_o 	= 4'd0;
						data_a_o 		= 0;
						enable_a_o 		= ~(ibus.enable);
						wren_a_o 		= 1'b0;
						nstate 			= S0;
						dbus.stall 		= 1'b0;
						spc_en 			= 1'b0;
						data_en 		= 1'b0;
					end
			endcase
		end

		//Instruction port
    //if ibus_address[31] select boot readdata delay until stall
    logic boot_chipsel;
    always_ff@(posedge clk_i or posedge reset_i)
		begin
      if(reset_i)
	  	`ifdef BOOT
				boot_chipsel <= 1'b1;//1 -> boot memory, 0 -> instruction memory
		`else
				boot_chipsel <= 1'b0;//1 -> boot memory, 0 -> instruction memory
		`endif
      else if((pstate == S0 || pstate == S3) && enable_a_o)
        boot_chipsel <= ibus.address[31];
		end

		assign clock_a_o 		= clk_i;
		assign ibus.instruction = boot_chipsel? q_boot_i : q_a_i;
		assign imem_readdata 	= data;
		
        //data port
    assign	clock_b_o 		= clk_i;
    assign  address_b_o 	= mem_addr;
    assign  byteena_b_o 	= dbus.byteenable;
    assign  data_b_o 		= dbus.writedata;
    assign	enable_b_o 		= 1'b1;
    assign	wren_b_o 		= (dbus.write & mem_chipsel);
    assign  mem_readdata	= q_b_i; 
	 
		core_top core_top_inst
			(
				.clk_i			(clk_i),
				.reset_i		(reset_i | ndmreset),
				//instruction master
				.ibus			(ibus),	
				//custom bus
				.dbus			(dbus),

				.resumeack_o	(resumeack),
				.running_o		(running),
				.halted_o		(halted),

				.haltreq_i		(haltreq),
				.resumereq_i	(resumereq),

				.ar_en_i		(ar_en),
				.ar_wr_i		(ar_wr),
				.ar_ad_i		(ar_ad),
				.ar_done_o		(ar_done),
				.ar_di_i		(ar_do),
				.ar_do_o		(ar_di),

				.am_en_i		(am_en),
				.am_wr_i		(am_wr),
				.am_st_i		(am_st),
				.am_ad_i		(am_ad),
				.am_di_i		(am_do),
				.am_do_o		(am_di),
				.am_done_o		(am_done),


        .ext_itr_i  (ext_interrupt),
        .timer_itr_i(timer_interrupt),
        .soft_itr_i (soft_intr),

        .plic_claim_o(plic_claim),
        .plic_complete_o(plic_complete)

			);

		debug_top debug_top_inst
			(
				.tms_i		(tms_i),
				.tck_i		(tck_i),
				.trstn_i	(/*1'b1*/~reset_i),
				.tdi_i		(tdi_i),
				.tdo_o		(tdo_o),

				.rst_i		(reset_i),
				.clk_i		(clk_i),

				.resumeack_i(resumeack),
				.running_i	(running),
				.halted_i	(halted),

				.haltreq_o	(haltreq),
				.resumereq_o(resumereq),
				.ndmreset_o	(ndmreset),

				.ar_en_o	(ar_en),
				.ar_wr_o	(ar_wr),
				.ar_ad_o	(ar_ad),
				.ar_done_i	(ar_done),
				.ar_di_i	(ar_di),
				.ar_do_o	(ar_do),

				.am_en_o	(am_en),
				.am_wr_o	(am_wr),
				.am_st_o	(am_st),
				.am_ad_o	(am_ad),
				.am_di_i	(am_di),
				.am_do_o	(am_do),
				.am_done_i	(am_done)
			);

		avalon_interconnect avalon_interconnect_inst(
				.clk_i				(clk_i),
				.stall_i			(1'b0),

				.avalon_addr_i		(dbus.address),

				.imem_readdata_i	(imem_readdata), 
				.mem_readdata_i		(mem_readdata), 
				.timer_readdata_i	(timer_readdata),
				.gpio_readdata_i	(gpio_readdata), 
				.uart_readdata_i	(uart_readdata), 
				.spi_readdata_i		(spi_readdata),
				.i2c_readdata_i 	(i2c_readdata),
				.pwm_readdata_i  	(pwm_readdata),
        .plic_readdata_i  (plic_readdata),
        .crc_readdata_i  (crc_readdata),

				.imem_addr_o		(imem_addr),
				.mem_addr_o			(mem_addr),
				.gpio_addr_o		(gpio_addr), 
				.timer_addr_o		(timer_addr),
				.spi_addr_o			(spi_addr),
				.i2c_addr_o     (i2c_addr),
				.pwm_addr_o     (pwm_addr),
        .plic_addr_o    (plic_addr),
        .crc_addr_o     (crc_addr),

				.imem_chipsel_o		(imem_chipsel),
				.mem_chipsel_o		(mem_chipsel),
				.timer_chipsel_o	(timer_chipsel),
				.uart_chipsel_o		(uart_chipsel),
				.gpio_chipsel_o		(gpio_chipsel),
				.spi_chipsel_o		(spi_chipsel),
				.i2c_chipsel_o   	(i2c_chipsel),
				.pwm_chipsel_o   	(pwm_chipsel),
        .soft_chipsel_o   (soft_chipsel),
        .plic_chipsel_o   (plic_chipsel),
        .crc_chipsel_o    (crc_chipsel),

				.data_out_o			(dbus.readdata)
			);	
	
		timer_top timer_inst
			(
				.clk_i		(clk_i),
				.stall_i	(1'b0),
				.reset		(reset_i | ndmreset ),
				.address	(timer_addr),
				.writedata	(dbus.writedata),
				.write		(dbus.write),
				.readdata	(timer_readdata),
				.read		(dbus.read),
			
				.chipselect	(timer_chipsel),
				.intr_o		(timer_interrupt)
			);
		gpio_top gpio_inst
			(
				.clk_i			(clk_i),
				.resetn_i		(reset_i | ndmreset ),
				.address_i		(gpio_addr),
				.writedata_i	(dbus.writedata),
				.write_i		(dbus.write),
				.readdata_o		(gpio_readdata),
				.read_i			(dbus.read),
				.chipselect_i	(gpio_chipsel),
			
				.gpio_oen		(gpio_oen),
				.gpio_i			(gpio_i),
				.gpio_o			(gpio_o),
				.interrupt_reg	(gpio_itr_sig)
				
					
			);
		uart_top uart_inst 
			(
				.clk_i			(clk_i),
				.rst_i			(reset_i | ndmreset ),
				.address_i		(dbus.address),
				.writedata_i	(dbus.writedata),
				.write_i		(dbus.write & uart_chipsel),
				.readdata_o		(uart_readdata),
				.read_i			(dbus.read & uart_chipsel),
				.chipselect_i	(uart_chipsel),
			
				.rx_i			(rx_i),
				.tx_o			(tx_o),
				.tx_intr_o(uart_tx_interrupt),
        .rx_intr_o(uart_rx_interrupt)
			);
		spi_top spi_inst 
			(
				.clk_i        (clk_i),
				.rst_i        (reset_i | ndmreset),
				.write_i      (dbus.write & spi_chipsel),
				.read_i       (dbus.read & spi_chipsel),
				.chipselect_i (spi_chipsel),
				.writedata_i  (dbus.writedata),
				.address_i    ({24'd0,dbus.address[7:0]}),
				.readdata_o   (spi_readdata),
			
				.spi_cs_o     (slave_select_o),
				.spi_miso_i   (miso_i),
				.spi_mosi_o   (mosi_o),
				.intr_o       (spi_interrupt),
				.spi_clk_o    (SCK_o)
			);
		i2c_top i2c_inst 
			(
				.clk_i      	(clk_i),
				.rstn_i     	(reset_i | ndmreset),
				.avl_addr   	(i2c_addr),
				.avl_wdata  	(dbus.writedata),
				.avl_write 		(dbus.write & i2c_chipsel),
				.avl_chipsel	(i2c_chipsel),
				.avl_rdata  	(i2c_readdata),
				.interrupt_o	(i2c_interrupt),
				.scl_pad_i     	(scl_pad_i),
				.scl_pad_o     	(scl_pad_o),
				.scl_padoen_o  	(scl_padoen_o),
				.sda_pad_i     	(sda_pad_i),
				.sda_pad_o    	(sda_pad_o),
				.sda_padoen_o  	(sda_padoen_o),
				.test			()

			);
		pwm_top pwm_inst 
			(
				.clk_i        	(clk_i),
				.rst_i        	(reset_i | ndmreset),
				.address_i    	(pwm_addr),
				.writedata_i  	(dbus.writedata),
				.write_i      	(dbus.write & pwm_chipsel ),
				.readdata_o   	(pwm_readdata),
				.read_i       	(dbus.read & pwm_chipsel),
		
				.chipselect_i 	(pwm_chipsel),
				.pwm1_h_o       (pwm1_h_o),
				.pwm1_l_o       (pwm1_l_o),
				.pwm2_h_o		(pwm2_h_o),
				.pwm2_l_o		(pwm2_l_o)
			);

    crc_avalon_wrap crc_avalon_wrap_inst
      (
        .clk_i        (clk_i),
        .reset_i      (reset_i | ndmreset),
        .write_i      (dbus.write),
        .read_i       (dbus.read),
        .chipselect_i (crc_chipsel),
        .writedata_i  (dbus.writedata),
        .address_i    (crc_addr),
        .readdata_o   (crc_readdata)
      );

    //software interrupt peripheral
//    logic soft_intr_reset;
//    assign soft_intr_reset = reset_i | ndmreset;
    always_ff@(posedge clk_i or posedge reset_i)
    begin
      if(reset_i)
        soft_intr <= 1'b0;
      else if(soft_chipsel && dbus.write)
        soft_intr <= dbus.writedata[0];
    end

    assign gpio_interrupt = gpio_itr_sig[3:2];
    //plic
    plic #
    (
      .Number_of_Sources(6),
      .Interrupt_Width  (3),
      .Number_of_Targets(1)
    )
    plic_inst
    (
      // signals for connecting to the Avalon fabric
      .clk_i        (clk_i),
      .resetn_i     (reset_i | ndmreset),
      .write_i      (dbus.write),
      .read_i       (dbus.read),
      .chipselect_i (plic_chipsel),
      .writedata_i  (dbus.writedata),
      .address_i    (plic_addr),

      //From Sources
      .Interrupt    ({i2c_interrupt, spi_interrupt, uart_tx_interrupt,uart_rx_interrupt, gpio_interrupt}),            // interrupt from source
      .ED           (1'b1), 
      //From Target(Hart  Context)
      .Interrupt_Claim   (plic_claim),
      .Interrupt_Complete(plic_complete),

      //To Target(Hart Context)
     .Interrupt_Notification(ext_interrupt),
     .readdata_o            (plic_readdata)

    );
		
	  
endmodule