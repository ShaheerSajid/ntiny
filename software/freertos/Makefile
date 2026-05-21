# ntiny FreeRTOS build automation
#
# Self-contained: clones its own OpenSBI tree under ./external/opensbi and
# builds OpenSBI out-of-tree into ./build/opensbi. All paths below are
# relative to this Makefile's directory.

# ==========================================
# Paths (all relative to this directory)
# ==========================================
TOOLCHAIN_BIN ?= /opt/riscv-linux/bin

# This Makefile's own directory and the project root, used only as anchors
# so absolute paths can be derived for sub-makes that need them.
SELF_DIR     := $(abspath $(CURDIR))
PROJ_ROOT    := $(abspath $(CURDIR)/../..)

BUILD_DIR    := $(SELF_DIR)/build
EXTERNAL_DIR := $(SELF_DIR)/external
FREERTOS_DIR := $(SELF_DIR)/FreeRTOS/Source
DEMO_DIR     := $(SELF_DIR)/FreeRTOS/Demo/RISC-V-NTINY-GCC

# Sibling directories shared with the Linux deployment
DRIVERS_DIR  := $(SELF_DIR)/../drivers
TOOLS_DIR    := $(SELF_DIR)/../tools
LINUX_DIR    := $(SELF_DIR)/../linux
DESIGN_DIR   := $(SELF_DIR)/../../design
SIM_DIR      := $(SELF_DIR)/../../flows/simulation

OPENSBI_TAG  ?= v1.8
OPENSBI_SRC  := $(EXTERNAL_DIR)/opensbi
OPENSBI_BUILD:= $(BUILD_DIR)/opensbi
OPENSBI_PLATFORM_DIR := $(LINUX_DIR)/opensbi-platform
OPENSBI_BIN  := $(OPENSBI_BUILD)/platform/opensbi-platform/firmware/fw_payload.bin

DTB          := $(BUILD_DIR)/ntiny.dtb
DTS_SRC      := $(LINUX_DIR)/ntiny.dts

# ==========================================
# Toolchain & ISA
# ==========================================
CROSS_COMPILE := riscv32-unknown-linux-gnu-
ISA           := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
ABI           := ilp32

SHELL        := /bin/bash
.SHELLFLAGS  := -ec
PATH         := $(TOOLCHAIN_BIN):$(PATH)

CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
SIZE    := $(CROSS_COMPILE)size

# ==========================================
# Targets
# ==========================================
FREERTOS_ELF := $(BUILD_DIR)/freertos.elf
FREERTOS_BIN := $(BUILD_DIR)/freertos.bin

INC_DIRS := -I$(DEMO_DIR) \
            -I$(FREERTOS_DIR)/include \
            -I$(FREERTOS_DIR)/portable/GCC/RISCV \
            -I$(DRIVERS_DIR) \
            -I$(DESIGN_DIR)/common \
            -I$(DRIVERS_DIR)/uart \
            -I$(DRIVERS_DIR)/gpio \
            -I$(DRIVERS_DIR)/timer \
            -I$(DRIVERS_DIR)/spi \
            -I$(DRIVERS_DIR)/i2c \
            -I$(DRIVERS_DIR)/pwm \
            -I$(DRIVERS_DIR)/plic

CFLAGS  := -march=$(ISA) -mabi=$(ABI) -Os -g \
           -ffunction-sections -fdata-sections \
           -fno-omit-frame-pointer \
           $(INC_DIRS)

LDFLAGS := -march=$(ISA) -mabi=$(ABI) \
           -static -nostdlib -nostartfiles \
           -Wl,-gc-sections \
           -T $(DEMO_DIR)/link.ld \
           -Wl,-Map=$(BUILD_DIR)/freertos.map \
           -lgcc

APP_SRCS := $(DEMO_DIR)/main.c \
            $(DEMO_DIR)/init.c \
            $(DRIVERS_DIR)/uart/uart.c \
            $(DRIVERS_DIR)/timer/timer.c

RTOS_SRCS := $(FREERTOS_DIR)/tasks.c \
             $(FREERTOS_DIR)/list.c \
             $(FREERTOS_DIR)/queue.c \
             $(FREERTOS_DIR)/timers.c \
             $(FREERTOS_DIR)/portable/MemMang/heap_4.c

PORT_SRCS := $(FREERTOS_DIR)/portable/GCC/RISCV/port.c \
             $(FREERTOS_DIR)/portable/GCC/RISCV/portasm.S

SRCS := $(APP_SRCS) $(RTOS_SRCS) $(PORT_SRCS)

# ==========================================
# Build rules
# ==========================================
.PHONY: all build clean opensbi ram-hex force-rm

all: build

build: force-rm $(DTB) $(FREERTOS_BIN) opensbi ram-hex
	@echo "==> Build complete. FreeRTOS is ready for simulation."

# Force a re-link each invocation; the per-source dependency graph is
# implicit (no .o caching) so this only clears the final artifacts.
force-rm:
	@rm -f $(FREERTOS_BIN) $(FREERTOS_ELF) $(OPENSBI_BIN)

$(DTB): $(DTS_SRC)
	@mkdir -p $(BUILD_DIR)
	@echo "==> Compiling Device Tree Blob"
	@dtc -I dts -O dtb -o $@ $<

$(FREERTOS_ELF): $(SRCS) $(DEMO_DIR)/link.ld
	@mkdir -p $(BUILD_DIR)
	@echo "==> Linking FreeRTOS ELF"
	$(CC) $(CFLAGS) $(SRCS) $(LDFLAGS) -o $@
	$(SIZE) $@

$(FREERTOS_BIN): $(FREERTOS_ELF)
	$(OBJCOPY) -O binary $< $@

# Clone OpenSBI on demand into ./external/opensbi (gitignored).
$(OPENSBI_SRC):
	@mkdir -p $(EXTERNAL_DIR)
	@echo "==> Cloning OpenSBI $(OPENSBI_TAG) into $(OPENSBI_SRC)"
	@git clone --depth=1 --branch $(OPENSBI_TAG) \
		https://github.com/riscv-software-src/opensbi $(OPENSBI_SRC)

# OpenSBI is built out-of-tree (O=$(OPENSBI_BUILD)) so all build artifacts
# land under this directory's build/, leaving the source tree untouched.
opensbi: $(OPENSBI_SRC) $(FREERTOS_BIN) $(DTB)
	@echo "==> Compiling OpenSBI with embedded FreeRTOS payload"
	@$(MAKE) -C $(OPENSBI_SRC) O=$(OPENSBI_BUILD) \
		CROSS_COMPILE=$(CROSS_COMPILE) \
		PLATFORM_DIR=$(OPENSBI_PLATFORM_DIR) \
		PLATFORM_RISCV_XLEN=32 \
		PLATFORM_RISCV_ISA=$(ISA) \
		PLATFORM_RISCV_ABI=$(ABI) \
		FW_PAYLOAD_PATH=$(FREERTOS_BIN) \
		FW_FDT_PATH=$(DTB) \
		-j$$(nproc)

ram-hex: $(SIM_DIR)/ram.hex

$(SIM_DIR)/ram.hex: opensbi
	@echo "==> Converting OpenSBI+FreeRTOS binary to ram.hex"
	@cd $(SIM_DIR) && python3 $(TOOLS_DIR)/hex_text.py $(OPENSBI_BIN) ram.hex

clean:
	rm -rf $(BUILD_DIR)

# Wipe the on-disk OpenSBI clone too. Useful before pushing or when the
# upstream tag changes.
distclean: clean
	rm -rf $(EXTERNAL_DIR)
