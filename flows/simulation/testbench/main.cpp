#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "Vtb_soc_top.h"
#include "verilated.h"
#include "verilated_fst_c.h"

// Default timeout: 10M cycles (20M half-cycles)
#define DEFAULT_MAX_CYCLES 10000000
#define RESET_CYCLES 10
#define TRACE_DEPTH 99

static void usage() {
	fprintf(stderr,
		"Usage: Vtb_soc_top [options] [+plusargs ...]\n"
		"  --timeout <cycles>   Max simulation cycles (default 10M)\n"
		"  --help, -h           Show this help\n"
		"\n"
		"FST waveform dumping is driven via plusargs:\n"
		"  +wave_start=<cycle>  Open FST and start dumping at this cycle\n"
		"  +wave_stop=<cycle>   Stop dumping (file finalised; sim keeps running)\n"
		"  +wave_file=<path>    Output FST path (default /tmp/wave.fst)\n"
		"\n"
		"Without +wave_start the FST machinery stays dormant (~no overhead).\n"
		"Once dumping ends the file does not grow further — bounded disk use.\n"
		"\n"
		"Other plusargs forwarded to the testbench:\n"
		"  +tracer_start_pc=<hex>  dv_tracer arm PC\n"
		"  +tracer_stop_pc=<hex>   dv_tracer disarm PC\n"
		"  +sig_file=<path>        RISCOF signature dump path\n"
		"  +sig_begin=<hex>        Signature start address\n"
		"  +sig_end=<hex>          Signature end address\n"
	);
}

// Read a +plusarg=<value> from argv. Returns true if found, value
// parsed into *out. Format-string `fmt` is one of "%llu", "%s",
// "%x" — same convention Verilator's $value$plusargs uses.
static bool read_plusarg_u64(int argc, char **argv, const char *key, uint64_t *out) {
	size_t klen = strlen(key);
	for (int i = 1; i < argc; i++) {
		if (argv[i][0] != '+') continue;
		if (strncmp(argv[i] + 1, key, klen) != 0) continue;
		if (argv[i][1 + klen] != '=') continue;
		*out = strtoull(argv[i] + 1 + klen + 1, NULL, 0);
		return true;
	}
	return false;
}

static bool read_plusarg_str(int argc, char **argv, const char *key, const char **out) {
	size_t klen = strlen(key);
	for (int i = 1; i < argc; i++) {
		if (argv[i][0] != '+') continue;
		if (strncmp(argv[i] + 1, key, klen) != 0) continue;
		if (argv[i][1 + klen] != '=') continue;
		*out = argv[i] + 1 + klen + 1;
		return true;
	}
	return false;
}

int main(int argc, char **argv) {
	Verilated::commandArgs(argc, argv);

	vluint64_t max_cycles = DEFAULT_MAX_CYCLES;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "--timeout") == 0 && i + 1 < argc) {
			max_cycles = strtoull(argv[i + 1], NULL, 10);
			i++;
		} else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
			usage();
			return 0;
		}
	}

	// FST plusargs
	uint64_t wave_start = 0;
	uint64_t wave_stop  = 0;
	const char *wave_file = "/tmp/wave.fst";
	bool wave_enabled = read_plusarg_u64(argc, argv, "wave_start", &wave_start);
	bool have_stop    = read_plusarg_u64(argc, argv, "wave_stop",  &wave_stop);
	read_plusarg_str(argc, argv, "wave_file", &wave_file);
	if (wave_enabled && !have_stop) wave_stop = UINT64_MAX;

	if (wave_enabled) {
		Verilated::traceEverOn(true);
		fprintf(stderr, "FST: armed file=%s window=[%llu, %llu]\n",
			wave_file,
			(unsigned long long)wave_start,
			(unsigned long long)wave_stop);
	}

	Vtb_soc_top *tb = new Vtb_soc_top;

	VerilatedFstC *m_trace = NULL;
	bool wave_opened = false;
	bool wave_finished = false;
	uint64_t cycle_count = 0;
	if (wave_enabled) {
		m_trace = new VerilatedFstC;
		tb->trace(m_trace, TRACE_DEPTH);
	}

	vluint64_t sim_time = 0;
	vluint64_t half_cycles = max_cycles * 2;
	int exit_code = 2; // default: TIMEOUT

	while (sim_time < half_cycles) {
		if (Verilated::gotFinish()) {
			exit_code = 0;
			break;
		}

		if (sim_time < RESET_CYCLES * 2)
			tb->reset = 1;
		else
			tb->reset = 0;

		tb->clk ^= 1;
		tb->eval();

		// Cycle-resolution book-keeping at posedge clk after reset deasserts
		if (wave_enabled && !wave_finished && tb->clk == 1 && !tb->reset) {
			cycle_count++;
			if (!wave_opened && cycle_count >= wave_start) {
				m_trace->open(wave_file);
				wave_opened = true;
				fprintf(stderr, "FST: dumpon  @cycle=%llu (file=%s)\n",
					(unsigned long long)cycle_count, wave_file);
			}
			if (wave_opened && cycle_count >= wave_stop) {
				m_trace->dump(sim_time);
				m_trace->close();
				delete m_trace;
				m_trace = NULL;
				wave_opened = false;
				wave_finished = true;
				fprintf(stderr, "FST: dumpoff @cycle=%llu\n",
					(unsigned long long)cycle_count);
			}
		}

		if (wave_opened && m_trace)
			m_trace->dump(sim_time);

		sim_time++;
	}

	if (exit_code == 2) {
		fprintf(stderr, "TIMEOUT after %llu cycles\n",
			(unsigned long long)max_cycles);
	}

	tb->final();
	if (m_trace) {
		if (wave_opened) {
			m_trace->dump(sim_time);
			m_trace->close();
		}
		delete m_trace;
	}
	delete tb;
	return exit_code;
}
