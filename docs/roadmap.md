# ntiny Roadmap

## Mission

ntiny is becoming a **full-blown RISC-V Linux application processor**, not
just an embedded microcontroller. The endgame is a **RV64GC SoC running a
real Debian/Ubuntu rootfs from disk**, deployed on a **Zybo Z7 FPGA board**
as the prototyping platform, and conformant to the **RVA22 / RVA22S64
profile** (the official RISC-V "Application Processor" profile that
mandates the ISA + privileged extensions a Linux distro can rely on).

The current ntiny state — RV32IMACBSU SoC, single hart, on-die SRAM only,
busybox initramfs — is the embedded *starting* configuration. Everything
in this roadmap is on the path to the application-class target.

A long-term ambition (Tier 4) is for the same RTL tree to emit either
configuration: an embedded RV32 microcontroller variant *or* an
application-class RV64 variant, configured by a single spec file.

Recent fixes are documented in [docs/bugs/](bugs/index.html).

## Done

| Group  | Item                                          | Where                                     |
|--------|-----------------------------------------------|-------------------------------------------|
| ISA    | RV32IMAC + Zba/Zbb/Zbc/Zbs/Zicond/Sstc/Zkr   | `design/core/alu/src/zba_zbb.sv` + decoder + DTS |
| RISCOF | 204 / 5 (5 misalign known fails)              | `flows/simulation/Makefile riscof_run`    |
| Linux  | 6.6 boot to login, 7.0 boot to /init          | `software/linux/Makefile`                 |
| Periph | GPIO + UART + I2C + SPI + PWM standardised to upstream IP layouts | `design/uncore/*` |
| Tape-out | TSMC 65nm, single hart RV32                | NUST microprocessor project               |

## In progress

| Group  | Item                                                  | Where                              |
|--------|-------------------------------------------------------|------------------------------------|
| BPU    | Re-enable IF / RAS / JAL prediction (currently tied off) | `design/core/branch/`           |
| Bus    | Phase 1: arbiter with grants                          | `design/interconnect/`             |

## Tier 1 — path to a usable Linux processor (current focus)

Three top-priority items, in order. Each unlocks the next.

### 1. Memory subsystem (DDR + caches) ★ HIGH PRIORITY

Without off-chip DRAM and a real cache hierarchy, ntiny is capped at
the on-die SRAM cliff (32 KB taped-out, 128 MB sim profile) — every
real Linux workload has its working set above that. The path:

1. Bus revamp Phase 1 — multi-master arbiter with grants. *(in progress)*
2. Bus revamp Phase 2 — write-back L1I + L1D caches (4 KB, 4-way,
   32 B lines, VIPT) behind the arbiter.
3. Bus revamp Phase 3 — AXI4 master at the cache miss path with a
   DRAM controller behind it. Sim uses DRAMsim3 via DPI; real
   silicon/FPGA uses LiteDRAM (or Zynq's PS-DDR for the Zybo bring-up
   — see Tier 2 below).
4. Memory map: add DRAM region (e.g. `0x80000000–0x9FFFFFFF` / 512 MB),
   PMP rules updated, BootROM copies firmware to DRAM and jumps.

See [bus_revamp_plan.md](bus_revamp_plan.md) for the full detail. ~6-10
sessions total.

### 2. RV64 parametrisation ★ HIGH PRIORITY

Most upstream RISC-V Linux software is **64-bit only**. The Debian
RISC-V port (the only general-purpose distro with broad package
coverage) ships RV64 only — RV32 was deprecated. So a "real Linux
processor" is RV64.

The work:

- **Pipeline** — datapath widths, immediate sign-extension, regfile
  storage, ALU operands all parametric on `XLEN`. Most of `core_pkg.sv`
  is already mechanically parametric.
- **MMU** — Sv32 ↔ Sv39 (or Sv48) parametric. PTW level count and
  PTE width are parameters. The biggest lift in the RV64 transition.
- **Atomics** — RV64A's `.D` (doubleword) variants in `amo_unit`.
- **CSRs** — `mhartid`, `mstatus` field encoding, `mtvec` alignment,
  PMP layout — all XLEN-dependent. `csr_unit` refactor.
- **Toolchain** — `riscv64-unknown-linux-gnu` alongside `riscv32`.
  OpenSBI is already XLEN-parametric.
- **Test infra** — RISCOF ACT for both RV32 and RV64. Linux RV64 defconfig.

~6-8 sessions. RV32 must keep building from the same tree (the
SoC-generator goal depends on it).

### 3. Real distro support (Debian RV64)

Replace the busybox initramfs with a real Linux distribution:

- **virtio-blk** as a block device (sim) → eMMC/SD on FPGA → real
  storage. Switch root to a partitioned filesystem (ext4).
- **Debian RV64 rootfs** from `debian-ports/riscv64`. Same boot
  artifacts as a real RISC-V SBC.
- **systemd or sysvinit** instead of busybox `/sbin/init`. Bash
  becomes the default user shell; busybox can stay for rescue.
- **U-Boot or GRUB** as the bootloader after OpenSBI, so kernel +
  initrd + bootargs come from `/boot/extlinux/extlinux.conf` and
  not from a hard-coded `fw_payload.bin` blob.

Once RV64 + DDR + virtio-blk are in, this becomes a (large but
tractable) integration step.

### 4. RVA22 / RVA22S64 profile compliance

The RISC-V "Application Processor" profile is the official certification
that says "this SoC can run a general-purpose Linux distro out of the
box." It mandates RV64GC plus a specific extension list:

| Extension | Status | What |
|-----------|--------|------|
| Zicbom / Zicbop / Zicboz | needed for caches  | cache-block management ops |
| Zihintpause              | trivial            | pause hint |
| Zicntr / Zihpm           | done               | counters |
| Sstc                     | done               | S-mode timer |
| Sscofpmf                 | needed             | counter-overflow IRQ for `perf` |
| Svinval                  | needed             | finer TLB invalidation |
| Svpbmt                   | needed             | page-based memory types |
| Svnapot                  | needed             | NAPOT page table entries |
| Smstateen                | needed             | state-enable extension |

Most are small additions on top of the work above. The point of
naming the profile: it's the formal target, and it tells third-party
software "yes, you can target ntiny like any other RISC-V SBC."

## Tier 2 — Zybo Z7 FPGA bring-up + SMP

### Zybo Z7 deployment

The Zybo Z7 (Zynq-7010 or Z7-20) is the prototyping platform. Plan:

- **Programmable Logic (PL)** — ntiny RTL goes here. Z7-20 has ~85K
  logic cells; should fit single-hart RV64 + L1 caches comfortably,
  dual-hart RV64 + L1 caches tightly, possibly with an L2 only on
  the bigger Zynq variants.
- **PS-DDR access** — Zybo's DDR3 is wired to the Zynq PS (Cortex-A9
  side). ntiny accesses it via the PS-PL **AXI HP** ports (high
  performance, 64-bit, four ports). This means **AXI is mandatory**
  for memory access on FPGA — Bus revamp Phase 3 is the prerequisite.
- **Peripherals** — UART, Ethernet (RGMII), SD card, HDMI, USB are
  all available. We can either use Zynq PS peripherals (talk via AXI
  GP) or instantiate our own in the PL. Initial bring-up should use
  PS peripherals for simplicity (UART for console, SD for rootfs);
  later phases move them to PL-side ntiny IP for an "ntiny-only" SoC.
- **Boot flow** — PS first-stage boot loads ntiny bitstream into PL
  via PCAP, then jumps to OpenSBI in PL-mapped memory. Or: load
  bitstream once at power-up, OpenSBI lives in DDR loaded by PS, ntiny
  fetches from DDR through AXI.

Specific things this adds vs the current sim flow:

- **Vivado synthesis flow** — `flows/synthesis/zynq/` with the .xpr
  project, constraint files, and bitstream gen scripts.
- **PS-PL AXI shim** — translate ntiny's bus to AXI4/AXI-Lite. Done
  by the bus revamp Phase 3 work; needs a Vivado IP wrapper.
- **Real bitstream timing closure** — Zynq-7020 PL runs comfortably
  at 50–100 MHz. Pipeline critical paths need to fit.

### SMP

After Zybo single-hart works, multicore. See
[multicore_plan.md](multicore_plan.md). Two flavours:

- **SMP-A** — N=2 with write-through D-cache (RAM is the architectural
  state, MESI not needed). Bus revamp Phase 1 only.
- **SMP-B** — N=2/4 with write-back L1D + MESI snoop bus. Tape-out
  grade. Depends on Bus revamp Phase 2.

For Zybo Z7-20: SMP-A is realistic at N=2. SMP-B is tight on the
smaller part, fine on the bigger one.

## Tier 3 — application-class peripherals + features

After the core SoC runs a real distro on FPGA, broaden the
peripheral set to match what desktop/server-class RISC-V SBCs ship:

- **Phase 5 peripherals** — watchdog, RTC, DMA, Ethernet (cdns,gem
  or LiteEth), USB device, TRNG, SD/eMMC, PMU. See
  [peripheral_standardization_plan.md](peripheral_standardization_plan.md)
  Phase 5 table.
- **Display** — framebuffer (VGA-class) → DRM/KMS (HDMI). Zybo Z7
  has HDMI tx pins on PL.
- **Audio** — I2S codec controller + ALSA bring-up.
- **Hypervisor (H)** — KVM-on-ntiny once we're stable; gates running
  guest OSes.
- **Vector (V)** — large area cost; revisit when the core has
  matured.
- **CLIC** — replace PLIC for finer-grained IRQ control once the
  application-class workload has shaped the requirements.

## Tier 4 — SoC generator (long-term finish line)

Same RTL tree, two emission targets:

- **Embedded variant** — RV32IMAC, single hart, ~32 KB SRAM,
  no MMU or simple Sv32, 5-7 peripherals. The current ntiny.
- **Application variant** — RV64GC + RVA22, multi-hart, write-back
  caches, AXI to DDR, full peripheral list, MMU Sv39/Sv48. The
  Tier 1-3 work above.

A single config file (TOML/YAML) describes the desired SoC:

```toml
[soc]
xlen = 64
harts = 2
cache_l1i = "4kb_4way_vipt"
cache_l1d = "4kb_4way_vipt_writeback"
mmu = "sv39"
profile = "rva22s64"

[peripherals]
ethernet = "cdns_gem"
storage = "sdhci_cadence"
display = "drm_hdmi"
usb = "dwc2_gadget"

[memory]
dram = { base = "0x80000000", size = "1G", controller = "litedram" }
```

The build emits a matching `soc_top.sv`, DTS, OpenSBI platform stub,
Linux defconfig, and Vivado project (or whatever target).

CI matrix tests both ends: every config in the matrix builds
RTL + DTS + Linux defconfig and boots a "hello world". The
configuration vocabulary should be simple enough that
"I want a 2-hart RV64 with Ethernet and an SD card" is a one-line spec.

## Out of scope here

- PMP RISCOF (5 misalign + 2 pmp-on-pte) — known false negatives
  per `reference_misalign_abi`
- RISCOF ACT-4 upgrade — independent of the Linux track
- PCIe root complex — too heavy for FPGA-class deployment; revisit
  if we ever get a successor tape-out