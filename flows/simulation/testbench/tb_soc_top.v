`timescale 1ns/10ps
`include "mem_map.svh"
module tb_soc_top(
`ifdef VERILATOR_SIM
    	input clk,reset,trst

);
`else
);
reg clk,reset,trst;
`endif

	  initial begin
		 $display("==============");
		 $display("SoC Terminal");
		 $display("==============");
		 `ifndef VERILATOR_SIM
		 clk = 0;
		 trst = 0;
		 reset = 1'b1; #100 reset = 1'b0; trst = 1'b1;
		 `endif
	  end


wire [`IMEM_ADDR_WIDTH-1:0] address_a_sig;
wire [`DMEM_ADDR_WIDTH-1:0] address_b_sig;
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
wire	[31:0]  q_boot_sig;


wire tms,tck,tdi,tdo;
`ifdef JTAG_DPI
SimJTAG SimJTAG_inst
(

	.clock(clk),
	.reset(reset),

	.enable(1'b1),
	.init_done(1'b1),

	.jtag_TCK(tck),
	.jtag_TMS(tms),
	.jtag_TDI(tdi),
	.jtag_TRSTn(),
	.srstn(),

	.jtag_TDO_data(tdo),
	.jtag_TDO_driven(1'b1)
);
`endif

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

arm_boot arm_boot_inst (

	.Q(q_boot_sig),
	.CLK(clock_a_sig),
	.CEN(~enable_a_sig),
	.A(address_a_sig),
	.EMA(0)
);


 wire  tx, rx;
soc_top soc_top_inst
	(
		.clk_i(clk) ,	// input  clk_i_sig
		.reset_i(reset) ,	// input  reset_i_sig
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
    	.q_boot_i(q_boot_sig),

		//uart
		.tx_o(tx) ,	// output  tx_sig
		.rx_i(rx) ,	// input  rx_sig
		// spi
		.mosi_o        (),
		.miso_i        (),
		.SCK_o         (),
		.slave_select_o(),
		//i2c
		.scl_pad_i(),
		.scl_pad_o(),
		.scl_padoen_o(),
		.sda_pad_i(),
		.sda_pad_o(),
		.sda_padoen_o(),
		//gpio
		.gpio_oen(),
		.gpio_o(),
		.gpio_i(),
		//pwm

		.pwm1_h_o       ( ),
		.pwm1_l_o       ( ),
		.pwm2_h_o		( ),
		.pwm2_l_o		( ),

		// jtag
		.tck_i(tck) ,	// input  TCK_sig
		.tms_i(tms) ,	// input  TMS_sig
		.tdi_i(tdi) ,	// input  TDI_sig
		.tdo_o(tdo)	// output  TDO_sig

	);


  uartdpi #(
    .BAUD(115200),
    .FREQ(50000000)
  )
  u_uart(
    .clk(clk),
    .rst(reset),
    .rx(tx),
    .tx(rx)
  );

// ============================================================
// Tohost monitor — detects test completion via write to TOHOST_ADDR
// Software writes 1 for PASS, any other non-zero value for FAIL.
// ============================================================

// Signature extraction for RISCOF: plusargs +sig_file, +sig_begin, +sig_end
string sig_file_str;
reg [31:0] sig_begin_addr, sig_end_addr;
reg sig_enabled;
integer sig_fd;
integer sig_idx;
reg [31:0] sig_word;

initial begin
	if ($value$plusargs("sig_file=%s", sig_file_str))
		sig_enabled = 1;
	else
		sig_enabled = 0;
	if (!$value$plusargs("sig_begin=%h", sig_begin_addr))
		sig_begin_addr = 32'h0;
	if (!$value$plusargs("sig_end=%h", sig_end_addr))
		sig_end_addr = 32'h0;
end

task dump_signature;
	integer word_begin, word_end;
	begin
		if (sig_enabled && sig_end_addr > sig_begin_addr) begin
			sig_fd = $fopen(sig_file_str, "w");
			if (sig_fd == 0) begin
				$display("ERROR: Cannot open signature file: %s", sig_file_str);
			end else begin
				// Signature is in DMEM: convert absolute address to DMEM word index
				word_begin = (sig_begin_addr - `DMEM_BASE) / 4;
				word_end   = (sig_end_addr - `DMEM_BASE) / 4;
				for (sig_idx = word_begin; sig_idx < word_end; sig_idx = sig_idx + 1) begin
					sig_word = mem_inst.m2.mem[sig_idx];
					$fwrite(sig_fd, "%08x\n", sig_word);
				end
				$fclose(sig_fd);
				$display("SIGNATURE: dumped %0d words to %s", word_end - word_begin, sig_file_str);
			end
		end
	end
endtask

always @(posedge clk) begin
	if (!reset &&
	    soc_top_inst.dbus.write &&
	    soc_top_inst.dbus.address == `TOHOST_ADDR) begin
		dump_signature;
		if (soc_top_inst.dbus.writedata == 32'h1) begin
			$display("TEST PASSED");
			$finish;
		end else begin
			$display("TEST FAILED (tohost = 0x%08h)", soc_top_inst.dbus.writedata);
			$finish;
		end
	end
end

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
