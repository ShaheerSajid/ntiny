#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "Vtb_soc_top.h"
#include "verilated.h"
#if VM_TRACE
#include <verilated_vcd_c.h>
#endif

// Default timeout: 10M cycles (20M half-cycles)
#define DEFAULT_MAX_CYCLES 10000000
#define RESET_CYCLES 10

static void usage() {
	fprintf(stderr,
		"Usage: Vtb_soc_top [options]\n"
		"  --timeout <cycles>          Max simulation cycles (default 10M)\n"
		"  --trace                     Always-on VCD tracing (whole simulation)\n"
		"\n"
		"VCD trigger options (forward-only — no cycles before start are captured):\n"
		"  --vcd-start-cycle <N>       Open VCD at this exact cycle\n"
		"  --vcd-stop-cycle  <N>       Close VCD at this exact cycle and exit\n"
		"  --vcd-start-pc    <hex>     Open VCD when pc_id first matches this PC\n"
		"  --vcd-stop-pc     <hex>     Close VCD when pc_id first matches this PC\n"
		"  --vcd-after-cycle <N>       Ignore PC triggers BEFORE this cycle (gating)\n"
		"  --vcd-margin      <cycles>  Cycles to record after stop trigger (default 50)\n"
		"  --vcd-output      <file>    VCD output filename (default waveform.vcd)\n"
		"\n"
		"Trigger precedence: --vcd-start-cycle / --vcd-stop-cycle override the PC\n"
		"triggers. PC triggers fire on the first match AFTER --vcd-after-cycle.\n"
		"\n"
		"Example: capture the SRET deadlock window from uart.log markers\n"
		"  PC[146800640] pc=c0134c12 → PC[147849216] pc=c0003076\n"
		"  ./Vtb_soc_top --timeout 200000000 --vcd-start-cycle 146500000 \\\n"
		"                --vcd-stop-cycle 148000000 --vcd-output sret_bug.vcd\n"
		"\n"
		"Example: PC triggers gated by cycle (skip early kernel calls)\n"
		"  ./Vtb_soc_top --vcd-start-pc c0229cc4 --vcd-stop-pc c0003076 \\\n"
		"                --vcd-after-cycle 145000000 --vcd-margin 200\n"
	);
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	// Parse args
	vluint64_t max_cycles = DEFAULT_MAX_CYCLES;
	bool enable_trace_full = false;
	uint32_t vcd_start_pc = 0;
	uint32_t vcd_stop_pc  = 0;
	bool have_start_pc = false;
	bool have_stop_pc  = false;
	vluint64_t vcd_start_cycle = 0;
	vluint64_t vcd_stop_cycle_arg = 0;
	bool have_start_cycle = false;
	bool have_stop_cycle  = false;
	vluint64_t vcd_after_cycle = 0;
	vluint64_t vcd_margin = 50;
	const char *vcd_filename = "waveform.vcd";

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
			max_cycles = strtoull(argv[i + 1], NULL, 10);
			i++;
		} else if (strcmp(argv[i], "--trace") == 0) {
			enable_trace_full = true;
		} else if (strcmp(argv[i], "--vcd-start-pc") == 0 && i + 1 < argc) {
			vcd_start_pc = strtoul(argv[i + 1], NULL, 16);
			have_start_pc = true;
			i++;
		} else if (strcmp(argv[i], "--vcd-stop-pc") == 0 && i + 1 < argc) {
			vcd_stop_pc = strtoul(argv[i + 1], NULL, 16);
			have_stop_pc = true;
			i++;
		} else if (strcmp(argv[i], "--vcd-start-cycle") == 0 && i + 1 < argc) {
			vcd_start_cycle = strtoull(argv[i + 1], NULL, 10);
			have_start_cycle = true;
			i++;
		} else if (strcmp(argv[i], "--vcd-stop-cycle") == 0 && i + 1 < argc) {
			vcd_stop_cycle_arg = strtoull(argv[i + 1], NULL, 10);
			have_stop_cycle = true;
			i++;
		} else if (strcmp(argv[i], "--vcd-after-cycle") == 0 && i + 1 < argc) {
			vcd_after_cycle = strtoull(argv[i + 1], NULL, 10);
			i++;
		} else if (strcmp(argv[i], "--vcd-margin") == 0 && i + 1 < argc) {
			vcd_margin = strtoull(argv[i + 1], NULL, 10);
			i++;
		} else if (strcmp(argv[i], "--vcd-output") == 0 && i + 1 < argc) {
			vcd_filename = argv[i + 1];
			i++;
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			usage();
			return 0;
		}
	}

	// Mode selection: full trace XOR triggered trace
	bool trigger_mode = have_start_pc || have_start_cycle;
	if (trigger_mode && enable_trace_full) {
		fprintf(stderr, "ERROR: --trace and --vcd-start-* are mutually exclusive\n");
		return 1;
	}

	if (trigger_mode) {
		fprintf(stderr, "Triggered VCD:");
		if (have_start_cycle)
			fprintf(stderr, " start_cycle=%llu", (unsigned long long)vcd_start_cycle);
		if (have_start_pc)
			fprintf(stderr, " start_pc=0x%08x", vcd_start_pc);
		if (have_stop_cycle)
			fprintf(stderr, " stop_cycle=%llu", (unsigned long long)vcd_stop_cycle_arg);
		if (have_stop_pc)
			fprintf(stderr, " stop_pc=0x%08x", vcd_stop_pc);
		if (vcd_after_cycle > 0)
			fprintf(stderr, " after_cycle=%llu", (unsigned long long)vcd_after_cycle);
		fprintf(stderr, " margin=%llu output=%s\n",
			(unsigned long long)vcd_margin, vcd_filename);
	}

	// Create DUT instance
	Vtb_soc_top *tb = new Vtb_soc_top;

#if VM_TRACE
	VerilatedVcdC *m_trace = NULL;
	bool vcd_opened = false;  // tracks whether m_trace->open() was actually called

	if (enable_trace_full || trigger_mode) {
		Verilated::traceEverOn(true);
		m_trace = new VerilatedVcdC;
		tb->trace(m_trace, 99);
	}

	// Full-trace mode: open file immediately
	if (enable_trace_full && m_trace) {
		remove(vcd_filename);
		m_trace->open(vcd_filename);
		vcd_opened = true;
	}

	// Triggered mode: pre-emptively delete any stale VCD so it doesn't
	// linger if the trigger never fires
	if (trigger_mode) {
		remove(vcd_filename);
	}
#endif

	vluint64_t sim_time = 0;
	vluint64_t half_cycles = max_cycles * 2;
	int exit_code = 2; // default: TIMEOUT

	// Trigger state machine
	bool vcd_armed = trigger_mode;        // waiting for start trigger
	bool vcd_dumping = false;             // currently writing to VCD
	bool vcd_stopped = false;             // stop trigger seen, counting down margin
	vluint64_t vcd_close_cycle = 0;       // cycle at which to close & exit
	vluint64_t prev_pc = 0;
	vluint64_t cycle_count = 0;           // counts full clock cycles (not half)

	// Simulation loop
	while (sim_time < half_cycles) {
		if (Verilated::gotFinish()) {
			exit_code = 0;
			break;
		}

		// Reset for first N cycles
		if (sim_time < RESET_CYCLES * 2)
			tb->reset = 1;
		else
			tb->reset = 0;

		tb->clk ^= 1;
		tb->eval();

#if VM_TRACE
		// Sample once per cycle at posedge clk
		if (trigger_mode && tb->clk == 1 && !tb->reset) {
			uint32_t pc_now = (uint32_t)tb->pc_id_o;
			cycle_count++;

			// ── Start trigger ──────────────────────────────────────────
			// Cycle-based start: open at exact cycle (overrides PC trigger)
			if (vcd_armed && have_start_cycle && cycle_count >= vcd_start_cycle) {
				fprintf(stderr,
					"[VCD] start at cycle %llu (cycle trigger) — opening %s\n",
					(unsigned long long)cycle_count, vcd_filename);
				m_trace->open(vcd_filename);
				vcd_opened = true;
				vcd_dumping = true;
				vcd_armed = false;
			}
			// PC-based start: gated by --vcd-after-cycle
			else if (vcd_armed && have_start_pc &&
			         cycle_count >= vcd_after_cycle &&
			         pc_now == vcd_start_pc && pc_now != prev_pc) {
				fprintf(stderr,
					"[VCD] start at cycle %llu, pc=0x%08x (pc trigger) — opening %s\n",
					(unsigned long long)cycle_count, pc_now, vcd_filename);
				m_trace->open(vcd_filename);
				vcd_opened = true;
				vcd_dumping = true;
				vcd_armed = false;
			}

			// ── Stop trigger (only after dumping started) ─────────────
			if (vcd_dumping && !vcd_stopped) {
				bool stop_now = false;
				const char *reason = "";
				if (have_stop_cycle && cycle_count >= vcd_stop_cycle_arg) {
					stop_now = true;
					reason = "cycle";
				} else if (have_stop_pc && pc_now == vcd_stop_pc && pc_now != prev_pc) {
					stop_now = true;
					reason = "pc";
				}
				if (stop_now) {
					vcd_close_cycle = cycle_count + vcd_margin;
					vcd_stopped = true;
					fprintf(stderr,
						"[VCD] stop at cycle %llu, pc=0x%08x (%s trigger) — "
						"will close at cycle %llu (+%llu margin)\n",
						(unsigned long long)cycle_count, pc_now, reason,
						(unsigned long long)vcd_close_cycle,
						(unsigned long long)vcd_margin);
				}
			}

			// Reached the post-stop margin: close VCD and exit
			if (vcd_stopped && cycle_count >= vcd_close_cycle) {
				fprintf(stderr,
					"[VCD] closing at cycle %llu — VCD saved to %s\n",
					(unsigned long long)cycle_count, vcd_filename);
				m_trace->dump(sim_time);
				m_trace->close();
				vcd_opened = false;
				delete m_trace;
				m_trace = NULL;
				exit_code = 0;
				goto cleanup;
			}

			prev_pc = pc_now;
		}

		if (m_trace && (enable_trace_full || vcd_dumping))
			m_trace->dump(sim_time);
#endif

		sim_time++;
	}

	if (exit_code == 2) {
		fprintf(stderr, "TIMEOUT after %llu cycles\n",
			(unsigned long long)max_cycles);
#if VM_TRACE
		if (trigger_mode && !vcd_opened) {
			fprintf(stderr,
				"[VCD] start trigger NEVER fired — no VCD written\n");
		} else if (trigger_mode && vcd_opened && !vcd_stopped) {
			fprintf(stderr,
				"[VCD] start trigger fired but stop trigger NEVER fired — "
				"VCD contains all cycles from start\n");
		}
#endif
	}

cleanup:
	tb->final();
#if VM_TRACE
	if (m_trace) {
		// Only flush + close if the file was actually opened
		if (vcd_opened) {
			m_trace->dump(sim_time);
			m_trace->close();
		}
		delete m_trace;
	}
#endif
	delete tb;

	return exit_code;
}
