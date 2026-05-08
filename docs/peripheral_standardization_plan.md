# Peripheral Standardisation + Linux Integration Plan

Date: 2026-05-02
Author: Plan triggered by Linux 6.6 reaching buildroot login on ntiny —
next step is moving from "Linux + HVC console only" to a full SoC image
where every ntiny peripheral is a first-class Linux device.

## TL;DR

ntiny currently has 7 custom peripherals (UART, SPI, I2C, GPIO, PWM,
TIMER, CRC) with bespoke register layouts. Linux can only talk to them
via custom drivers we'd have to write and maintain ourselves.

This plan refactors ntiny's peripheral RTL to match register layouts of
well-known upstream Linux IPs. After the refactor the in-tree Linux
drivers bind directly to ntiny peripherals — we get sysfs GPIO,
`/dev/spidev*`, `i2cdetect`, `/dev/ttyS0`, hardware PWM, etc. for free,
without writing or maintaining a single line of kernel-driver code.

The trade-off: **every bare-metal driver under `software/drivers/` and
every bare-metal test under `software/tests/` must be updated in
lockstep with the RTL register changes.** RTL, bare-metal driver, and
bare-metal test are a single unit of work — they cannot land
independently. Per-peripheral RISCOF + bare-metal regressions gate each
step.

## Why standardise

| Path | Effort | Maintenance | Linux ecosystem |
|---|---|---|---|
| Custom RTL + custom kernel drivers | High one-time + ongoing | Forever | None — manual integration per subsystem |
| Custom RTL + UIO | Low | Low | Userspace only — no `/dev/spidev`, no sysfs GPIO, no kernel I2C bus |
| **Standardise RTL to upstream IP** | **High one-time** | **Zero ongoing kernel** | **Full — every Linux subsystem just works** |

We're early enough that the one-time RTL refactor is cheap relative to a
lifetime of maintaining custom drivers across multiple kernel versions.

## Target IPs

| ntiny peripheral | Target upstream IP | Linux driver | DT compatible | Why this target |
|---|---|---|---|---|
| UART | SiFive UART0 | `drivers/tty/serial/sifive.c` | `sifive,uart0` | RISC-V native, simple regs, clean Linux driver |
| GPIO | SiFive GPIO0 | `drivers/gpio/gpio-sifive.c` | `sifive,gpio0` | Direct sysfs GPIO + IRQ support |
| SPI | SiFive SPI0 | `drivers/spi/spi-sifive.c` | `sifive,spi0` | Same family, simple FIFO model |
| I2C | OpenCores I2C | `drivers/i2c/busses/i2c-ocores.c` | `opencores,i2c-ocores` | Tiny, academic-friendly, exact-match RTL is publicly available |
| PWM | SiFive PWM | `drivers/pwm/pwm-sifive.c` | `sifive,pwm0` | Same family |
| TIMER | merge into CLINT | (existing CLINT mtime) | — | We already have CLINT mtime; the peripheral TIMER is redundant |
| CRC | UIO only | none | `generic-uio` | Not a standard Linux concept; userspace mmap is the right answer |

All five SiFive IPs have clean, short reference implementations from
SiFive's open-source hardware repos (`sifive-blocks`) — the register
layouts and semantics are public.

## Phases

### Phase 1.5 — PLIC S-mode context (HARD PREREQUISITE, discovered 2026-05-02)

Discovered while booting Phase 1 DT: the PLIC HW + opensbi-platform.c
declare M-mode context only (`context_map [0] = {0,-1}`). Linux runs in
S-mode and crashes inside `plic_irq_enable+0x30` (NULL deref) the moment
any peripheral driver requests an IRQ — backtrace through
`request_threaded_irq -> __setup_irq -> irq_startup -> irq_enable ->
plic_irq_enable`.

This blocks the entire Phase 2 sequence — every Phase 2 step turns on a
peripheral driver that requests IRQs from the PLIC, and every one will
hit the same NULL deref until S-mode context is wired.

Required:
1. PLIC RTL: add S-mode context (its own enable/threshold/claim
   registers + S-mode external IRQ output line).
2. Core: route the PLIC's S-mode external IRQ to the SEIP bit
   (privilege_unit / interrupt_ctrl).
3. opensbi-platform.c: set `context_map [0] = { 0, 1 }` (M-mode ctx 0,
   S-mode ctx 1).
4. ntiny.dtsi: `plic { interrupts-extended = <&cpu0_intc 11>,
   <&cpu0_intc 9>; }` so the Linux PLIC driver registers both contexts.
5. Smoke test: an S-mode peripheral driver requests an IRQ without
   crashing.

Until this is done, Phase 1 ships peripheral DT nodes with
`status = "disabled"` so drivers don't probe and the kernel boots.

### Phase 1 — Devicetree scaffolding (low risk, ~1 session)

- Write `software/linux/ntiny.dtsi` describing every peripheral against
  its **target** layout. Drivers will probe; some will fail to bind
  cleanly (RTL doesn't match yet) — that's fine, it's the scaffold.
- Wire DT into OpenSBI build: `make FW_FDT_PATH=...` so `fw_payload.bin`
  carries the FDT and hands it to Linux at boot.
- Drop `CONFIG_SOC_VIRT=y` (was loadbearing only because it brought in
  the generic riscv platform); replace with explicit `CONFIG_OF=y` plus
  the driver Kconfigs we'll need:
  - `CONFIG_SERIAL_SIFIVE=y`, `CONFIG_SERIAL_SIFIVE_CONSOLE=y`
  - `CONFIG_GPIO_SIFIVE=y`
  - `CONFIG_SPI_SIFIVE=y`
  - `CONFIG_I2C_OCORES=y`
  - `CONFIG_PWM_SIFIVE=y`
  - `CONFIG_UIO_PDRV_GENIRQ=y` (for CRC)
- Verify Linux still boots to login. New peripherals' probe failures
  should be loud-but-non-fatal (look like "sifive,gpio0: probe failed,
  defer" in dmesg). HVC console still goes through SBI.

Deliverable: 1 PR with new dtsi + OpenSBI Makefile change + defconfig
update. No RTL changes yet.

### Phase 2 — Per-peripheral RTL refactor

Each peripheral is its own self-contained step. The RTL change, the
bare-metal driver under `software/drivers/<periph>/`, and the
bare-metal test under `software/tests/<periph>/` are **one unit of work
that lands as one commit** — they cannot be split. The structure is
identical for every peripheral:

1. Read upstream driver's `compatible` block to extract the canonical
   register layout (offsets, bit positions, FIFO behaviour, IRQ rules).
2. Refactor `design/uncore/<periph>/src/*.sv` to that layout. Update
   `<periph>_defs.sv` (the RTL `define block) to match.
3. Update `software/drivers/<periph>/<periph>_defs.h` (bare-metal
   register-offset header — must mirror `<periph>_defs.sv`) and
   `<periph>.c` / `<periph>.h` (bare-metal driver functions). This is
   non-optional: every existing bare-metal user breaks otherwise.
4. Update `software/tests/<periph>/<periph>_test.c` for any assertion
   that touched a specific register address, bit position, or behaviour
   that changed.
5. Run RISCOF (sanity, regression baseline) + the peripheral's
   bare-metal test (functional check on the new layout).
6. Run Linux: confirm the matching kernel driver now binds cleanly and
   the device is functional from userspace.
7. Add a userspace smoke test in initramfs (e.g. `gpioset`/`gpioget`,
   `spidev_test`, `i2cdetect`, `pwm-tool`).

Order — smallest layout to biggest, biggest functional impact first
inside that constraint:

| # | Peripheral | RTL effort | Bare-metal touch | Linux signal |
|---|---|---|---|---|
| 2a | **GPIO**  | small  | minor  | `/sys/class/gpio` works |
| 2b | **UART**  | medium | medium | `/dev/ttyS0` + drop HVC dependency |
| 2c | **I2C**   | medium | medium | `i2cdetect`, slave devices appear |
| 2d | **SPI**   | medium | medium | `/dev/spidev0.0` + flash MTD |
| 2e | **PWM**   | small  | minor  | `/sys/class/pwm` works |

Each step ≈ 1-2 sessions. GPIO first because it's the simplest layout
change and gives us the loudest Linux signal (sysfs gpio appearing).

UART is intentionally not first: while the SiFive UART layout swap
itself isn't huge, dropping the HVC console + switching the
earlycon/console path is touchy. Worth doing once a couple of other
peripherals are landing cleanly so we have confidence in the DT plumbing.

### Phase 3 — Cleanup

- Drop the redundant peripheral TIMER from RTL (CLINT covers OS tick).
- Wire CRC to UIO with `compatible = "generic-uio"` + `interrupts =`.
- Remove the OpenSBI `ntiny-uart` console driver once `sifive,uart0`
  drives `/dev/ttyS0` and is wired as the primary Linux console.
- Drop `CONFIG_HVC_RISCV_SBI` from defconfig.

### Phase 4 — Bonus / future

- **MTD on SPI flash** (`m25p80` driver) → `/dev/mtd0` for storage.
- **Network**: ntiny has no MAC today; if/when we add one, target
  `xilinx_emaclite` or write a Cadence MACB-compatible block.
- **RNG**: wrap `rng_seed.sv` as `timer-iomem-rng` for kernel entropy.
- **Real RTC**: optional; today we use jiffies + CLINT.

## Per-peripheral checklist template

When taking on phase 2x for any peripheral:

- [ ] Read upstream driver source — note exact register offsets, bit
      positions, FIFO depths, IRQ semantics.
- [ ] Diff vs current ntiny RTL — list every register/bit that moves.
- [ ] Update RTL (`design/uncore/<periph>/src/*.sv` + `_defs.sv`).
- [ ] Update bare-metal driver (`software/drivers/<periph>/`).
- [ ] Update bare-metal test (`software/tests/<periph>/`) — both
      register offsets AND any expected behaviour that changed.
- [ ] Verilator lint clean.
- [ ] Bare-metal test passes.
- [ ] RISCOF still 204/5 (no core regressions from the RTL touch).
- [ ] DT node in `ntiny.dtsi` matches the new layout.
- [ ] Kernel boots; `dmesg | grep <periph>` shows successful probe.
- [ ] Userspace smoke test from initramfs.
- [ ] Commit with full before/after register-map diff in the message.

## Validation / regression strategy

Three layers, run on every Phase 2 step:

1. **RISCOF** (M-mode, no peripheral access) — proves we didn't break
   the core during the RTL touch. Single peripheral test runs only;
   never batch ([feedback_single_test.md], [feedback_use_makefile.md]).
2. **Bare-metal peripheral test** — proves the new register layout works
   end-to-end at the metal.
3. **Linux probe + userspace smoke** — proves the upstream driver binds
   cleanly to our RTL.

A peripheral is "done" only when all three pass.

## Risks

- **Bare-metal/Linux drift.** Forgetting to update a bare-metal test
  alongside RTL leaves a quiet false-pass. Mitigation: the per-step
  checklist forces a bare-metal test re-run every time.
- **Layout subtleties.** Upstream IP behaviour is sometimes subtler than
  the register map suggests (FIFO half-full vs almost-full thresholds,
  TX-empty vs TX-idle for HW handshake, glitch-free vs glitchy CS in
  SPI). Mitigation: read driver source, not just the "datasheet"
  comment header.
- **Console regression mid-flight.** When we move console from HVC to
  ttyS0 in step 2b we might briefly lose visibility. Mitigation: keep
  HVC console and earlycon=sbi as fallback until ttyS0 is verified, then
  drop in a separate cleanup commit.
- **SoC tape-out implications.** Register layout changes shift the
  software contract. Anyone with code that already hits a hard-coded
  register offset (firmware, demos, eval-board examples) needs updating.
  Mitigation: do this *before* freezing the next tape-out version.

## Deferred decisions

- Should we keep the custom UART around as an "ntiny-debug-uart" with
  HVC behind it for early-bringup of new tape-outs? Probably yes — the
  custom UART is small and the SiFive UART pulls in more gates.
- Should I2C support 10-bit addresses? `i2c-ocores` does, but our
  current I2C IP is 7-bit only. Decide before refactoring 2c.
- TIMER drop: do we keep one custom mmio timer for non-OS uses (e.g.
  watchdog), or rely entirely on CLINT? Lean: drop it; add a separate
  watchdog peripheral later if needed.

## Tracking

Each phase 2 step is its own commit + memory update. Use commit prefix
`peripherals: <name>: standardise to <upstream>`.

This plan supersedes the "Phase 2 — write custom kernel drivers" branch
of `docs/roadmap.md`.

## Phase 5 — peripherals ntiny doesn't yet have

Phases 1–3 standardised everything that was already on the SoC. The
next round adds peripherals ntiny doesn't have today, picking only
those with a stable upstream Linux DT binding so we keep the
"ntiny is just another RISC-V SoC" posture.

| Peripheral       | Upstream binding                                | Why |
|------------------|-------------------------------------------------|-----|
| Watchdog         | `sifive,fu540-c000-wdt` or `riscv,sbi-srst`     | Protect against runaway init; `wdtctl` works |
| RTC              | `dallas,ds1307` (i2c) or `sifive,clic-rtc`      | Wall-clock across reboots; `hwclock` works |
| DMA              | `snps,axi-dma-1.01a` or `xilinx,axi-dma-1.00.a` | Offload memcpy / slave-IO; Linux dmaengine |
| Ethernet MAC     | `cdns,gem` (Cadence GEM) or `litex,liteeth`     | Networking; iproute2 works out of the box |
| USB device       | `dwc2,gadget` or `chipidea,usb2`                | USB serial / gadget; Linux gadget framework |
| TRNG             | `timeriomem-rng` or `sifive,fu740-c000-rng`     | Replace jitterentropy fallback |
| SD / eMMC        | `sdhci-cadence` or `microchip,sdhci-mvebu`      | Block storage |
| PMU              | `sifive,fu540-c000-pmu`                         | Hardware perf counters → `perf` |

Sequencing matches the Phase 2 cadence (one commit per peripheral):
RTL refactor + bare-metal driver + Linux DT enable land in lockstep,
verified by both a bare-metal test and a Linux self-test entry.

Out of this round but worth flagging:

- **AXI / AXI-Lite interconnect** — current bus is custom. Switching
  to AXI gets us free interop with vendor IP (DMA, Ethernet, USB)
  without per-peripheral plumbing, and is a precondition for any
  significant peripheral expansion. Tracked in
  [bus_revamp_plan.md](bus_revamp_plan.md).
- **PCIe root complex** — too heavy for ntiny's footprint; revisit
  for a successor SoC.
