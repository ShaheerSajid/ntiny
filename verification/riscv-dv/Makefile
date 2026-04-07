SHELL := /bin/bash

NTINY_ROOT  := $(shell cd ../.. && pwd)
SIM_DIR     := $(NTINY_ROOT)/flows/simulation
SCRIPT_DIR  := $(shell pwd)
VENV        := $(HOME)/Software/python_env/bin/activate
RISCV_DV    := $(HOME)/Downloads/riscv-dv

# ── Verilator build flags ────────────────────────────────────────────────────
VERILATOR_WARNINGS = \
	-Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
	-Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
	-Wno-UNPACKED -Wno-UNSIGNED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT

VERILATOR_FLAGS = \
	$(VERILATOR_WARNINGS) \
	--no-timing --timescale-override 1ns/10ps -O3 \
	-DVERILATOR_SIM -DDV_TRACER --trace \
	-sv --top-module tb_soc_top --cc \
	+define+RAM_SIZE_BYTES=1048576

VERILATOR_INCDIRS = \
	+incdir+$(NTINY_ROOT)/design/common/ \
	+incdir+$(NTINY_ROOT)/design/uncore/i2c/src/ \
	+incdir+$(NTINY_ROOT)/design/uncore/timer/src/ \
	+incdir+$(NTINY_ROOT)/design/uncore/pwm/src/ \
	+incdir+$(NTINY_ROOT)/design/uncore/spi/src/ \
	+incdir+$(NTINY_ROOT)/design/uncore/uart/src/ \
	+incdir+$(NTINY_ROOT)/design/core/fpu/PakFPU/src/

VERILATOR_SRCS = \
	-f $(SIM_DIR)/src.args \
	$(NTINY_ROOT)/verification/dv/src/pkg.sv \
	$(NTINY_ROOT)/verification/dv/src/tracer_pkg.sv \
	$(NTINY_ROOT)/verification/dv/src/tracer.sv \
	$(SIM_DIR)/testbench/uartdpi.c \
	$(SIM_DIR)/testbench/uartdpi.sv \
	$(SIM_DIR)/testbench/tb_soc_top.v \
	--exe $(SIM_DIR)/testbench/main.cpp

# ── Targets ──────────────────────────────────────────────────────────────────

.PHONY: help
help:
	@echo "riscv-dv verification targets:"
	@echo "  make verilator        — build Verilator model (1MB RAM, DV_TRACER)"
	@echo "  make run              — run all riscv-dv tests"
	@echo "  make run TEST=<name>  — run one test (e.g. riscv_arithmetic_basic_test)"
	@echo "  make list             — list available tests"
	@echo "  make clean            — remove build artifacts and results"

# Build Verilator model with DV_TRACER + 1MB RAM for riscv-dv tests
.PHONY: verilator
verilator:
	@echo "Building Verilator model for riscv-dv (1MB RAM, DV_TRACER)..."
	cd $(SIM_DIR) && verilator $(VERILATOR_FLAGS) \
		$(VERILATOR_INCDIRS) $(VERILATOR_SRCS)
	make -j4 -C $(SIM_DIR)/obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	cp $(SIM_DIR)/obj_dir/Vtb_soc_top ./
	@echo "Model built: $(SCRIPT_DIR)/Vtb_soc_top"

# Run all tests (or one with TEST=<name>)
.PHONY: run
run:
	@if [ ! -f Vtb_soc_top ]; then \
		echo "No model found. Run 'make verilator' first."; exit 1; \
	fi
ifdef TEST
	./run_riscv_dv.sh -tn $(TEST) $(if $(SEED),--seed $(SEED))
else
	./run_riscv_dv.sh $(if $(SEED),--seed $(SEED))
endif

# List available tests
.PHONY: list
list:
	@./run_riscv_dv.sh --list

# Clean build artifacts and test results
.PHONY: clean
clean:
	rm -rf obj_dir Vtb_soc_top out
