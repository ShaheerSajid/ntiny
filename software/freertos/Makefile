# ntiny FreeRTOS build automation
#
#   make prepare   one-time: clone FreeRTOS-Kernel + OpenSBI into ./external/
#   make build     compile freertos.elf, wrap into OpenSBI fw_payload.bin,
#                  emit ram.hex into flows/simulation/
#   make run       build + launch the verilator sim (Linux flow's runner)
#   make clean     wipe ./build/ + flows/simulation/ram.hex
#   make distclean clean + scrub OpenSBI build output
#   make wipe      delete ./external/ entirely
#
# Layout:
#   external/FreeRTOS-Kernel  — upstream kernel @ FREERTOS_TAG
#   external/opensbi          — upstream OpenSBI @ OPENSBI_TAG
#   port/                     — ntiny S-mode port (boot, trap, UART, FreeRTOSConfig)
#   app/                      — demo (two-task UART hello)
#   build/                    — freertos.elf / .bin / .map
#
# OpenSBI is built reusing software/linux/opensbi-platform/ (same UART
# init, same Sstc/Svadu menvcfgh setup). The payload swap is just
# FW_PAYLOAD_PATH=build/freertos.bin instead of the Linux Image.

NTINY      := $(abspath $(CURDIR)/../..)
include $(NTINY)/.env

EXTERNAL_DIR  := $(CURDIR)/external
BUILD_DIR     := $(CURDIR)/build
SIM_DIR       := $(NTINY)/flows/simulation

FREERTOS_TAG  ?= V11.1.0
OPENSBI_TAG   ?= v1.8

FREERTOS_DIR  ?= $(EXTERNAL_DIR)/FreeRTOS-Kernel
OPENSBI_DIR   ?= $(EXTERNAL_DIR)/opensbi

override FREERTOS_DIR := $(abspath $(FREERTOS_DIR))
override OPENSBI_DIR  := $(abspath $(OPENSBI_DIR))

# OpenSBI ports require a GNU toolchain that emits ELF without forcing
# libc — both /opt/riscv-elf and /opt/riscv-linux-gnu fit. We use the
# bare-metal one for everything to match the rest of software/.
TOOLCHAIN_BIN ?= $(TOOLCHAIN_ELF)
CC      := $(TOOLCHAIN_BIN)/riscv64-unknown-elf-gcc
OBJCOPY := $(TOOLCHAIN_BIN)/riscv64-unknown-elf-objcopy
SIZE    := $(TOOLCHAIN_BIN)/riscv64-unknown-elf-size

# Match the rv32imafc_zicsr_zaamo_zalrsc_*/ilp32f multilib in
# /opt/riscv-elf so newlib + libgcc come pre-tuned. FreeRTOS itself
# uses no floats; the FP-ABI is just the multilib selector.
ISA  := rv32imafc_zicsr_zaamo_zalrsc_zba_zbb_zbc_zbs
ABI  := ilp32f

# OpenSBI must build with a linker that supports -pie (its top-level
# Makefile bails with "linker does not support creating PIEs" otherwise).
# The bundled /opt/riscv-elf ld doesn't, so OpenSBI uses the Linux-gnu
# toolchain — same as software/linux/Makefile. The FreeRTOS payload
# above still uses /opt/riscv-elf (no PIE needed for a flat S-mode image).
OPENSBI_CROSS := $(TOOLCHAIN_LINUX)/riscv64-unknown-linux-gnu-
OPENSBI_ISA   := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
OPENSBI_ABI   := ilp32

PLATFORM_DIR  := $(NTINY)/software/linux/opensbi-platform
DTB           := $(NTINY)/software/linux/ntiny.dtb

# ── Source layout ───────────────────────────────────────────────
PORT_DIR   := $(CURDIR)/port
APP_DIR    := $(CURDIR)/app

KERNEL_SRCS := \
    $(FREERTOS_DIR)/tasks.c \
    $(FREERTOS_DIR)/queue.c \
    $(FREERTOS_DIR)/list.c \
    $(FREERTOS_DIR)/portable/MemMang/heap_4.c

PORT_SRCS := \
    $(PORT_DIR)/boot.S \
    $(PORT_DIR)/portASM.S \
    $(PORT_DIR)/port.c \
    $(PORT_DIR)/ntiny_uart.c \
    $(PORT_DIR)/libstubs.c

APP_SRCS := \
    $(APP_DIR)/main.c

SRCS := $(KERNEL_SRCS) $(PORT_SRCS) $(APP_SRCS)

INCLUDES := \
    -I$(FREERTOS_DIR)/include \
    -I$(PORT_DIR)

CFLAGS := \
    -march=$(ISA) -mabi=$(ABI) \
    -mcmodel=medany \
    -O2 -g \
    -ffunction-sections -fdata-sections \
    -ffreestanding -fno-builtin \
    -Wall -Wextra -Wno-unused-parameter \
    $(INCLUDES)

LDFLAGS := \
    -march=$(ISA) -mabi=$(ABI) \
    -nostartfiles -nostdlib \
    -Wl,--gc-sections \
    -Wl,-Map=$(BUILD_DIR)/freertos.map \
    -T $(PORT_DIR)/link.ld

# libgcc holds RV32 helper routines (e.g. 64-bit arithmetic) that
# tasks.c / queue.c can call via the compiler. -lgcc is the only
# host library we link against.
LDLIBS := -lgcc

# ── Outputs ─────────────────────────────────────────────────────
FREERTOS_ELF := $(BUILD_DIR)/freertos.elf
FREERTOS_BIN := $(BUILD_DIR)/freertos.bin
OPENSBI_BIN  := $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.bin
RAM_HEX      := $(SIM_DIR)/ram.hex

SHELL := /bin/bash
.SHELLFLAGS := -ec

.PHONY: all help prepare clone-freertos clone-opensbi build force-rm \
        freertos opensbi ram-hex run clean distclean wipe

all: build

help:
	@echo "Targets:"
	@echo "  make prepare    clone FreeRTOS-Kernel + OpenSBI into ./external/"
	@echo "  make build      compile freertos.elf + fw_payload.bin + ram.hex"
	@echo "  make run        build + launch verilator (uses Linux flow's run_linux.sh)"
	@echo "  make clean      rm build/ + flows/simulation/ram.hex"
	@echo "  make distclean  clean + scrub OpenSBI build output"
	@echo "  make wipe       delete external/"
	@echo ""
	@echo "Overrides:"
	@echo "  FREERTOS_TAG = $(FREERTOS_TAG)"
	@echo "  FREERTOS_DIR = $(FREERTOS_DIR)"
	@echo "  OPENSBI_TAG  = $(OPENSBI_TAG)"
	@echo "  OPENSBI_DIR  = $(OPENSBI_DIR)"

# ── prepare: clone external repos ───────────────────────────────
prepare: clone-freertos clone-opensbi

clone-freertos:
	@if [ ! -d $(FREERTOS_DIR) ]; then \
		echo "==> Cloning FreeRTOS-Kernel $(FREERTOS_TAG) into $(FREERTOS_DIR)"; \
		mkdir -p $(dir $(FREERTOS_DIR)); \
		git clone --depth=1 --branch $(FREERTOS_TAG) \
			https://github.com/FreeRTOS/FreeRTOS-Kernel $(FREERTOS_DIR); \
	else \
		echo "==> $(FREERTOS_DIR) already exists, skipping clone"; \
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

# ── build: freertos.elf → freertos.bin → fw_payload.bin → ram.hex ─
build: prepare force-rm freertos opensbi ram-hex
	@echo "==> Build complete."
	@echo "    freertos.elf  : $(FREERTOS_ELF)"
	@echo "    freertos.bin  : $(FREERTOS_BIN)"
	@echo "    fw_payload    : $(OPENSBI_BIN)"
	@echo "    ram.hex       : $(RAM_HEX)"

# OpenSBI caches the payload .o by name only — without nuking the
# whole payload chain a stale Linux Image stays embedded. Same trick
# the Linux Makefile uses.
force-rm:
	@rm -f $(OPENSBI_BIN) \
	       $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.elf \
	       $(OPENSBI_DIR)/build/platform/opensbi-platform/firmware/fw_payload.o

freertos: $(FREERTOS_BIN)

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

$(FREERTOS_ELF): $(SRCS) $(PORT_DIR)/link.ld | $(BUILD_DIR)
	@echo "==> Compiling FreeRTOS"
	@$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRCS) $(LDLIBS)
	@$(SIZE) $@

$(FREERTOS_BIN): $(FREERTOS_ELF)
	@$(OBJCOPY) -O binary --gap-fill 0 $< $@
	@echo "==> $(notdir $@): $$(stat -c %s $@) bytes"

# Build OpenSBI's DTB if missing (relies on the Linux Makefile target).
$(DTB):
	@$(MAKE) -C $(NTINY)/software/linux ntiny.dtb

opensbi: $(OPENSBI_BIN)

$(OPENSBI_BIN): $(FREERTOS_BIN) $(DTB)
	@echo "==> Building OpenSBI ($(OPENSBI_TAG)) with FreeRTOS payload"
	@$(MAKE) -C $(OPENSBI_DIR) \
		CROSS_COMPILE=$(OPENSBI_CROSS) \
		PLATFORM_DIR=$(PLATFORM_DIR) \
		PLATFORM_RISCV_XLEN=32 \
		PLATFORM_RISCV_ISA=$(OPENSBI_ISA) \
		PLATFORM_RISCV_ABI=$(OPENSBI_ABI) \
		FW_PAYLOAD_PATH=$(FREERTOS_BIN) \
		FW_FDT_PATH=$(DTB) \
		-j$$(nproc)

ram-hex: $(RAM_HEX)

$(RAM_HEX): $(OPENSBI_BIN)
	@echo "==> Generating ram.hex"
	@cd $(SIM_DIR) && python3 $(NTINY)/software/tools/hex_text.py $(OPENSBI_BIN) ram.hex

# ── run: end-to-end ──────────────────────────────────────────────
# Reuses the Linux flow's run_linux.sh: rebuilds the verilator model
# at 128 MB RAM if needed, then streams uart.log. Default timeout is
# 60M cycles — plenty for a few tick scheduler turns at 100 Hz.
run: build
	@echo "==> Launching ntiny verilator sim"
	@cd $(SIM_DIR) && OPENSBI_BIN=$(OPENSBI_BIN) bash run_linux.sh 60000000

# ── cleanup ──────────────────────────────────────────────────────
clean:
	@rm -rf $(BUILD_DIR)
	@rm -f $(RAM_HEX)

distclean: clean
	@if [ -d $(OPENSBI_DIR) ]; then \
		$(MAKE) -C $(OPENSBI_DIR) clean; \
	fi

wipe: distclean
	@echo "==> Removing $(EXTERNAL_DIR)"
	@rm -rf $(EXTERNAL_DIR)
