# Tier 1 — next-steps tracker

Working branch for the items at the top of `docs/roadmap.md`. Each
section below lists exit criteria so a session can pick one up
without re-reading the entire roadmap. Order is the priority order
from `roadmap.md` — earlier items unblock later ones.

## 1. Bus revamp Phase 1 — multi-master arbiter with grants

**Status:** in progress per roadmap.

**Why first:** SMP-A, write-back caches (Phase 2), and the AXI
master path (Phase 3) all need a real multi-master bus underneath.
Today everything routes through `core_top`'s ad-hoc PTW / AMO / core
arbitration in `core_top.sv`.

**Exit criteria:**
- New `arbiter.sv` (round-robin or priority — see `bus_revamp_plan.md`) with `mem_bus[N]` slave inputs and one `mem_bus` master output.
- core_top stops doing inline `ptw_active ? ... : amo_active ? ... : core` muxing on `dmem_port`.
- All RISCOF + Linux 6.6/6.12/7.0 boots stay green.

## 2. Bus revamp Phase 2 — write-back L1I + L1D caches

**Why second:** Linux working set blows past 32 KB SRAM constantly.
Caches let the eventual DRAM tier work without per-access bus
latency. Also the precondition for SMP-B (MESI snoop bus).

**Exit criteria:**
- `icache.sv` + `dcache.sv` upgraded from current scaffolding to 4 KB / 4-way / 32 B / VIPT, write-back for D, write-through-no-allocate-on-miss for I.
- Cache-block CSRs added (Zicboz / Zicbom — also part of RVA22S64).
- Linux boots stay green; CoreMark / Dhrystone numbers improve.

## 3. Bus revamp Phase 3 — AXI4 master + DDR controller

**Why third:** unlocks both the Zybo Z7 FPGA bring-up (PS-DDR via
AXI HP) and the RV64-Linux-with-Debian story (working set in the
GBs). Also the dividing line between "embedded SoC" and
"application processor" in `roadmap.md`'s framing.

**Exit criteria:**
- AXI4 master interface adapter on the cache-miss path.
- DRAMsim3 DPI for sim; LiteDRAM (or Zynq PS-DDR for FPGA) for
  hardware.
- `mem_map.svh` gains a DRAM region (`0x80000000–0x9FFFFFFF` /
  512 MB working baseline).
- BootROM copies firmware from SRAM-resident flash image to DRAM
  and jumps; OpenSBI lives in DRAM.

## 4. RV64 parametrisation

**Why fourth:** Debian RV64 (the only general-purpose distro for
RISC-V) needs `XLEN=64`. Toolchain consolidation from this session
already gives a working `riscv64-unknown-linux-gnu` multilib, so
the blocker is purely RTL.

**Exit criteria:**
- `XLEN` parameter threads through `core_pkg.sv`, ALU, regfile,
  CSR storage, immediate sign-extension, branch_comp, fetch.
- MMU parametric on Sv32 ↔ Sv39: PTW level count, PTE width, ASID
  width.
- RV64A doublewords (`.D` AMO + LR/SC) in `amo_unit`.
- RISCOF runs both `rv32imafc_zba_zbb_zbc_zbs` AND `rv64imafdc`
  configs from the same tree.
- Linux boots a `rv64imafdc` defconfig at least to /init.

## 5. Real distro support (Debian RV64)

**Why fifth:** the visible end-of-Tier-1 milestone — the SoC runs a
real Linux distribution from a real disk.

**Exit criteria:**
- virtio-blk in DTS + Linux config; sim-side block device backed
  by a host file; FPGA-side eMMC/SD on Zybo.
- Switch root to `/dev/vda1` (sim) or `/dev/mmcblk0p1` (FPGA),
  ext4 partitioned `debian-ports/riscv64` rootfs.
- systemd or sysvinit boots; busybox demoted to /sbin/busybox for
  rescue.
- U-Boot or GRUB picks up kernel + initrd + cmdline from
  `/boot/extlinux/extlinux.conf` instead of the
  `fw_payload.bin`-embedded image.

## 6. RVA22 / RVA22S64 profile compliance

**Why sixth:** the formal target. Tells third-party software "yes,
ntiny runs your distro." Most of the missing bits are small
additions on top of (4) and (5).

| Extension | Notes |
|---|---|
| Zicbom / Zicbop / Zicboz | needed for caches; already on the Phase 2 cache plan |
| Zihintpause | trivial — decoder hook |
| Sscofpmf | counter-overflow IRQ for `perf` / kernel PMU |
| Svinval | finer TLB invalidation than `sfence.vma` |
| Svpbmt / Svnapot | page-based memory types + NAPOT page table entries |
| Smstateen | state-enable extension; gates other things |

**Exit criteria:** all of the above compile clean against the
defconfig + RISCOF gives a green RVA22S64 profile run (when the
suite supports profile flags).

## 7. Zybo Z7-20 FPGA bring-up (Tier 2 first item)

**Why parked here:** ntiny on Z7-10 over-utilises 2× LUT/FF (synth
report from this session). Z7-20 has ~3× the resources and
comfortably fits single-hart RV64 + L1 caches. Bus revamp Phase 3
is the prerequisite for *Linux* on FPGA (need DDR via AXI HP), but
a baremetal demo on Z7-20 BRAM is achievable today.

**Exit criteria (incremental):**
- `flows/synthesis/fpga/vivado/zybo_z7_20/` scaffold (mostly a
  copy of the existing `zybo_z7_10/` with the part + board_part
  swapped).
- Bitstream + baremetal hello on board (UART through Pmod JE,
  LEDs blinking on `gpio_o[3:0]`).
- (After bus Phase 3) Linux on FPGA via PS-DDR.

---

## Open items inherited from the previous session

These are loose ends from `main` that fit naturally into Tier 1
work and should be cleared as the relevant section lands:

- `sudo rm -rf /opt/riscv /opt/riscv-linux /opt/riscv_bitmanip`
  — frees ~8.6 GB; the new multilib trees at `/opt/riscv-elf` +
  `/opt/riscv-linux-gnu` cover both bare-metal and Linux. Awaiting
  user sudo (the bash sandbox can't run it).
- BPU re-enable (3 paths still tied off — IF / RAS / JAL). Sequenced
  fix plan in `project_bpu_reenable_plan` memory; lands cleanly any
  time after Phase 1 arbiter is in (avoids re-touching the same
  code while it's churning).
- Trigger Module match logic (CSRs already exist post-this-session
  — see `project_trigger_csr` if added). Adding match logic gives
  GDB hardware breakpoints; otherwise GDB falls back to software
  ebreak which already works.

---

## How to use this branch

Branch off `tier1-roadmap` per item; merge back when green:

```
git checkout tier1-roadmap
git pull
git checkout -b bus-phase1-arbiter
... work ...
git push origin bus-phase1-arbiter
# then PR / merge into tier1-roadmap

# When tier1-roadmap is fully green and ready to ship:
git checkout main && git merge --ff-only tier1-roadmap
git push origin main
```

Each commit on a sub-branch should pass: RISCOF green + Linux 6.6
+ 6.12 + 7.0 boots + Vivado synth (warning count not increasing).
