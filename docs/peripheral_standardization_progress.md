# Peripheral Standardisation — Progress + Remaining Plan

Companion to `docs/peripheral_standardization_plan.md`. That document
describes the *strategy*; this one tracks *current state* and lays out
the remaining moves in concrete RTL/driver detail.

## Status (2026-05-04)

| Peripheral | Target IP | Status | Commits |
|---|---|---|---|
| GPIO | `sifive,gpio0` | **DONE** end-to-end (Linux sysfs gpio works) | `e940915` |
| UART | `sifive,uart0` | RTL + bare-metal + DT done; verifying with `/dev/ttyS0` | (in flight) |
| I2C  | `opencores,i2c-ocores` | RTL + bare-metal + DT done; verifying with `/dev/i2c-0` | (in flight) |
| SPI  | `sifive,spi0` | NOT STARTED — full Xilinx → SiFive rewrite required | — |
| PWM  | `sifive,pwm0` | NOT STARTED — full custom → SiFive rewrite required | — |
| TIMER| (drop) | Pending Phase 3 | — |
| CRC  | `generic-uio` | DT node present but `disabled`; flip in Phase 3 | — |

Pre-requisite work completed alongside the per-peripheral phases:

- `9e5b11a` Phase 1 — DT scaffolding + driver Kconfigs
- `cdb887b` Phase 1.5 — PLIC dual-context (M+S) + SEIP HW signal so
  any peripheral driver can request an IRQ without crashing
- `3d90c06` core fix — `pc_for_async` used `branch_target_address` on
  T→NT mispredict; now uses `branch_recovery_target`. This was the
  layout-sensitive boot-hang in `kernfs_name_hash` exposed by Phase 2a's
  cpio shift.

## Phase 2c follow-up — Linux i2c-ocores enablement debug

The RTL refactor in `256d66f` is correct (verified by bare-metal
peek/poke). DT keeps `status = "disabled"` because flipping it to
`"okay"` triggers a kernel-side bug in init:

- LEGACY_PTYS=y baseline → `Unable to handle kernel access to user
  memory ... at virtual address 00000004 ... epc :
  get_page_from_freelist+0x18e/0xb3c`. NULL deref at offset 4 of a
  zero pointer (likely a NULL `struct zone *` or freelist pointer
  inside the PCP fast path).
- LEGACY_PTYS=n variant → silent sysctl hang: 188 M sim cycles of
  pure kernel idle with zero U-mode samples. Userspace process called
  a syscall and never returned.

Static audit done so far (rules out the obvious culprits):

- **i2c.sv RTL is quiescent after probe**: at reset ctrl=0 ⇒
  s_core_en=0 ⇒ cmd writes are gated off, byte_controller stays in
  ST_IDLE, cmd_ack stays 0, irq_flag stays 0, interrupt_o stays 0.
  Driver writes ctrl=EN=0x80 last; bit 6 (IEN) is never set during
  probe, so even if irq_flag were set, the qualified output stays 0.
- **PLIC wiring is correct**: `sources_i[3] = i2c_interrupt`,
  matching DT `interrupts = <4>` (PLIC source 4).
- **i2c-ocores driver flow looks vanilla**: ioremap + clk_get +
  request_irq + ocores_init (read-modify-write ctrl, set prelo/prehi,
  IACK, enable) + i2c_add_adapter. No DMA, no shared resources.
- **Bare-metal driver works** with the new RTL (peek/poke + functional
  test pass).

Strongest remaining hypothesis: same layout-sensitive HW bug class
that bit kernfs_name_hash earlier this session. Enabling the I2C node
(a) shifts kernel BSS/data layout (just by registering another
platform device's worth of allocations), (b) i2c_add_adapter does
substantial kobject / kernfs activity that exercises slab allocator
fast paths — exactly the kind of code that the page-aliasing bug
class corrupts unpredictably.

Plan for next debug session:

1. Collect a tighter trap probe with sync-fault filtering and
   register-window snapshot at the moment of NULL deref.
2. With that, identify the stale PA being read, then check whether
   it's part of a kernel buddy/pcp structure that lives at a PA
   recently written-to by another agent (PTW Svadu writeback, AMO
   reservation, etc).
3. If yes, this is a fresh manifestation of the kernel-user page
   aliasing class — and worth a targeted RTL fix in `core_top.sv` /
   `amo_unit.sv` rather than DT-level workarounds.

Until then Phase 2d (SPI) and Phase 2e (PWM) can proceed. Their RTL
refactors are independent and won't regress on the I2C kernel issue.

## Phase 2d — SPI standardisation (`sifive,spi0`)

**Scope:** the existing ntiny SPI uses a Xilinx-style register layout
(DGIER / IPISR / IPIER / SRR / CR / SR / DTR / DRR / SSR). The SiFive
SPI0 layout is fundamentally different, so this is a near-complete
RTL rewrite of `design/uncore/spi/src/spi.sv` and `spi_defs.sv`.

### Target register map (drivers/spi/spi-sifive.c)

| Offset | Reg | Purpose |
|---|---|---|
| 0x00 | sckdiv | clock divisor: bits[11:0] |
| 0x04 | sckmode | bit0 = CPHA, bit1 = CPOL |
| 0x10 | csid | active CS index (0..ncs-1) |
| 0x14 | csdef | one bit per CS line, default level |
| 0x18 | csmode | 0=AUTO, 2=HOLD, 3=OFF |
| 0x28 | delay0 | bits[7:0] cssck, bits[23:16] sckcs |
| 0x2c | delay1 | bits[15:0] intercs, bits[31:16] interxfr |
| 0x40 | fmt | bits[1:0] proto, bit2 endian, bit3 dir, bits[19:16] len |
| 0x48 | txdata | write data; bit31 = TX-full on read |
| 0x4c | rxdata | read data; bit31 = RX-empty |
| 0x50 | txmark | TX watermark threshold |
| 0x54 | rxmark | RX watermark threshold |
| 0x60 | fctrl | bit0 = enable memory-mapped flash mode |
| 0x64 | ffmt | flash command + address layout |
| 0x70 | ie | bit0 = txwm enable, bit1 = rxwm enable |
| 0x74 | ip | bit0 = txwm pending, bit1 = rxwm pending |

### RTL plan

1. Drop the entire current `spi.sv` body (Xilinx-style FSM).
2. Reuse the existing serial-shift core — it works at the bit level
   regardless of register layout — but rewrap with the SiFive register
   set above.
3. Single CS line (ntiny has one slave_select_o pin) — keep `csdef`,
   `csmode` minimal (AUTO + HOLD only). `csid` is a 1-bit field.
4. Watermark interrupts replace the Xilinx-style separate IPISR/IPIER —
   simpler, fewer registers.
5. Drop memory-mapped flash mode (`fctrl` / `ffmt`) for Phase 2d. They
   stay RAZ/WI; flash boot via SPI is a long-tail feature not needed
   for a tape-out test chip.

### Address slice in `soc_top.sv`

Currently `spi_addr = dmem_bus.addr[7:0]` (8 bits, byte address).
SiFive layout reaches up to 0x74 — same 8-bit slice covers it. Keep.

### Bare-metal driver (`software/drivers/spi/`)

Existing API: `spi_init / spi_transfer / spi_cs / ...`. Keep the API
surface; rewrite the implementation against the new register set.
Update `spi_test.c`'s peek/poke walker to test the SiFive R/W
registers (sckdiv, sckmode, csid, csdef, fmt, txmark, rxmark, ie).

### Bare-metal test impact

Existing tests reference DGIER/IPISR/IPIER/SRR/CR — all of those
disappear. The functional loopback test (CPOL/CPHA × MOSI/MISO) can be
preserved structurally, just retargeted at the new fmt register.

### DT binding flip

```
spi@10010000 {
    compatible = "sifive,spi0";
    reg = <0x10010000 0x1000>;
    interrupt-parent = <&plic>;
    interrupts = <3>;
    clocks = <&soc_clk>;             /* 50 MHz, no lying needed for SPI */
    #address-cells = <1>;
    #size-cells = <0>;

    /* spidev for direct userspace SPI access — used by self-test */
    spidev@0 {
        compatible = "linux,spidev";
        reg = <0>;
        spi-max-frequency = <1000000>;
    };
};
```

### Verification

- Bare-metal `spi_test` peek/poke + loopback at 100 kHz / 1 MHz.
- Linux `dmesg | grep sifive_spi` shows clean probe.
- `/dev/spidev0.0` appears in self-test → `spi.driver PASS`.
- Optional: spidev_test loopback pattern.

### Estimated effort

~4-6 hours of focused RTL + driver work. Roughly 2× the GPIO refactor
because the Xilinx-style code being replaced is larger and the SiFive
SPI has more registers than the SiFive GPIO.

## Phase 2e — PWM standardisation (`sifive,pwm0`)

**Scope:** the existing ntiny PWM has a 4-output dual-channel layout
(pwm1_h, pwm1_l, pwm2_h, pwm2_l) with deadtime + complementary-redundant
modes. The SiFive PWM is a different model — single counter, multiple
compare channels driving independent outputs.

### Target register map (drivers/pwm/pwm-sifive.c)

| Offset | Reg | Purpose |
|---|---|---|
| 0x00 | cfg | bits[3:0] scale, bits[8] sticky, bit[9] zerocmp, bit[12] enalways, bit[13] enoneshot, bits[31:28] cmp{0,1,2,3} centered/gang/ip |
| 0x08 | count | free-running 31-bit counter, low bits |
| 0x10 | s | scaled count value (= count >> scale) |
| 0x20 | cmp0 | 16-bit compare value, channel 0 |
| 0x24 | cmp1 | channel 1 |
| 0x28 | cmp2 | channel 2 |
| 0x2c | cmp3 | channel 3 |

Single counter. A pwm channel asserts low until the counter hits its
cmp value, then high until rollover. Each cmp also generates an IRQ.

### RTL plan

1. Drop `pkg_pwm_decodes.sv` and the dual-channel + deadtime + invert
   logic. We lose the deadtime feature in this transition.
2. Implement a single 31-bit free-running counter (cnt) gated by `cfg.enalways`.
3. Implement 4 compare channels driving 4 outputs:
   - `pwm_cmp0_o`, `pwm_cmp1_o`, `pwm_cmp2_o`, `pwm_cmp3_o`
   - Each is a registered output, low while `cnt < cmp`, high otherwise.
4. SoC top: keep two output pins (pwm1_h, pwm2_h — wire to cmp0, cmp1).
   The other two compare channels (cmp2, cmp3) terminate inside the
   SoC for now (or become future expansion pins).
5. Drop deadtime + complementary modes. For motor-control use we'd
   re-add them as a custom extension (phase 2e+ext).

### Address slice in `soc_top.sv`

Currently `pwm_addr = dmem_bus.addr[7:2]` (6-bit word index). SiFive
PWM reaches 0x2c = word 11 — fits in 6 bits.

### DT binding flip

```
pwm@10040000 {
    compatible = "sifive,pwm0";
    reg = <0x10040000 0x1000>;
    interrupt-parent = <&plic>;
    interrupts = <0>, <0>, <0>, <0>;   /* 4 IRQs, currently unwired */
    clocks = <&soc_clk>;
    #pwm-cells = <3>;
};
```

PWM has 4 IRQs in the SiFive binding (one per compare channel). Our
RTL today doesn't wire any PWM IRQs through PLIC. Two options:
- (a) Wire 4 new PLIC sources (RTL change in soc_top + bigger PLIC
  NUM_SOURCES). Best long-term.
- (b) Declare `interrupts = <0>` (none) and rely on poll mode in the
  driver. Simpler for Phase 2e first cut.

Going with (b) for the initial commit. (a) becomes a follow-up.

### Verification

- Bare-metal `pwm_test`: program cmp0 = 0x4000, cmp1 = 0x8000 with
  scale=0, observe duty cycles on pwm_cmp0/1.
- Linux `/sys/class/pwm/pwmchip0` appears.
- `echo 0 > /sys/class/pwm/pwmchip0/export` then `period`/`duty_cycle`
  /`enable` from sysfs.

### Estimated effort

~3-5 hours. Less than SPI because the SiFive PWM is simpler (one counter
+ 4 compares, no FIFOs, no protocol layer). The dual-channel deadtime
feature loss is the main user-visible cost.

## Phase 3 — Cleanup

Already detailed in the parent plan; for completeness, the concrete
bullet list of remaining work after 2d + 2e:

1. **Drop the redundant TIMER peripheral.** `design/uncore/timer/` and
   its DT node. CLINT mtimer covers the OS tick. Bare-metal code that
   uses the peripheral TIMER (delay loops) needs migrating to
   `mtime`-based waits.
2. **Wire CRC to UIO.** Flip `crc@10060000` to `status = "okay"`. CRC is
   a custom IP with no upstream Linux driver target; userspace mmaps it
   via `/dev/uioN`.
3. **Retire OpenSBI's `ntiny-uart` console driver** once `/dev/ttyS0`
   is stable. Drop `CONFIG_HVC_RISCV_SBI` from defconfig and the SBI
   put/get hooks from `software/linux/opensbi-platform/platform.c`.
   Until then the system has a redundant 2-console setup (HVC + ttyS0)
   which is fine but a little weird.
4. **Drop the "lying clock" trick for UART** if/when we figure out a
   cleaner way to make the SiFive driver compute the right `div`. The
   trick is documented inline in `ntiny.dts` and in this doc; not a
   blocker but a smell.
5. **GPIO 32-IRQ matrix expansion.** Currently only `gpio[1:0]` are
   IRQ-capable in PLIC. The SiFive GPIO driver's `ngpio` follows the
   IRQ count, so Linux only sees 2 GPIO pins. To expose all 32 we need
   to wire 32 PLIC sources from the GPIO `interrupt_reg[31:0]`. Bigger
   PLIC, more IRQ enable bits.
6. **Refcount warnings during pty_init.** With `LEGACY_PTYS=n` they may
   already be gone — verify after the next clean boot. If still
   present, dig into `tty_class` initialisation order on RV32 minimal
   config.

## Phase 4 (bonus / long-tail, not on the critical path)

- MTD on SPI flash (`m25p80` driver, requires our SPI to support flash
  command sequencing — which the SiFive `fctrl`/`ffmt` regs do, but we
  stubbed those in 2d).
- DMA hooks on UART/SPI/I2C (none of the upstream SiFive drivers expose
  DMA today; would need a custom DMA controller too).
- Ethernet MAC. ntiny has none today; future addition. Target
  `cdns,macb` (Cadence MACB-compatible) — well-supported in Linux.
- True RTC. Currently jiffies + CLINT. Adding an RTC peripheral is
  quality-of-life only.

## Phase 5 — IEEE / industry-standard peripheral migration (long-term)

The SiFive + OpenCores targets we're moving to in Phase 2 are
upstream-Linux-friendly but are still **vendor-specific register
layouts**, not industry standards. The longer-term direction is to
migrate again to peripherals whose register layouts ARE the actual
industry/IEEE specs, so any OS (not just Linux) recognises them and
COTS reference firmware works without modification. Concrete moves:

| Peripheral | Current target (Phase 2) | IEEE / industry target | Linux compat impact |
|---|---|---|---|
| UART | `sifive,uart0` | NS16550/8250-compatible (`ns16550a`) | Wider (every OS has a 16550 driver — Linux, BSD, U-Boot, EDK2, FreeRTOS, …). Drops the SiFive-specific lying-clock hack. |
| SPI | `sifive,spi0` | DesignWare APB SPI (`snps,dw-apb-ssi`) or PL022 | DesignWare is in every embedded SoC; PL022 is the ARM Primecell standard. Both have richer register sets but well-documented industry specs. |
| I2C | `opencores,i2c-ocores` | OpenCores i2c-ocores IS an industry-tracked open spec already; this stays. Alt: SMBus-compliant Designware I2C (`snps,designware-i2c`). | OpenCores was the right pick; SMBus designware is heavier but covers SMBus extensions. |
| GPIO | `sifive,gpio0` | Generic `linux,gpio-mmio` (the lowest-common-denominator) | Wider compatibility but loses SiFive's IRQ matrix; we'd need to drop to a poll-mode model or rebuild IRQ wiring around IEEE-style "single composite GPIO IRQ + status register". |
| PWM | `sifive,pwm0` | No IEEE std; closest is `pwm-mmio-generic` (kernel >=6.0). | Vendor lock-in is the SiFive cost; generic mmio has fewer features. |
| TIMER | (drop) | (n/a) | n/a |
| Ethernet MAC | (n/a today) | IEEE 802.3 + Cadence MACB or DW EQOS | Industry standard MACs come with full IEEE 802.3 framing. |
| JTAG / Debug | RV-debug spec (already standard) | IEEE 1149.1 / 1149.7 | Already aligned. |

**Why not IEEE-first from day one?** The Phase 2 SiFive targets are a
*much* smaller RTL refactor (each peripheral is 200-500 LOC of register
decode), and prove the end-to-end Linux-driver-binding flow with
minimum risk. Phase 5 is bigger because each industry-spec target has
considerably more registers, more side-effects, and stricter timing
guarantees:

- `ns16550a` UART: 12 registers including 2 shadow banks selected by
  DLAB, FIFO threshold programming, modem-control lines. ~3-4× the
  Phase 2b SiFive UART RTL.
- `snps,dw-apb-ssi` SPI: ~30 registers including DMA channels,
  programmable burst length, slave select polarity, etc.
- `snps,designware-i2c`: SMBus protocols, DMA, hardware filtering.

Each Phase 5 step gets its own focused session, lands as one commit,
and **deprecates the corresponding Phase 2 target** by retiring the
sifive,*/opencores,* compat string. Bare-metal drivers + tests and the
boot self-test all migrate alongside.

**Cross-cutting cleanup needed first:**
- Bus arbiter that issues true grant signals to MMIO masters
  (`docs/bus_revamp_plan.md` Phase 1) — eliminates the response-leak
  bug class that has bitten us before. Phase 5 IPs typically have
  more concurrent state (FIFOs + DMA), making bus correctness more
  load-bearing.
- 32-IRQ matrix expansion (Phase 3 cleanup, listed above) — many
  IEEE-std peripherals have more interrupts per device.
- A standard clock controller node so all the peripherals can declare
  proper input clocks (drops the "lying clock" UART workaround
  permanently).

**Order:** Phase 2 (SiFive/OCores) lands first → Phase 3 cleanup →
**Phase 5 only after Phase 4 has stabilised the SoC integration**. The
gap between Phase 4 and Phase 5 may be measured in tape-out cycles
(this is a longer-term direction, not a near-term sprint).

## Order of operations summary

1. Land Phase 2b + 2c (UART + I2C) — IN FLIGHT, this session.
2. Open Phase 2d (SPI) as a focused session — biggest single
   refactor remaining.
3. Phase 2e (PWM).
4. Phase 3 cleanup pass — done as one consolidated commit per item.
5. Phase 4 items pulled in as actually needed.
