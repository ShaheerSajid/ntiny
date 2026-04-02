# ntiny — RV32IMAFCSU SoC

A RISC-V SoC built around a single-issue, in-order 4-stage pipeline core with Sv32 virtual memory. Taped out on TSMC 65nm as part of NUST's microprocessor project and successfully tested on a custom PCB.

## ISA Support

| Extension | Description |
|-----------|-------------|
| RV32I | Base integer instruction set |
| M | Hardware multiply/divide |
| A | Atomic instructions (LR.W, SC.W, AMO.W) |
| F | Single-precision floating point (PakFPU) |
| C | Compressed (16-bit) instructions |
| Zba | Address generation bit-manipulation |
| Zbb | Basic bit-manipulation |
| Zicsr | CSR instructions |
| Zifencei | Instruction-fetch fence |

## SoC Features

- **Pipeline**: 4-stage in-order (IF/ID → IE → IMEM → IWB) with full forwarding
- **Privilege modes**: M, S, and U with trap delegation (`medeleg`/`mideleg`)
- **Virtual memory**: Sv32 MMU with ITLB, DTLB, hardware page table walker, and A/D bit handling
- **Debug**: JTAG debug interface with halt/resume/single-step
- **Interrupts**: PLIC + CLINT (machine timer, software interrupts)

### Peripherals

| Peripheral | Base Address | Description |
|------------|-------------|-------------|
| CLINT | 0x02000000 | Core-local interruptor (mtime, mtimecmp, MSIP) |
| PLIC | 0x0C000000 | Platform-level interrupt controller |
| UART | 0x10000000 | Serial TX/RX with configurable baud rate |
| SPI | 0x10010000 | SPI master |
| I2C | 0x10020000 | I2C master (OpenCores-based) |
| GPIO | 0x10030000 | Bidirectional I/O with direction control |
| PWM | 0x10040000 | Dual-channel PWM with dead-time |
| Timer | 0x10050000 | Prescaler, compare, interrupt |
| CRC | 0x10060000 | Hardware LFSR-based CRC |

## Directory Structure

```
design/
  core/           Core pipeline
    alu/             ALU + MUL/DIV + Zba/Zbb
    core_top/        Top-level pipeline integration
    csr_unit/        CSR read/write/set/clear + privilege state
    hazard_unit/     Centralised stall/flush/trap logic
    mmu/             Sv32 MMU (ITLB, DTLB, PTW)
    amo_unit/        Atomic memory operations (LR/SC/AMO)
    fpu/             PakFPU single-precision floating point
    c_ext/           RV32C compressed instruction decoder
    forwarding_unit/ Data hazard forwarding
    stall_unit/      Structural hazard detection (bubble insertion)
    branch/          Branch comparator + target address
    interrupt/       Trap/interrupt controller
  uncore/         Peripherals (UART, SPI, I2C, Timer, GPIO, PWM, PLIC, CRC)
  interconnect/   Bus interconnect + address decoder
  memory/         Dual-port RAM
  debug/          JTAG debug module (DTM + DM)
  soc_top/        Top-level SoC integration
  common/         Shared headers: mem_map.svh, mem_map.h, mem_map.json
flows/
  simulation/     Verilator/Questa/Incisive simulation + Makefile
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
cd flows/simulation

# Full run + signature comparison summary
make riscof_run

# F-extension compliance suite + summary
make riscof_fpu_run

# Summary only (if riscof_work already exists)
make riscof_summary

# List tests without running
make riscof_testlist
```

Current status (non-PMP): **156/156 pass** (base), **495/495 pass** (with F-ext). PMP is not yet implemented.

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

### Profiles

| Profile | RAM Size | Description |
|---------|----------|-------------|
| **default** | 32 KB | Taped-out SoC (TSMC 65nm) |
| **riscof** | 16 MB | RISCOF compliance (vm_sv32 page tables need large RAM) |
| **linux** | 8 MB | Linux boot (kernel + rootfs) |

All profiles use unified RAM at `0x80000000` (code + data in one region).

### Default Address Map

| Region | Base | Size |
|--------|------|------|
| Boot ROM | 0x00001000 | 4 KB |
| CLINT | 0x02000000 | 64 KB |
| PLIC | 0x0C000000 | 32 MB |
| Tohost | 0x0F000000 | 4 B |
| UART | 0x10000000 | 4 KB |
| SPI | 0x10010000 | 4 KB |
| I2C | 0x10020000 | 4 KB |
| GPIO | 0x10030000 | 4 KB |
| PWM | 0x10040000 | 4 KB |
| Timer | 0x10050000 | 4 KB |
| CRC | 0x10060000 | 4 KB |
| RAM | 0x80000000 | profile-dependent |
