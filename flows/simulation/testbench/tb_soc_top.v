`timescale 1ns/10ps
`include "mem_map.svh"
module tb_soc_top(
`ifdef VERILATOR_SIM
    	input clk,reset,trst,
    	output [31:0] pc_id_o,
    	output [1:0]  priv_level_o

);
`else
);
reg clk,reset,trst;
`endif

`ifdef VERILATOR_SIM
assign pc_id_o      = soc_top_inst.core_top_inst.pc_id;
assign priv_level_o = soc_top_inst.core_top_inst.priv_level;
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


 wire  tx, rx;
soc_top soc_top_inst
	(
		.clk_i(clk) ,
		.reset_i(reset) ,
		//uart
		.tx_o(tx) ,
		.rx_i(rx) ,
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
		.tck_i(tck) ,
		.tms_i(tms) ,
		.tdi_i(tdi) ,
		.tdo_o(tdo)

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
				// Signature is in unified RAM: convert absolute address to word index
				word_begin = (sig_begin_addr - `RAM_BASE) / 4;
				word_end   = (sig_end_addr - `RAM_BASE) / 4;
				for (sig_idx = word_begin; sig_idx < word_end; sig_idx = sig_idx + 1) begin
					sig_word = soc_top_inst.ram_inst.mem[sig_idx];
					$fwrite(sig_fd, "%08x\n", sig_word);
				end
				$fclose(sig_fd);
				$display("SIGNATURE: dumped %0d words to %s", word_end - word_begin, sig_file_str);
			end
		end
	end
endtask

// Only trigger tohost in M-mode (bare-metal tests), not during Linux (S/U-mode)
always @(posedge clk) begin
	if (!reset &&
	    soc_top_inst.dmem_bus.req &&
	    soc_top_inst.dmem_bus.we &&
	    soc_top_inst.dmem_bus.addr == `TOHOST_ADDR &&
	    soc_top_inst.core_top_inst.priv_level == 2'b11) begin
		dump_signature;
		if (soc_top_inst.dmem_bus.wdata == 32'h1) begin
			$display("TEST PASSED");
			$finish;
		end else begin
			$display("TEST FAILED (tohost = 0x%08h)", soc_top_inst.dmem_bus.wdata);
			$finish;
		end
	end
end

// ── Fast simulation console ─────────────────────────────────────
// Captures UART TX register writes directly from the bus, bypassing
// the slow bit-by-bit UART serializer. Characters appear immediately.
integer sim_con_fd;
integer sim_dbg_fd;
initial begin
	sim_con_fd = $fopen("uart.log", "w");
	sim_dbg_fd = $fopen("debug.log", "w");
end

always @(posedge clk) begin
	if (!reset &&
	    soc_top_inst.dmem_bus.req &&
	    soc_top_inst.dmem_bus.we &&
	    soc_top_inst.dmem_bus.addr == 32'h10000004) begin  // UART TX @ 0x10000004
		$fwrite(sim_con_fd, "%c", soc_top_inst.dmem_bus.wdata[7:0]);
		$fflush(sim_con_fd);
		$write("%c", soc_top_inst.dmem_bus.wdata[7:0]);
	end
end

// ── Trap / mret monitor ──
always @(posedge clk) begin
	if (!reset) begin
		if (soc_top_inst.core_top_inst.interrupt_valid) begin
			$fwrite(sim_dbg_fd, "TRAP @%0d pc=%08h cause=%08h priv=%0d→%0d tval=%08h epc=%08h satp=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.ecause_csr,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.trap_to_s ? 2'd1 : 2'd3,
				soc_top_inst.core_top_inst.mtval_csr,
				soc_top_inst.core_top_inst.epc_csr,
				soc_top_inst.core_top_inst.csr_unit_inst._SATP);
			$fflush(sim_dbg_fd);
		end
		if (soc_top_inst.core_top_inst.wb_xret_fire) begin
			$fwrite(sim_dbg_fd, "XRET @%0d pc=%08h priv=%0d satp=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.csr_unit_inst._SATP);
			$fflush(sim_dbg_fd);
		end
	end
end

// ── sbi_putc auipc/jalr trace ──
// Targeted at the NULL pointer crash from sbi_putc's jalr to
// sbi_console_putchar (c0150e52). Capture pc_id, pc_ie, pc_iwb, ra
// register, fb head/next vaddrs, and fb_push events whenever we're
// near sbi_putc (PC range c0150e44..c0150e60). The crash should fire
// roughly 1 cycle after the jalr executes — so log the few cycles
// AROUND the auipc + jalr execution.
always @(posedge clk) begin
	if (!reset) begin
		// IE / IWB activity inside sbi_putc
		if ((soc_top_inst.core_top_inst.pc_ie  >= 32'hc0150e44 &&
		     soc_top_inst.core_top_inst.pc_ie  <= 32'hc0150e5c) ||
		    (soc_top_inst.core_top_inst.pc_iwb >= 32'hc0150e44 &&
		     soc_top_inst.core_top_inst.pc_iwb <= 32'hc0150e5c)) begin
			$fwrite(sim_dbg_fd, "PUTC @%0d pc_id=%08h pc_ie=%08h pc_iwb=%08h wr=%0b@x%0d=%08h ra=%08h fb_cnt=%0d hva=%08h nva=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_id,
				soc_top_inst.core_top_inst.pc_ie,
				soc_top_inst.core_top_inst.pc_iwb,
				soc_top_inst.core_top_inst.rf_wr_en,
				soc_top_inst.core_top_inst.rf_wr_addr,
				soc_top_inst.core_top_inst.rf_wr_data,
				soc_top_inst.core_top_inst.regfile_inst.regfile[1],
				soc_top_inst.core_top_inst.fb_count,
				soc_top_inst.core_top_inst.fb_head.vaddr,
				soc_top_inst.core_top_inst.fb_next.vaddr);
			$fflush(sim_dbg_fd);
		end
	end
end



// ── Lightweight PC sampler (every 1M cycles) ────────────────────
// Useful for finding cycle numbers to feed --vcd-start-cycle / --vcd-stop-cycle.
reg [31:0] pc_sample_cnt;
always @(posedge clk) begin
	if (reset)
		pc_sample_cnt <= 0;
	else begin
		pc_sample_cnt <= pc_sample_cnt + 1;
		if (pc_sample_cnt[19:0] == 20'h0) begin // every ~1M cycles
			$fwrite(sim_dbg_fd, "PC[%0d] pc=%08h priv=%0d satp=%08h fdt0=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.csr_unit_inst._SATP,
				soc_top_inst.ram_inst.mem[32'h880000]);  // FDT magic at phys 0x82200000
			$fflush(sim_dbg_fd);
		end
	end
end

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
