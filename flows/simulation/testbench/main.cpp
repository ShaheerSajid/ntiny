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

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	// Parse --timeout <cycles> and --trace from command line
	vluint64_t max_cycles = DEFAULT_MAX_CYCLES;
	bool enable_trace = false;

	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
			max_cycles = strtoull(argv[i + 1], NULL, 10);
			i++;
		} else if (strcmp(argv[i], "--trace") == 0) {
			enable_trace = true;
		}
	}

	// Create DUT instance
	Vtb_soc_top *tb = new Vtb_soc_top;

#if VM_TRACE
	// Set up VCD tracing (only if --trace is passed and built with trace support)
	VerilatedVcdC *m_trace = NULL;
	if (enable_trace) {
		Verilated::traceEverOn(true);
		m_trace = new VerilatedVcdC;
		tb->trace(m_trace, 2);
		m_trace->open("waveform.vcd");
	}
#endif

	vluint64_t sim_time = 0;
	vluint64_t half_cycles = max_cycles * 2;
	int exit_code = 2; // default: TIMEOUT

	// Simulation loop
	while (sim_time < half_cycles) {
		// Check for $finish from testbench (tohost write)
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
		if (m_trace)
			m_trace->dump(sim_time);
#endif

		sim_time++;
	}

	if (exit_code == 2)
		fprintf(stderr, "TIMEOUT after %llu cycles\n",
			(unsigned long long)max_cycles);

	tb->final();
#if VM_TRACE
	if (m_trace) {
		m_trace->dump(sim_time);
		m_trace->close();
		delete m_trace;
	}
#endif
	delete tb;

	return exit_code;
}
