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
// Loop-control + shift_input registers for radix_tree_extend BUG_ON debug:
// s1 (x9)  = local maxshift, s2 (x18) = local shift loop var,
// s11 (x27) = caller's shift arg (idr_get_free).
wire [31:0] wp_x9   = soc_top_inst.core_top_inst.regfile_inst.regfile[9];
wire [31:0] wp_x18  = soc_top_inst.core_top_inst.regfile_inst.regfile[18];
wire [31:0] wp_x19  = soc_top_inst.core_top_inst.regfile_inst.regfile[19];
wire [31:0] wp_x27  = soc_top_inst.core_top_inst.regfile_inst.regfile[27];

// Last-32 PC ring (overwritten round-robin so always have 32 most-recent).
reg [31:0] fault_pc_ring [0:31];
reg [4:0]  fault_pc_idx = 5'd0;
always @(posedge clk) begin
    if (!reset) begin
        fault_pc_ring[fault_pc_idx] <= wp_pc_iwb;
        fault_pc_idx <= fault_pc_idx + 5'd1;
    end
end

// Dump up to FAULT_DUMP_MAX faults (originally one-shot, now 8) so we
// catch both the WARN ebreak (cause=3) AND the lethal load/page fault
// that follows. Each dump includes PC-ring snapshot.
localparam integer FAULT_DUMP_MAX = 8;
reg [3:0] fault_count = 4'd0;
integer fi;
always @(posedge clk) begin
    // Filter: real synchronous exceptions in S-mode kernel high-half.
    //   cause 0/1/4/5/6/7  : misalign / access fault
    //   cause 2            : illegal insn
    //   cause 3            : breakpoint (WARN/BUG ebreak)
    //   cause 12/13/15     : insn / load / store page fault
    // Exclude ECALL (8,9,11) and async interrupts (high bit set).
    if (!reset && wp_int_v && (wp_ecause[31] == 1'b0)
        && ((wp_ecause[7:0] >= 8'd12) || (wp_ecause[7:0] == 8'd2)
            || (wp_ecause[7:0] == 8'd3) || (wp_ecause[7:0] <= 8'd7))
        && (wp_priv == 2'd1) && (wp_epc[31:28] == 4'hc)
        && (fault_count < FAULT_DUMP_MAX[3:0])) begin
        $fwrite(fault_log_fd,
            "@%0d [#%0d] KERNEL SYNC FAULT cause=%08h epc=%08h badaddr=%08h\n",
            wp_cycle, fault_count, wp_ecause, wp_epc, wp_mtval);
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
        $fwrite(fault_log_fd,
            "  s1=%08h s2=%08h s3=%08h s11=%08h\n",
            wp_x9, wp_x18, wp_x19, wp_x27);
        $fwrite(fault_log_fd, "  PC ring (32 entries, oldest first):\n");
        for (fi = 0; fi < 32; fi = fi + 1) begin
            $fwrite(fault_log_fd, "    [%2d] %08h\n",
                fi, fault_pc_ring[(fault_pc_idx + fi) & 5'h1f]);
        end
        $fflush(fault_log_fd);
        fault_count <= fault_count + 4'd1;
    end
end

// ── AMO commit snoop ───────────────────────────────────────────
// Log every AMO write that hits the d-port. Targets bus-response-leak
// bug class (xas_load fix in commit a few weeks ago was AMO-related).
// Volume is low — AMOs are rare during boot.
integer amo_log_fd;
initial amo_log_fd = $fopen("logs/amo_commit.log", "w");

wire        wp_amo_active = soc_top_inst.core_top_inst.amo_active;
wire        wp_amo_dbus_we    = soc_top_inst.core_top_inst.amo_dbus_write;
wire [31:0] wp_amo_dbus_addr  = soc_top_inst.core_top_inst.amo_dbus_addr;
wire [31:0] wp_amo_dbus_wdata = soc_top_inst.core_top_inst.amo_dbus_writedata;
wire [3:0]  wp_amo_dbus_be    = soc_top_inst.core_top_inst.amo_dbus_byteenable;

always @(posedge clk) begin
    if (!reset && wp_amo_active && wp_amo_dbus_we) begin
        $fwrite(amo_log_fd,
            "@%0d AMO_WR addr=%08h wdata=%08h be=%h pc_iwb=%08h\n",
            wp_cycle, wp_amo_dbus_addr, wp_amo_dbus_wdata,
            wp_amo_dbus_be, wp_pc_iwb);
        $fflush(amo_log_fd);
    end
end

// ── PTW writeback snoop ────────────────────────────────────────
// Log every PTW write that hits the d-port. Should only be Svadu
// A/D bit updates targeting page-table entry addresses. Anything
// else (or bursts of writes here) is suspicious.
integer ptw_log_fd;
initial ptw_log_fd = $fopen("logs/ptw_writeback.log", "w");

wire        wp_ptw_active = soc_top_inst.core_top_inst.ptw_active;
wire        wp_dmem_we    = soc_top_inst.dmem_bus.we;
wire        wp_dmem_req   = soc_top_inst.dmem_bus.req;
wire [31:0] wp_dmem_addr  = soc_top_inst.dmem_bus.addr;
wire [31:0] wp_dmem_wdata = soc_top_inst.dmem_bus.wdata;

always @(posedge clk) begin
    if (!reset && wp_ptw_active && wp_dmem_req && wp_dmem_we) begin
        $fwrite(ptw_log_fd,
            "@%0d PTW_WB addr=%08h wdata=%08h pc_iwb=%08h\n",
            wp_cycle, wp_dmem_addr, wp_dmem_wdata, wp_pc_iwb);
        $fflush(ptw_log_fd);
    end
end

// ── Cycle-windowed bus-write log w/ master tag ─────────────────
// Every committed write on dmem_bus during a focused window around
// the v7.0 panic (~98.6M cycles), tagged with master + flush state.
// The window keeps the log manageable; widen for other crash sites.
//
// Also unconditionally log any write targeting PA 0x82015000..0x82015fff
// (the kernel slab page that hosts the IDR radix_tree_root passed to
// the BUG_ON site at v7.0 pty_init crash). Captures cross-boot
// corruption candidates regardless of cycle.
localparam integer BUSWR_WIN_LO = 32'd95_000_000;
localparam integer BUSWR_WIN_HI = 32'd99_500_000;

integer wr_log_fd;
initial wr_log_fd = $fopen("logs/bus_write.log", "w");

wire [3:0]  wp_dmem_be    = soc_top_inst.dmem_bus.be;
wire        wp_c2a_write  = soc_top_inst.core_top_inst.c2a_write;
wire        wp_excpt_ie   = soc_top_inst.core_top_inst.exception_from_ie;
wire        wp_iwb_flush  = soc_top_inst.core_top_inst.iwb_flush;
// NB: wp_ie_flush + wp_pc_ie are declared at top of kfh probe block above.

// Targets the panic-relevant slab page (PA 0x82015000-0x82015fff).
wire wp_addr_panicpage = (wp_dmem_addr[31:12] == 20'h82015);
// Targets the radix_tree_node slab area (0x82400000-0x824FFFFF) for ALL
// shift-byte writes throughout the entire boot. Catches the shift=36
// corruption source that was written before our bus_write window.
wire wp_addr_rtnode    = (wp_dmem_addr[31:20] == 12'h824) &&
                          wp_dmem_be == 4'b0001;

always @(posedge clk) begin
    if (!reset && wp_dmem_req && wp_dmem_we
        && ((wp_cycle >= BUSWR_WIN_LO && wp_cycle <= BUSWR_WIN_HI)
            || wp_addr_panicpage
            || wp_addr_rtnode)) begin
        $fwrite(wr_log_fd,
            "@%0d %s addr=%08h wdata=%08h be=%h c2a=%0d excie=%0d ief=%0d iwbf=%0d pc_ie=%08h pc_iwb=%08h%s%s\n",
            wp_cycle,
            wp_ptw_active ? "PTW" :
            wp_amo_active ? "AMO" : "COR",
            wp_dmem_addr, wp_dmem_wdata, wp_dmem_be,
            wp_c2a_write, wp_excpt_ie, wp_ie_flush, wp_iwb_flush,
            wp_pc_ie, wp_pc_iwb,
            wp_addr_panicpage ? " *PANIC_PAGE*" : "",
            wp_addr_rtnode ? " *RTNODE_SHIFT*" : "");
        $fflush(wr_log_fd);
    end
end

// ── Memory snapshot at first sync fault ────────────────────────
// On first kernel sync fault, dump 4KB of RAM around the suspect
// kernel slab page (covering 0xc2015000-0xc2016fff virt = phys
// 0x82015000-0x82016fff). This is the page that hosts the IDR
// radix_tree_root that crashed the v7.0 boot. Lets us see what
// values are at the corrupted struct fields at fault time.
integer mem_snap_fd;
initial mem_snap_fd = $fopen("logs/mem_snapshot.log", "w");

reg mem_snap_done = 1'b0;
integer si;
// RAM index of phys 0x82415000 = (0x82415000 - 0x80000000) / 4 = 0x90_5400
// (with v7.0 page offset). We dump 4096 words = 16KB from that index,
// covering 0x82415000-0x82418fff — the slab pages that hold the IDR
// root + its child radix_tree_nodes (the BUGgy one is at 0x82415be0).
localparam integer SNAP_BASE_IDX = 32'h0090_5400;
localparam integer SNAP_WORDS    = 32'd4096;

always @(posedge clk) begin
    if (!reset && wp_int_v && (wp_ecause[31] == 1'b0)
        && ((wp_ecause[7:0] >= 8'd12) || (wp_ecause[7:0] == 8'd2)
            || (wp_ecause[7:0] == 8'd3) || (wp_ecause[7:0] <= 8'd7))
        && (wp_priv == 2'd1) && (wp_epc[31:28] == 4'hc)
        && !mem_snap_done) begin
        $fwrite(mem_snap_fd,
            "@%0d MEM SNAPSHOT cause=%08h epc=%08h\n",
            wp_cycle, wp_ecause, wp_epc);
        $fwrite(mem_snap_fd,
            "  range: phys 0x%08h .. 0x%08h\n",
            32'h80000000 + (SNAP_BASE_IDX << 2),
            32'h80000000 + ((SNAP_BASE_IDX + SNAP_WORDS) << 2) - 1);
        for (si = 0; si < SNAP_WORDS; si = si + 1) begin
            if ((si & 32'd3) == 32'd0)
                $fwrite(mem_snap_fd, "\n  %08h:",
                    32'h80000000 + ((SNAP_BASE_IDX + si) << 2));
            $fwrite(mem_snap_fd, " %08h",
                soc_top_inst.ram_inst.mem[SNAP_BASE_IDX + si]);
        end
        $fwrite(mem_snap_fd, "\n");
        $fflush(mem_snap_fd);
        mem_snap_done <= 1'b1;
    end
end

// ── Bus read log (windowed) — captures req cycle + next-cycle rdata
// so we can confirm whether the data the bus returns to the core
// matches what's actually at the requested PA, or whether it's stale
// from a previous transaction (the suspected load-path bug).
integer rd_log_fd;
initial rd_log_fd = $fopen("logs/bus_read.log", "w");
wire wp_dmem_read = wp_dmem_req & ~wp_dmem_we;

// Latch req-cycle metadata so we can pair it with next-cycle rdata.
reg        rd_pending_q   = 1'b0;
reg [31:0] rd_addr_q      = 32'h0;
reg [3:0]  rd_be_q        = 4'h0;
reg [31:0] rd_pc_ie_q     = 32'h0;
reg [31:0] rd_pc_iwb_q    = 32'h0;
reg        rd_ptw_q       = 1'b0;
reg        rd_amo_q       = 1'b0;
reg        rd_in_window_q = 1'b0;

always @(posedge clk) begin
    if (!reset && rd_pending_q && rd_in_window_q) begin
        $fwrite(rd_log_fd,
            "@%0d %s addr=%08h be=%h rdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle - 1,  // event happened on previous cycle's req
            rd_ptw_q ? "PTW" : (rd_amo_q ? "AMO" : "COR"),
            rd_addr_q, rd_be_q,
            soc_top_inst.dmem_bus.rdata,  // rdata available NOW
            rd_pc_ie_q, rd_pc_iwb_q);
        $fflush(rd_log_fd);
    end
    // Latch this cycle's req for next-cycle rdata pairing.
    rd_pending_q   <= wp_dmem_read;
    rd_addr_q      <= wp_dmem_addr;
    rd_be_q        <= wp_dmem_be;
    rd_pc_ie_q     <= wp_pc_ie;
    rd_pc_iwb_q    <= wp_pc_iwb;
    rd_ptw_q       <= wp_ptw_active;
    rd_amo_q       <= wp_amo_active;
    rd_in_window_q <= (wp_cycle >= BUSWR_WIN_LO &&
                       wp_cycle <= BUSWR_WIN_HI);
end

// ── Branch resolution probe at IE ──────────────────────────────
// Capture branch_taken_valid + pc_ie + actual branch operands AS SEEN
// at the IE stage (where the HW resolves the branch), so we can
// compare to regfile state at IWB and identify forwarding misses.
integer brres_log_fd;
initial brres_log_fd = $fopen("logs/brres.log", "w");
wire        wp_branch_taken_v = soc_top_inst.core_top_inst.branch_taken_valid;
wire        wp_branch_taken_h = soc_top_inst.core_top_inst.branch_taken;
always @(posedge clk) begin
    if (!reset && wp_pc_ie == 32'hc0276ebe) begin
        $fwrite(brres_log_fd,
            "@%0d BRRES_IE pc_ie=%08h branch_taken=%0d branch_taken_v=%0d a3_rf=%08h s6_rf=%08h s11_rf=%08h\n",
            wp_cycle, wp_pc_ie, wp_branch_taken_h, wp_branch_taken_v,
            wp_x13_a3_pre, wp_x16_s6, wp_x27);
        $fflush(brres_log_fd);
    end
end

// ── BLTU register snapshot probe ───────────────────────────────
// At PC c0276ebe (idr_get_free's `bltu a3, s6, c027704e` — the only
// path that calls radix_tree_extend), capture a3 and s6 to determine
// whether the bltu fired because of a HW shift bug, a kernel-side
// `iter->next_index` corruption, or some other condition.
//
// Also capture at c0276eba (the bltu BEFORE this one) so we have the
// register state ONE INSTRUCTION earlier — unaffected by any later
// writes. Plus capture every entry into radix_tree_extend (PC c0275d14)
// so we can correlate.
integer bltu_log_fd;
initial bltu_log_fd = $fopen("logs/bltu_snap.log", "w");
wire [31:0] wp_x12_a2 = soc_top_inst.core_top_inst.regfile_inst.regfile[12];
wire [31:0] wp_x16_s6 = soc_top_inst.core_top_inst.regfile_inst.regfile[22]; // s6 is x22
wire [31:0] wp_x13_a3_pre  = soc_top_inst.core_top_inst.regfile_inst.regfile[13];
always @(posedge clk) begin
    if (!reset && wp_pc_iwb == 32'hc0276ebe) begin
        $fwrite(bltu_log_fd,
            "@%0d BLTU pc_iwb=%08h a3=%08h s6=%08h s11=%08h cond_a3<s6=%0d\n",
            wp_cycle, wp_pc_iwb, wp_x13_a3_pre, wp_x16_s6, wp_x27,
            (wp_x13_a3_pre < wp_x16_s6) ? 1 : 0);
        $fflush(bltu_log_fd);
    end
    // Also log the prior bltu (c0276eba) and extend-entry (c0275d14)
    if (!reset && wp_pc_iwb == 32'hc0275d14) begin
        $fwrite(bltu_log_fd,
            "@%0d EXT_ENTRY pc_iwb=%08h a0=%08h a1=%08h a2=%08h a3=%08h s11=%08h\n",
            wp_cycle, wp_pc_iwb, wp_x10, wp_x11, wp_x12, wp_x13_a3_pre, wp_x27);
        $fflush(bltu_log_fd);
    end
end

// ── Anomaly detector: c2a_write asserts under exception_from_ie ──
// The c2a mem_op is supposed to be NOP when exception_from_ie is high.
// If c2a_write somehow asserts simultaneously, that's a wrong-path
// store leak.
integer anom_log_fd;
initial anom_log_fd = $fopen("logs/store_anomaly.log", "w");

always @(posedge clk) begin
    if (!reset && wp_c2a_write && wp_excpt_ie) begin
        $fwrite(anom_log_fd,
            "@%0d STORE_UNDER_EXCPT addr=%08h wdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle, soc_top_inst.core_top_inst.c2a_address,
            soc_top_inst.core_top_inst.c2a_writedata,
            wp_pc_ie, wp_pc_iwb);
        $fflush(anom_log_fd);
    end
    // Also flag: ie_flush asserted yet c2a_write still high — wrong-path
    // store about to commit despite the squash signal being raised.
    if (!reset && wp_c2a_write && wp_ie_flush) begin
        $fwrite(anom_log_fd,
            "@%0d STORE_UNDER_IE_FLUSH addr=%08h wdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle, soc_top_inst.core_top_inst.c2a_address,
            soc_top_inst.core_top_inst.c2a_writedata,
            wp_pc_ie, wp_pc_iwb);
        $fflush(anom_log_fd);
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
