SHELL := /bin/bash

# ── tools ─────────────────────────────────────────────────────
VERILATOR ?= verilator
# Multilib bare-metal elf toolchain — assembles rv32i / rv32im / ilp32.
RV_PREFIX ?= /opt/riscv-elf/bin/riscv64-unknown-elf
RV_AS     := $(RV_PREFIX)-as
RV_LD     := $(RV_PREFIX)-ld
RV_OBJCOPY:= $(RV_PREFIX)-objcopy
RV_OBJDUMP:= $(RV_PREFIX)-objdump
HEX_TEXT  := ../../software/tools/hex_text.py

# ── target test (overridable: make TEST=foo) ──────────────────
TEST ?= test_basic

# ── march for the assembler ───────────────────────────────────
# rv32im is a strict superset of rv32i; the existing tests don't
# use M-ext mnemonics, so it's safe as the default. Per-test
# override: `make MARCH=rv32i ...`.
MARCH ?= rv32im_zicsr_zba_zbb_zbc_zbs_zicond

# ── verilator config ──────────────────────────────────────────
VLT_WARN = \
    -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH -Wno-PINMISSING \
    -Wno-MULTIDRIVEN -Wno-STMTDLY -Wno-UNPACKED -Wno-UNSIGNED \
    -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT

VLT_FLAGS = \
    $(VLT_WARN) \
    --no-timing --timescale-override 1ns/10ps \
    -O3 -DVERILATOR_SIM \
    -sv --top-module tb_ooo --cc

VLT_INCDIRS = +incdir+../../design/common/

# Just the modules the OoO core actually needs.
RTL_SRCS = \
    ../../design/common/common_pkg.sv \
    ../../design/core/include/core_pkg.sv \
    ../../design/buses/src/buses.sv \
    ../../design/core_ooo/include/core_ooo_pkg.sv \
    ../../design/core/regfile/src/reg_file.sv \
    ../../design/core/alu/src/divider.sv \
    ../../design/core/alu/src/zba_zbb.sv \
    ../../design/core/alu/src/zbs.sv \
    ../../design/core/alu/src/clmul.sv \
    ../../design/core/alu/src/alu.sv \
    ../../design/core_ooo/src/fetch.sv \
    ../../design/core_ooo/src/decode.sv \
    ../../design/core_ooo/src/execute.sv \
    ../../design/core_ooo/src/memunit.sv \
    ../../design/core_ooo/src/muldiv_unit.sv \
    ../../design/core_ooo/src/bpu_ooo.sv \
    ../../design/core_ooo/src/lsq.sv \
    ../../design/core_ooo/src/csr_unit.sv \
    ../../design/core_ooo/src/rat.sv \
    ../../design/core_ooo/src/rs.sv \
    ../../design/core_ooo/src/rob.sv \
    ../../design/core_ooo/src/core_ooo_top.sv \
    tb_ooo.sv

# ── test battery (M0 sanity + M2 OoO/M-ext + M3 recovery) ─────
TESTS = test_basic test_loop test_jalr test_subword test_imm_edges test_dep_chain test_ooo_stress test_muldiv test_misp_recovery test_bext test_csr

# ── targets ───────────────────────────────────────────────────
.PHONY: all build sw run test-all clean

all: run

test-all: build
	@pass=0; fail=0; \
	for t in $(TESTS); do \
	    printf '%-20s ' "$$t"; \
	    rm -f ram.hex; \
	    $(MAKE) -s sw TEST=$$t >/dev/null 2>&1 || { echo "BUILD FAIL"; fail=$$((fail+1)); continue; }; \
	    out=$$(./obj_dir/Vtb_ooo 2>&1); \
	    val=$$(echo "$$out" | awk -F'0x' '/halt_value/ {print $$2}'); \
	    cyc=$$(echo "$$out" | awk '/cycles/ {print $$3}'); \
	    if [ "$$val" = "deadbeef" ]; then \
	        printf 'PASS  (cycles=%s)\n' "$$cyc"; pass=$$((pass+1)); \
	    else \
	        printf 'FAIL  (halt=0x%s)\n' "$$val"; fail=$$((fail+1)); \
	    fi; \
	done; \
	echo "── $$pass passed, $$fail failed ──"; \
	[ "$$fail" = "0" ]

build: obj_dir/Vtb_ooo

obj_dir/Vtb_ooo: $(RTL_SRCS) main.cpp
	$(VERILATOR) $(VLT_FLAGS) $(VLT_INCDIRS) $(RTL_SRCS) --exe main.cpp
	$(MAKE) -j4 -C obj_dir -f Vtb_ooo.mk Vtb_ooo

sw: ram.hex

ram.hex: sw/$(TEST).bin
	python3 $(HEX_TEXT) $< $@

sw/$(TEST).bin: sw/$(TEST).elf
	$(RV_OBJCOPY) -O binary $< $@

sw/$(TEST).elf: sw/$(TEST).s sw/link.ld
	$(RV_AS) -march=$(MARCH) -mabi=ilp32 -o sw/$(TEST).o $<
	$(RV_LD) -T sw/link.ld -o $@ sw/$(TEST).o
	$(RV_OBJDUMP) -d $@ > sw/$(TEST).dis

run: build sw
	./obj_dir/Vtb_ooo

clean:
	rm -rf obj_dir ram.hex sw/*.o sw/*.elf sw/*.bin sw/*.dis
