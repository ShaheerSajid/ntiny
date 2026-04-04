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

// ── Crash trace state ───────────────────────────────────────────
reg crash_trace_arm;
reg [31:0] crash_trace_cnt;
reg [1:0] crash_prev_priv;
reg [31:0] crash_prev_sscratch;
initial begin crash_trace_arm = 0; crash_trace_cnt = 0; crash_prev_priv = 3; crash_prev_sscratch = 0; end

// ── Fast simulation console ─────────────────────────────────────
// Captures UART TX register writes directly from the bus, bypassing
// the slow bit-by-bit UART serializer. Characters appear immediately.
integer sim_con_fd;
initial sim_con_fd = $fopen("uart.log", "w");

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

// ── TLB/MMU trace for bad_page debugging ────────────────────────
// Log DTLB fills, sfence flushes, and data accesses to suspicious PFNs
integer mmu_fd;
initial mmu_fd = $fopen("mmu_trace.log", "w");

always @(posedge clk) begin
	if (!reset) begin
		// Log every DTLB fill
		if (soc_top_inst.core_top_inst.mmu_inst.tlb_fill &&
		    !soc_top_inst.core_top_inst.mmu_inst.ptw_for_insn) begin
			$fwrite(mmu_fd, "DTLB-FILL: vpn1=%03h vpn0=%03h -> ppn1=%03h ppn0=%03h mega=%0b rwx=%0b%0b%0b adu=%0b%0b%0b vaddr=%08h\n",
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.vpn1,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.vpn0,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.ppn1,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.ppn0,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.mega,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.r,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.w,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.x,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.a,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.d,
				soc_top_inst.core_top_inst.mmu_inst.fill_entry.u,
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr);
		end

		// Log SFENCE.VMA
		if (soc_top_inst.core_top_inst.mmu_inst.sfence_i)
			$fwrite(mmu_fd, "SFENCE: pc_ie=%08h\n",
				soc_top_inst.core_top_inst.pc_ie);

		// Log data page faults with PTW state
		if (soc_top_inst.core_top_inst.mmu_inst.d_fault_o)
			$fwrite(mmu_fd, "D-FAULT: vaddr=%08h store=%0b priv=%0d ptw_state=%0d ptw_pte=%08h mega=%0b\n",
				soc_top_inst.core_top_inst.mmu_inst.d_vaddr_i,
				soc_top_inst.core_top_inst.mmu_inst.d_store_i,
				soc_top_inst.core_top_inst.mmu_inst.d_eff_priv,
				soc_top_inst.core_top_inst.mmu_inst.ptw_state,
				soc_top_inst.core_top_inst.mmu_inst.ptw_pte,
				soc_top_inst.core_top_inst.mmu_inst.ptw_mega);

		// Log PMP check during all PTW reads
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 1 ||
		    soc_top_inst.core_top_inst.mmu_inst.ptw_state == 3)
			$fwrite(mmu_fd, "PTW-PMP: state=%0d vaddr=%08h addr=%08h addr_g=%08h priv=%0d d_pmp_fault=%0b ptw_pmp_denied=%0b match0=%0b match1=%0b pmpaddr0=%08h pmpaddr1=%08h pmpcfg0=%08h\n",
				soc_top_inst.core_top_inst.mmu_inst.ptw_state,
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr,
				soc_top_inst.core_top_inst.mmu_inst.ptw_addr_o,
				soc_top_inst.core_top_inst.mmu_inst.ptw_addr_o[31:2],
				soc_top_inst.core_top_inst.mmu_inst.d_pmp_priv,
				soc_top_inst.core_top_inst.mmu_inst.d_pmp_fault,
				soc_top_inst.core_top_inst.mmu_inst.ptw_pmp_denied,
				soc_top_inst.core_top_inst.mmu_inst.pmp_d_check.match[0],
				soc_top_inst.core_top_inst.mmu_inst.pmp_d_check.match[1],
				soc_top_inst.core_top_inst.mmu_inst.pmpaddr_i[0],
				soc_top_inst.core_top_inst.mmu_inst.pmpaddr_i[1],
				soc_top_inst.core_top_inst.mmu_inst.pmpcfg_i[0]);
			// Also dump the checker's internal fault
			$fwrite(mmu_fd, "  CHK: fault_o=%0b priv_i=%0b\n",
				soc_top_inst.core_top_inst.mmu_inst.pmp_d_check.fault_o,
				soc_top_inst.core_top_inst.mmu_inst.pmp_d_check.priv_i);

		// Log PTW faults (when PTW itself causes the fault)
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 5)  // PTW_FAULT
			$fwrite(mmu_fd, "PTW-FAULT: vaddr=%08h pte=%08h mega=%0b perm=%0b priv_fault=%0b for_store=%0b ptw_priv=%0d ptw_sum=%0b live_priv=%0d live_sum=%0b\n",
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr,
				soc_top_inst.core_top_inst.mmu_inst.ptw_pte,
				soc_top_inst.core_top_inst.mmu_inst.ptw_mega,
				soc_top_inst.core_top_inst.mmu_inst.ptw_perm_fault,
				soc_top_inst.core_top_inst.mmu_inst.ptw_priv_fault,
				soc_top_inst.core_top_inst.mmu_inst.ptw_for_store,
				soc_top_inst.core_top_inst.mmu_inst.ptw_priv,
				soc_top_inst.core_top_inst.mmu_inst.ptw_sum,
				soc_top_inst.core_top_inst.mmu_inst.d_eff_priv,
				soc_top_inst.core_top_inst.mmu_inst.sum_bit);

		// Log sret transitions (U-mode return)
		if (soc_top_inst.core_top_inst.csr_unit_inst.sret_i &&
		    soc_top_inst.core_top_inst.csr_unit_inst.priv_level == 2'b01)
			$fwrite(mmu_fd, "SRET: sepc=%08h sscratch=%08h priv=%0d->%0d\n",
				soc_top_inst.core_top_inst.csr_unit_inst._SEPC,
				soc_top_inst.core_top_inst.csr_unit_inst._SSCRATCH,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.csr_unit_inst._MSTATUS[8] ? 1 : 0);
	end
end

// ── Lightweight PC sampler (every 1M cycles) ────────────────────
reg [31:0] pc_sample_cnt;
always @(posedge clk) begin
	if (reset)
		pc_sample_cnt <= 0;
	else begin
		pc_sample_cnt <= pc_sample_cnt + 1;
		// ── Crash trace: log EVERY priv change and trap near init ──
		// Always log when: priv changes, trap fires, or sscratch changes
		// Only active after first SRET to user mode
		if (soc_top_inst.core_top_inst.csr_unit_inst.sret_i &&
		    soc_top_inst.core_top_inst.csr_unit_inst.priv_level == 2'b01 &&
		    soc_top_inst.core_top_inst.csr_unit_inst._MSTATUS[8] == 1'b0)
			crash_trace_arm <= 1;

		if (crash_trace_arm) begin
			// Log on trap, priv change, or sscratch write
			if (soc_top_inst.core_top_inst.interrupt_valid ||
			    soc_top_inst.core_top_inst.csr_unit_inst.priv_level != crash_prev_priv ||
			    soc_top_inst.core_top_inst.csr_unit_inst._SSCRATCH != crash_prev_sscratch) begin
				$fwrite(mmu_fd, "EV pc_ie=%08h priv=%0d sscratch=%08h scause=%08h sepc=%08h trap=%0b async=%0b ie_type=%0d\n",
					soc_top_inst.core_top_inst.pc_ie,
					soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
					soc_top_inst.core_top_inst.csr_unit_inst._SSCRATCH,
					soc_top_inst.core_top_inst.csr_unit_inst._SCAUSE,
					soc_top_inst.core_top_inst.csr_unit_inst._SEPC,
					soc_top_inst.core_top_inst.interrupt_valid,
					soc_top_inst.core_top_inst.async_trap,
					soc_top_inst.core_top_inst.ctrl_bus_ie.inst_type);
				$fflush(mmu_fd);
			end
			crash_prev_priv <= soc_top_inst.core_top_inst.csr_unit_inst.priv_level;
			crash_prev_sscratch <= soc_top_inst.core_top_inst.csr_unit_inst._SSCRATCH;
		end
		if (pc_sample_cnt[19:0] == 20'h0) begin // every ~1M cycles
			$fwrite(sim_con_fd, "PC[%0d] pc=%08h priv=%0d satp=%08h\n",
				pc_sample_cnt,
				soc_top_inst.core_top_inst.pc_out,
				soc_top_inst.core_top_inst.csr_unit_inst.priv_level,
				soc_top_inst.core_top_inst.csr_unit_inst._SATP);
			$fflush(sim_con_fd);
		end
	end
end

// Diagnostic pipeline tracer (dedicated file for maintainability)
`include "testbench/diag_tracer.vh"

// Debug: trace page faults and PTW activity
`ifdef DV_MMU_TRACE
always @(posedge clk) begin
	if (!reset) begin
		// Instruction page fault
		if (soc_top_inst.core_top_inst.mmu_i_fault)
			$display("MMU: I-FAULT vaddr=%08h paddr=%08h pc_id=%08h priv=%0d",
				soc_top_inst.core_top_inst.mmu_inst.i_vaddr_i,
				soc_top_inst.core_top_inst.mmu_inst.i_paddr_o,
				soc_top_inst.core_top_inst.pc_id,
				soc_top_inst.core_top_inst.priv_level);
		// Data page fault
		if (soc_top_inst.core_top_inst.mmu_d_fault)
			$display("MMU: D-FAULT vaddr=%08h store=%0b pc_ie=%08h priv=%0d d_eff_priv=%0d",
				soc_top_inst.core_top_inst.mmu_inst.d_vaddr_i,
				soc_top_inst.core_top_inst.mmu_inst.d_store_i,
				soc_top_inst.core_top_inst.pc_ie,
				soc_top_inst.core_top_inst.priv_level,
				soc_top_inst.core_top_inst.mmu_inst.d_eff_priv);
		// PTW state transitions
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 5 /* PTW_FAULT */)
			$display("MMU: PTW-FAULT vaddr=%08h for_insn=%0b for_store=%0b pte=%08h mega=%0b",
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr,
				soc_top_inst.core_top_inst.mmu_inst.ptw_for_insn,
				soc_top_inst.core_top_inst.mmu_inst.ptw_for_store,
				soc_top_inst.core_top_inst.mmu_inst.ptw_pte,
				soc_top_inst.core_top_inst.mmu_inst.ptw_mega);
		// PTW reading PTE
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 1 /* PTW_L1 */ && !soc_top_inst.core_top_inst.mmu_inst.ptw_stall_i)
			$display("MMU: PTW-L1 addr=%08h data=%08h vaddr=%08h",
				soc_top_inst.core_top_inst.mmu_inst.ptw_addr_o,
				soc_top_inst.core_top_inst.mmu_inst.ptw_data_i,
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr);
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 3 /* PTW_L0 */ && !soc_top_inst.core_top_inst.mmu_inst.ptw_stall_i)
			$display("MMU: PTW-L0 addr=%08h data=%08h vaddr=%08h",
				soc_top_inst.core_top_inst.mmu_inst.ptw_addr_o,
				soc_top_inst.core_top_inst.mmu_inst.ptw_data_i,
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr);
		// PTW FILL (permission check)
		if (soc_top_inst.core_top_inst.mmu_inst.ptw_state == 4 /* PTW_FILL */)
			$display("MMU: PTW-FILL vaddr=%08h pte=%08h perm_fault=%0b priv_fault=%0b for_insn=%0b for_store=%0b mega=%0b",
				soc_top_inst.core_top_inst.mmu_inst.ptw_vaddr,
				soc_top_inst.core_top_inst.mmu_inst.ptw_pte,
				soc_top_inst.core_top_inst.mmu_inst.ptw_perm_fault,
				soc_top_inst.core_top_inst.mmu_inst.ptw_priv_fault,
				soc_top_inst.core_top_inst.mmu_inst.ptw_for_insn,
				soc_top_inst.core_top_inst.mmu_inst.ptw_for_store,
				soc_top_inst.core_top_inst.mmu_inst.ptw_mega);
		// DTLB hit with fault
		if (soc_top_inst.core_top_inst.mmu_inst.d_translate &&
		    soc_top_inst.core_top_inst.mmu_inst.d_req_i &&
		    soc_top_inst.core_top_inst.mmu_inst.dtlb_hit &&
		    !soc_top_inst.core_top_inst.mmu_inst.d_perm_ok)
			$display("MMU: DTLB-FAULT vaddr=%08h store=%0b entry: r=%0b w=%0b x=%0b d=%0b a=%0b u=%0b",
				soc_top_inst.core_top_inst.mmu_inst.d_vaddr_i,
				soc_top_inst.core_top_inst.mmu_inst.d_store_i,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.r,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.w,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.x,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.d,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.a,
				soc_top_inst.core_top_inst.mmu_inst.dtlb_entry.u);
	end
end
`endif

`ifndef VERILATOR_SIM
	always begin
		 #10 clk = !clk;
	end
`endif

endmodule
