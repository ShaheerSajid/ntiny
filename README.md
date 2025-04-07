# 32 bit RISCV Implementation

This is an implementation of a processor on the opensource RISC-V ISA. The processor features a single issue, in-order 4-stage pipeline. It currently supports integer, multiply, compressed and bit-manipulation instruction sets. It is an improvement over the following repo:. THe processor was taped out on TSMC 65nm as part of NUST's microprocessor project. The SoC features JTAG, debug, peripherals like UART, SPI, I2C, PWM, Timers, PLIC, GPIOs and hardware CRC. The SoC has been successfuly tested after tapeout on a custom PCB.
