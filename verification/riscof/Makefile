SHELL := /bin/bash

NTINY_ROOT  := $(shell cd ../.. && pwd)
include $(NTINY_ROOT)/.env

SIM_DIR     := $(NTINY_ROOT)/flows/simulation
MEM_MAP_JSON := $(NTINY_ROOT)/design/common/mem_map.json
VENV        := $(RISCOF_VENV)
SUITE       := $(shell pwd)/riscv-arch-test/riscv-test-suite
ENV         := $(SUITE)/env
WORK        := $(shell pwd)/riscof_work

# RAM size from memory map JSON (decimal for +define+)
RAM_SIZE := $(shell python3 -c "import json; d=json.load(open('$(MEM_MAP_JSON)')); print(int(d['profiles']['riscof']['RAM_SIZE_BYTES'],16))")

# ── Verilator build flags ────────────────────────────────────────────────────
VERILATOR_WARNINGS = \
	-Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
	-Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
	-Wno-UNPACKED -Wno-UNSIGNED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT

VERILATOR_FLAGS = \
	$(VERILATOR_WARNINGS) \
	--no-timing --timescale-override 1ns/10ps -O3 \
	-DVERILATOR_SIM \
	-sv --top-module tb_soc_top --cc \
	+define+RAM_SIZE_BYTES=$(RAM_SIZE)

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
	@echo "RISCOF verification targets:"
	@echo "  make verilator           — build Verilator model for RISCOF"
	@echo "  make verilator_fpu       — build with FPU enabled"
	@echo "  make run                 — run RISCOF compliance suite"
	@echo "  make run_fpu             — run F-extension compliance suite"
	@echo "  make summary             — print pass/fail summary"
	@echo "  make clean               — remove build artifacts and results"

# Build Verilator model for RISCOF
.PHONY: verilator
verilator:
	@echo "Building Verilator model for RISCOF (RAM=$(RAM_SIZE))..."
	cd $(SIM_DIR) && rm -rf obj_dir && verilator $(VERILATOR_FLAGS) \
		$(VERILATOR_INCDIRS) $(VERILATOR_SRCS)
	make -j4 -C $(SIM_DIR)/obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	cp $(SIM_DIR)/obj_dir/Vtb_soc_top $(SIM_DIR)/Vtb_soc_top
	@echo "Model built: $(SIM_DIR)/Vtb_soc_top"

# Build with FPU
.PHONY: verilator_fpu
verilator_fpu:
	@echo "Building Verilator model for RISCOF+FPU..."
	cd $(SIM_DIR) && rm -rf obj_dir && verilator $(VERILATOR_FLAGS) \
		-DFPU $(VERILATOR_INCDIRS) $(VERILATOR_SRCS)
	make -j4 -C $(SIM_DIR)/obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top
	cp $(SIM_DIR)/obj_dir/Vtb_soc_top $(SIM_DIR)/Vtb_soc_top
	@echo "Model built: $(SIM_DIR)/Vtb_soc_top"

# Run RISCOF compliance tests
.PHONY: run
run: verilator
	@echo "Running RISCOF compliance tests..."
	source $(VENV) && riscof run \
		--config=config.ini \
		--suite=$(SUITE) \
		--env=$(ENV) \
		--work-dir=$(WORK) || true
	@$(MAKE) summary

# Generate ONLY the spike reference signatures, skipping the DUT-side
# simulation. Useful when the DUT is being debugged and may hang —
# without this, a hung DUT prevents spike from generating its refs,
# which makes individual smoke tests impossible (no reference to
# compare against). Run this once after a `clean`, then iterate on
# the DUT with the smoke test helper at /tmp/smoke_test.sh.
#
# Uses riscof's `--no-dut-run` flag (which still requires the ntiny
# plugin to be loadable, but does not actually run Vtb_soc_top).
.PHONY: gen_refs
gen_refs:
	@echo "Generating spike reference signatures (no DUT run)..."
	source $(VENV) && riscof run \
		--config=config.ini \
		--suite=$(SUITE) \
		--env=$(ENV) \
		--work-dir=$(WORK) \
		--no-dut-run || true
	@echo "Spike reference signatures generated. Use smoke tests now."

# Run F-extension tests
.PHONY: run_fpu
run_fpu: verilator_fpu
	@echo "Running RISCOF F-extension compliance tests..."
	source $(VENV) && riscof run \
		--config=config_fpu.ini \
		--suite=$(SUITE) \
		--env=$(ENV) \
		--work-dir=$(WORK) || true
	@$(MAKE) summary

# Print pass/fail summary
.PHONY: summary
summary:
	@echo ""; \
	echo "========================================"; \
	echo " RISCOF Signature Comparison Summary"; \
	echo "========================================"; \
	pass=0; fail=0; missing=0; \
	for ref in $$(find $(WORK) -name "Reference-spike.signature" 2>/dev/null | sort); do \
		testdir=$$(dirname "$$ref"); \
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

# List available test suites
.PHONY: testlist
testlist:
	source $(VENV) && riscof testlist \
		--config=config.ini \
		--suite=$(SUITE) \
		--env=$(ENV)

# Clean
.PHONY: clean
clean:
	rm -rf $(WORK)
	cd $(SIM_DIR) && rm -rf obj_dir Vtb_soc_top
