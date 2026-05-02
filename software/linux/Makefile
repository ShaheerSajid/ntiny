# ntiny Linux build automation
#
#   make prepare   one-time: clone Linux + OpenSBI inside ./external/,
#                  apply ntiny patches, install defconfig
#   make build     rebuild kernel + opensbi + ram.hex (force-fresh:
#                  re-embeds initramfs.cpio every time, no stale images)
#   make run       launch the verilator sim and stream uart.log
#   make clean     wipe local build artifacts (dtb, ram.hex)
#   make distclean also wipe Linux/OpenSBI build outputs
#   make wipe      remove the cloned external repos entirely
#
# External repos clone INTO this directory by default:
#   software/linux/external/linux         (Linux source tree)
#   software/linux/external/opensbi       (OpenSBI source tree)
# Both are git-ignored. Override via env if you want to share clones:
#   make LINUX_DIR=/path/to/linux OPENSBI_DIR=/path/to/opensbi prepare
#
# Toolchain: expects riscv32-unknown-linux-gnu-* in PATH or at
# /opt/riscv-linux/bin (the default location).

NTINY      := $(abspath $(CURDIR)/../..)
EXTERNAL_DIR := $(CURDIR)/external
LINUX_DIR  ?= $(EXTERNAL_DIR)/linux
OPENSBI_DIR?= $(EXTERNAL_DIR)/opensbi
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
INITRAMFS   := $(CURDIR)/initramfs.cpio
DTB         := $(CURDIR)/ntiny.dtb

KERNEL_PATCH := $(CURDIR)/patches/0001-ntiny-kernel-required.patch
DTS_MAKEFILE := $(CURDIR)/patches/ntiny-dts-Makefile

BUILDROOT_DIR ?= /home/shaheer/Downloads/buildroot

.PHONY: all prepare clone-linux clone-opensbi apply-patches \
        dtb kernel opensbi ram-hex build force-rm rebuild run \
        initramfs-rebuild \
        clean distclean wipe help

all: build

help:
	@echo "Targets:"
	@echo "  make prepare           - clone Linux + OpenSBI into ./external/, apply ntiny patches"
	@echo "  make build             - rebuild kernel + opensbi + ram.hex (force-fresh image)"
	@echo "  make rebuild           - alias for build (always force-rm Image + fw_payload first)"
	@echo "  make run               - launch the verilator sim and stream uart.log"
	@echo "  make initramfs-rebuild - rebuild busybox + repack cpio (requires \$$BUILDROOT_DIR)"
	@echo "  make clean             - wipe local build artifacts (dtb, ram.hex)"
	@echo "  make distclean         - also wipe Linux/OpenSBI build outputs"
	@echo "  make wipe              - delete the entire ./external/ tree"
	@echo ""
	@echo "Paths:"
	@echo "  LINUX_DIR     = $(LINUX_DIR)"
	@echo "  OPENSBI_DIR   = $(OPENSBI_DIR)"
	@echo "  BUILDROOT_DIR = $(BUILDROOT_DIR)"
	@echo "  TOOLCHAIN_BIN = $(TOOLCHAIN_BIN)"

# ── prepare: clone external repos and apply ntiny patches ────────────
prepare: clone-linux clone-opensbi apply-patches

clone-linux:
	@if [ ! -d $(LINUX_DIR) ]; then \
		echo "==> Cloning Linux $(LINUX_TAG) into $(LINUX_DIR)"; \
		mkdir -p $(dir $(LINUX_DIR)); \
		git clone --depth=1 --branch $(LINUX_TAG) \
			https://github.com/torvalds/linux $(LINUX_DIR); \
	else \
		echo "==> $(LINUX_DIR) already exists, skipping clone"; \
	fi

clone-opensbi:
	@if [ ! -d $(OPENSBI_DIR) ]; then \
		echo "==> Cloning OpenSBI $(OPENSBI_TAG) into $(OPENSBI_DIR)"; \
		mkdir -p $(dir $(OPENSBI_DIR)); \
		git clone --depth=1 --branch $(OPENSBI_TAG) \
			https://github.com/riscv-software-src/opensbi $(OPENSBI_DIR); \
	else \
		echo "==> $(OPENSBI_DIR) already exists, skipping clone"; \
	fi

# Always re-applies: copies DTS, applies kernel patch (idempotent),
# regenerates ntiny_defconfig (with @NTINY_LINUX@ substituted), and
# runs `make ntiny_defconfig` so .config matches our intent. Run this
# any time you suspect .config got reset (e.g. wrong ARCH/XLEN).
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
	@# Some kbuild rules clean usr/initramfs_data.S, but the .o build
	@# rule still expects it. If missing, restore from git.
	@if [ ! -f $(LINUX_DIR)/usr/initramfs_data.S ]; then \
		echo "==> Restoring usr/initramfs_data.S from git"; \
		cd $(LINUX_DIR) && git checkout HEAD -- usr/initramfs_data.S; \
	fi
	@echo "==> Installing ntiny_defconfig as .config"
	@sed 's|@NTINY_LINUX@|$(CURDIR)|g' $(CURDIR)/ntiny_defconfig \
		> $(LINUX_DIR)/arch/riscv/configs/ntiny_defconfig
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) ntiny_defconfig
	@echo "==> Done. Run 'make build' next."

# ── build: rebuild kernel + opensbi + ram.hex ───────────────────────
# `build` always force-removes Image and fw_payload first so the kernel
# re-link picks up the current initramfs.cpio bytes (kbuild's own
# dependency tracking does NOT depend on the cpio file). This is the
# fix for "I changed initramfs.cpio but the kernel didn't pick it up".
build: force-rm dtb kernel opensbi ram-hex
	@echo "==> Build complete."
	@echo "    kernel:  $(KERNEL_IMG)"
	@echo "    opensbi: $(OPENSBI_BIN)"
	@echo "    ram.hex: $(SIM_DIR)/ram.hex"

rebuild: build

force-rm:
	@rm -f $(KERNEL_IMG) $(OPENSBI_BIN) $(LINUX_DIR)/usr/initramfs_inc_data \
	       $(LINUX_DIR)/usr/initramfs_data.o $(LINUX_DIR)/usr/built-in.a

dtb: ntiny.dtb

ntiny.dtb: ntiny.dts
	@echo "==> dtc → $@"
	@dtc -I dts -O dtb -o $@ $<

kernel: $(KERNEL_IMG)

# Order-only dep on apply-patches: ntiny_defconfig is always re-installed
# into arch/riscv/configs/ before the kernel build, so working-tree edits
# to the defconfig actually reach .config. Without this, kbuild's
# olddefconfig only fills in newly-introduced symbols and silently keeps
# stale values from a prior .config — the trap that hid the psmouse
# initcall Oops while pty_init looked like the failure point.
$(KERNEL_IMG): $(CURDIR)/ntiny_defconfig $(INITRAMFS) $(KERNEL_PATCH) | apply-patches
	@if [ ! -d $(LINUX_DIR) ]; then \
		echo "ERROR: $(LINUX_DIR) not found. Run 'make prepare' first."; \
		exit 1; \
	fi
	@if [ ! -f $(LINUX_DIR)/usr/initramfs_data.S ]; then \
		echo "==> Restoring missing usr/initramfs_data.S"; \
		cd $(LINUX_DIR) && git checkout HEAD -- usr/initramfs_data.S; \
	fi
	@echo "==> Building Linux kernel ($(LINUX_TAG))"
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) olddefconfig
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) -j$$(nproc)

opensbi: $(OPENSBI_BIN)

$(OPENSBI_BIN): $(KERNEL_IMG) $(DTB)
	@if [ ! -d $(OPENSBI_DIR) ]; then \
		echo "ERROR: $(OPENSBI_DIR) not found. Run 'make prepare' first."; \
		exit 1; \
	fi
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

# ── initramfs-rebuild: rebuild busybox in buildroot, repack the cpio ──
# initramfs.cpio is a SHIPPED BINARY in this repo. Editing busybox
# source (e.g. shell/ash.c) under $(BUILDROOT_DIR)/output/build/ does
# nothing on its own — buildroot must rebuild busybox AND repack the
# rootfs cpio, then you copy that cpio over $(INITRAMFS).
#
# This target stops short of the copy on purpose, so cpio rotation is
# always a deliberate step you can git-diff and revert.
initramfs-rebuild:
	@if [ ! -d $(BUILDROOT_DIR) ]; then \
		echo "ERROR: BUILDROOT_DIR=$(BUILDROOT_DIR) not found."; \
		echo "Set BUILDROOT_DIR=/path/to/buildroot or clone buildroot there."; \
		exit 1; \
	fi
	@echo "==> Rebuilding busybox in $(BUILDROOT_DIR)"
	@cd $(BUILDROOT_DIR) && $(MAKE) busybox-rebuild
	@echo "==> Repacking rootfs cpio"
	@cd $(BUILDROOT_DIR) && $(MAKE)
	@NEW_CPIO=$(BUILDROOT_DIR)/output/images/rootfs.cpio; \
	 if [ -f $$NEW_CPIO ]; then \
		echo ""; \
		echo "==> New cpio ready: $$NEW_CPIO"; \
		echo "    To activate it, run:"; \
		echo "      cp $$NEW_CPIO $(INITRAMFS)"; \
		echo "      $(MAKE) build"; \
	 else \
		echo "ERROR: expected $$NEW_CPIO, not produced. Inspect buildroot output."; \
		exit 1; \
	 fi

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

wipe: distclean
	@echo "==> Removing $(EXTERNAL_DIR)"
	@rm -rf $(EXTERNAL_DIR)
