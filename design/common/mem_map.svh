// Memory Map Configuration — single source of truth for all address ranges and sizes.
// Edit this file to change memory sizes or base addresses. Rebuild to apply.

// --- Instruction Memory (IMEM) ---
`ifndef IMEM_BASE
  `define IMEM_BASE     32'h0000_0000
`endif
`ifndef IMEM_SIZE_BYTES
  `define IMEM_SIZE_BYTES 32'h0000_8000  // 32KB default
`endif
`define IMEM_END        (`IMEM_BASE + `IMEM_SIZE_BYTES - 1)
`define IMEM_DEPTH      (`IMEM_SIZE_BYTES / 4)       // word count
`define IMEM_ADDR_WIDTH $clog2(`IMEM_DEPTH)

// --- Data Memory (DMEM) ---
`ifndef DMEM_BASE
  `define DMEM_BASE     32'h0001_0000
`endif
`ifndef DMEM_SIZE_BYTES
  `define DMEM_SIZE_BYTES 32'h0000_2000  // 8KB default
`endif
`define DMEM_END        (`DMEM_BASE + `DMEM_SIZE_BYTES - 1)
`define DMEM_DEPTH      (`DMEM_SIZE_BYTES / 4)       // word count
`define DMEM_ADDR_WIDTH $clog2(`DMEM_DEPTH)

// --- Boot ROM ---
`ifndef BOOT_BASE
  `define BOOT_BASE     32'h8000_0000
`endif
`ifndef BOOT_SIZE_BYTES
  `define BOOT_SIZE_BYTES 32'h0000_0200  // 512B default
`endif
`define BOOT_END        (`BOOT_BASE + `BOOT_SIZE_BYTES - 1)

// --- Peripherals ---
`define CRC_BASE        32'h0008_0000
`define CRC_END         32'h0008_001F
`define UART_BASE       32'h0010_0000
`define UART_END        32'h0010_0010
`define TIMER_BASE      32'h0020_0000
`define TIMER_END       32'h0020_0010
`define GPIO_BASE       32'h0040_0000
`define GPIO_END        32'h0040_000F
`define PLIC_BASE       32'h0080_0000
`define PLIC_END        32'h0080_000F
`define SPI_BASE        32'h0100_0000
`define SPI_END         32'h0100_00FF
`define I2C_BASE        32'h0200_0000
`define I2C_END         32'h0200_00FF
`define PWM_BASE        32'h0200_1000
`define PWM_END         32'h0200_1FFF
`define SOFT_INT_ADDR   32'h0400_0000

// --- Tohost (test completion) ---
`define TOHOST_ADDR     32'h0F00_0000
