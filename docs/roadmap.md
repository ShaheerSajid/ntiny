# ntiny Roadmap

ntiny boots Linux 6.6 to the buildroot login prompt and Linux 7.0
through to busybox `/init`. Recent work is documented in
[docs/bugs/](bugs/index.html).

## Done

| Group  | Item                                          | Where                                     |
|--------|-----------------------------------------------|-------------------------------------------|
| ISA    | Zba + Zbb + Zbc + Zbs + Zicond + Sstc + Zkr   | `design/core/alu/src/zba_zbb.sv` + decoder + DTS |
| RISCOF | 204 / 5 (5 misalign known fails)              | `flows/simulation/Makefile riscof_run`    |
| Linux  | 6.6 boot to login, 7.0 boot to /init          | `software/linux/Makefile`                  |
| Periph | GPIO + UART + I2C + SPI + PWM standardised to upstream IP layouts | `design/uncore/*` |

## In progress

| Group  | Item                                                  | Where                              |
|--------|-------------------------------------------------------|------------------------------------|
| BPU    | Re-enable IF / RAS / JAL prediction (currently tied off) | [project_bpu_reenable_plan](../README.md) |
| Bus    | Phase 1: arbiter with grants ([bus_revamp_plan.md](bus_revamp_plan.md) §1) | `design/interconnect/`        |

## Next

| Group  | Item                                                              | Cost          |
|--------|-------------------------------------------------------------------|---------------|
| Periph | Phase 3 cleanup — drop redundant TIMER, wire CRC to UIO, retire HVC, fix bare-metal TEST_TEMPLATE | 1 session    |
| Random | MMIO RNG: wrap `rng_seed.sv` as `timeriomem-rng` peripheral       | 1 session     |
| BPU    | BHT (256 × 2-bit), BTB (16-32 entry), RAS (4-8 entry) at IF       | 4 sessions    |
| Bus    | Phase 2: write-back L1I/L1D caches (VIPT)                         | 4 sessions    |
| SMP    | N=2 multicore overlay ([multicore_plan.md](multicore_plan.md))    | per phasing   |
| Trap   | CLIC replacement for PLIC                                         | post-BPU      |

## Out of scope here

- PMP RISCOF (5 misalign + 2 pmp-on-pte) — known false negatives
  ([reference_misalign_abi memory](../README.md))
- RISCOF ACT-4 upgrade — independent of this plan

## Long-term direction — toward an ntiny SoC generator

The endgame is to turn ntiny into a configurable SoC generator: a user
specifies the features they need (XLEN, ISA extensions, peripheral
list, hart count) and the build produces a synthesisable RTL bundle
plus a matching software stack.

The phasing below is the rough order of work to get there.

### Tier 1 — broaden the existing RV32 SoC

Goal: ntiny RV32 is a comfortable Linux platform with the peripherals
real boards need.

- **Phase 5 peripherals** — watchdog, RTC, DMA, Ethernet, USB device,
  TRNG, SD/eMMC, PMU. See
  [peripheral_standardization_plan.md](peripheral_standardization_plan.md)
  Phase 5 table. Each lands as RTL + bare-metal driver + DT enable
  in one commit, matching Phase 2 cadence.
- **More RISC-V extensions for Linux**
  - **Zicboz / Zicbom** — cache-block management instructions; needed
    once we add caches in bus revamp Phase 2.
  - **Smstateen / Sscofpmf** — state-enable + counter overflow
    interrupts; gates Linux's modern PMU integration.
  - **Sscofpmf + Sstc** — finer-grained S-mode control; Sstc already
    landed.
  - **Hypervisor (H)** — long-term for KVM-on-ntiny demos. Big lift.
  - **Vector (V)** — out of scope while we're CPU-area-bound on 65nm,
    revisit on a successor process node.
- **Bus revamp Phase 2** — write-back L1I/L1D caches (4 KB, 4-way,
  32 B lines, VIPT). [bus_revamp_plan.md](bus_revamp_plan.md). The
  AXI/AXI-Lite migration in Phase 3 is what unlocks vendor-IP reuse
  for the Phase 5 peripherals.

### Tier 2 — multicore (SMP)

Goal: ntiny boots Linux SMP with `nr_cpus=2`, then `nr_cpus=4` after
the RAM/L2 question is resolved.

See [multicore_plan.md](multicore_plan.md). Two sub-plans:

- **SMP-A** — N=2 with the existing write-through D-cache (no MESI
  needed; RAM is the architectural state). Bus revamp Phase 1
  arbiter is the only hard prerequisite.
- **SMP-B** — N=2/4 with write-back L1D + MESI snoop bus. Tape-out
  grade. Depends on bus revamp Phase 2.

### Tier 3 — RV64 parametrisation

Goal: same RTL, single `XLEN` parameter, builds either RV32 or RV64.

- **Pipeline** — datapath widths, immediate sign-extension,
  register-file storage, ALU operands all parametric on `XLEN`.
  Most of this is already mechanically parametric in `core_pkg.sv`;
  the actual hard work is rebuilding test infrastructure (RISCOF
  ACT, bare-metal tests, Linux defconfig) for both widths.
- **MMU** — Sv32 ↔ Sv39/Sv48 parametric. Page-table walker generic
  over level count. PTE width parameter. Bigger lift.
- **Atomics** — RV64A adds the `.D` (doubleword) variants of LR/SC
  and AMO ops. amo_unit gains a width parameter.
- **CSRs** — mhartid, status MSB encoding, mtvec alignment all
  XLEN-dependent. csr_unit refactor.
- **Toolchain** — riscv64-unknown-linux-gnu in addition to riscv32.
  Linux defconfig switch. OpenSBI is already XLEN-parametric.

### Tier 4 — SoC generator

Goal: a config file (TOML/YAML) describes the desired SoC; build
emits matching RTL + DTS + software headers + memory map.

Pieces needed:

- **Configuration schema** — XLEN, ISA extension set, hart count,
  peripheral list (with addresses + IRQs), cache geometry, MMU
  variant.
- **RTL emitter** — currently we have a lot of `+define+` /
  parameter cascades; the generator picks the right values and
  emits a top-level `soc_top.sv` that instantiates only what's
  configured.
- **DTS generator** — already done at peripheral granularity by
  hand; the generator stitches enabled peripheral nodes into a
  full DTS.
- **Memory map generator** — already exists at
  `scripts/gen_mem_map.py`; extend it to take the config and
  produce `mem_map.json` automatically.
- **Software glue** — bare-metal CRT, OpenSBI platform, Linux
  defconfig, and `mem_map.h` all derived from the config.
- **CI** — every config in a matrix builds + boots a "hello world"
  bare-metal test. RV32-only, RV64-only, and SMP variants gate the
  release.

This is multi-quarter work and is the natural finish line for ntiny
as a research/teaching SoC. The configuration vocabulary should be
simple enough that "I want a 2-hart RV64 with Ethernet and PCIe" is
a one-line spec.
