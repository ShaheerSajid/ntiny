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
// the slow bit-by-bit UART serializer. Characters appear immediately
// in uart.log. Watch the boot live with `tail -f uart.log` in a
// second terminal — Verilator's own stdout buffering interleaves
// $write() calls with verilator-internal output and produces
// garbled per-character output, so we don't mirror to stdout.
integer sim_con_fd;
initial sim_con_fd = $fopen("uart.log", "w");

always @(posedge clk) begin
	if (!reset &&
	    soc_top_inst.dmem_bus.req &&
	    soc_top_inst.dmem_bus.we &&
	    soc_top_inst.dmem_bus.addr == 32'h10000004) begin  // UART TX @ 0x10000004
		$fwrite(sim_con_fd, "%c", soc_top_inst.dmem_bus.wdata[7:0]);
		$fflush(sim_con_fd);
	end
end

// ── Lightweight PC sampler (every 1M cycles) ────────────────────
// Logs pc_out + priv every ~1M cycles into pc_sample.log so a tight
// Linux loop can be diagnosed without rebuilding. Each line:
//   PC[<cycle>] pc=<hex> priv=<0|1|3>
integer sim_pc_fd;
initial sim_pc_fd = $fopen("pc_sample.log", "w");

reg [31:0] pc_sample_cnt;
always @(posedge clk) begin
	if (reset)
		pc_sample_cnt <= 0;
	else begin
		pc_sample_cnt <= pc_sample_cnt + 1;
		if (pc_sample_cnt[19:0] == 20'h0) begin // every ~1M cycles
			$fwrite(sim_pc_fd, "PC[%0d] pc=%08h priv=%0d\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level);
			$fflush(sim_pc_fd);
		end
	end
end

// ── Performance counters ───────────────────────────────────────────────
// Dumps a profile line to perf.log every 100K cycles. Useful for finding
// the actual pipeline bottleneck (which is what revealed fb_empty=22%
// dominates ifid_stall — DEPTH=2→4 perf fix used these numbers).
integer sim_perf_fd;
initial sim_perf_fd = $fopen("perf.log", "w");

reg [31:0] cnt_imem_req, cnt_imem_rvalid;
reg [31:0] cnt_dmem_req, cnt_dmem_rvalid, cnt_dmem_write;
reg [31:0] cnt_aligner_emit;
reg [31:0] cnt_bpu_if_fire;
reg [31:0] cnt_squash_cyc;
reg [31:0] cnt_ie_stall_dmem, cnt_ie_stall_alu, cnt_ie_stall_mmu;
reg [31:0] cnt_if_id_stall;
reg [31:0] cnt_fb_full, cnt_fb_empty;

reg [31:0] lst_imem_req, lst_imem_rvalid;
reg [31:0] lst_dmem_req, lst_dmem_rvalid, lst_dmem_write;
reg [31:0] lst_aligner_emit;
reg [31:0] lst_bpu_if_fire;
reg [31:0] lst_squash_cyc;
reg [31:0] lst_ie_stall_dmem, lst_ie_stall_alu, lst_ie_stall_mmu;
reg [31:0] lst_if_id_stall;
reg [31:0] lst_fb_full, lst_fb_empty;

always @(posedge clk) begin
	if (reset) begin
		cnt_imem_req <= 0; cnt_imem_rvalid <= 0;
		cnt_dmem_req <= 0; cnt_dmem_rvalid <= 0; cnt_dmem_write <= 0;
		cnt_aligner_emit <= 0;
		cnt_bpu_if_fire <= 0;
		cnt_squash_cyc <= 0;
		cnt_ie_stall_dmem <= 0; cnt_ie_stall_alu <= 0; cnt_ie_stall_mmu <= 0;
		cnt_if_id_stall <= 0;
		cnt_fb_full <= 0; cnt_fb_empty <= 0;
		lst_imem_req <= 0; lst_imem_rvalid <= 0;
		lst_dmem_req <= 0; lst_dmem_rvalid <= 0; lst_dmem_write <= 0;
		lst_aligner_emit <= 0;
		lst_bpu_if_fire <= 0;
		lst_squash_cyc <= 0;
		lst_ie_stall_dmem <= 0; lst_ie_stall_alu <= 0; lst_ie_stall_mmu <= 0;
		lst_if_id_stall <= 0;
		lst_fb_full <= 0; lst_fb_empty <= 0;
	end else begin
		if (soc_top_inst.core_top_inst.imem_port.req)
			cnt_imem_req <= cnt_imem_req + 1;
		if (soc_top_inst.core_top_inst.imem_port.rvalid)
			cnt_imem_rvalid <= cnt_imem_rvalid + 1;
		if (soc_top_inst.core_top_inst.fb_full)
			cnt_fb_full <= cnt_fb_full + 1;
		if (soc_top_inst.core_top_inst.fb_count == '0)
			cnt_fb_empty <= cnt_fb_empty + 1;

		if (soc_top_inst.core_top_inst.dmem_port.req) begin
			cnt_dmem_req <= cnt_dmem_req + 1;
			if (soc_top_inst.core_top_inst.dmem_port.we)
				cnt_dmem_write <= cnt_dmem_write + 1;
		end
		if (soc_top_inst.core_top_inst.dmem_port.rvalid)
			cnt_dmem_rvalid <= cnt_dmem_rvalid + 1;

		if (soc_top_inst.core_top_inst.compressed_aligner_inst.instruction_valid_o
		    && !soc_top_inst.core_top_inst.if_id_stall)
			cnt_aligner_emit <= cnt_aligner_emit + 1;
		if (soc_top_inst.core_top_inst.compressed_aligner_inst.squash_q)
			cnt_squash_cyc <= cnt_squash_cyc + 1;
		if (soc_top_inst.core_top_inst.bpu_if_redirect_fire)
			cnt_bpu_if_fire <= cnt_bpu_if_fire + 1;

		if (soc_top_inst.core_top_inst.dmem_port.req
		    && !soc_top_inst.core_top_inst.dmem_port.ready)
			cnt_ie_stall_dmem <= cnt_ie_stall_dmem + 1;
		if (soc_top_inst.core_top_inst.alu_stall)
			cnt_ie_stall_alu <= cnt_ie_stall_alu + 1;
		if (soc_top_inst.core_top_inst.mmu_d_stall)
			cnt_ie_stall_mmu <= cnt_ie_stall_mmu + 1;
		if (soc_top_inst.core_top_inst.if_id_stall)
			cnt_if_id_stall <= cnt_if_id_stall + 1;

		// Window dump every 100K cycles
		if (pc_sample_cnt[16:0] == 17'h0 && pc_sample_cnt > 0) begin
			$fwrite(sim_perf_fd,
				"WIN @%0d imem_req=%0d(+%0d) rv=%0d(+%0d) dmem_req=%0d(+%0d) dmem_wr=%0d(+%0d) emit=%0d(+%0d) bpuif=%0d(+%0d) squash=%0d(+%0d) dmem_stall=%0d(+%0d) alu_stall=%0d(+%0d) mmu_stall=%0d(+%0d) ifid_stall=%0d(+%0d) fb_full=%0d(+%0d) fb_empty=%0d(+%0d)\n",
				pc_sample_cnt,
				cnt_imem_req,          cnt_imem_req - lst_imem_req,
				cnt_imem_rvalid,       cnt_imem_rvalid - lst_imem_rvalid,
				cnt_dmem_req,          cnt_dmem_req - lst_dmem_req,
				cnt_dmem_write,        cnt_dmem_write - lst_dmem_write,
				cnt_aligner_emit,      cnt_aligner_emit - lst_aligner_emit,
				cnt_bpu_if_fire,       cnt_bpu_if_fire - lst_bpu_if_fire,
				cnt_squash_cyc,        cnt_squash_cyc - lst_squash_cyc,
				cnt_ie_stall_dmem,     cnt_ie_stall_dmem - lst_ie_stall_dmem,
				cnt_ie_stall_alu,      cnt_ie_stall_alu - lst_ie_stall_alu,
				cnt_ie_stall_mmu,      cnt_ie_stall_mmu - lst_ie_stall_mmu,
				cnt_if_id_stall,       cnt_if_id_stall - lst_if_id_stall,
				cnt_fb_full,           cnt_fb_full - lst_fb_full,
				cnt_fb_empty,          cnt_fb_empty - lst_fb_empty);
			$fflush(sim_perf_fd);
			lst_imem_req     <= cnt_imem_req;
			lst_imem_rvalid  <= cnt_imem_rvalid;
			lst_dmem_req     <= cnt_dmem_req;
			lst_dmem_rvalid  <= cnt_dmem_rvalid;
			lst_dmem_write   <= cnt_dmem_write;
			lst_aligner_emit <= cnt_aligner_emit;
			lst_bpu_if_fire  <= cnt_bpu_if_fire;
			lst_squash_cyc   <= cnt_squash_cyc;
			lst_ie_stall_dmem<= cnt_ie_stall_dmem;
			lst_ie_stall_alu <= cnt_ie_stall_alu;
			lst_ie_stall_mmu <= cnt_ie_stall_mmu;
			lst_if_id_stall  <= cnt_if_id_stall;
			lst_fb_full      <= cnt_fb_full;
			lst_fb_empty     <= cnt_fb_empty;
		end
	end
end

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
