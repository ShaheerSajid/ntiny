SHELL := /bin/bash

# Path to the unified memory map JSON
MEM_MAP_JSON = ../../design/common/mem_map.json

# Extract RISCOF profile RAM size from JSON (decimal for +define+)
RISCOF_RAM_SIZE := $(shell python3 -c "import json; d=json.load(open('$(MEM_MAP_JSON)')); print(int(d['profiles']['riscof']['RAM_SIZE_BYTES'],16))")

# --- Memory map generation ---
.PHONY: gen_mem_map
gen_mem_map:
	python3 ../../scripts/gen_mem_map.py

.PHONY: check_mem_map
check_mem_map:
	python3 ../../scripts/gen_mem_map.py --check

# --- Common Verilator flags ---
VERILATOR_WARNINGS = \
	-Wno-UNOPTFLAT \
	-Wno-INITIALDLY \
	-Wno-UNUSED \
	-Wno-WIDTH \
	-Wno-CASEINCOMPLETE \
	-Wno-PINMISSING \
	-Wno-MULTIDRIVEN \
	-Wno-STMTDLY \
	-Wno-UNPACKED \
	-Wno-UNSIGNED \
	-Wno-LITENDIAN \
	-Wno-MODDUP \
	-Wno-MISINDENT

VERILATOR_COMMON = \
	$(VERILATOR_WARNINGS) \
	--no-timing \
	--timescale-override 1ns/10ps \
	-O3 \
	-DVERILATOR_SIM \
	--trace \
	-sv --top-module tb_soc_top \
	--cc

VERILATOR_INCDIRS = \
	+incdir+../../design/common/ \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	+incdir+../../design/core/fpu/PakFPU/src/

VERILATOR_SRCS = \
	-f src.args \
	../../verification/dv/src/pkg.sv \
	../../verification/dv/src/tracer_pkg.sv \
	../../verification/dv/src/tracer.sv \
	testbench/uartdpi.c \
	testbench/uartdpi.sv \
	testbench/tb_soc_top.v \
	--exe testbench/main.cpp

VERILATOR_RISCOF_DEFINES = \
	+define+RAM_SIZE_BYTES=$(RISCOF_RAM_SIZE)

# --- Init ---
mem_init:
	python3 ../../software/tools/hex_text.py ../../software/build/baremetal.bin ram.hex

# --- Questa targets ---
questa_sim:
	if [ -d "work" ]; then  vdel -lib work -all; fi
	vlib work
	vlog -sv -work work ../../verification/dv/src/pkg.sv
	vlog -sv -work work ../../verification/dv/src/tracer_pkg.sv
	vlog -sv -work work ../../verification/dv/src/tracer.sv
	vlog -sv -work work \
	+define+BOOT \
	+incdir+../../design/common/ \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	-f src.args
	vlog -sv -work work -dpiheader testbench/dpiheader.h testbench/SimJTAG.v
	vlog -sv -work work -dpiheader testbench/dpiheader.h testbench/uartdpi.sv
	vlog -64 -ccflags "-I./" testbench/remote_bitbang.cc
	vlog -64 -ccflags "-I./" testbench/SimJTAG.cc
	vlog -64 -ccflags "-I./" testbench/uartdpi.c
	vlog -sv -work work testbench/arm_boot_dummy.v
	vlog -sv -work work testbench/arm_imem_dummy.v
	vlog -sv -work work testbench/arm_dmem_dummy.v
	vlog -sv -work work testbench/mem.v
	if [ $# -eq 0 ]; then vlog -sv -work work testbench/tb_soc_top.v; else vlog -sv -work work +define+$(DPI) testbench/tb_soc_top.v; fi
	vsim -c -t 1ps -L work -voptargs="+acc" tb_soc_top  -do "run -all; exit"

# --- Incisive targets ---
incisive_sim:
	irun \
	-batch \
	-s \
	-sv \
	+linedebug \
	+access+rwc \
	+incdir+../../design/common/ \
	+incdir+../../design/uncore/i2c/src/ \
	+incdir+../../design/uncore/timer/src/ \
	+incdir+../../design/uncore/pwm/src/ \
	+incdir+../../design/uncore/spi/src/ \
	+incdir+../../design/uncore/uart/src/ \
	+define+BOOT \
	-f src.args \
	testbench/arm_boot_dummy.v \
	testbench/arm_imem_dummy.v \
	testbench/arm_dmem_dummy.v \
	testbench/mem.v \
	testbench/tb_soc_top.v \
	-q \
	-timescale 1ns/10ps \
	-top tb_soc_top \
	-input "@run; exit"

incisive_sim_gate:
	irun \
	-gui \
	-s \
	+linedebug \
	+access+rwc \
    ../synthesis/genus/work/output/top_m.v \
	../65GP_TT/verilog/tcbn65gplus.v \
	../65GP_TT/verilog/tphn65gpgv2od3_sl.v \
	testbench/arm_boot_dummy.v \
	testbench/arm_imem_dummy.v \
	testbench/arm_dmem_dummy.v \
	testbench/tb_soc_top_gate.v \
	-q \
	-timescale 1ns/10ps \
	-top tb_top

# --- Verilator targets ---

# Build the Verilator model (no simulation)
verilator_build:
	verilator $(VERILATOR_COMMON) \
	-DDV_TRACER \
	$(VERILATOR_INCDIRS) \
	$(VERILATOR_SRCS)
	make -j4 -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	mv obj_dir/Vtb_soc_top ./

# Build without DV_TRACER for bench (dhrystone/coremark) — avoids the
# multi-GB trace log that slows down long-running benchmarks. Uses 64KB
# RAM to match link_bench.ld (default 32KB is too small for Dhrystone
# which places the stack at 0x80010000).
verilator_build_bench:
	verilator $(VERILATOR_COMMON) \
	+define+RAM_SIZE_BYTES=65536 \
	$(VERILATOR_INCDIRS) \
	$(VERILATOR_SRCS)
	make -j4 -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	mv obj_dir/Vtb_soc_top ./

# Run simulation (no waveform by default)
verilator_run:
	./Vtb_soc_top

# Run simulation with VCD waveform tracing
verilator_run_trace:
	./Vtb_soc_top --trace

# Open waveform viewer (after verilator_run_trace)
verilator_wave:
	gtkwave --dump waveform.vcd

# --- Convenience compound targets ---

.PHONY: questa
questa: clean mem_init questa_sim

.PHONY: incisive
incisive: clean mem_init incisive_sim

.PHONY: incisive_gate
incisive_gate: clean mem_init incisive_sim_gate

# Build and run (no trace, fast)
.PHONY: verilator
verilator: clean mem_init verilator_build verilator_run

# Build and run with waveform
.PHONY: verilator_trace
verilator_trace: clean mem_init verilator_build verilator_run_trace

# Regression test target — returns exit code for CI
.PHONY: verilator_test
verilator_test: clean mem_init verilator_build
	@echo "--- Running Verilator regression test ---"
	@./Vtb_soc_top --timeout 5000000; \
	EXIT_CODE=$$?; \
	if [ $$EXIT_CODE -eq 0 ]; then \
		echo "RESULT: PASS"; \
	elif [ $$EXIT_CODE -eq 2 ]; then \
		echo "RESULT: TIMEOUT"; \
	else \
		echo "RESULT: FAIL (exit code $$EXIT_CODE)"; \
	fi; \
	exit $$EXIT_CODE

# --- Verification (RISCOF / riscv-dv) ---
# These have moved to their own Makefiles:
#   RISCOF:   make -C ../../verification/riscof run
#   riscv-dv: make -C ../../verification/riscv-dv run
#
# Legacy aliases (forward to new locations):
.PHONY: riscof_run riscof_fpu_run riscof_summary
riscof_run:
	$(MAKE) -C ../../verification/riscof run
riscof_fpu_run:
	$(MAKE) -C ../../verification/riscof run_fpu
riscof_summary:
	$(MAKE) -C ../../verification/riscof summary

.PHONY: clean
clean:
	rm -f *.key *.log *.history transcript *.wlf *.text *.X *.svcf *.vcd
	if [ -d "work" ]; then rm -r work; fi
	if [ -d "obj_dir" ]; then rm -r obj_dir; fi
	if [ -f "Vtb_soc_top" ]; then rm Vtb_soc_top; fi
	if [ -d "INCA_libs" ]; then rm -r INCA_libs; fi
	if [ -d "waves.shm" ]; then rm -r waves.shm; fi
	if [ -d ".simvision" ]; then rm -r .simvision; fi
