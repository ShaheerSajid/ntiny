# ntiny Linux build automation
#
#   make prepare   one-time: clone Linux + OpenSBI, apply ntiny patches,
#                  copy DTS into the kernel tree
#   make build     rebuild kernel + opensbi + ram.hex
#   make run       launch the verilator sim and stream uart.log
#   make clean     wipe build artifacts in this directory
#   make distclean also wipe Linux/OpenSBI build outputs
#
# Override paths via environment:
#   make LINUX_DIR=/path/to/linux OPENSBI_DIR=/path/to/opensbi prepare
#
# Toolchain: expects riscv32-unknown-linux-gnu-* in PATH or at
# /opt/riscv-linux/bin (the default location).

NTINY      := $(abspath $(CURDIR)/../..)
LINUX_DIR  ?= $(HOME)/Downloads/linux
OPENSBI_DIR?= $(HOME)/Downloads/opensbi
SIM_DIR    := $(NTINY)/flows/simulation
TOOLCHAIN_BIN ?= /opt/riscv-linux/bin

LINUX_TAG  ?= v6.6
OPENSBI_TAG?= v1.8

CROSS_COMPILE := riscv32-unknown-linux-gnu-
ARCH          := riscv
ISA           := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
ABI           := ilp32

SHELL := /bin/bash
.SHELLFLAGS := -ec
PATH := $(TOOLCHAIN_BIN):$(PATH)

OPENSBI_BIN := $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.bin
KERNEL_IMG  := $(LINUX_DIR)/arch/riscv/boot/Image
DTB         := $(CURDIR)/ntiny.dtb

KERNEL_PATCH := $(CURDIR)/patches/0001-ntiny-kernel-required.patch
DTS_MAKEFILE := $(CURDIR)/patches/ntiny-dts-Makefile

.PHONY: all prepare clone-linux clone-opensbi apply-patches \
        dtb kernel opensbi ram-hex build run clean distclean help

all: build

help:
	@echo "Targets:"
	@echo "  make prepare   - clone Linux + OpenSBI, apply ntiny patches"
	@echo "  make build     - rebuild kernel + opensbi + ram.hex"
	@echo "  make run       - launch the verilator sim and stream uart.log"
	@echo "  make clean     - wipe local build artifacts"
	@echo "  make distclean - also wipe Linux/OpenSBI build outputs"
	@echo ""
	@echo "Environment overrides:"
	@echo "  LINUX_DIR     ($(LINUX_DIR))"
	@echo "  OPENSBI_DIR   ($(OPENSBI_DIR))"
	@echo "  TOOLCHAIN_BIN ($(TOOLCHAIN_BIN))"

# ── prepare: clone external repos and apply ntiny patches ────────────
prepare: clone-linux clone-opensbi apply-patches

clone-linux:
	@if [ ! -d $(LINUX_DIR) ]; then \
		echo "==> Cloning Linux $(LINUX_TAG) into $(LINUX_DIR)"; \
		git clone --depth=1 --branch $(LINUX_TAG) \
			https://github.com/torvalds/linux $(LINUX_DIR); \
	else \
		echo "==> $(LINUX_DIR) already exists, skipping clone"; \
	fi

clone-opensbi:
	@if [ ! -d $(OPENSBI_DIR) ]; then \
		echo "==> Cloning OpenSBI $(OPENSBI_TAG) into $(OPENSBI_DIR)"; \
		git clone --depth=1 --branch $(OPENSBI_TAG) \
			https://github.com/riscv-software-src/opensbi $(OPENSBI_DIR); \
	else \
		echo "==> $(OPENSBI_DIR) already exists, skipping clone"; \
	fi

apply-patches:
	@echo "==> Copying ntiny DTS into the kernel tree"
	@mkdir -p $(LINUX_DIR)/arch/riscv/boot/dts/ntiny
	@cp $(CURDIR)/ntiny.dts $(LINUX_DIR)/arch/riscv/boot/dts/ntiny/ntiny.dts
	@cp $(DTS_MAKEFILE)     $(LINUX_DIR)/arch/riscv/boot/dts/ntiny/Makefile
	@echo "==> Applying $(notdir $(KERNEL_PATCH)) (idempotent)"
	@cd $(LINUX_DIR) && \
		git apply --check $(KERNEL_PATCH) 2>/dev/null && \
		git apply $(KERNEL_PATCH) || \
		echo "    (already applied or no-op)"
	@echo "==> Installing ntiny_defconfig as .config"
	@sed 's|@NTINY_LINUX@|$(CURDIR)|g' $(CURDIR)/ntiny_defconfig \
		> $(LINUX_DIR)/arch/riscv/configs/ntiny_defconfig
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) ntiny_defconfig
	@echo "==> Done. Run 'make build' next."

# ── build: rebuild kernel + opensbi + ram.hex ───────────────────────
build: dtb kernel opensbi ram-hex
	@echo "==> Build complete."
	@echo "    kernel:  $(KERNEL_IMG)"
	@echo "    opensbi: $(OPENSBI_BIN)"
	@echo "    ram.hex: $(SIM_DIR)/ram.hex"

dtb: ntiny.dtb

ntiny.dtb: ntiny.dts
	@echo "==> dtc → $@"
	@dtc -I dts -O dtb -o $@ $<

kernel: $(KERNEL_IMG)

$(KERNEL_IMG): ntiny_defconfig
	@echo "==> Building Linux kernel ($(LINUX_TAG))"
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) olddefconfig
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -j$$(nproc)

opensbi: $(OPENSBI_BIN)

$(OPENSBI_BIN): $(KERNEL_IMG) $(DTB)
	@echo "==> Building OpenSBI ($(OPENSBI_TAG))"
	@cd $(OPENSBI_DIR) && $(MAKE) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		PLATFORM_DIR=$(CURDIR)/opensbi-platform \
		PLATFORM_RISCV_XLEN=32 \
		PLATFORM_RISCV_ISA=$(ISA) \
		PLATFORM_RISCV_ABI=$(ABI) \
		FW_PAYLOAD_PATH=$(KERNEL_IMG) \
		FW_FDT_PATH=$(DTB) \
		-j$$(nproc)

ram-hex: $(SIM_DIR)/ram.hex

$(SIM_DIR)/ram.hex: $(OPENSBI_BIN)
	@echo "==> Generating ram.hex"
	@cd $(SIM_DIR) && python3 $(NTINY)/software/tools/hex_text.py $(OPENSBI_BIN) ram.hex

# ── run: launch the verilator sim ───────────────────────────────────
run:
	@if [ ! -x $(SIM_DIR)/Vtb_soc_top ]; then \
		echo "ERROR: $(SIM_DIR)/Vtb_soc_top not found."; \
		echo "Build the verilator model first (see flows/simulation)."; \
		exit 1; \
	fi
	@echo "==> Running ntiny Linux. Watch $(SIM_DIR)/uart.log."
	@cd $(SIM_DIR) && rm -f uart.log && \
		./Vtb_soc_top --timeout 1000000000 &
	@sleep 1
	@tail -f $(SIM_DIR)/uart.log

# ── cleanup ─────────────────────────────────────────────────────────
clean:
	@rm -f ntiny.dtb $(SIM_DIR)/ram.hex

distclean: clean
	@if [ -d $(LINUX_DIR) ]; then \
		cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) mrproper; \
	fi
	@if [ -d $(OPENSBI_DIR) ]; then \
		cd $(OPENSBI_DIR) && $(MAKE) clean; \
	fi
