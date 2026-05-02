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
	    soc_top_inst.dmem_bus.addr == 32'h10000004) begin  // UART TX @ 0x10000004
		$fwrite(sim_con_fd, "%c", soc_top_inst.dmem_bus.wdata[7:0]);
		$fflush(sim_con_fd);
	end
end

// ── Cycle counter + hierarchical pipeline taps (used by all probes below) ─
integer wp_cycle = 0;
always @(posedge clk) if (!reset) wp_cycle <= wp_cycle + 1;

wire [31:0] wp_pc_iwb = soc_top_inst.core_top_inst.pc_iwb;
wire [1:0]  wp_priv   = soc_top_inst.core_top_inst.priv_level;

// dmem-bus taps used by the ash deep-state probes below.
wire        wp_dport_req    = soc_top_inst.core_top_inst.dmem_port.req;
wire        wp_dport_we     = soc_top_inst.core_top_inst.dmem_port.we;
wire [31:0] wp_dport_wdata  = soc_top_inst.core_top_inst.dmem_port.wdata;
wire [31:0] wp_dport_addr   = soc_top_inst.core_top_inst.dmem_port.addr;
wire [31:0] wp_dport_rdata  = soc_top_inst.core_top_inst.dmem_port.rdata;
wire        wp_dport_rvalid = soc_top_inst.core_top_inst.dmem_port.rvalid;

// ── ash deep-state probe v2: req/rvalid ring + pending-pair model ──
// Captures every U-mode dmem bus event with TWO key fixes vs v1:
//   1) PC tag is pc_imem (the IMEM-stage instr issuing the req), not
//      pc_iwb (which lags by one slot and mis-attributes ops).
//   2) Loads use a pending-pair model: snapshot {pc_imem,addr} on req,
//      fill in rdata when rvalid arrives. Stores commit immediately.
// This way the (pc, addr, data) triple actually belongs to the SAME
// instruction and any VA→PA mismatch can be trusted.
// Dumped to ash_parsefile_state.log when pc_iwb=0x44362 (raise_error
// site, ash.c:12272 "bad for loop variable") retires.
integer ash_dump_fd;
initial ash_dump_fd = $fopen("logs/ash_parsefile_state.log", "w");

wire [31:0] wp_pc_imem = soc_top_inst.core_top_inst.pc_imem;

// Bigger ring (1024) + PC filter to keep ops only from the parser
// region 0x42000..0x44400 (__pgetc, preadbuffer, readtoken,
// xxreadtoken, raise_error_syntax). Covers ~thousands of cycles
// without being overrun by unrelated user-mode activity.
localparam int ASH_RING_SZ = 1024;
reg [31:0] ash_ring_cyc   [0:ASH_RING_SZ-1];
reg [31:0] ash_ring_pc    [0:ASH_RING_SZ-1];
reg [31:0] ash_ring_addr  [0:ASH_RING_SZ-1];
reg [31:0] ash_ring_data  [0:ASH_RING_SZ-1];
reg        ash_ring_we    [0:ASH_RING_SZ-1];
reg [9:0]  ash_ring_head  = 10'd0;
reg        ash_ring_full  = 1'b0;

// 1-deep pending load (ntiny is single-issue in-order; only one load
// in flight at a time). Captured on req=1&we=0; completed on rvalid=1.
reg        pend_v        = 1'b0;
reg [31:0] pend_cyc, pend_pc, pend_addr;

// PC filter: only push when the issuing PC is in the parser code range.
// Keeps the ring focused on __pgetc / readtoken / xxreadtoken activity.
function automatic logic in_parser_range(input [31:0] pc);
    in_parser_range = (pc >= 32'h00042000) && (pc < 32'h00044400);
endfunction

task push_ring;
    input [31:0] cyc;
    input [31:0] pc;
    input [31:0] addr;
    input [31:0] data;
    input        we;
    begin
        if (in_parser_range(pc)) begin
            ash_ring_cyc  [ash_ring_head] = cyc;
            ash_ring_pc   [ash_ring_head] = pc;
            ash_ring_addr [ash_ring_head] = addr;
            ash_ring_data [ash_ring_head] = data;
            ash_ring_we   [ash_ring_head] = we;
            ash_ring_head = ash_ring_head + 10'd1;
            if (ash_ring_head == 10'd0) ash_ring_full = 1'b1;
        end
    end
endtask

always @(posedge clk) begin
    if (!reset && wp_priv == 2'd0) begin
        // Complete pending load when its rvalid arrives.
        if (pend_v && wp_dport_rvalid) begin
            push_ring(pend_cyc, pend_pc, pend_addr, wp_dport_rdata, 1'b0);
            pend_v <= 1'b0;
        end
        // New request this cycle.
        if (wp_dport_req) begin
            if (wp_dport_we) begin
                // Store: commit immediately with wdata.
                push_ring(wp_cycle, wp_pc_imem, wp_dport_addr, wp_dport_wdata, 1'b1);
            end else begin
                // Load: defer until rvalid. If pend was already set
                // (shouldn't happen on a single-issue core, but guard),
                // drop the previous one to avoid stuck pending state.
                pend_v    <= 1'b1;
                pend_cyc  <= wp_cycle;
                pend_pc   <= wp_pc_imem;
                pend_addr <= wp_dport_addr;
            end
        end
    end
end

// ── lasttoken sniffer (probe v3 add-on) ──
// Catches every write to ash's `lasttoken` global (gp-1336). The 4 PCs
// that legally write it (per disasm of busybox-1.37.0 ash):
//   0x43734  sw a0, gp-1336    (TWORD=3 set in word-parser exit)
//   0x43ebc  sw a0, gp-1336    (xxreadtoken's special-char token type)
//   0x43fd6  sw s0, gp-1336    (readtoken's keyword conversion result)
//   0x44162  sw zero, gp-1336  (cleared in some default-case path)
// Any write from a *different* PC = unauthorized corruption (signal
// handler, stack overflow, HW). Latches the FIRST write of value 21
// (TFOR) for one-shot diagnosis.
localparam int LT_RING_SZ = 64;
reg [31:0] lt_ring_cyc  [0:LT_RING_SZ-1];
reg [31:0] lt_ring_pc   [0:LT_RING_SZ-1];
reg [31:0] lt_ring_addr [0:LT_RING_SZ-1];
reg [31:0] lt_ring_data [0:LT_RING_SZ-1];
reg [5:0]  lt_ring_head = 6'd0;
reg        lt_ring_full = 1'b0;
reg [31:0] lt_pa_seen   = 32'h0;          // discovered phys addr of lasttoken
reg        lt_tfor_caught = 1'b0;
reg [31:0] lt_tfor_cyc, lt_tfor_pc, lt_tfor_addr;

// Detect a write to lasttoken: either it's one of the 4 known PCs
// (legit writers) OR it's a write to the discovered PA from any PC.
wire lt_legit_write = wp_dport_req && wp_dport_we && (wp_priv == 2'd0) &&
    (wp_pc_imem == 32'h00043734 || wp_pc_imem == 32'h00043ebc ||
     wp_pc_imem == 32'h00043fd6 || wp_pc_imem == 32'h00044162);
wire lt_match_pa    = wp_dport_req && wp_dport_we && (wp_priv == 2'd0) &&
                      (lt_pa_seen != 32'h0) && (wp_dport_addr == lt_pa_seen);
wire lt_any_write   = lt_legit_write || lt_match_pa;

always @(posedge clk) begin
    if (!reset && lt_any_write) begin
        // Snap to ring (push every observation, even repeats)
        lt_ring_cyc [lt_ring_head] <= wp_cycle;
        lt_ring_pc  [lt_ring_head] <= wp_pc_imem;
        lt_ring_addr[lt_ring_head] <= wp_dport_addr;
        lt_ring_data[lt_ring_head] <= wp_dport_wdata;
        lt_ring_head <= lt_ring_head + 6'd1;
        if (lt_ring_head == 6'd63) lt_ring_full <= 1'b1;
        // Latch the discovered PA from the first legit write.
        if (lt_legit_write && lt_pa_seen == 32'h0)
            lt_pa_seen <= wp_dport_addr;
        // One-shot: capture the first write of TFOR (=21).
        if (!lt_tfor_caught && wp_dport_wdata[7:0] == 8'd21) begin
            lt_tfor_caught <= 1'b1;
            lt_tfor_cyc    <= wp_cycle;
            lt_tfor_pc     <= wp_pc_imem;
            lt_tfor_addr   <= wp_dport_addr;
        end
    end
end

// ── ash globals write log (probe v4) ──
// Stream-snoops every U-mode write to the 5 ash parser globals at
// PA 0x80cf0470..0x80cf0487. PAs derived from gp=0xe59b0 — verified
// stable across runs with the same busybox binary:
//   wordtext     = gp-1344 = 0xe5470 → PA 0x80cf0470
//   lasttoken    = gp-1336 = 0xe5478 → PA 0x80cf0478
//   quoteflag    = gp-1332 = 0xe547c → PA 0x80cf047c
//   tokpushback  = gp-1328 = 0xe5480 → PA 0x80cf0480
//   checkkwd     = gp-1324 = 0xe5484 → PA 0x80cf0484
// Each write streams into logs/ash_globals.log so the run survives
// any subsequent crash/timeout. Goal: catch writes from a PC OUTSIDE
// the known legit writer set — those would be signal-handler or
// stack-overflow corruption. Also tags M/S-mode writes which
// shouldn't happen at all to U-mode addresses.
integer ash_globals_fd;
initial ash_globals_fd = $fopen("logs/ash_globals.log", "w");

wire ash_glob_addr_hit =
    wp_dport_req && wp_dport_we &&
    (wp_dport_addr >= 32'h80cf0470 && wp_dport_addr <= 32'h80cf0487);

function automatic string ash_glob_name(input [31:0] addr);
    case (addr)
        32'h80cf0470: ash_glob_name = "wordtext   ";
        32'h80cf0478: ash_glob_name = "lasttoken  ";
        32'h80cf047c: ash_glob_name = "quoteflag  ";
        32'h80cf0480: ash_glob_name = "tokpushback";
        32'h80cf0484: ash_glob_name = "checkkwd   ";
        default:      ash_glob_name = "??         ";
    endcase
endfunction

// Known legit writer PCs for each global (from disasm of busybox-1.37.0):
//   lasttoken:    0x43734, 0x43ebc, 0x43fd6, 0x44162
//   tokpushback:  0x42e04, 0x43d1e, 0x43e08, 0x43f36, 0x4415e, 0x4416e,
//                 0x4419a, 0x441cc, 0x44232, 0x4430a
// (Other globals: too many writers to enumerate cheaply — log-and-eyeball.)
// "Unauthorized" flag is conservative: PC outside the parser-code range
// 0x42000..0x44400 OR priv != 0 → almost certainly signal-handler or
// trap path stomping on parser state.
function automatic logic ash_glob_unauth(
        input [31:0] addr, input [31:0] pc_imem, input [1:0] priv);
    if (priv != 2'd0) ash_glob_unauth = 1'b1;
    else if (pc_imem < 32'h00042000 || pc_imem >= 32'h00044400)
        ash_glob_unauth = 1'b1;
    else ash_glob_unauth = 1'b0;
endfunction

always @(posedge clk) begin : ash_globals_log_blk
    if (!reset && ash_glob_addr_hit) begin
        $fwrite(ash_globals_fd,
            "@%0d %s pc=%08h wdata=%08h priv=%0d%s\n",
            wp_cycle,
            ash_glob_name(wp_dport_addr),
            wp_pc_imem, wp_dport_wdata, wp_priv,
            ash_glob_unauth(wp_dport_addr, wp_pc_imem, wp_priv) ? "  <UNAUTH>" : "");
        $fflush(ash_globals_fd);
    end
end

// Dump on parser-error PC fire (one-shot)
reg ash_dumped = 0;
always @(posedge clk) begin : ash_deep_dump_blk
    int i, n, count;
    if (!reset && wp_priv == 2'd0 && wp_pc_iwb == 32'h00044362 && !ash_dumped) begin
        ash_dumped <= 1'b1;
        $fwrite(ash_dump_fd, "@%0d ASH parser error fired — deep state dump (probe v3)\n", wp_cycle);
        $fwrite(ash_dump_fd, "  pc_iwb=%08h pc_imem=%08h gp=%08h sp=%08h pend_v=%0d\n",
                wp_pc_iwb, wp_pc_imem,
                soc_top_inst.core_top_inst.regfile_inst.regfile[3],
                soc_top_inst.core_top_inst.regfile_inst.regfile[2],
                pend_v);
        $fwrite(ash_dump_fd, "  lasttoken_pa=%08h  tfor_caught=%0d", lt_pa_seen, lt_tfor_caught);
        if (lt_tfor_caught)
            $fwrite(ash_dump_fd, "  (TFOR set @%0d pc=%08h paddr=%08h)\n",
                    lt_tfor_cyc, lt_tfor_pc, lt_tfor_addr);
        else
            $fwrite(ash_dump_fd, "\n");

        $fwrite(ash_dump_fd, "--- lasttoken write history (oldest first; legit + PA-matched) ---\n");
        count = lt_ring_full ? LT_RING_SZ : lt_ring_head;
        for (n = 0; n < count; n++) begin
            i = lt_ring_full ? ((lt_ring_head + n) & 6'h3f) : n;
            $fwrite(ash_dump_fd, "  @%0d  pc=%08h  paddr=%08h  data=%08h\n",
                    lt_ring_cyc[i], lt_ring_pc[i], lt_ring_addr[i], lt_ring_data[i]);
        end

        count = ash_ring_full ? ASH_RING_SZ : ash_ring_head;
        $fwrite(ash_dump_fd, "--- last %0d parser-range dmem ops (oldest first; PC = pc_imem when req issued) ---\n", count);
        for (n = 0; n < count; n++) begin
            i = ash_ring_full ? ((ash_ring_head + n) & 10'h3ff) : n;
            $fwrite(ash_dump_fd, "  @%0d  pc=%08h  %s paddr=%08h  data=%08h\n",
                    ash_ring_cyc[i], ash_ring_pc[i],
                    ash_ring_we[i] ? "ST" : "LD",
                    ash_ring_addr[i], ash_ring_data[i]);
        end
        $fflush(ash_dump_fd);
    end
end

// ── BPU mispredict monitor (probe v5) ─────────────────────────
// Streams every BPU mispredict event (direction or target) with full
// IE-stage branch context plus the same-cycle flush state. Goal: catch
// the iter-3 strcmp bug we traced — a `bne` that resolves not-taken
// after a DTLB-miss/PTW stall, but the predicted-taken target commits
// anyway. If that happens, this log will show
//   pc_ie=000a267c pred=T act=N ie_flush=0 iwb_flush=0
// for cycle ~82273075 (the strcmp iter-3 bne). If the BPU recovery is
// working, the same line will have ie_flush=1 / iwb_flush=1 — and the
// silent-commit bug is somewhere else.

integer bpu_misp_fd;
initial bpu_misp_fd = $fopen("logs/bpu_mispredict.log", "w");

wire        bpu_dir_mis      = soc_top_inst.core_top_inst.bpu_dir_mismatch;
wire        bpu_tgt_mis      = soc_top_inst.core_top_inst.bpu_tgt_mismatch;
wire        bpu_misp         = soc_top_inst.core_top_inst.bpu_mispredict;
wire [31:0] wp_pc_ie         = soc_top_inst.core_top_inst.pc_ie;
wire        wp_pred_taken    = soc_top_inst.core_top_inst.ctrl_bus_ie.predicted_taken;
wire        wp_branch_taken  = soc_top_inst.core_top_inst.branch_taken;
wire [31:0] wp_pred_pc_ie    = soc_top_inst.core_top_inst.predicted_pc_ie;
wire [31:0] wp_pred_tgt_ie   = soc_top_inst.core_top_inst.predicted_target_ie;
wire [31:0] wp_actual_tgt    = soc_top_inst.core_top_inst.branch_target_address;
wire        wp_iwb_flush     = soc_top_inst.core_top_inst.iwb_flush;
wire        wp_ie_flush      = soc_top_inst.core_top_inst.ie_flush;

// ── flush + redirect snoop (probe v5d) ───────────────────────
// Captures every U-mode cycle where any flush or redirect signal
// asserts, plus ie_stall and aligner_valid. Goal: pin down the
// exact cycle the iter-3 bne is squashed at IE entry (~82273073).
integer flush_fd;
initial flush_fd = $fopen("logs/flush_redirect.log", "w");

wire        wp_imem_flush       = soc_top_inst.core_top_inst.imem_flush;
wire        wp_branch_taken_valid = soc_top_inst.core_top_inst.branch_taken_valid;
wire        wp_bpu_redirect_fire  = soc_top_inst.core_top_inst.bpu_redirect_fire;
wire        wp_bpu_if_redirect_fire = soc_top_inst.core_top_inst.bpu_if_redirect_fire;
wire        wp_ie_stall         = soc_top_inst.core_top_inst.ie_stall;
wire        wp_aligner_valid    = soc_top_inst.core_top_inst.aligner_valid;

// Tight cycle window around the failure (LBU2 retire ~82273074, bne should
// load IE at 82273073). Log only U-mode in window 82272900..82273100 to
// keep the file small.
`ifdef ENABLE_DEBUG_PROBES
always @(posedge clk) begin : flush_log_blk
    if (!reset && (wp_priv == 2'd0) &&
        (wp_cycle >= 32'd82272900) && (wp_cycle <= 32'd82273100)) begin
        if (wp_ie_flush || wp_imem_flush || wp_iwb_flush ||
            wp_branch_taken_valid || wp_bpu_redirect_fire || wp_bpu_if_redirect_fire) begin
            $fwrite(flush_fd,
                "@%0d pc_ie=%08h ie_stall=%0d aligner_v=%0d ie_flush=%0d imem_flush=%0d iwb_flush=%0d bt_valid=%0d bpu_pred=%0d bpu_if=%0d\n",
                wp_cycle, wp_pc_ie, wp_ie_stall, wp_aligner_valid,
                wp_ie_flush, wp_imem_flush, wp_iwb_flush,
                wp_branch_taken_valid, wp_bpu_redirect_fire, wp_bpu_if_redirect_fire);
            $fflush(flush_fd);
        end
    end
end

// ── strcmp loop IWB commit stream (probe v5c) ────────────────
// Logs every U-mode commit (pc_iwb retire) within the strcmp loop
// body PCs 0x000a2674..0x000a268a. Fires one line per committed
// instruction, in commit order. Smoking-gun pattern: a cycle with
// pc_iwb=0xa2686 (sub) WITHOUT a preceding pc_iwb=0xa267c (bne)
// in the same loop iteration → predicted-target committed before
// the predicting branch could resolve.
integer strcmp_iwb_fd;
initial strcmp_iwb_fd = $fopen("logs/strcmp_iwb.log", "w");

always @(posedge clk) begin : strcmp_iwb_probe_blk
    if (!reset && (wp_priv == 2'd0) &&
        (wp_pc_iwb >= 32'h000a2674) && (wp_pc_iwb <= 32'h000a268a)) begin
        $fwrite(strcmp_iwb_fd, "@%0d pc_iwb=%08h\n", wp_cycle, wp_pc_iwb);
        $fflush(strcmp_iwb_fd);
    end
end

// ── strcmp bne operand probe (probe v5b) ─────────────────────
// Logs every IE-stage execution of the strcmp bne at PC 0x000a267c
// with the actual operands feeding branch_comp + the resolved
// direction + the forwarding-mux selectors. Tiny log (one line
// per strcmp call iteration). Goal: catch the iter-3 case where
// opA == opB at the load level but opA != opB at branch_comp
// (= load-use hazard escape via stale forwarding).
integer strcmp_fd;
initial strcmp_fd = $fopen("logs/strcmp_bne.log", "w");

wire [31:0] wp_opA       = soc_top_inst.core_top_inst.opA_forwarded_data;
wire [31:0] wp_opB       = soc_top_inst.core_top_inst.opB_forwarded_data;
wire [1:0]  wp_fwda      = soc_top_inst.core_top_inst.forwarda_ie;
wire [1:0]  wp_fwdb      = soc_top_inst.core_top_inst.forwardb_ie;

always @(posedge clk) begin : strcmp_bne_probe_blk
    if (!reset && (wp_priv == 2'd0) && (wp_pc_ie == 32'h000a267c)) begin
        $fwrite(strcmp_fd,
            "@%0d pc_ie=%08h opA=%08h opB=%08h taken=%0d pred=%0d fwda=%0d fwdb=%0d ie_flush=%0d\n",
            wp_cycle, wp_pc_ie, wp_opA, wp_opB,
            wp_branch_taken, wp_pred_taken,
            wp_fwda, wp_fwdb, wp_ie_flush);
        $fflush(strcmp_fd);
    end
end

// U-mode only (priv=0): kernel mispredicts dominate volume but are
// not relevant to the userspace ash bug. Cuts log rate ~10x.
always @(posedge clk) begin : bpu_misp_log_blk
    if (!reset && bpu_misp && (wp_priv == 2'd0)) begin
        $fwrite(bpu_misp_fd,
            "@%0d MISP pc_ie=%08h pred=%s act=%s pred_pc=%08h pred_tgt=%08h act_tgt=%08h ie_flush=%0d iwb_flush=%0d %s%s\n",
            wp_cycle, wp_pc_ie,
            wp_pred_taken   ? "T" : "N",
            wp_branch_taken ? "T" : "N",
            wp_pred_pc_ie, wp_pred_tgt_ie, wp_actual_tgt,
            wp_ie_flush, wp_iwb_flush,
            bpu_dir_mis ? "DIR" : "",
            bpu_tgt_mis ? " TGT" : "");
        $fflush(bpu_misp_fd);
    end
end

// ── Bash tokenizer IWB commit stream (probe v9) ─────────────────
// Logs every U-mode IWB retire whose pc_iwb falls in bash's
// post-getc tokenizer area (0x14338..0x14400). Used to verify
// whether the conditional branches `bnez a4, 0x14450` (line 14342),
// `bnez a4, 0x143f2` (14346 -> 1434a), and `bnez s11, 0x143fa`
// (1434c) actually retire on each call to the byte-getter. If the
// `bnez s11` at 1434c is ever absent from the stream after a
// non-zero byte was returned (s11 == returned byte) — same
// fingerprint as the strcmp bne drop bug, just at a different PC.

integer btiwb_fd;
initial btiwb_fd = $fopen("logs/bash_tok_iwb.log", "w");

always @(posedge clk) begin : btiwb_probe_blk
    if (!reset && wp_priv == 2'd0 && wp_cycle >= 32'd80_000_000 &&
        wp_pc_iwb >= 32'h00014338 && wp_pc_iwb <= 32'h00014400) begin
        $fwrite(btiwb_fd, "@%0d pc_iwb=%08h\n", wp_cycle, wp_pc_iwb);
        $fflush(btiwb_fd);
    end
end

// ── U-mode store stream (probe v8) ──────────────────────────────
// Captures every U-mode dport store in cycle window 80M+ with the
// byte at the LSB of the address (what an SB would have written).
// Used to verify that bash's per-byte tokenizer-buffer writes match
// the bytes it just loaded. If load got 0x20 but the immediately-
// following store writes 0x0a, the store path has a bug.
integer ust_fd;
initial ust_fd = $fopen("logs/umode_stores.log", "w");

always @(posedge clk) begin : ust_probe_blk
    if (!reset && wp_priv == 2'd0 && wp_cycle >= 32'd80_000_000 &&
        wp_dport_req && wp_dport_we) begin
        if (wp_dport_addr >= 32'h80000000 && wp_dport_addr < 32'h88000000) begin
            $fwrite(ust_fd,
                "@%0d pc=%08h addr=%08h wdata=%08h byte=%02h\n",
                wp_cycle, wp_pc_imem, wp_dport_addr, wp_dport_wdata,
                wp_dport_wdata[8*wp_dport_addr[1:0] +: 8]);
            $fflush(ust_fd);
        end
    end
end

// ── U-mode load writeback (probe v7) ────────────────────────────
// Captures every U-mode load that retires (ctrl_bus_iwb.wb_sel ==
// MEMORY) with the value written to the destination register. Used
// to verify what the CPU's lbu/lh/lw byte-mux actually delivers vs
// what the dport returned (probe v6 captures dport-side correctness).
// If probe v7 shows 0x0a where probe v6 said 0x20 at the same cycle,
// the byte-mux is buggy. If v7 matches v6, corruption is downstream
// (e.g., a clobbered register or buffer write).

integer ulwb_fd;
initial ulwb_fd = $fopen("logs/umode_load_writeback.log", "w");

wire [31:0] wp_writeback_data = soc_top_inst.core_top_inst.write_back_data;
wire        wp_iwb_is_load    = (soc_top_inst.core_top_inst.ctrl_bus_iwb.wb_sel == MEMORY);
wire [4:0]  wp_iwb_rd         = soc_top_inst.core_top_inst.ctrl_bus_iwb.rd_int[4:0];
wire [31:0] wp_readdata_iwb   = soc_top_inst.core_top_inst.readdata_iwb;

always @(posedge clk) begin : ulwb_probe_blk
    if (!reset && wp_priv == 2'd0 && wp_cycle >= 32'd80_000_000 &&
        wp_iwb_is_load && wp_iwb_rd != 5'd0) begin
        $fwrite(ulwb_fd,
            "@%0d pc_iwb=%08h rd=%0d wb=%08h raw=%08h\n",
            wp_cycle, wp_pc_iwb, wp_iwb_rd, wp_writeback_data, wp_readdata_iwb);
        $fflush(ulwb_fd);
    end
end

// ── U-mode byte-load corruption hunt (probe v6) ─────────────────
// Captures every U-mode dport read in cycle window 80M-200M with the
// byte that LBU/LB would extract at addr[1:0]. Used to find byte-level
// corruption between RAM and bash/ash tokenizer. Symptom: bash sees
// '#' comment lines as commands, suggesting the 0x23 byte fails to
// arrive at bash's load instruction. This probe captures every U-mode
// read in the RAM range so post-processing can correlate addresses
// against expected file content.

integer  ubp_fd;
integer  ubp_hash_fd;
initial begin
    ubp_fd      = $fopen("logs/umode_byte_reads.log", "w");
    ubp_hash_fd = $fopen("logs/umode_hash_byte_reads.log", "w");
end

reg        ubp_pend_v = 1'b0;
reg [31:0] ubp_pend_cyc;
reg [31:0] ubp_pend_pc;
reg [31:0] ubp_pend_addr;

always @(posedge clk) begin : ubp_probe_blk
    logic [7:0] ubp_byte;
    if (!reset && wp_priv == 2'd0 && wp_cycle >= 32'd80_000_000) begin
        // Latched read completes
        if (ubp_pend_v && wp_dport_rvalid) begin
            ubp_byte = wp_dport_rdata[8*ubp_pend_addr[1:0] +: 8];
            // Wide stream: log every U-mode RAM read
            if (ubp_pend_addr >= 32'h80000000 && ubp_pend_addr < 32'h88000000) begin
                $fwrite(ubp_fd,
                    "@%0d pc=%08h addr=%08h rdata=%08h b@lsb=%02h\n",
                    ubp_pend_cyc, ubp_pend_pc, ubp_pend_addr,
                    wp_dport_rdata, ubp_byte);
                $fflush(ubp_fd);
                // Narrow stream: log only when extracted byte == '#' (0x23)
                if (ubp_byte == 8'h23) begin
                    $fwrite(ubp_hash_fd,
                        "@%0d pc=%08h addr=%08h rdata=%08h\n",
                        ubp_pend_cyc, ubp_pend_pc, ubp_pend_addr,
                        wp_dport_rdata);
                    $fflush(ubp_hash_fd);
                end
            end
            ubp_pend_v <= 1'b0;
        end
        // New U-mode read request
        if (wp_dport_req && !wp_dport_we) begin
            ubp_pend_v    <= 1'b1;
            ubp_pend_cyc  <= wp_cycle;
            ubp_pend_pc   <= wp_pc_imem;
            ubp_pend_addr <= wp_dport_addr;
        end
    end
end
`endif // ENABLE_DEBUG_PROBES

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
