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

// ── Linux 6.12 __schedule_bug NULL-prev watchpoint ──────────────
// Targeted instrumentation for the xas_load / NULL-prev HW corruption bug.
// Symptom: __schedule_bug at c0028046 (`lw a2, 576(a0)`) faults on a0=0.
// a0 is `mv a0, s6` from __schedule, so s6 (= prev task ptr loaded at
// __schedule entry from `lw s6, 1180(s5)`) was NULL when handed off.
//
// This block writes s6_watch.log:
//   - Every transition of x22 (s6) from non-zero to zero (corruption signature)
//   - Every entry to __schedule_bug body (PC c0028032), with current x10 (a0)
//   - Every async-trap commit (interrupt_valid + is_interrupt cause)
//
// All addresses match linux-6.12/System.map. If the kernel build changes,
// re-run: `awk '$3=="T" && /__schedule_bug/' .../System.map`.
integer s6_log_fd;
initial s6_log_fd = $fopen("logs/s6_watch.log", "w");

integer wp_cycle = 0;
always @(posedge clk) if (!reset) wp_cycle <= wp_cycle + 1;

// Hierarchical taps
wire        wp_rf_we   = soc_top_inst.core_top_inst.rf_wr_en;
wire [4:0]  wp_rf_addr = soc_top_inst.core_top_inst.rf_wr_addr;
wire [31:0] wp_rf_data = soc_top_inst.core_top_inst.rf_wr_data;
wire [31:0] wp_pc_iwb  = soc_top_inst.core_top_inst.pc_iwb;
wire [31:0] wp_s6_now  = soc_top_inst.core_top_inst.regfile_inst.regfile[22];
wire [31:0] wp_a0_now  = soc_top_inst.core_top_inst.regfile_inst.regfile[10];
wire        wp_int_v   = soc_top_inst.core_top_inst.interrupt_valid;
wire [31:0] wp_ecause  = soc_top_inst.core_top_inst.ecause_csr;
wire [31:0] wp_epc     = soc_top_inst.core_top_inst.epc_csr;
wire [1:0]  wp_priv    = soc_top_inst.core_top_inst.priv_level;

localparam [31:0] WP_SCHED_BUG_ENTRY = 32'hc0028032;  // __schedule_bug
localparam [31:0] WP_SCHED_BUG_LW    = 32'hc0028046;  // lw a2, 576(a0)
localparam [31:0] WP_SCHED_LO        = 32'hc01d8cbe;  // __schedule entry
localparam [31:0] WP_SCHED_HI        = 32'hc01d91b8;  // schedule (= __schedule end)

// Detect entry: pc_iwb advances PAST the first instruction of __schedule_bug.
// First insn at c0028032 is lui (4 bytes), so pc_iwb == c0028036 means
// the lui just retired and we're entering the function.
reg wp_inside_sched_bug = 0;
reg [31:0] wp_a0_at_entry = 32'h0;
reg [31:0] wp_s6_last_nonzero = 32'h0;
reg [31:0] wp_s6_last_nonzero_pc = 32'h0;
integer    wp_s6_last_nonzero_cyc = 0;

always @(posedge clk) begin
    if (!reset) begin
        // 1. Track s6 nonzero history
        if (wp_rf_we && wp_rf_addr == 5'd22 && wp_rf_data != 32'h0) begin
            wp_s6_last_nonzero     <= wp_rf_data;
            wp_s6_last_nonzero_pc  <= wp_pc_iwb;
            wp_s6_last_nonzero_cyc <= wp_cycle;
        end

        // 2. s6 → 0 transition inside __schedule
        if (wp_rf_we && wp_rf_addr == 5'd22 && wp_rf_data == 32'h0 &&
            wp_s6_now != 32'h0 &&
            wp_pc_iwb >= WP_SCHED_LO && wp_pc_iwb < WP_SCHED_HI) begin
            $fwrite(s6_log_fd,
                "@%0d S6_TO_ZERO pc_iwb=%08h prev_s6=%08h (last_nonzero @%0d pc=%08h val=%08h)\n",
                wp_cycle, wp_pc_iwb, wp_s6_now,
                wp_s6_last_nonzero_cyc, wp_s6_last_nonzero_pc, wp_s6_last_nonzero);
            $fflush(s6_log_fd);
        end

        // 3. Async traps inside __schedule (most likely culprit window)
        if (wp_int_v && wp_ecause[31] &&
            wp_epc >= WP_SCHED_LO && wp_epc < WP_SCHED_HI) begin
            $fwrite(s6_log_fd,
                "@%0d ASYNC_TRAP_IN_SCHED epc=%08h cause=%08h s6=%08h priv=%0d\n",
                wp_cycle, wp_epc, wp_ecause, wp_s6_now, wp_priv);
            $fflush(s6_log_fd);
        end

        // 4. Entry to __schedule_bug — capture a0 + read saved ra from __schedule's stack frame.
        //    __schedule's prologue does `sw ra, 44(sp)` (at c01d8cc6), so when we land in
        //    __schedule_bug, mem[sp+44] holds the address that called schedule()/__schedule.
        //    Linux 6.12 maps virt c0000000 → phys 0x80400000 (offset 0x3FC00000), and
        //    ram_inst.mem[idx] holds the word at phys 0x80000000 + 4*idx.
        if (wp_pc_iwb == (WP_SCHED_BUG_ENTRY + 32'd4) && !wp_inside_sched_bug) begin : sched_bug_capture
            logic [31:0] cur_sp;
            logic [31:0] paddr;
            logic [31:0] idx;
            logic [31:0] word;
            int          i;
            cur_sp = soc_top_inst.core_top_inst.regfile_inst.regfile[2];

            wp_inside_sched_bug <= 1'b1;
            wp_a0_at_entry      <= wp_a0_now;
            $fwrite(s6_log_fd,
                "@%0d ENTER __schedule_bug a0(prev)=%08h s6=%08h sp=%08h\n",
                wp_cycle, wp_a0_now, wp_s6_now, cur_sp);
            // Dump 32 stack words from sp upward — covers __schedule's frame (48 bytes)
            // PLUS the parent (schedule, +16 bytes) PLUS the grandparent's frame.
            // Linux kernel virt c0/c1xxxxxx → phys at virt - 0x3FC00000.
            $fwrite(s6_log_fd, "    stack dump @sp=%08h:\n", cur_sp);
            for (i = 0; i < 32; i++) begin
                paddr = (cur_sp + i*4) - 32'h3FC00000;
                idx   = (paddr - 32'h80000000) >> 2;
                word  = soc_top_inst.ram_inst.mem[idx];
                $fwrite(s6_log_fd, "      [sp+%0d] %08h: %08h\n",
                        i*4, cur_sp + i*4, word);
            end
            $fflush(s6_log_fd);
            if (wp_a0_now == 32'h0) begin
                $display("WATCHPOINT: __schedule_bug entered with prev=NULL @ cycle %0d  sp=%08h",
                         wp_cycle, cur_sp);
                $fwrite(s6_log_fd,
                    "*** PREV=NULL bug fired @%0d. See stack dump above to walk back to original schedule() caller. ***\n",
                    wp_cycle);
                $fflush(s6_log_fd);
            end
        end
        // Reset entry flag once we leave the function range
        if (wp_inside_sched_bug && (wp_pc_iwb < 32'hc0028030 || wp_pc_iwb > 32'hc002808a))
            wp_inside_sched_bug <= 1'b0;
    end
end

// ── AMO/PTW bus arbitration race detector ──────────────────────
// Hypothesis: amo_unit's dbus_stall_i is wired to ~dmem_port.ready
// without checking ptw_active. When Svadu PTW pre-empts the bus
// during AMO_READ or AMO_WRITE, the PTW's ready/rvalid makes amo_unit
// think its OWN access completed → silently dropped atomic OR wrong
// data captured into amo_unit's read_data_q.
//
// This block counts and logs all AMO/PTW collision events.
integer amo_ptw_log_fd;
initial amo_ptw_log_fd = $fopen("logs/amo_ptw_race.log", "w");

// State enum: IDLE=0, AMO_READ=1, AMO_WRITE=2, DONE=3
wire [1:0]  amo_state_now    = soc_top_inst.core_top_inst.amo_unit_inst.state;
wire        wp_ptw_active    = soc_top_inst.core_top_inst.ptw_active;
wire        wp_dmem_ready    = soc_top_inst.core_top_inst.dmem_port.ready;
wire        wp_dmem_rvalid   = soc_top_inst.core_top_inst.dmem_port.rvalid;
wire        wp_dmem_we       = soc_top_inst.core_top_inst.dmem_port.we;
wire [31:0] wp_dmem_addr     = soc_top_inst.core_top_inst.dmem_port.addr;
wire [31:0] wp_amo_addr      = soc_top_inst.core_top_inst.amo_dbus_addr;
wire        wp_amo_active    = soc_top_inst.core_top_inst.amo_active;

integer ev_collide_total       = 0;  // any cycle amo_active && ptw_active
integer ev_amo_advance_in_ptw  = 0;  // AMO state changed while ptw_active
reg [1:0] amo_state_q = 0;

always @(posedge clk) begin
    if (!reset) begin
        amo_state_q <= amo_state_now;

        // Total collision cycles
        if (wp_amo_active && wp_ptw_active) begin
            ev_collide_total <= ev_collide_total + 1;
            if (ev_collide_total < 30) begin
                $fwrite(amo_ptw_log_fd,
                    "@%0d  COLLIDE amo_state=%0d amo_addr=%08h dmem_addr=%08h dmem_we=%0d ready=%0d rvalid=%0d\n",
                    wp_cycle, amo_state_now, wp_amo_addr, wp_dmem_addr, wp_dmem_we, wp_dmem_ready, wp_dmem_rvalid);
                $fflush(amo_ptw_log_fd);
            end
        end

        // The smoking-gun: AMO advances state (other than to IDLE on flush)
        // while ptw_active=1. That means the bus response amo_unit consumed
        // belonged to PTW, not the AMO.
        if (amo_state_q != amo_state_now && amo_state_q != 2'd0 &&
            amo_state_now != 2'd0 && wp_ptw_active) begin
            ev_amo_advance_in_ptw <= ev_amo_advance_in_ptw + 1;
            $display("AMO_ADVANCE_IN_PTW @%0d  state %0d->%0d  amo_addr=%08h",
                     wp_cycle, amo_state_q, amo_state_now, wp_amo_addr);
            $fwrite(amo_ptw_log_fd,
                "*** AMO_ADVANCE_IN_PTW @%0d  state %0d->%0d  amo_addr=%08h dmem_addr=%08h ***\n",
                wp_cycle, amo_state_q, amo_state_now, wp_amo_addr, wp_dmem_addr);
            $fflush(amo_ptw_log_fd);
        end
    end
end

// ── core2avl / regular-load PTW response-leak detector ──────────
// Same bug class as AMO/PTW but for regular loads. Pipeline: when a
// load is in IMEM stage, readdata_imem is combinationally driven from
// dmem_port.rdata. If the bus's rdata/rvalid still belongs to a PTW
// transaction (ptw_active just dropped, or PTW response straddles the
// IE→IMEM boundary), the load captures PTE bytes into the regfile.
//
// Detector: at the cycle a load instruction commits to IWB, check if
// ptw_active OR ptw_active_q was high during the IMEM cycle. If so,
// the load's writeback may be PTW's data.
integer c2a_ptw_log_fd;
initial c2a_ptw_log_fd = $fopen("logs/c2a_ptw_race.log", "w");

// pull the pipeline state hooks
wire        wp_iwb_is_load = soc_top_inst.core_top_inst.ctrl_bus_iwb.mem_op == 2'd0; // READ=0, WRITE=1, NO_MEM_OP=2
wire [31:0] wp_iwb_pc      = soc_top_inst.core_top_inst.pc_iwb;
wire [31:0] wp_readdata_iwb= soc_top_inst.core_top_inst.readdata_iwb;
wire        wp_ptw_active_q= soc_top_inst.core_top_inst.ptw_active_q;
// Track whether ptw_active_q was set during the cycle the IWB-bound
// load was actually in IMEM (= one cycle ago). Use a 1-cycle delay.
reg ptw_was_active_in_imem_cyc = 0;
always @(posedge clk) begin
    if (!reset) begin
        // Capture: at the cycle a load IS in IMEM, was ptw owning the bus?
        // The pipeline drives dmem_port.rdata into readdata_imem (combinational)
        // and IWB latches it at the next edge.
        // If ptw_active|ptw_active_q is 1 the cycle BEFORE this edge, the
        // captured readdata could be PTW's residual.
        ptw_was_active_in_imem_cyc <= soc_top_inst.core_top_inst.ptw_active |
                                       soc_top_inst.core_top_inst.ptw_active_q;
    end
end

integer ev_c2a_ptw_susp_total = 0;
always @(posedge clk) begin
    if (!reset && wp_iwb_is_load && ptw_was_active_in_imem_cyc) begin
        ev_c2a_ptw_susp_total <= ev_c2a_ptw_susp_total + 1;
        if (ev_c2a_ptw_susp_total < 50) begin
            $fwrite(c2a_ptw_log_fd,
                "@%0d  C2A_LOAD_AFTER_PTW pc_iwb=%08h readdata=%08h\n",
                wp_cycle, wp_iwb_pc, wp_readdata_iwb);
            $fflush(c2a_ptw_log_fd);
        end
        if (ev_c2a_ptw_susp_total == 0) begin
            $display("C2A_LOAD_AFTER_PTW first hit @%0d pc_iwb=%08h", wp_cycle, wp_iwb_pc);
        end
    end
end

// ── vDSO-range pointer tracker ──────────────────────────────────
// Hypothesis: busybox's __libc_free at PC 0x8e5a4 is called with a
// corrupted pointer 0x9573e270 (lands inside vDSO area). The corrupt
// pointer was placed somewhere in busybox heap by an earlier op. To
// find that op, snoop every dmem_port WRITE whose wdata is in the
// vDSO range (0x95700000-0x95800000) and every READ that returns a
// value in that range. The first time the value 0x9573e270 (or a
// near neighbor) appears as wdata to a heap-area address tells us
// where the corruption originated.
integer ptr_log_fd;
initial ptr_log_fd = $fopen("logs/ptr_tracker.log", "w");

wire        wp_dport_req    = soc_top_inst.core_top_inst.dmem_port.req;
wire        wp_dport_we     = soc_top_inst.core_top_inst.dmem_port.we;
wire [31:0] wp_dport_wdata  = soc_top_inst.core_top_inst.dmem_port.wdata;
wire [31:0] wp_dport_addr   = soc_top_inst.core_top_inst.dmem_port.addr;
wire [31:0] wp_dport_rdata  = soc_top_inst.core_top_inst.dmem_port.rdata;
wire        wp_dport_rvalid = soc_top_inst.core_top_inst.dmem_port.rvalid;

integer ev_vdso_store_total = 0;
integer ev_vdso_read_total  = 0;
always @(posedge clk) begin
    if (!reset) begin
        // Stores of vDSO-range values
        if (wp_dport_req && wp_dport_we &&
            wp_dport_wdata >= 32'h95700000 && wp_dport_wdata < 32'h95800000) begin
            ev_vdso_store_total <= ev_vdso_store_total + 1;
            if (ev_vdso_store_total < 200) begin
                $fwrite(ptr_log_fd,
                    "@%0d  STORE_VDSO_VAL wdata=%08h addr=%08h pc_iwb=%08h priv=%0d\n",
                    wp_cycle, wp_dport_wdata, wp_dport_addr, wp_pc_iwb, wp_priv);
                $fflush(ptr_log_fd);
            end
        end
        // Reads returning vDSO-range values
        if (wp_dport_rvalid &&
            wp_dport_rdata >= 32'h95700000 && wp_dport_rdata < 32'h95800000) begin
            ev_vdso_read_total <= ev_vdso_read_total + 1;
            if (ev_vdso_read_total < 200) begin
                $fwrite(ptr_log_fd,
                    "@%0d  READ_VDSO_VAL  rdata=%08h pc_iwb=%08h priv=%0d\n",
                    wp_cycle, wp_dport_rdata, wp_pc_iwb, wp_priv);
                $fflush(ptr_log_fd);
            end
        end
    end
end

// ── ash parser-error capture ────────────────────────────────────
// busybox-ash prints "bad for loop variable" when its parser hits
// the error path at PC 0x4435e. When that PC retires, snapshot full
// register state + 32 stack words (= ash's call chain + parser ctx).
integer ash_log_fd;
initial ash_log_fd = $fopen("logs/ash_parser_err.log", "w");

reg ash_caught = 0;
always @(posedge clk) begin : ash_caught_blk
    int          i;
    logic [31:0] paddr, idx, word, sp_val, gp_val;
    if (!reset && wp_priv == 2'd0 && wp_pc_iwb == 32'h00044362 && !ash_caught) begin
        ash_caught <= 1'b1;
        sp_val = soc_top_inst.core_top_inst.regfile_inst.regfile[2];
        gp_val = soc_top_inst.core_top_inst.regfile_inst.regfile[3];
        $display("ASH PARSER ERROR captured @%0d sp=%08h", wp_cycle, sp_val);
        $fwrite(ash_log_fd, "@%0d ASH parser error site reached (PC 0x4435e)\n", wp_cycle);
        for (i = 0; i < 32; i++) begin
            $fwrite(ash_log_fd, "  x%-2d = %08h\n", i,
                    soc_top_inst.core_top_inst.regfile_inst.regfile[i]);
        end
        // Dump 32 stack words from sp upward (call frames)
        $fwrite(ash_log_fd, "  --- stack @sp=%08h ---\n", sp_val);
        for (i = 0; i < 32; i++) begin
            // user va → phys: kernel maps user pages somewhere in 0x80000000+ phys range
            // we can't easily MMU-translate from tb. Instead snoop ram_inst.mem at
            // assumed phys. For known-mapped user data on stack, look at
            // dmem_bus signals nearby. Here we just emit a comment; the trace_log
            // will show actual sw/lw to these addresses.
            $fwrite(ash_log_fd, "    [sp+%0d] vaddr=%08h\n", i*4, sp_val + i*4);
        end
        // Look at busybox bss area near gp for ash globals (these ARE in ram_inst.mem at phys 0x80000000+)
        // gp-1344 = wordtext (busybox global); gp-1332 = quoteflag
        $fwrite(ash_log_fd, "  --- ash globals via gp=%08h ---\n", gp_val);
        $fwrite(ash_log_fd, "  wordtext (gp-1344)  vaddr=%08h\n", gp_val - 32'd1344);
        $fwrite(ash_log_fd, "  quoteflag (gp-1332) vaddr=%08h\n", gp_val - 32'd1332);
        $fflush(ash_log_fd);
    end
end

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

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
