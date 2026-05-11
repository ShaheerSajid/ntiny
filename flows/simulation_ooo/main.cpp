// Verilator harness for the OoO core M0 testbench.
//
// Toggles the clock until `done_o` goes high or the cycle limit
// expires. Prints the halt value + final PC + cycle count.

#include "Vtb_ooo.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    // Cycle cap — overridable via +max_cycles=N
    uint64_t max_cycles = 200000;
    for (int i = 1; i < argc; ++i) {
        if (std::strncmp(argv[i], "+max_cycles=", 12) == 0) {
            max_cycles = std::strtoull(argv[i] + 12, nullptr, 0);
        }
    }

    auto* dut = new Vtb_ooo;

    // Reset
    dut->reset = 1;
    dut->clk   = 0;
    for (int i = 0; i < 4; ++i) {
        dut->clk = !dut->clk;
        dut->eval();
    }
    dut->reset = 0;

    uint64_t cycles = 0;
    bool done = false;
    while (!Verilated::gotFinish() && cycles < max_cycles) {
        dut->clk = 1; dut->eval();
        dut->clk = 0; dut->eval();
        cycles++;
        if (dut->done_o) { done = true; break; }
    }

    std::printf("=== sim end ===\n");
    std::printf("done       : %s\n", done ? "yes" : "TIMEOUT");
    std::printf("cycles     : %llu\n", (unsigned long long)cycles);
    std::printf("final pc   : 0x%08x\n", (unsigned)dut->pc_o);
    std::printf("halt_value : 0x%08x\n", (unsigned)dut->halt_value_o);

    delete dut;
    return done ? 0 : 1;
}
