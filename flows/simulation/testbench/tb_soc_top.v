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
		 // ./logs/ holds the uart console + dv_tracer output.
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
// All instruction tracing lives in tb_tracer (rvfi-style log). It
// reaches into core_top via hierarchical refs and gates start/stop on
// +tracer_start_pc / +tracer_stop_pc plusargs. Independent of the FST
// waveform dump below.
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
// in uart.log. Watch the boot live with `tail -f uart.log`.
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

// ── PC sampler ───────────────────────────────────────────────────
// One sample per 1000 cycles, written to logs/pc_sample.log. Cheap
// way to correlate uart.log boot output to actual cycle numbers, so
// the FST window plusargs can be picked accurately.
integer wp_cycle = 0;
always @(posedge clk) if (!reset) wp_cycle <= wp_cycle + 1;

wire [31:0] wp_pc_iwb = soc_top_inst.core_top_inst.pc_iwb;
wire [1:0]  wp_priv   = soc_top_inst.core_top_inst.priv_level;

integer pc_sample_fd;
initial pc_sample_fd = $fopen("logs/pc_sample.log", "w");
always @(posedge clk) begin
    if (!reset && (wp_cycle % 32'd1000 == 0)) begin
        $fwrite(pc_sample_fd, "@%0d priv=%0d pc=%08h\n",
                wp_cycle, wp_priv, wp_pc_iwb);
        $fflush(pc_sample_fd);
    end
end

// ── Layer-1 pipeline-invariant watcher ──────────────────────────
// Cheap SV-level asserts that fire on violations of the pipeline's
// expected invariants. Each violation is logged with cycle + PC + the
// signals involved. Goal: catch HW bugs at the cycle they happen
// instead of 30M cycles later when Linux trips on the corrupted state.
//
// Rationale see project_pty_init_kernfs_corruption + the trace_event_init
// regression — the bug class is "speculative writeback / store leaks
// past flush". These probes would have caught both at flush-time.
integer watch_fd;
initial watch_fd = $fopen("logs/watcher.log", "w");

wire        wp_rf_wr_en   = soc_top_inst.core_top_inst.rf_wr_en;
wire [4:0]  wp_rf_wr_addr = soc_top_inst.core_top_inst.rf_wr_addr;
wire [31:0] wp_rf_wr_data = soc_top_inst.core_top_inst.rf_wr_data;
wire        wp_iwb_flush  = soc_top_inst.core_top_inst.iwb_flush;
wire        wp_ie_flush   = soc_top_inst.core_top_inst.ie_flush;
wire        wp_imem_flush = soc_top_inst.core_top_inst.imem_flush;
wire        wp_int_v_w    = soc_top_inst.core_top_inst.interrupt_valid;
wire        wp_excpt_ie_w = soc_top_inst.core_top_inst.exception_from_ie;
wire        wp_c2a_write_w  = soc_top_inst.core_top_inst.c2a_write;
wire [31:0] wp_c2a_addr_w   = soc_top_inst.core_top_inst.c2a_address;
wire [31:0] wp_c2a_wdata_w  = soc_top_inst.core_top_inst.c2a_writedata;
wire [31:0] wp_pc_ie_w      = soc_top_inst.core_top_inst.pc_ie;
wire [31:0] wp_exec_iwb     = soc_top_inst.core_top_inst.exec_result_iwb;

// Counters so a flood of violations doesn't drown the log. Each INV
// class has its own cap so a chatty class can't starve a quiet but
// interesting one. WATCH_GATE_CYCLE arms the asserts only after a
// chosen cycle so the cap covers the WARN region (cycle ~179.7M for
// the trace_event_init regression) instead of being eaten by early
// boot noise.
integer w1_cnt = 0;  // regfile write under iwb_flush
integer w2_cnt = 0;  // store under ie_flush
integer w3_cnt = 0;  // store under exception_from_ie
integer w4_cnt = 0;  // store under interrupt_valid (same cycle)
integer w5_cnt = 0;  // double-retire flush-conditional
integer w6_cnt = 0;  // (addr,wdata) store committed twice within N cycles
localparam integer WATCH_LIMIT      = 4096;
localparam integer WATCH_GATE_CYCLE = 32'd175_000_000;
wire wp_armed = (wp_cycle >= WATCH_GATE_CYCLE);

// ── Invariant 1: regfile write under iwb_flush ──
// iwb_flush is the IWB-stage squash. While it's high, no architectural
// rd writeback should retire. Any rf_wr_en=1 under iwb_flush is a
// speculative regfile write leaking past the squash.
always @(posedge clk) begin
    if (!reset && wp_armed && wp_rf_wr_en && wp_iwb_flush && wp_rf_wr_addr != 5'd0
        && w1_cnt < WATCH_LIMIT) begin
        $fwrite(watch_fd,
            "@%0d INV1 RF_WR_UNDER_IWB_FLUSH pc_iwb=%08h x%0d=%08h\n",
            wp_cycle, wp_pc_iwb, wp_rf_wr_addr, wp_rf_wr_data);
        $fflush(watch_fd);
        w1_cnt <= w1_cnt + 1;
    end
end

// ── Invariant 2: c2a_write under ie_flush ──
// Stores are issued from IE; ie_flush squashing should kill the store.
// A c2a_write asserting same cycle as ie_flush is a wrong-path store
// committing to the bus (the pty_init / radix_tree corruption family).
always @(posedge clk) begin
    if (!reset && wp_armed && wp_c2a_write_w && wp_ie_flush && w2_cnt < WATCH_LIMIT) begin
        $fwrite(watch_fd,
            "@%0d INV2 STORE_UNDER_IE_FLUSH addr=%08h wdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle, wp_c2a_addr_w, wp_c2a_wdata_w, wp_pc_ie_w, wp_pc_iwb);
        $fflush(watch_fd);
        w2_cnt <= w2_cnt + 1;
    end
end

// ── Invariant 3: c2a_write under exception_from_ie ──
// Synchronous IE exceptions should suppress the c2a memory op for the
// same cycle. A simultaneous c2a_write is a wrong-path store under a
// trapping insn (e.g. misaligned AMO that should not commit).
always @(posedge clk) begin
    if (!reset && wp_armed && wp_c2a_write_w && wp_excpt_ie_w && w3_cnt < WATCH_LIMIT) begin
        $fwrite(watch_fd,
            "@%0d INV3 STORE_UNDER_EXCPT addr=%08h wdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle, wp_c2a_addr_w, wp_c2a_wdata_w, wp_pc_ie_w, wp_pc_iwb);
        $fflush(watch_fd);
        w3_cnt <= w3_cnt + 1;
    end
end

// ── Invariant 4: c2a_write same cycle as interrupt_valid ──
// On async-trap fire, the IE-stage instruction's bus op should not
// commit (the trap pre-empts it). If c2a_write coincides with
// interrupt_valid the store is leaking past the trap squash. This is
// a softer flag than INV2 — async-trap may or may not raise ie_flush
// in the same cycle depending on timing.
always @(posedge clk) begin
    if (!reset && wp_armed && wp_c2a_write_w && wp_int_v_w && w4_cnt < WATCH_LIMIT) begin
        $fwrite(watch_fd,
            "@%0d INV4 STORE_AT_INT_FIRE addr=%08h wdata=%08h pc_ie=%08h pc_iwb=%08h\n",
            wp_cycle, wp_c2a_addr_w, wp_c2a_wdata_w, wp_pc_ie_w, wp_pc_iwb);
        $fflush(watch_fd);
        w4_cnt <= w4_cnt + 1;
    end
end

// ── Invariant 5: double-retire FLUSH-GATED ──
// Same architectural PC should not retire twice unless a flush event
// happened between the two retires. Plain double-retire is loop noise
// (kernel memcpy/strcmp iterates same PC with different exec_result).
// We restrict to: same PC retiring twice within 16 cycles, AND a
// flush event (interrupt_valid OR ie_flush OR iwb_flush OR
// exception_from_ie) was observed somewhere in that window. Filter
// on pc_iwb high-half=0xc (kernel) to skip boot-stub noise.
reg [31:0] dr_pc_q   [0:15];
reg [31:0] dr_exec_q [0:15];
reg [31:0] dr_cyc_q  [0:15];
reg [3:0]  dr_idx;
integer dr_i;
// Track most-recent cycle a flush/trap event fired.
reg [31:0] last_flush_cyc;
initial begin
    dr_idx = 4'd0;
    last_flush_cyc = 32'h0;
    for (dr_i = 0; dr_i < 16; dr_i = dr_i + 1) begin
        dr_pc_q[dr_i]   = 32'h0;
        dr_exec_q[dr_i] = 32'h0;
        dr_cyc_q[dr_i]  = 32'h0;
    end
end
always @(posedge clk) begin
    if (!reset) begin
        if (wp_int_v_w | wp_ie_flush | wp_iwb_flush | wp_excpt_ie_w)
            last_flush_cyc <= wp_cycle;
        if (wp_pc_iwb[31:28] == 4'hc) begin
            // Scan ring for same-PC entry retired within last 16 cycles
            // with a different exec_result, gated on a flush event
            // having happened between prev_cyc and now.
            for (dr_i = 0; dr_i < 16; dr_i = dr_i + 1) begin
                if (dr_pc_q[dr_i] == wp_pc_iwb
                    && dr_pc_q[dr_i] != 32'h0
                    && dr_exec_q[dr_i] != wp_exec_iwb
                    && (wp_cycle - dr_cyc_q[dr_i]) <= 32'd16
                    && last_flush_cyc > dr_cyc_q[dr_i]
                    && last_flush_cyc <= wp_cycle
                    && wp_armed
                    && w5_cnt < WATCH_LIMIT) begin
                    $fwrite(watch_fd,
                        "@%0d INV5 FLUSH_DOUBLE_RETIRE pc_iwb=%08h prev_exec=%08h cur_exec=%08h prev_cyc=%0d flush_cyc=%0d\n",
                        wp_cycle, wp_pc_iwb, dr_exec_q[dr_i], wp_exec_iwb,
                        dr_cyc_q[dr_i], last_flush_cyc);
                    $fflush(watch_fd);
                    w5_cnt <= w5_cnt + 1;
                end
            end
            dr_pc_q[dr_idx]   <= wp_pc_iwb;
            dr_exec_q[dr_idx] <= wp_exec_iwb;
            dr_cyc_q[dr_idx]  <= wp_cycle;
            dr_idx <= dr_idx + 4'd1;
        end
    end
end

// ── Invariant 6: double-store-commit detector ──
// Same (addr, wdata) hitting c2a_write twice within 32 cycles is
// suspicious — usually means a store re-executed after a trap squash
// got replayed without clearing memory effects. Idempotent stores
// (function-prologue saves) are common so we filter on a tight
// window AND require a flush event between the two commits.
reg [31:0] ds_addr_q  [0:15];
reg [31:0] ds_wdata_q [0:15];
reg [31:0] ds_cyc_q   [0:15];
reg [3:0]  ds_idx;
integer ds_i;
initial begin
    ds_idx = 4'd0;
    for (ds_i = 0; ds_i < 16; ds_i = ds_i + 1) begin
        ds_addr_q[ds_i]  = 32'h0;
        ds_wdata_q[ds_i] = 32'h0;
        ds_cyc_q[ds_i]   = 32'h0;
    end
end
always @(posedge clk) begin
    if (!reset && wp_c2a_write_w) begin
        // Scan ring for same (addr, wdata) committed within last 32
        // cycles with a flush event between then and now.
        for (ds_i = 0; ds_i < 16; ds_i = ds_i + 1) begin
            if (ds_addr_q[ds_i] == wp_c2a_addr_w
                && ds_wdata_q[ds_i] == wp_c2a_wdata_w
                && ds_cyc_q[ds_i] != 32'h0
                && (wp_cycle - ds_cyc_q[ds_i]) <= 32'd32
                && last_flush_cyc > ds_cyc_q[ds_i]
                && last_flush_cyc <= wp_cycle
                && wp_armed
                && w6_cnt < WATCH_LIMIT) begin
                $fwrite(watch_fd,
                    "@%0d INV6 DOUBLE_STORE addr=%08h wdata=%08h prev_cyc=%0d flush_cyc=%0d pc_ie=%08h\n",
                    wp_cycle, wp_c2a_addr_w, wp_c2a_wdata_w,
                    ds_cyc_q[ds_i], last_flush_cyc, wp_pc_ie_w);
                $fflush(watch_fd);
                w6_cnt <= w6_cnt + 1;
            end
        end
        ds_addr_q[ds_idx]  <= wp_c2a_addr_w;
        ds_wdata_q[ds_idx] <= wp_c2a_wdata_w;
        ds_cyc_q[ds_idx]   <= wp_cycle;
        ds_idx <= ds_idx + 4'd1;
    end
end

// ── Refcount-AMO probe (event_create_dir regression) ───────────
// Logs every retire of `amoadd.w a5, a1, (a0)` at PC c00ae66a (the
// trace_event_call->refcount inc inside event_create_dir). For each
// retire we capture cycle, write_back_data (= OLD refcount value
// returned by AMO into a5), s4 (= trace_event_call*, x20), s4+40
// (= refcount addr).
//
// The kernel WARN fires when this AMO's OLD value was 0 (refcount=0
// before inc → use-after-free per Linux refcount_t semantics). The
// probe lets us identify exactly which trace_event_call had refcount=0
// in its struct at the time of the AMO. Tiny output (~one line per
// event registration ≈ a few hundred lines for the boot).
integer rc_fd;
initial rc_fd = $fopen("logs/refcount_amo.log", "w");
wire [31:0] wp_s4 = soc_top_inst.core_top_inst.regfile_inst.regfile[20];
always @(posedge clk) begin
    // pc_iwb=c00ae66a + an architectural rd writeback (rf_wr_en) for
    // a5=x15. Captures only the AMO's retire cycle.
    if (!reset && wp_pc_iwb == 32'hc00ae66a
        && wp_rf_wr_en && wp_rf_wr_addr == 5'd15) begin
        $fwrite(rc_fd,
            "@%0d AMO_RETIRE pc_iwb=%08h s4=%08h refcount_addr=%08h old_refcount=%08h\n",
            wp_cycle, wp_pc_iwb, wp_s4, wp_s4 + 32'd40, wp_rf_wr_data);
        $fflush(rc_fd);
    end
end

// ── FST waveform dump ───────────────────────────────────────────
// Lifecycle is owned by main.cpp (parses +wave_start / +wave_stop /
// +wave_file plusargs and drives VerilatedFstC directly). The
// SV $dumpvars + traceEverOn route was abandoned because Verilator's
// runtime silently dropped all dumps with "previous dump at t=0"
// warnings (FST file had signal defs but zero value transitions).

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
