SHELL := /bin/bash

NTINY_ROOT  := $(shell cd ../.. && pwd)
SIM_DIR     := $(NTINY_ROOT)/flows/simulation_ooo
VENV        := $(HOME)/Software/riscof_env/bin/activate
SUITE       := $(NTINY_ROOT)/verification/riscof/riscv-arch-test/riscv-test-suite
ENV         := $(SUITE)/env
WORK        := $(shell pwd)/riscof_work

# RAM size for the tb_ooo's mem array. 4 MB covers all rv32i_m/I + M
# tests with margin (the in-order flow uses 32 MB to fit vm_sv32 page
# tables; the OoO core has no MMU so we don't need that).
RAM_WORDS := 1048576

VLT_WARN = \
    -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH -Wno-PINMISSING \
    -Wno-MULTIDRIVEN -Wno-STMTDLY -Wno-UNPACKED -Wno-UNSIGNED \
    -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT

VLT_FLAGS = \
    $(VLT_WARN) \
    --no-timing --timescale-override 1ns/10ps \
    -O3 -DVERILATOR_SIM \
    -sv --top-module tb_ooo --cc \
    +define+RAM_WORDS=$(RAM_WORDS)

VLT_INCDIRS = +incdir+$(NTINY_ROOT)/design/common/

RTL_SRCS = \
    $(NTINY_ROOT)/design/common/common_pkg.sv \
    $(NTINY_ROOT)/design/core/include/core_pkg.sv \
    $(NTINY_ROOT)/design/buses/src/buses.sv \
    $(NTINY_ROOT)/design/core_ooo/include/core_ooo_pkg.sv \
    $(NTINY_ROOT)/design/core/regfile/src/reg_file.sv \
    $(NTINY_ROOT)/design/core/alu/src/divider.sv \
    $(NTINY_ROOT)/design/core/alu/src/zba_zbb.sv \
    $(NTINY_ROOT)/design/core/alu/src/zbs.sv \
    $(NTINY_ROOT)/design/core/alu/src/clmul.sv \
    $(NTINY_ROOT)/design/core/alu/src/alu.sv \
    $(NTINY_ROOT)/design/core_ooo/src/fetch.sv \
    $(NTINY_ROOT)/design/core_ooo/src/decode.sv \
    $(NTINY_ROOT)/design/core_ooo/src/execute.sv \
    $(NTINY_ROOT)/design/core_ooo/src/memunit.sv \
    $(NTINY_ROOT)/design/core_ooo/src/muldiv_unit.sv \
    $(NTINY_ROOT)/design/core_ooo/src/rat.sv \
    $(NTINY_ROOT)/design/core_ooo/src/rs.sv \
    $(NTINY_ROOT)/design/core_ooo/src/rob.sv \
    $(NTINY_ROOT)/design/core_ooo/src/core_ooo_top.sv \
    $(SIM_DIR)/tb_ooo.sv

.PHONY: help
help:
	@echo "OoO RISCOF verification:"
	@echo "  make verilator      — build Vtb_ooo with RAM_WORDS=$(RAM_WORDS)"
	@echo "  make run            — run RISCOF compliance suite"
	@echo "  make gen_refs       — spike reference signatures only (no DUT run)"
	@echo "  make summary        — print pass/fail summary"
	@echo "  make smoke          — run a single I-test as a flow check"
	@echo "  make clean          — remove build artifacts and results"
	@echo ""
	@echo "Filter tests with RISCOF_SKIP=substr1,substr2 ..."
	@echo "Default skip recommended for OoO at M3-A:"
	@echo "  RISCOF_SKIP=privilege,pmp"
	@echo "(privilege+pmp need CSR+trap+PMP — out of scope until M7.)"

.PHONY: verilator
verilator:
	@echo "Building Vtb_ooo for RISCOF (RAM_WORDS=$(RAM_WORDS))..."
	cd $(SIM_DIR) && rm -rf obj_dir && \
		verilator $(VLT_FLAGS) $(VLT_INCDIRS) $(RTL_SRCS) \
			--exe $(SIM_DIR)/main.cpp
	$(MAKE) -j4 -C $(SIM_DIR)/obj_dir/ -f Vtb_ooo.mk Vtb_ooo
	@echo "Model: $(SIM_DIR)/obj_dir/Vtb_ooo"

.PHONY: run
run: verilator
	@echo "Running RISCOF (OoO DUT)..."
	source $(VENV) && riscof run \
		--config=config.ini \
		--suite=$(SUITE) \
		--env=$(ENV) \
		--work-dir=$(WORK) || true
	@$(MAKE) summary

.PHONY: gen_refs
gen_refs:
	@echo "Generating spike reference signatures (no DUT run)..."
	source $(VENV) && riscof run \
		--config=config.ini \
		--suite=$(SUITE) \
		--env=$(ENV) \
		--work-dir=$(WORK) \
		--no-dut-run || true

.PHONY: summary
summary:
	@echo ""; \
	echo "========================================"; \
	echo " OoO RISCOF Signature Comparison Summary"; \
	echo "========================================"; \
	pass=0; fail=0; missing=0; \
	for ref in $$(find $(WORK) -name "Reference-spike.signature" 2>/dev/null | sort); do \
		testdir=$$(dirname "$$ref"); \
		testname=$$(basename $$(dirname "$$testdir")); \
		dutsig="$$(dirname "$$testdir")/dut/DUT-ntiny_ooo.signature"; \
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

# Build the DUT then run a single I-test to validate the flow.
.PHONY: smoke
smoke: verilator
	@echo "OoO RISCOF smoke (rv32i_m/I/src/add-01) ..."
	source $(VENV) && riscof run \
		--config=config.ini \
		--suite=$(SUITE)/rv32i_m/I/src \
		--env=$(ENV) \
		--work-dir=$(WORK)_smoke || true

.PHONY: clean
clean:
	rm -rf $(WORK) $(WORK)_smoke
