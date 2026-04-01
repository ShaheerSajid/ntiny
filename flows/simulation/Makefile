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
	-Wno-MODDUP

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
	+define+RAM_SIZE_BYTES=$(RISCOF_RAM_SIZE) \
	+define+DV_DIAG_TRACE

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
	make -j -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
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

# --- RISCOF targets ---
RISCOF_DIR = ../../verification/riscof
RISCOF_SUITE = $(RISCOF_DIR)/riscv-arch-test/riscv-test-suite/
RISCOF_ENV = $(RISCOF_DIR)/riscv-arch-test/riscv-test-suite/env
RISCOF_VENV = $(HOME)/Software/riscof_env/bin/activate
RISCOF_WORK = riscof_work

# Build Verilator model for RISCOF (4MB RAM, no DV_TRACER)
verilator_build_riscof:
	verilator $(VERILATOR_COMMON) \
	$(VERILATOR_RISCOF_DEFINES) \
	$(VERILATOR_INCDIRS) \
	$(VERILATOR_SRCS)
	make -j -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	cp obj_dir/Vtb_soc_top ./

.PHONY: riscof
riscof: clean verilator_build_riscof
	@echo "--- Running RISCOF compliance tests ---"
	cd $(RISCOF_DIR) && source $(RISCOF_VENV) && \
	riscof run --config=config.ini \
		--suite=$(realpath $(RISCOF_SUITE)) \
		--env=$(realpath $(RISCOF_ENV))

# Build Verilator model for RISCOF with FPU enabled
verilator_build_riscof_fpu:
	verilator $(VERILATOR_COMMON) \
	-DFPU \
	$(VERILATOR_RISCOF_DEFINES) \
	$(VERILATOR_INCDIRS) \
	$(VERILATOR_SRCS)
	make -j -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	cp obj_dir/Vtb_soc_top ./

.PHONY: riscof_fpu
riscof_fpu: clean verilator_build_riscof_fpu
	@echo "--- Running RISCOF F-extension compliance tests ---"
	cd $(RISCOF_DIR) && source $(RISCOF_VENV) && \
	riscof run --config=config_fpu.ini \
		--suite=$(realpath $(RISCOF_SUITE)) \
		--env=$(realpath $(RISCOF_ENV))

# Print a pass/fail summary by comparing DUT signatures against Spike references.
# Run after 'make riscof' (or standalone if riscof_work already exists).
.PHONY: riscof_summary
riscof_summary:
	@echo ""; \
	echo "========================================"; \
	echo " RISCOF Signature Comparison Summary"; \
	echo "========================================"; \
	pass=0; fail=0; missing=0; \
	for ref in $$(find $(RISCOF_WORK) -name "Reference-spike.signature" 2>/dev/null | sort); do \
		testdir=$$(dirname "$$ref"); \
		suite=$$(echo "$$testdir" | sed 's|.*/riscof_work/||' | sed 's|/ref$$||' | sed 's|/src/||' | tr '/' ' '); \
		testname=$$(basename $$(dirname "$$testdir")); \
		dutsig="$$(dirname "$$testdir")/dut/DUT-ntiny.signature"; \
		if [ ! -f "$$dutsig" ]; then \
			printf "  %-55s  MISSING\n" "$$testname"; \
			missing=$$((missing+1)); \
		elif diff -q "$$dutsig" "$$ref" > /dev/null 2>&1; then \
			printf "  %-55s  PASS\n" "$$testname"; \
			pass=$$((pass+1)); \
		else \
			ndiff=$$(diff "$$dutsig" "$$ref" | grep -c '^[<>]' || true); \
			printf "  %-55s  FAIL  ($$ndiff differing lines)\n" "$$testname"; \
			fail=$$((fail+1)); \
		fi; \
	done; \
	echo "========================================"; \
	echo "  PASS: $$pass   FAIL: $$fail   MISSING: $$missing   TOTAL: $$((pass+fail+missing))"; \
	echo "========================================"

# Full run + summary in one command
.PHONY: riscof_run
riscof_run: clean verilator_build_riscof
	@echo "--- Running RISCOF compliance tests ---"
	cd $(RISCOF_DIR) && source $(RISCOF_VENV) && \
	riscof run --config=config.ini \
		--suite=$(realpath $(RISCOF_SUITE)) \
		--env=$(realpath $(RISCOF_ENV)) \
		--work-dir=$(realpath .)/$(RISCOF_WORK) || true
	@$(MAKE) riscof_summary

.PHONY: riscof_testlist
riscof_testlist:
	cd $(RISCOF_DIR) && source $(RISCOF_VENV) && \
	riscof testlist --config=config.ini \
		--suite=$(realpath $(RISCOF_SUITE)) \
		--env=$(realpath $(RISCOF_ENV))

.PHONY: clean
clean:
	rm -f *.key *.log *.history transcript *.wlf *.text *.X *.svcf *.vcd
	if [ -d "work" ]; then rm -r work; fi
	if [ -d "obj_dir" ]; then rm -r obj_dir; fi
	if [ -f "Vtb_soc_top" ]; then rm Vtb_soc_top; fi
	if [ -d "INCA_libs" ]; then rm -r INCA_libs; fi
	if [ -d "waves.shm" ]; then rm -r waves.shm; fi
	if [ -d ".simvision" ]; then rm -r .simvision; fi
