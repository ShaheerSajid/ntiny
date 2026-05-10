# software/Makefile — Unified build system for ntiny firmware
SHELL := /bin/bash

# ─── Toolchain ────────────────────────────────────────────────────────────────
TOOLCHAIN = /opt/riscv/bin
CC      = $(TOOLCHAIN)/riscv64-unknown-elf-gcc
OBJCOPY = $(TOOLCHAIN)/riscv64-unknown-elf-objcopy
ELFSIZE = $(TOOLCHAIN)/riscv64-unknown-elf-size

# ─── Paths (relative to software/) ────────────────────────────────────────────
ROOT      = ..
COMMON    = common
DESIGN    = $(ROOT)/design
SIM_DIR   = $(ROOT)/flows/simulation
BUILDDIR  = build

# Peripheral driver directories
UART_SW  = drivers/uart
GPIO_SW  = drivers/gpio
TIMER_SW = drivers/timer
SPI_SW   = drivers/spi
I2C_SW   = drivers/i2c
PWM_SW   = drivers/pwm
PLIC_SW  = drivers/plic

# ─── Flags ────────────────────────────────────────────────────────────────────
INCLUDES = \
	-I$(COMMON) \
	-I$(DESIGN)/common \
	-I$(UART_SW) \
	-I$(GPIO_SW) \
	-I$(TIMER_SW) \
	-I$(SPI_SW) \
	-I$(I2C_SW) \
	-I$(PWM_SW) \
	-I$(PLIC_SW)

ARCH     = -mabi=ilp32 -march=rv32imfc_zicsr_zba_zbb
CFLAGS   = $(INCLUDES) -O2 -ffunction-sections -fdata-sections $(ARCH)

LDFLAGS = \
	-T $(COMMON)/link.ld \
	-Wl,-gc-sections \
	--specs=nosys.specs \
	-nostartfiles

# ─── Common sources ──────────────────────────────────────────────────────────
# Minimal set: boot + printf (for benchmarks and standalone builds)
SRCS_MINIMAL = \
	$(COMMON)/init.c \
	$(COMMON)/ee_printf.c \
	$(COMMON)/cvt.c \
	$(UART_SW)/uart.c

# Full set: all drivers (for peripheral tests that have cross-dependencies)
SRCS_COMMON = \
	$(SRCS_MINIMAL) \
	$(COMMON)/test_common.c \
	$(TIMER_SW)/timer.c \
	$(GPIO_SW)/gpio.c \
	$(SPI_SW)/spi.c \
	$(I2C_SW)/i2c.c \
	$(PWM_SW)/pwm.c \
	$(PLIC_SW)/plic.c

# ─── Test registry ────────────────────────────────────────────────────────────
# Each test: TESTS += name, name_MAIN = ..., name_SRCS = ...

TESTS += uart
uart_MAIN = tests/uart/main.c
uart_SRCS = $(UART_SW)/uart_test.c

TESTS += gpio
gpio_MAIN = tests/gpio/main.c
gpio_SRCS = $(GPIO_SW)/gpio_test.c

TESTS += timer
timer_MAIN = tests/timer/main.c
timer_SRCS = $(TIMER_SW)/timer_test.c

TESTS += spi
spi_MAIN = tests/spi/main.c
spi_SRCS = $(SPI_SW)/spi_test.c

TESTS += i2c
i2c_MAIN = tests/i2c/main.c
i2c_SRCS = $(I2C_SW)/i2c_test.c

TESTS += pwm
pwm_MAIN = tests/pwm/main.c
pwm_SRCS = $(PWM_SW)/pwm_test.c

TESTS += clint
clint_MAIN = tests/clint/main.c

# Tiny FPGA bring-up demo: prints "Hello from ntiny" forever and
# blinks the low 4 GPIO pins (= LD0..3 on Zybo Z7).
# gpio.c + uart.c already pulled via SRCS_COMMON.
TESTS += hello
hello_MAIN = tests/hello/main.c

# ─── Peripheral test flags ────────────────────────────────────────────────────
# -DPeak_poke selects register peek/poke tests (works without external hardware)
TEST_CFLAGS = -DPeak_poke -DVERILATOR

# ─── Boot text ────────────────────────────────────────────────────────────────
BOOT_TEXT = $(BUILDDIR)/boot.text

$(BOOT_TEXT): $(COMMON)/boot.bin | $(BUILDDIR)
	python3 tools/hex_text.py $< $@

# ─── Auto-generated targets per test ─────────────────────────────────────────
define TEST_TEMPLATE
# Build ELF
$(BUILDDIR)/$(1).elf: $($(1)_MAIN) $($(1)_SRCS) $(SRCS_COMMON) $(COMMON)/link.ld | $(BUILDDIR)
	$(CC) -o $$@ $($(1)_MAIN) $($(1)_SRCS) $(SRCS_COMMON) $(CFLAGS) $(TEST_CFLAGS) $(LDFLAGS)
	$(ELFSIZE) $$@

# Build memory files
$(BUILDDIR)/$(1).imem.text $(BUILDDIR)/$(1).dmem.text: $(BUILDDIR)/$(1).elf
	$(OBJCOPY) -O binary --gap-fill 0 $$< $(BUILDDIR)/$(1).bin
	python3 tools/hex_text.py $(BUILDDIR)/$(1).bin $(BUILDDIR)/$(1).mem.text
	python3 tools/split.py $(BUILDDIR)/$(1).mem.text $(BUILDDIR)/$(1).imem.text $(BUILDDIR)/$(1).dmem.text

.PHONY: test_$(1)
test_$(1): $(BUILDDIR)/$(1).imem.text $(BUILDDIR)/$(1).dmem.text $(BOOT_TEXT)
	@echo "=== Built test: $(1) ==="

.PHONY: run_$(1)
run_$(1): test_$(1)
	@cp $(BUILDDIR)/$(1).imem.text $(SIM_DIR)/imem.text
	@cp $(BUILDDIR)/$(1).dmem.text $(SIM_DIR)/dmem.text
	@cp $(BOOT_TEXT) $(SIM_DIR)/boot.text
	@echo "--- Running $(1) test in Verilator ---"
	@cd $(SIM_DIR) && ./Vtb_soc_top --timeout 5000000; \
	EXIT_CODE=$$$$?; \
	if [ $$$$EXIT_CODE -eq 0 ]; then \
		echo "$(1): PASS"; \
	elif [ $$$$EXIT_CODE -eq 2 ]; then \
		echo "$(1): TIMEOUT"; \
	else \
		echo "$(1): FAIL (exit code $$$$EXIT_CODE)"; \
	fi; \
	exit $$$$EXIT_CODE
endef

$(foreach t,$(TESTS),$(eval $(call TEST_TEMPLATE,$(t))))

$(BUILDDIR):
	mkdir -p $(BUILDDIR)

# ─── Aggregate targets ───────────────────────────────────────��────────────────
.PHONY: test_all_build
test_all_build: $(foreach t,$(TESTS),test_$(t))

.PHONY: test_all
test_all: test_all_build
	@PASS=0; FAIL=0; SKIP=0; \
	for t in $(TESTS); do \
		echo ""; \
		$(MAKE) --no-print-directory run_$$t && PASS=$$((PASS+1)) || FAIL=$$((FAIL+1)); \
	done; \
	echo ""; \
	echo "========================================"; \
	echo "  PASS: $$PASS  FAIL: $$FAIL"; \
	echo "========================================"; \
	[ $$FAIL -eq 0 ]

# ─── Benchmarks ───────────────────────────────────────────────────────────────
COREMARK_DIR = benchmarks/coremark
DHRYSTONE_DIR = benchmarks/dhrystone

# Benchmarks use integer-only march; 64KB linker script for headroom
BENCH_MARCH = -mabi=ilp32 -march=rv32imfc_zicsr_zba_zbb
BENCH_LDFLAGS = \
	-T $(COMMON)/link_bench.ld \
	-Wl,-gc-sections \
	-Wl,-u,ISR_DEFAULT_ASM,-u,ISR_TIMER_ASM,-u,ISR_EXT_ASM,-u,ISR_SOFT_ASM \
	--specs=nosys.specs \
	-nostartfiles

.PHONY: benchmark_coremark
benchmark_coremark: | $(BUILDDIR)
	$(CC) -o $(BUILDDIR)/coremark.elf \
		$(COREMARK_DIR)/core_main.c \
		$(COREMARK_DIR)/core_list_join.c \
		$(COREMARK_DIR)/core_matrix.c \
		$(COREMARK_DIR)/core_state.c \
		$(COREMARK_DIR)/core_util.c \
		$(COREMARK_DIR)/portme/core_portme.c \
		$(SRCS_MINIMAL) $(INCLUDES) \
		-Ofast -ffunction-sections -fdata-sections $(BENCH_MARCH) \
		-I$(COREMARK_DIR) \
		-I$(COREMARK_DIR)/portme \
		-flto \
		-finline-functions \
		-finline-limit=1000 \
		-fno-code-hoisting \
		-mbranch-cost=0 \
		-funroll-all-loops \
		-DITERATIONS=1 \
		-DCLOCKS_PER_SEC=50000000 \
		-DVERILATOR \
		$(BENCH_LDFLAGS)
	$(ELFSIZE) $(BUILDDIR)/coremark.elf
	$(OBJCOPY) -O binary --gap-fill 0 $(BUILDDIR)/coremark.elf $(BUILDDIR)/coremark.bin
	python3 tools/hex_text.py $(BUILDDIR)/coremark.bin $(SIM_DIR)/ram.hex
	@echo "=== Built benchmark: coremark (ram.hex in $(SIM_DIR)) ==="

.PHONY: benchmark_dhrystone
benchmark_dhrystone: | $(BUILDDIR)
	$(CC) -c -o $(BUILDDIR)/dhry_1.o $(DHRYSTONE_DIR)/dhry_1.c \
		$(INCLUDES) -I$(DHRYSTONE_DIR) \
		-Ofast -ffunction-sections -fdata-sections $(BENCH_MARCH) \
		-std=gnu89 -Wno-implicit -fno-common \
		-DMSC_CLOCK -DNOENUM -DCLK_TCK=50000000 -DDHRY_ITERS=10000 -DVERILATOR
	$(CC) -c -o $(BUILDDIR)/dhry_2.o $(DHRYSTONE_DIR)/dhry_2.c \
		$(INCLUDES) -I$(DHRYSTONE_DIR) \
		-Ofast -ffunction-sections -fdata-sections $(BENCH_MARCH) \
		-std=gnu89 -Wno-implicit -fno-common \
		-DMSC_CLOCK -DNOENUM -DCLK_TCK=50000000 -DDHRY_ITERS=10000 -DVERILATOR
	$(CC) -o $(BUILDDIR)/dhrystone.elf \
		$(BUILDDIR)/dhry_1.o $(BUILDDIR)/dhry_2.o \
		$(COMMON)/clock.c \
		$(SRCS_MINIMAL) $(INCLUDES) \
		-Ofast -ffunction-sections -fdata-sections $(BENCH_MARCH) \
		-DVERILATOR \
		$(BENCH_LDFLAGS)
	$(ELFSIZE) $(BUILDDIR)/dhrystone.elf
	$(OBJCOPY) -O binary --gap-fill 0 $(BUILDDIR)/dhrystone.elf $(BUILDDIR)/dhrystone.bin
	python3 tools/hex_text.py $(BUILDDIR)/dhrystone.bin $(SIM_DIR)/ram.hex
	@echo "=== Built benchmark: dhrystone (ram.hex in $(SIM_DIR)) ==="

# ─── Baremetal interactive demo ───────────────────────────────────────────────
.PHONY: baremetal
baremetal: | $(BUILDDIR)
	$(CC) -o $(BUILDDIR)/baremetal.elf \
		tests/baremetal/main.c \
		$(SRCS_COMMON) \
		$(CFLAGS) $(LDFLAGS)
	$(ELFSIZE) $(BUILDDIR)/baremetal.elf
	$(OBJCOPY) -O binary --gap-fill 0 $(BUILDDIR)/baremetal.elf $(BUILDDIR)/baremetal.bin
	python3 tools/hex_text.py $(BUILDDIR)/baremetal.bin $(BUILDDIR)/baremetal.mem.text
	python3 tools/split.py $(BUILDDIR)/baremetal.mem.text $(BUILDDIR)/baremetal.imem.text $(BUILDDIR)/baremetal.dmem.text
	python3 tools/hex_text.py $(COMMON)/boot.bin $(BUILDDIR)/boot.text
	@echo "=== Built baremetal ==="

# ─── FPGA hex generation ─────────────────────────────────────────────────────
.PHONY: fpga_hex
fpga_hex: baremetal
	python3 tools/bin2hex.py $(BUILDDIR)/baremetal.bin $(BUILDDIR)/sys_onchip_memory2_0.hex
	python3 tools/bin2hex.py $(COMMON)/boot.bin $(BUILDDIR)/boot.hex
	@echo "=== Generated FPGA hex files ==="

# ─── Utility targets ─────────────────────────────────────────────────────────
.PHONY: list_tests
list_tests:
	@echo "Peripheral tests: $(TESTS)"
	@echo "Benchmarks: coremark dhrystone"
	@echo "Other: baremetal"

.PHONY: clean
clean:
	rm -rf $(BUILDDIR)
