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
		 // All sim log files are written into ./logs/ — created here so the
		 // various $fopen("logs/foo.log", ...) calls below don't silently
		 // fail. Safe to call multiple times.
		 void'($system("mkdir -p logs"));
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
 // SPI external self-loop: shorts MOSI back to MISO so the bare-metal
 // SPI loopback test can verify the shift path end-to-end without an
 // off-chip slave model.
 wire  spi_mosi_w;
soc_top soc_top_inst
	(
		.clk_i(clk) ,
		.reset_i(reset) ,
		//uart
		.tx_o(tx) ,
		.rx_i(rx) ,
		// spi
		.mosi_o        (spi_mosi_w),
		.miso_i        (spi_mosi_w),
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


  // 250000 baud — moderate speedup over 115200 (~2x faster sim
  // wallclock for UART traffic) while still well above the failure
  // points seen at 1M/5M baud where uartdpi RX races back-to-back
  // SoC TX. Must match opensbi-platform/platform.c divisor.
  uartdpi #(
    .BAUD(250000),
    .FREQ(50000000)
  )
  u_uart(
    .clk(clk),
    .rst(reset),
    .rx(tx),
    .tx(rx)
  );

`ifdef DV_TRACER
// All tracing/logging lives in the testbench. tb_tracer reaches into
// core_top via hierarchical refs and instantiates the rvfi tracer.
tb_tracer u_tracer (
    .clk_i  (clk),
    .reset_i(reset)
);
`endif

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
initial sim_con_fd = $fopen("logs/uart.log", "w");

always @(posedge clk) begin
	if (!reset &&
	    soc_top_inst.dmem_bus.req &&
	    soc_top_inst.dmem_bus.we &&
	    soc_top_inst.dmem_bus.addr == 32'h10000000) begin  // UART TXDATA @ 0x10000000 (sifive,uart0 layout)
		$fwrite(sim_con_fd, "%c", soc_top_inst.dmem_bus.wdata[7:0]);
		$fflush(sim_con_fd);
	end
end

// ── PC sampler ──────────────────────────────────────────────────
// Lightweight periodic execution trace (every 1000 cycles). Useful
// for post-mortem boot triage without DV_TRACER's multi-GB overhead.
integer wp_cycle = 0;
always @(posedge clk) if (!reset) wp_cycle <= wp_cycle + 1;

integer pc_sample_fd;
initial pc_sample_fd = $fopen("logs/pc_sample.log", "w");

wire [31:0] wp_pc_iwb = soc_top_inst.core_top_inst.pc_iwb;
wire [1:0]  wp_priv   = soc_top_inst.core_top_inst.priv_level;

always @(posedge clk) begin
    if (!reset && (wp_cycle % 32'd1000 == 0)) begin
        $fwrite(pc_sample_fd, "@%0d priv=%0d pc=%08h\n",
                wp_cycle, wp_priv, wp_pc_iwb);
        $fflush(pc_sample_fd);
    end
end

// ── kernfs_name_hash inner-loop progress sampler ───────────────
// At each timer tick, the trap probe captures EPC inside this
// function. Sample the suspected `len` register (a4) and the
// `name` pointer (a5) at that same cycle so we can watch them
// progress (or not) across iterations.
integer kfh_log_fd;
initial kfh_log_fd = $fopen("logs/kfh_progress.log", "w");

// Iteration-resolution probe: at every IE-stage commit of the bne at
// PC c0112834, capture s1+a0+predicted_taken+branch_taken. Filtered
// to only fire when s1 is "near" a0 (within 0x40 bytes either side)
// to keep volume sane while still catching the equality moment.
wire [31:0] wp_a0 = soc_top_inst.core_top_inst.regfile_inst.regfile[10];
wire [31:0] wp_s1 = soc_top_inst.core_top_inst.regfile_inst.regfile[9];
wire        wp_branch_taken = soc_top_inst.core_top_inst.branch_taken;
wire        wp_pred_taken   = soc_top_inst.core_top_inst.ctrl_bus_ie.predicted_taken;
wire        wp_mispredict   = soc_top_inst.core_top_inst.bpu_mispredict;
wire        wp_ie_flush     = soc_top_inst.core_top_inst.ie_flush;
wire [31:0] wp_pc_ie        = soc_top_inst.core_top_inst.pc_ie;

// Track whether we've already hit the stuck loop (a0 = c0c6b049, s1
// crossing a0). After that point, log every 1000th iter so we can
// verify the loop is still spinning without flooding.
reg kfh_in_stuck = 1'b0;
reg [31:0] kfh_iter = 32'h0;
always @(posedge clk) begin
    if (!reset && wp_priv == 2'd1 &&
        wp_pc_ie == 32'hc0112834) begin
        // Always log when s1 is "near" a0
        if ((wp_a0 > wp_s1 ? wp_a0 - wp_s1 : wp_s1 - wp_a0) <= 32'h40) begin
            $fwrite(kfh_log_fd,
                "@%0d BNE  s1=%08h a0=%08h taken=%0d pred=%0d misp=%0d ie_flush=%0d\n",
                wp_cycle, wp_s1, wp_a0, wp_branch_taken, wp_pred_taken,
                wp_mispredict, wp_ie_flush);
            $fflush(kfh_log_fd);
            if (wp_a0 == 32'hc0c6b049) kfh_in_stuck <= 1'b1;
        end else if (kfh_in_stuck && (kfh_iter[15:0] == 16'h0)) begin
            // Sparse periodic log inside stuck loop
            $fwrite(kfh_log_fd,
                "@%0d STUCK s1=%08h a0=%08h\n",
                wp_cycle, wp_s1, wp_a0);
            $fflush(kfh_log_fd);
        end
        kfh_iter <= kfh_iter + 1;
    end
end

// ── Kernel sync-fault forensic probe ─────────────────────────────
// On the FIRST priv=1 (S-mode kernel) synchronous exception
// (cause < 16, not a timer/external interrupt), dump full register
// state + a 32-entry PC history. Use this to root-cause kernel oopses
// like the i2c-enabled init NULL-deref in get_page_from_freelist —
// figure out what SET the registers to the values that caused the
// fault.
integer fault_log_fd;
initial fault_log_fd = $fopen("logs/sync_fault.log", "w");

// Direct hierarchical register taps (avoid array hier ref issues).
wire [31:0] wp_x1  = soc_top_inst.core_top_inst.regfile_inst.regfile[1];
wire [31:0] wp_x2  = soc_top_inst.core_top_inst.regfile_inst.regfile[2];
wire [31:0] wp_x3  = soc_top_inst.core_top_inst.regfile_inst.regfile[3];
wire [31:0] wp_x4  = soc_top_inst.core_top_inst.regfile_inst.regfile[4];
wire [31:0] wp_x8  = soc_top_inst.core_top_inst.regfile_inst.regfile[8];
wire [31:0] wp_x10 = soc_top_inst.core_top_inst.regfile_inst.regfile[10];
wire [31:0] wp_x11 = soc_top_inst.core_top_inst.regfile_inst.regfile[11];
wire [31:0] wp_x12 = soc_top_inst.core_top_inst.regfile_inst.regfile[12];
wire [31:0] wp_x13 = soc_top_inst.core_top_inst.regfile_inst.regfile[13];
wire [31:0] wp_x14 = soc_top_inst.core_top_inst.regfile_inst.regfile[14];
wire [31:0] wp_x15 = soc_top_inst.core_top_inst.regfile_inst.regfile[15];

// Last-32 PC ring (overwritten round-robin so always have 32 most-recent).
reg [31:0] fault_pc_ring [0:31];
reg [4:0]  fault_pc_idx = 5'd0;
always @(posedge clk) begin
    if (!reset) begin
        fault_pc_ring[fault_pc_idx] <= wp_pc_iwb;
        fault_pc_idx <= fault_pc_idx + 5'd1;
    end
end

reg fault_dumped = 1'b0;
integer fi;
always @(posedge clk) begin
    // Filter to FAULTS only (cause >= 12 = page faults; cause 2 illegal
    // insn; cause 0/1/4/5/6/7 misalign/access). Exclude ECALLs (8,9).
    // Also require epc in kernel high-half so we skip the transient
    // instruction fault head.S takes during MMU enable.
    if (!reset && wp_int_v && (wp_ecause[31] == 1'b0)
        && ((wp_ecause[7:0] >= 8'd12) || (wp_ecause[7:0] == 8'd2)
            || (wp_ecause[7:0] <= 8'd7))
        && (wp_priv == 2'd1) && (wp_epc[31:28] == 4'hc) && !fault_dumped) begin
        $fwrite(fault_log_fd,
            "@%0d KERNEL SYNC FAULT cause=%08h epc=%08h badaddr=%08h\n",
            wp_cycle, wp_ecause, wp_epc, wp_mtval);
        $fwrite(fault_log_fd,
            "  satp=%08h status=%08h\n", wp_satp, wp_status);
        $fwrite(fault_log_fd,
            "  ra=%08h sp=%08h gp=%08h tp=%08h\n",
            wp_x1, wp_x2, wp_x3, wp_x4);
        $fwrite(fault_log_fd,
            "  s0=%08h\n", wp_x8);
        $fwrite(fault_log_fd,
            "  a0=%08h a1=%08h a2=%08h a3=%08h\n",
            wp_x10, wp_x11, wp_x12, wp_x13);
        $fwrite(fault_log_fd,
            "  a4=%08h a5=%08h\n", wp_x14, wp_x15);
        $fwrite(fault_log_fd, "  PC ring (32 entries, oldest first):\n");
        for (fi = 0; fi < 32; fi = fi + 1) begin
            $fwrite(fault_log_fd, "    [%2d] %08h\n",
                fi, fault_pc_ring[(fault_pc_idx + fi) & 5'h1f]);
        end
        $fflush(fault_log_fd);
        fault_dumped <= 1'b1;
    end
end

// ── Trap probe ─────────────────────────────────────────────────
// Captures every committed trap (sync exception or async interrupt)
// plus stvec / sscratch / satp / tp / sp at the moment of commit.
// Goal: identify the page-fault-loop source after the cpio-shift
// boot regression. Filtered to S-mode (priv=1) to keep volume sane.
integer trap_log_fd;
initial trap_log_fd = $fopen("logs/trap_probe.log", "w");

wire        wp_int_v   = soc_top_inst.core_top_inst.interrupt_valid;
wire [31:0] wp_ecause  = soc_top_inst.core_top_inst.ecause_csr;
wire [31:0] wp_epc     = soc_top_inst.core_top_inst.epc_csr;
wire [31:0] wp_mtval   = soc_top_inst.core_top_inst.mtval_csr;
wire        wp_to_s    = soc_top_inst.core_top_inst.trap_to_s;
wire [31:0] wp_satp    = soc_top_inst.core_top_inst.satp_csr;
wire [31:0] wp_status  = soc_top_inst.core_top_inst.status_csr;
wire [31:0] wp_tp_reg  = soc_top_inst.core_top_inst.regfile_inst.regfile[4];
wire [31:0] wp_sp_reg  = soc_top_inst.core_top_inst.regfile_inst.regfile[2];

always @(posedge clk) begin
    if (!reset && wp_int_v) begin
        $fwrite(trap_log_fd,
            "@%0d trap priv=%0d to_s=%0d cause=%08h epc=%08h tval=%08h satp=%08h status=%08h tp=%08h sp=%08h\n",
            wp_cycle, wp_priv, wp_to_s, wp_ecause, wp_epc, wp_mtval,
            wp_satp, wp_status, wp_tp_reg, wp_sp_reg);
        $fflush(trap_log_fd);
    end
end

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
