#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>  // for strtol

#include "Vtb_soc_top.h"
#include "verilated.h"
#include <verilated_vcd_c.h>

#define MAX_SIM_TIME 100000
#define RESET_TIME 10
vluint64_t sim_time = 0;

int main(int argc, char **argv) {
		
	
	// Initialize Verilators variables
	Verilated::commandArgs(argc, argv);

  Verilated::traceEverOn(true);
	// Create an instance of our module under test
	Vtb_soc_top *tb = new Vtb_soc_top;
  VerilatedVcdC *m_trace = new VerilatedVcdC;
  tb->trace(m_trace, 2);
  m_trace->open("waveform.vcd");
	// Tick the clock until we are done

	while(!Verilated::gotFinish()) {
    if(sim_time < RESET_TIME)
      tb->reset = 1;
    else
      tb->reset = 0;
		
    tb->clk ^= 1;
    tb->eval();
    m_trace->dump(sim_time);
    sim_time++;
	
	} 
  tb->final();
  m_trace->dump(sim_time);

  m_trace->close();
  delete tb;
  delete m_trace;
  exit(EXIT_SUCCESS);
} 
