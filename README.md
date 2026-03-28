# ntiny — RV32IMFC SoC

A RISC-V SoC built around a single-issue, in-order 4-stage pipeline core. Taped out on TSMC 65nm as part of NUST's microprocessor project and successfully tested on a custom PCB.

## ISA Support

| Extension | Description |
|-----------|-------------|
| RV32I | Base integer instruction set |
| M | Hardware multiply/divide |
| F | Single-precision floating point (PakFPU) |
| C | Compressed (16-bit) instructions |
| Zba | Address generation bit-manipulation |
| Zbb | Basic bit-manipulation |
| Zicsr | CSR instructions |

## SoC Features

- 4-stage pipeline (Fetch, Decode, Execute, Memory/Writeback)
- JTAG debug interface with halt/resume/single-step
- M-mode privilege level with trap handling (ecall, ebreak, misaligned)
- Boot ROM at 0x80000000 for JTAG-based boot flow

### Peripherals

| Peripheral | Base Address | Description |
|------------|-------------|-------------|
| UART | 0x00100000 | Serial TX/RX with configurable baud rate |
| Timer | 0x00200000 | Prescaler, compare, interrupt |
| GPIO | 0x00400000 | Bidirectional I/O with direction control |
| PLIC | 0x00800000 | Platform-Level Interrupt Controller |
| SPI | 0x01000000 | Xilinx-compatible SPI master |
| I2C | 0x02000000 | I2C master (OpenCores-based) |
| PWM | 0x02001000 | Dual-channel PWM with dead-time |
| CRC | 0x00080000 | Hardware LFSR-based CRC |

## Directory Structure

```
design/
  core/           Core pipeline (ALU, decoder, CSR, regfile, FPU, etc.)
  uncore/         Peripherals (UART, SPI, I2C, Timer, GPIO, PWM, PLIC, CRC)
  interconnect/   Avalon bus interconnect
  debug/          JTAG debug module (DTM + DM)
  soc_top/        Top-level SoC integration
  common/         Shared headers: mem_map.svh, mem_map.h, mem_map.json
flows/
  simulation/     Verilator/Questa/Incisive simulation targets
  synthesis/      Genus synthesis scripts
software/
  mem_init/       Bare-metal test programs, linker scripts, firmware
verification/
  dv/             Design verification (RVFI tracer)
  riscof/         RISCOF compliance test infrastructure
scripts/
  gen_mem_map.py  Memory map generator
```

## Building and Simulation

### Prerequisites

- [Verilator](https://verilator.org) (v5+)
- RISC-V GCC toolchain at `/opt/riscv/bin`
- Python 3.6+ (for memory map generation and RISCOF)

### Quick Start

```bash
cd flows/simulation

# Build and run a bare-metal test
make verilator

# Build and run with VCD waveform
make verilator_trace

# CI regression test (returns exit code)
make verilator_test
```

### RISCOF Compliance Tests

```bash
# Run ISA compliance suite (RV32IMC_Zba_Zbb)
make riscof

# Run F-extension compliance suite
make riscof_fpu

# List tests without running
make riscof_testlist
```

### Other Simulators

```bash
make questa     # Mentor Questa (requires license)
make incisive   # Cadence Incisive (requires license)
```

## Memory Map

All memory addresses are defined in a single source of truth: [`design/common/mem_map.json`](design/common/mem_map.json).

A generator script produces all downstream files:

```bash
python3 scripts/gen_mem_map.py          # generate all files
python3 scripts/gen_mem_map.py --check  # verify files are up-to-date (CI)
make -C flows/simulation gen_mem_map    # or via Makefile
```

### Generated Files

| File | Purpose |
|------|---------|
| `design/common/mem_map.svh` | SystemVerilog \`define header (RTL) |
| `design/common/mem_map.h` | C header with `NTINY_` prefixed defines (firmware) |
| `software/mem_init/tests/common/link.ld` | Linker script — default profile |
| `verification/riscof/ntiny/env/link.ld` | Linker script — RISCOF profile |

### Profiles

The JSON defines multiple memory profiles:

- **default** — Taped-out SoC (IMEM 32KB @ 0x0, DMEM 8KB @ 0x10000, Boot ROM @ 0x80000000)
- **riscof** — RISCOF compliance testing (IMEM 2MB @ 0x0, DMEM 32MB @ 0x10000000)

The Makefile automatically reads RISCOF profile values from the JSON, so changing `mem_map.json` and re-running `gen_mem_map.py` is all that's needed to update the entire flow.

Peripheral C headers (`design/uncore/*/sw/*.h`) include `mem_map.h` and use backward-compatible aliases, so existing firmware code continues to work without changes.

### Default Address Map

| Region | Base | End | Size |
|--------|------|-----|------|
| IMEM | 0x00000000 | 0x00007FFF | 32 KB |
| DMEM | 0x00010000 | 0x00011FFF | 8 KB |
| CRC | 0x00080000 | 0x0008001F | 32 B |
| UART | 0x00100000 | 0x00100010 | 16 B |
| Timer | 0x00200000 | 0x00200010 | 16 B |
| GPIO | 0x00400000 | 0x0040000F | 16 B |
| PLIC | 0x00800000 | 0x0080000F | 16 B |
| SPI | 0x01000000 | 0x010000FF | 256 B |
| I2C | 0x02000000 | 0x020000FF | 256 B |
| PWM | 0x02001000 | 0x02001FFF | 4 KB |
| Soft IRQ | 0x04000000 | — | 4 B |
| Tohost | 0x0F000000 | — | 4 B |
| Boot ROM | 0x80000000 | 0x800001FF | 512 B |
