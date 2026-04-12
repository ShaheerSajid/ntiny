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
integer sim_dbg_fd;
initial begin
	sim_pc_fd = $fopen("pc_sample.log", "w");
	sim_dbg_fd = $fopen("debug.log", "w");
end

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

// ── CYC trace: re-arm on every U-mode trap, capture 60 cycles each.
// The last capture in the log is the failing trap.
reg [31:0] cyc_count;
reg [31:0] cyc_trap_idx;
always @(posedge clk) begin
	if (reset) begin
		cyc_count    <= 32'hffffffff;
		cyc_trap_idx <= 0;
	end else begin
		// Each interrupt firing from U-mode starts a fresh 60-cycle window
		if (soc_top_inst.core_top_inst.interrupt_valid &&
		    soc_top_inst.core_top_inst.csr_unit_inst.priv_level == 2'd0) begin
			cyc_count    <= 0;
			cyc_trap_idx <= cyc_trap_idx + 1;
		end
		if (cyc_count < 60) begin
			$fwrite(sim_dbg_fd, "CYC[%0d] @%0d pc_out=%08h pc_id=%08h pc_ie=%08h pc_iwb=%08h iv=%0b ie_st=%0b hv=%0b hva=%08h hword=%08h hix=%0d is_c=%0b aln_pop=%0b fb_cnt=%0d tp=%08h\n",
				cyc_trap_idx,
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.pc_id,
				soc_top_inst.core_top_inst.pc_ie,
				soc_top_inst.core_top_inst.pc_iwb,
				soc_top_inst.core_top_inst.interrupt_valid,
				soc_top_inst.core_top_inst.ie_stall,
				soc_top_inst.core_top_inst.fb_head_valid,
				soc_top_inst.core_top_inst.fb_head.vaddr,
				soc_top_inst.core_top_inst.fb_head.word,
				soc_top_inst.core_top_inst.compressed_aligner_inst.half_index_q,
				soc_top_inst.core_top_inst.compressed_aligner_inst.is_compressed_o,
				soc_top_inst.core_top_inst.aligner_pop,
				soc_top_inst.core_top_inst.fb_count,
				soc_top_inst.core_top_inst.regfile_inst.regfile[4]);
			$fflush(sim_dbg_fd);
			cyc_count <= cyc_count + 1;
		end
	end
end

// ── U-mode debug — track entries/exits + wild jumps to high VA ──
// Records:
//   USTART  — first cycle pc_out is in U-mode (priv=0) after each xret
//             from S-mode (sret); shows the entry point Linux jumped to
//   UTRAP   — interrupt_valid in U-mode (every U-mode trap into S-mode)
//   HIGHVA  — pc_out in [0xffff0000, 0xffffffff] regardless of priv
//             (catches the kernel/vdso wild-jump pattern from the
//             init crash where epc=0xfffff0f6)
reg [1:0] last_priv;
always @(posedge clk) begin
	if (reset) begin
		last_priv <= 2'd3;
	end else begin
		// USTART: first cycle in U-mode (priv 1→0 transition)
		if (soc_top_inst.core_top_inst.csr_unit_inst.priv_level == 2'd0 &&
		    last_priv != 2'd0) begin
			$fwrite(sim_dbg_fd, "USTART @%0d pc=%08h satp=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst._SATP);
			$fflush(sim_dbg_fd);
		end
		// UTRAP: interrupt fires while we're in U-mode
		if (soc_top_inst.core_top_inst.interrupt_valid &&
		    soc_top_inst.core_top_inst.csr_unit_inst.priv_level == 2'd0) begin
			$fwrite(sim_dbg_fd, "UTRAP @%0d cause=%08h epc=%08h tval=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.ecause_csr,
				soc_top_inst.core_top_inst.epc_csr,
				soc_top_inst.core_top_inst.mtval_csr);
			$fflush(sim_dbg_fd);
		end
		// HIGHVA: pc_out in the very high VA range — any time
		if (soc_top_inst.core_top_inst.pc_out[31:16] == 16'hffff) begin
			$fwrite(sim_dbg_fd, "HIGHVA @%0d pc=%08h priv=%0d stvec=%08h vec_o=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.csr_unit_inst._STVEC,
				soc_top_inst.core_top_inst.csr_unit_inst.vec_o);
			$fflush(sim_dbg_fd);
		end
		// On every interrupt_valid (trap firing), dump stvec/mtvec/vec_o
		// so we can see what target the HW is about to use.
		if (soc_top_inst.core_top_inst.interrupt_valid) begin
			$fwrite(sim_dbg_fd, "TRAP @%0d cause=%08h epc=%08h priv=%0d→%0d stvec=%08h mtvec=%08h vec_o=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.ecause_csr,
				soc_top_inst.core_top_inst.epc_csr,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.trap_to_s ? 2'd1 : 2'd3,
				soc_top_inst.core_top_inst.csr_unit_inst._STVEC,
				soc_top_inst.core_top_inst.csr_unit_inst._MTVEC,
				soc_top_inst.core_top_inst.csr_unit_inst.vec_o);
			$fflush(sim_dbg_fd);
		end
		last_priv <= soc_top_inst.core_top_inst.csr_unit_inst.priv_level;
	end
end

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
