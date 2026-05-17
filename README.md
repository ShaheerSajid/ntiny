# ntiny — RV32IMACBSU SoC

A RISC-V SoC built around a single-issue, in-order 4-stage pipeline
core with Sv32 virtual memory. Taped out on TSMC 65nm as part of
NUST's microprocessor project and successfully tested on a custom PCB.

ntiny boots Linux 6.6 to a buildroot login prompt and Linux 7.0
through to busybox `/init`. Forty-plus bugs found and fixed during
bring-up are catalogued in [docs/bugs/](docs/bugs/index.html).

## ISA Support

| Extension | Description |
|-----------|-------------|
| RV32I    | Base integer instruction set |
| M        | Hardware multiply/divide |
| A        | Atomic instructions (LR.W, SC.W, AMO.W) |
| F        | Single-precision floating point (PakFPU) |
| C        | Compressed (16-bit) instructions |
| Zba/Zbb/Zbc/Zbs | Bit manipulation |
| Zicond   | Conditional move (`czero.eqz/nez`) |
| Sstc     | S-mode timer extension (`stimecmp`) |
| Zkr      | Entropy source (CSR `seed`) |
| Zicsr / Zifencei | CSR + i-fence baseline |

## SoC Features

- **Pipeline**: 4-stage in-order (IF/ID → IE → IMEM → IWB) with full forwarding
- **Privilege modes**: M, S, and U with trap delegation (`medeleg` / `mideleg`)
- **Virtual memory**: Sv32 MMU with ITLB, DTLB, HW page table walker, and A/D bit handling (Svadu)
- **Atomics**: full Zaamo + Zalrsc with reservation set in `amo_unit`
- **Debug**: JTAG debug interface with halt/resume/single-step
- **Interrupts**: PLIC + CLINT + S-mode timer (Sstc)

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
- RISC-V toolchain (bare-metal elf + Linux gnu); paths configured in `.env`
- Spike ISS (only needed for RISCOF reference); path in `.env`
- Python 3.10+ (for memory map generation and RISCOF)

### One-time setup

All tool paths live in `.env` at the repo root — `TOOLCHAIN_ELF`,
`TOOLCHAIN_LINUX`, `SPIKE_BIN`, `RISCOF_VENV`. Every Makefile and
helper script reads from there, so a single edit retargets the whole
repo. Defaults are tuned for this dev box; override per checkout if
your toolchains live elsewhere.

After cloning, run the bootstrap once:

```bash
./.init           # creates .venv/, installs riscof, clones arch-test
```

`.init` is idempotent — safe to re-run if the venv or the
`verification/riscof/riscv-arch-test/` clone gets nuked.

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

Current status (riscv-arch-test, latest tip): **225 PASS / 27 FAIL /
3 MISSING out of 255** tests. The historic 204/5 record stands — the
arch-test suite has since grown from 209 → 255 tests, so 22 of today's
27 failures are newer-suite cases that didn't exist at the original
verification milestone:
- 5 historic `misalign-l*/s*` (HW-vs-M-mode-trap-handler ABI mismatch,
  spec-permitted variants — see [reference_misalign_abi](docs/))
- 17 PMP-misalign extensions + sv32×PMP edge cases + vm_* corners
- 5 small CSR/trap-handler diffs (ecall, ebreak, cebreak,
  pmpzaamo_cfg_wr, pmps_none/pmpu_none)
- Zba+Zbb+Zbc+Zbs all pass

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
| **linux** | 128 MB | Linux boot (OpenSBI + kernel + initramfs) |

All profiles use unified RAM at `0x80000000` (code + data in one region).

## Linux

```bash
cd software/linux
make prepare              # one-time: clone + patch external/{linux,opensbi}
make build                # build kernel + opensbi + ram.hex
make run                  # launch verilator sim, stream uart.log

# Switch kernel version
make build LINUX_TAG=v7.0 LINUX_DIR=~/Downloads/linux-v7.0

# Build a release image with a specific cpio
make release VERSION=1.0
```

See [`software/linux/README.md`](software/linux/README.md) for details.

## Documentation

| Doc | What |
|-----|------|
| [docs/bugs/](docs/bugs/index.html) | Bug catalog with detail pages for recent fixes |
| [docs/linux_boot_process.md](docs/linux_boot_process.md) | Linux boot walkthrough (OpenSBI → kernel → init) |
| [docs/roadmap.md](docs/roadmap.md) | What's next: BPU re-enable, bus revamp, SMP |
| [docs/peripheral_standardization_plan.md](docs/peripheral_standardization_plan.md) | Phase 2 plan: refactor peripherals to upstream Linux IP layouts |
| [docs/bus_revamp_plan.md](docs/bus_revamp_plan.md) | Bus arbiter + write-back caches |
| [docs/multicore_plan.md](docs/multicore_plan.md) | SMP overlay (depends on bus revamp Phase 1) |
| [docs/privileged_architecture.md](docs/privileged_architecture.md) | Privilege spec implementation notes |

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
