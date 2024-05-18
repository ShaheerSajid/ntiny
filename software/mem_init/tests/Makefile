TOOLCHAIN = /opt/riscv64_new/bin
CC = $(TOOLCHAIN)/riscv64-unknown-elf-gcc
ELFSIZE = $(TOOLCHAIN)/riscv64-unknown-elf-size
OBJCOPY = $(TOOLCHAIN)/riscv64-unknown-elf-objcopy

COMMON_DIR = common
BAREMETAL_DIR = baremetal
COREMARK_DIR = coremark
DHRYSTONE_DIR = dhrystone
TEST_DIR = Firmware_tests
UART_SW = ../../../design/uncore/uart/sw
GPIO_SW = ../../../design/uncore/gpio/sw
TIMER_SW = ../../../design/uncore/timer/sw
SPI_SW = ../../../design/uncore/spi/sw
I2C_SW = ../../../design/uncore/i2c/sw
PWM_SW = ../../../design/uncore/pwm/sw
PLIC_SW = ../../../design/uncore/plic/sw

CFLAGS =	-I$(UART_SW) \
		-I$(GPIO_SW) \
		-I$(TIMER_SW) \
		-I$(SPI_SW) \
		-I$(I2C_SW) \
		-I$(PWM_SW) \
		-I$(PLIC_SW) \
		-I$(COMMON_DIR) \
		-I$(TEST_DIR) \
		-Ofast -ffunction-sections -fdata-sections -mabi=ilp32 -march=rv32imc_zba_zbb
		
LDFLAGS =	-T $(COMMON_DIR)/link.ld \
		-Wl,-gc-sections \
		--specs=nosys.specs \
		-nostartfiles

SRCS_COMMON =		$(COMMON_DIR)/init.c \
			$(COMMON_DIR)/ee_printf.c \
			$(COMMON_DIR)/cvt.c \
			$(UART_SW)/uart.c \
			$(TIMER_SW)/timer.c \
			$(GPIO_SW)/gpio.c \
			$(SPI_SW)/spi.c \
			$(I2C_SW)/i2c.c \
			$(PWM_SW)/pwm.c \
			$(PLIC_SW)/plic.c



baremetal_compile:
	$(CC) -o main.elf $(BAREMETAL_DIR)/main.c $(SRCS_COMMON) $(CFLAGS) $(LDFLAGS)
	
coremark_compile:
	$(CC) -o main.elf \
	$(COREMARK_DIR)/core_main.c \
	$(COREMARK_DIR)/core_list_join.c \
	$(COREMARK_DIR)/core_matrix.c \
	$(COREMARK_DIR)/core_state.c \
	$(COREMARK_DIR)/core_util.c \
	$(COREMARK_DIR)/portme/core_portme.c \
	$(SRCS_COMMON) $(CFLAGS) \
	-I$(COREMARK_DIR) \
	-I$(COREMARK_DIR)/portme \
	-finline-functions \
	-finline-limit=400 \
	-fno-code-hoisting \
	-mbranch-cost=0 \
	-funroll-all-loops \
	-DITERATIONS=1 \
	-DCLOCKS_PER_SEC=50000000 \
	$(LDFLAGS)
	
dhrystone_compile:
	$(CC) -o main.elf \
	$(DHRYSTONE_DIR)/dhry_1.c \
	$(DHRYSTONE_DIR)/dhry_2.c \
	$(COMMON_DIR)/clock.c \
	$(SRCS_COMMON) $(CFLAGS) \
	-DMSC_CLOCK \
	-DNOENUM \
	-DCLK_TCK=50000000 \
	-DDHRY_ITERS=1000 \
	-Wno-implicit \
	-fno-common \
	-DVERILATOR \
	-I$(DHRYSTONE_DIR) \
	$(LDFLAGS)
	
generate_hex:
		$(ELFSIZE) main.elf
		$(OBJCOPY) -O binary --gap-fill 0 main.elf sys_onchip_memory2_0.bin
		$(COMMON_DIR)/bin2hex_2 sys_onchip_memory2_0.bin sys_onchip_memory2_0.hex
		$(COMMON_DIR)/bin2hex_2 $(COMMON_DIR)/boot.bin boot.hex
		$(COMMON_DIR)/hex_text sys_onchip_memory2_0.bin mem.text
		$(COMMON_DIR)/hex_text $(COMMON_DIR)/boot.bin boot.text
		sed -i 's/0x//' mem.text
		sed -i 's/0x//' boot.text

.PHONY: baremetal
baremetal: clean baremetal_compile generate_hex

.PHONY: coremark
coremark: clean coremark_compile generate_hex

.PHONY: dhrystone
dhrystone: clean dhrystone_compile generate_hex

.PHONY: clean
clean:
	rm -f *.elf *.bin *.hex *.text
