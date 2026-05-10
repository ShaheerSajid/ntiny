# ntiny Linux build automation
#
#   make prepare   one-time: clone Linux + OpenSBI inside ./external/,
#                  apply ntiny patches, install defconfig
#   make build     rebuild kernel + opensbi + ram.hex (force-fresh:
#                  re-embeds initramfs.cpio every time, no stale images)
#   make run       launch the verilator sim and stream uart.log
#   make release   package an ntiny Linux release tarball into releases/
#   make clean     wipe local build artifacts (dtb, ram.hex)
#   make distclean also wipe Linux/OpenSBI build outputs
#   make wipe      remove the cloned external repos entirely
#
# Externals clone INTO this directory by default:
#   software/linux/external/linux         (Linux source tree)
#   software/linux/external/opensbi       (OpenSBI source tree)
# Both are git-ignored. Override LINUX_DIR / OPENSBI_DIR to share or
# pick a specific tree (e.g. `~/Downloads/linux-v7.0`).
#
# Variables you can override:
#   LINUX_TAG     git tag to clone (default v6.6)
#   LINUX_DIR     existing kernel tree to build against
#   OPENSBI_TAG   git tag for OpenSBI (default v1.8)
#   OPENSBI_DIR   existing OpenSBI tree to build against
#   INITRAMFS     rootfs cpio to embed (default ./initramfs.cpio)
#   VERSION       release label, e.g. `make release VERSION=1.0`
#
# Toolchain: expects riscv32-unknown-linux-gnu-* in PATH or at
# /opt/riscv-linux/bin (the default location).

NTINY      := $(abspath $(CURDIR)/../..)
EXTERNAL_DIR := $(CURDIR)/external
SIM_DIR    := $(NTINY)/flows/simulation
TOOLCHAIN_BIN ?= /opt/riscv-linux/bin

LINUX_TAG     ?= v6.6
OPENSBI_TAG   ?= v1.8
BUILDROOT_TAG ?= 2024.02

# All external collateral lives under ./external/. Each kernel version
# clones into its own directory so multiple checkouts coexist
# (e.g. external/linux-v6.6 and external/linux-v7.0). OpenSBI and
# Buildroot are version-pinned but single-checkout. Override any of
# these on the command line to point at an existing tree elsewhere.
LINUX_DIR     ?= $(EXTERNAL_DIR)/linux-$(LINUX_TAG)
OPENSBI_DIR   ?= $(EXTERNAL_DIR)/opensbi
BUILDROOT_DIR ?= $(EXTERNAL_DIR)/buildroot
INITRAMFS     ?= $(CURDIR)/initramfs.cpio

CROSS_COMPILE := riscv32-unknown-linux-gnu-
ARCH          := riscv
ISA           := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
ABI           := ilp32

SHELL := /bin/bash
.SHELLFLAGS := -ec
PATH := $(TOOLCHAIN_BIN):$(PATH)

# All paths absolute so sub-makes (OpenSBI, kbuild) running from
# different cwds can resolve them. LINUX_DIR / OPENSBI_DIR /
# BUILDROOT_DIR / INITRAMFS may be passed in as relative paths on the
# command line; abspath canonicalises them.
override LINUX_DIR     := $(abspath $(LINUX_DIR))
override OPENSBI_DIR   := $(abspath $(OPENSBI_DIR))
override BUILDROOT_DIR := $(abspath $(BUILDROOT_DIR))
override INITRAMFS     := $(abspath $(INITRAMFS))

OPENSBI_BIN := $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.bin
KERNEL_IMG  := $(LINUX_DIR)/arch/riscv/boot/Image
DTB         := $(CURDIR)/ntiny.dtb

# Per-tag kernel patch. The base patch (0001-ntiny-kernel-required.patch)
# was authored against v6.6; lines have shifted in newer kernels so
# the patch needs a tag-specific variant. apply-patches looks for a
# `<base>.<LINUX_TAG>.patch` first and falls back to the base name.
KERNEL_PATCH_BASE := $(CURDIR)/patches/0001-ntiny-kernel-required
KERNEL_PATCH      := $(if $(wildcard $(KERNEL_PATCH_BASE).$(LINUX_TAG).patch),\
                          $(KERNEL_PATCH_BASE).$(LINUX_TAG).patch,\
                          $(KERNEL_PATCH_BASE).patch)
DTS_MAKEFILE := $(CURDIR)/patches/ntiny-dts-Makefile

# Release packaging
RELEASE_DIR ?= $(CURDIR)/releases
VERSION     ?= dev

.PHONY: all prepare prepare-buildroot \
        clone-linux clone-opensbi clone-buildroot apply-patches \
        dtb kernel opensbi ram-hex build force-rm rebuild run \
        initramfs-rebuild cpio-unpack cpio-pack release \
        clean distclean wipe help

all: build

# Default goal puts you on the standalone path: `make run` clones if
# needed, applies all patches, rebuilds kernel + OpenSBI, and launches
# the sim. Re-running is idempotent.

help:
	@echo "Targets:"
	@echo "  make run [LINUX_TAG=vX.Y]"
	@echo "    Standalone — clones (if needed), patches, rebuilds, runs sim."
	@echo "  make prepare           - clone Linux + OpenSBI into ./external/, apply ntiny patches"
	@echo "  make build             - rebuild kernel + opensbi + ram.hex (force-fresh image)"
	@echo "  make rebuild           - alias for build"
	@echo "  make release VERSION=x - package fw_payload+Image+dtb+cpio into releases/ntiny-linux-x/"
	@echo "  make cpio-unpack DEST=d - extract initramfs.cpio into d/ (preserves /dev nodes)"
	@echo "  make cpio-pack   SRC=d  - rebuild initramfs.cpio from d/ via gen_init_cpio"
	@echo "  make prepare-buildroot - clone Buildroot into ./external/ (only needed for full cpio rebuild)"
	@echo "  make initramfs-rebuild - rebuild busybox + repack cpio (uses \$$BUILDROOT_DIR)"
	@echo "  make clean             - wipe local build artifacts (dtb, ram.hex)"
	@echo "  make distclean         - also wipe Linux/OpenSBI build outputs"
	@echo "  make wipe              - delete the entire ./external/ tree"
	@echo ""
	@echo "Paths (overridable on command line):"
	@echo "  LINUX_TAG     = $(LINUX_TAG)"
	@echo "  LINUX_DIR     = $(LINUX_DIR)"
	@echo "  OPENSBI_TAG   = $(OPENSBI_TAG)"
	@echo "  OPENSBI_DIR   = $(OPENSBI_DIR)"
	@echo "  BUILDROOT_TAG = $(BUILDROOT_TAG)"
	@echo "  BUILDROOT_DIR = $(BUILDROOT_DIR)"
	@echo "  INITRAMFS     = $(INITRAMFS)"
	@echo "  TOOLCHAIN_BIN = $(TOOLCHAIN_BIN)"
	@echo "  VERSION       = $(VERSION)"

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

# Buildroot is OPTIONAL: only needed if you want to regenerate the
# initramfs cpio (the repo ships a pre-built one). Run
# `make prepare-buildroot` once, then `make initramfs-rebuild` whenever
# you tweak busybox config or shell sources.
prepare-buildroot: clone-buildroot

clone-buildroot:
	@if [ ! -d $(BUILDROOT_DIR) ]; then \
		echo "==> Cloning Buildroot $(BUILDROOT_TAG) into $(BUILDROOT_DIR)"; \
		mkdir -p $(dir $(BUILDROOT_DIR)); \
		git clone --depth=1 --branch $(BUILDROOT_TAG) \
			https://github.com/buildroot/buildroot $(BUILDROOT_DIR); \
	else \
		echo "==> $(BUILDROOT_DIR) already exists, skipping clone"; \
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
		if git apply --reverse --check $(KERNEL_PATCH) 2>/dev/null; then \
			echo "    (already applied — skipping)"; \
		elif git apply --check $(KERNEL_PATCH) 2>/dev/null; then \
			git apply $(KERNEL_PATCH) && echo "    applied"; \
		else \
			echo "    ERROR: patch will neither apply forward nor is already applied."; \
			echo "    Manual intervention needed; run 'cd $(LINUX_DIR) && git apply --check $(KERNEL_PATCH)'"; \
			exit 1; \
		fi
	@# Some kbuild rules clean usr/initramfs_data.S, but the .o build
	@# rule still expects it. If missing, restore from git.
	@if [ ! -f $(LINUX_DIR)/usr/initramfs_data.S ]; then \
		echo "==> Restoring usr/initramfs_data.S from git"; \
		cd $(LINUX_DIR) && git checkout HEAD -- usr/initramfs_data.S; \
	fi
	@echo "==> Installing ntiny_defconfig as .config (INITRAMFS=$(INITRAMFS))"
	@sed -e 's|@NTINY_LINUX@|$(CURDIR)|g' \
	     -e 's|@NTINY_CPIO@|$(INITRAMFS)|g' \
	     $(CURDIR)/ntiny_defconfig \
		> $(LINUX_DIR)/arch/riscv/configs/ntiny_defconfig
	@cd $(LINUX_DIR) && $(MAKE) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) ntiny_defconfig
	@echo "==> Done. Run 'make build' next."

# ── build: rebuild kernel + opensbi + ram.hex ───────────────────────
# `build` always force-removes Image and fw_payload first so the kernel
# re-link picks up the current initramfs.cpio bytes (kbuild's own
# dependency tracking does NOT depend on the cpio file). This is the
# fix for "I changed initramfs.cpio but the kernel didn't pick it up".
build: prepare force-rm dtb kernel opensbi ram-hex
	@echo "==> Build complete."
	@echo "    kernel:  $(KERNEL_IMG)"
	@echo "    opensbi: $(OPENSBI_BIN)"
	@echo "    ram.hex: $(SIM_DIR)/ram.hex"

rebuild: build

force-rm:
	@# Kernel-side: force-rm Image so the kernel re-link re-embeds the
	@# current initramfs.cpio (kbuild doesn't track the cpio file).
	@# Also drop usr/initramfs_data.cpio — it's regenerated from
	@# CONFIG_INITRAMFS_SOURCE; if that path changes, kbuild won't
	@# re-generate without explicit removal, leaving a stale embedded
	@# cpio (or an empty 512-byte placeholder) in the kernel image.
	@rm -f $(KERNEL_IMG) \
	       $(LINUX_DIR)/usr/initramfs_inc_data \
	       $(LINUX_DIR)/usr/initramfs_data.cpio \
	       $(LINUX_DIR)/usr/initramfs_data.o $(LINUX_DIR)/usr/built-in.a
	@# OpenSBI-side: nuke the whole payload chain (.bin + .elf + .o).
	@# fw_payload.S uses .incbin FW_PAYLOAD_PATH at build time, but
	@# OpenSBI's make doesn't track FW_PAYLOAD_PATH as a dependency —
	@# without removing all three, switching kernels (e.g. v6.6 → v6.12)
	@# silently re-uses the previously-embedded Image bytes through
	@# the cached .o/.elf, and the resulting fw_payload.bin still
	@# carries the OLD kernel.
	@rm -f $(OPENSBI_BIN) \
	       $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.elf \
	       $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.o

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

# ── run: end-to-end standalone — build everything, then launch sim ──
# Depends on `build` so kernel + OpenSBI + ram.hex are guaranteed
# fresh. run_linux.sh handles the verilator-side rebuild + sim launch
# (and now always wipes its own obj_dir + Vtb_soc_top first so a stale
# RTL build can't mask new changes).
run: build
	@echo "==> Launching ntiny Linux sim via $(SIM_DIR)/run_linux.sh"
	@cd $(SIM_DIR) && bash run_linux.sh 1000000000

# ── cpio-unpack / cpio-pack: edit-then-rebuild without buildroot ────
# Common need: tweak a script under /etc/init.d/ in the shipped cpio.
# A naive `cpio -idmv | find | cpio -o` workflow silently drops
# character device nodes (/dev/console, /dev/null) because non-root
# extraction can't recreate them — and the kernel fails init with
# "unable to open an initial console" → SIGTRAP → kernel panic.
#
# These targets use the kernel's own `gen_init_cpio` tool with a spec
# file generated by `tools/dir_to_cpio_list.py` (auto-injects the
# missing device nodes). Both work entirely as a regular user.
#
# Typical session:
#   make cpio-unpack DEST=/tmp/cpio-work
#   <edit /tmp/cpio-work/etc/init.d/S95peripherals>
#   make cpio-pack   SRC=/tmp/cpio-work
#   make build
GEN_INIT_CPIO := $(EXTERNAL_DIR)/gen_init_cpio
DIR_TO_LIST   := $(CURDIR)/tools/dir_to_cpio_list.py
DEST          ?= /tmp/ntiny-cpio-work
SRC           ?= /tmp/ntiny-cpio-work

cpio-unpack: $(INITRAMFS)
	@mkdir -p $(DEST)
	@# Non-root cpio extraction can't recreate /dev/console + /dev/null
	@# (mknod requires CAP_MKNOD). The 2>/dev/null + `|| true` drops
	@# the cosmetic warnings. cpio-pack re-injects the device nodes via
	@# gen_init_cpio's spec file, so the round-trip is lossless.
	@cd $(DEST) && cpio -idmu --quiet < $(INITRAMFS) 2>/dev/null || true
	@echo "==> Unpacked $(INITRAMFS) into $(DEST)"
	@echo "    edit the tree, then: make cpio-pack SRC=$(DEST)"

cpio-pack: $(GEN_INIT_CPIO)
	@if [ ! -d $(SRC) ]; then \
		echo "ERROR: SRC=$(SRC) is not a directory."; exit 1; \
	fi
	@python3 $(DIR_TO_LIST) $(SRC) > $(SRC)/.cpio_list
	@$(GEN_INIT_CPIO) $(SRC)/.cpio_list > $(INITRAMFS)
	@rm -f $(SRC)/.cpio_list
	@ls -lh $(INITRAMFS)
	@echo "==> Re-packed $(INITRAMFS) from $(SRC) (with device nodes)"
	@echo "    next: make build"

# Auto-build gen_init_cpio from whichever Linux source is live.
$(GEN_INIT_CPIO): $(LINUX_DIR)/usr/gen_init_cpio.c
	@mkdir -p $(EXTERNAL_DIR)
	@gcc -O2 -o $@ $<
	@echo "==> Built $@"

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

# ── release: package an ntiny Linux image ───────────────────────────
# Bundles the build outputs into a versioned release directory:
#   releases/ntiny-linux-VERSION/
#     fw_payload.bin    OpenSBI + embedded kernel + DTB
#     Image             plain kernel image (for re-embedding)
#     ntiny.dtb         compiled device tree
#     initramfs.cpio    rootfs (this build's INITRAMFS)
#     ram.hex           ready-to-load verilator memory image
#     README.txt        provenance: kernel tag, opensbi tag, isa, build date
release: build
	@mkdir -p $(RELEASE_DIR)/ntiny-linux-$(VERSION)
	@cp $(OPENSBI_BIN)         $(RELEASE_DIR)/ntiny-linux-$(VERSION)/
	@cp $(KERNEL_IMG)          $(RELEASE_DIR)/ntiny-linux-$(VERSION)/
	@cp $(DTB)                 $(RELEASE_DIR)/ntiny-linux-$(VERSION)/
	@cp $(INITRAMFS)           $(RELEASE_DIR)/ntiny-linux-$(VERSION)/
	@cp $(SIM_DIR)/ram.hex     $(RELEASE_DIR)/ntiny-linux-$(VERSION)/
	@( \
		echo "ntiny Linux release $(VERSION)"; \
		echo "Built: $$(date -Iseconds)"; \
		echo ""; \
		echo "Components:"; \
		echo "  Linux       $(LINUX_TAG)   ($(LINUX_DIR))"; \
		echo "  OpenSBI     $(OPENSBI_TAG) ($(OPENSBI_DIR))"; \
		echo "  ISA         $(ISA)"; \
		echo "  ABI         $(ABI)"; \
		echo "  Initramfs   $(INITRAMFS)"; \
		echo ""; \
		echo "Files:"; \
		echo "  fw_payload.bin   OpenSBI + kernel + DTB (load at 0x80000000)"; \
		echo "  Image            plain kernel image"; \
		echo "  ntiny.dtb        compiled device tree"; \
		echo "  initramfs.cpio   rootfs (uncompressed cpio newc)"; \
		echo "  ram.hex          verilator hex (ready for run_linux.sh)"; \
	) > $(RELEASE_DIR)/ntiny-linux-$(VERSION)/README.txt
	@echo "==> Release ready: $(RELEASE_DIR)/ntiny-linux-$(VERSION)/"
	@ls -lh $(RELEASE_DIR)/ntiny-linux-$(VERSION)/

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
