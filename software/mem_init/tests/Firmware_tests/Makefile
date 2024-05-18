CC = /opt/riscv64/bin/riscv64-unknown-elf-gcc
ELFSIZE = /opt/riscv64/bin/riscv64-unknown-elf-size
OBJCOPY = /opt/riscv64/bin/riscv64-unknown-elf-objcopy

COMMON_DIR = ../common
BAREMETAL_DIR = ../baremetal

UART_SW = ../../../../design/uncore/uart/sw
GPIO_SW = ../../../../design/uncore/gpio/sw
TIMER_SW = ../../../../design/uncore/timer/sw
SPI_SW = ../../../../design/uncore/spi/sw
I2C_SW = ../../../../design/uncore/i2c/sw
PWM_SW = ../../../../design/uncore/pwm/sw
DE1SOC = ../../../../flows/fpga/quartus/de1soc
DE10NANO = ../../../../flows/fpga/quartus/de10nano

CFLAGS =	-I$(UART_SW) \
		-I$(GPIO_SW) \
		-I$(TIMER_SW) \
		-I$(SPI_SW) \
		-I$(I2C_SW) \
		-I$(PWM_SW) \
		-I$(COMMON_DIR) \
		-I./ \
		-O3 -ffunction-sections -fdata-sections -mabi=ilp32 -march=rv32im
		
LDFLAGS =	-T $(COMMON_DIR)/link.ld \
		-Wl,-gc-sections \
		--specs=nosys.specs \
		-nostartfiles

SRCS_COMMON =		$(COMMON_DIR)/init.c \
			$(COMMON_DIR)/ee_printf.c \
			$(COMMON_DIR)/cvt.c \
			$(UART_SW)/uart.c $(UART_SW)/uart_test.c \
			$(TIMER_SW)/timer.c $(TIMER_SW)/timer_test.c \
			$(GPIO_SW)/gpio.c $(GPIO_SW)/gpio_test.c \
			$(SPI_SW)/spi.c $(SPI_SW)/spi_test.c \
			$(I2C_SW)/i2c.c $(I2C_SW)/i2c_test.c \
			$(PWM_SW)/pwm.c $(PWM_SW)/pwm_test.c \
			test_common.c 

baremetal_test:
	$(CC) -o main.elf test.c -DPeak_poke $(SRCS_COMMON) $(CFLAGS) $(LDFLAGS)


generate_hex:
		$(ELFSIZE) main.elf
		$(OBJCOPY) -O binary --gap-fill 0 main.elf sys_onchip_memory2_0.bin
		$(COMMON_DIR)/bin2hex_2 sys_onchip_memory2_0.bin sys_onchip_memory2_0.hex
		$(COMMON_DIR)/hex_text sys_onchip_memory2_0.bin mem.text
		cp sys_onchip_memory2_0.hex ../../../../flows/fpga/quartus/de10lite/sys_onchip_memory2_0.hex
		cp sys_onchip_memory2_0.hex ../../../../flows/fpga/quartus/de1soc/sys_onchip_memory2_0.hex
		cp sys_onchip_memory2_0.hex ../../../../flows/fpga/quartus/de10nano/sys_onchip_memory2_0.hex
		cp mem.text ../../../../flows/fpga/quartus/de1soc/mem.text
		cp mem.text ../../../../flows/fpga/quartus/de10lite/mem.text
		cp mem.text ../../../../flows/fpga/quartus/de10nano/mem.text
	
.PHONY: test
test: clean baremetal_test generate_hex


.PHONY: clean
clean:
	rm -f *.elf *.bin *.hex *.text $(DE1SOC)/*.hex $(DE10NANO)/*.hex
