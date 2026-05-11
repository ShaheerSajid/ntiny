SHELL := /bin/bash

# ── tools ─────────────────────────────────────────────────────
VERILATOR ?= verilator
RV_PREFIX ?= /opt/riscv-linux/bin/riscv32-unknown-linux-gnu
RV_AS     := $(RV_PREFIX)-as
RV_LD     := $(RV_PREFIX)-ld
RV_OBJCOPY:= $(RV_PREFIX)-objcopy
RV_OBJDUMP:= $(RV_PREFIX)-objdump
HEX_TEXT  := ../../software/tools/hex_text.py

# ── target test (overridable: make TEST=foo) ──────────────────
TEST ?= test_basic

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
    ../../design/core_ooo/src/core_ooo_top.sv \
    tb_ooo.sv

# ── targets ───────────────────────────────────────────────────
.PHONY: all build sw run clean

all: run

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
	$(RV_AS) -march=rv32i -mabi=ilp32 -o sw/$(TEST).o $<
	$(RV_LD) -T sw/link.ld -o $@ sw/$(TEST).o
	$(RV_OBJDUMP) -d $@ > sw/$(TEST).dis

run: build sw
	./obj_dir/Vtb_ooo

clean:
	rm -rf obj_dir ram.hex sw/*.o sw/*.elf sw/*.bin sw/*.dis
