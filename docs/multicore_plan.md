# Multicore (SMP) Conversion Plan

Date: 2026-05-06
Status: Draft for later execution. No code yet.

This is the fleshed-out version of `bus_revamp_plan.md` Phase 4
("coherence + multicore — LONG TERM"). It depends on Phases 1–2 of
that plan and is sequenced against them — read `bus_revamp_plan.md`
first.

## TL;DR

- ntiny is single-hart-baked-in but most pipeline state (PMP, MMU,
  CSRs) is already per-core. The hard parts are: bus fabric, AMO/LR-SC
  reservation, CLINT/PLIC fan-out, OpenSBI HSM, and (once caches land)
  cache coherence.
- The **bus revamp Phase 1 arbiter is a hard prerequisite**. Without
  per-master grant signals, replicating cores on the current static
  priority mux re-creates the AMO/PTW response-leak bug across harts.
- **Coherency strategy depends on whether caches are write-through
  (today) or write-back (post-revamp Phase 2):**
  - If SMP lands **before** revamp Phase 2 → coherence-by-RAM is free
    (D-cache already bypasses itself on read), only need a
    bus-snooping reservation tracker for LR/SC.
  - If SMP lands **after** revamp Phase 2 → write-back caches require
    a real MESI snoop protocol or a shared L2 with directory.
- Recommendation: **SMP-before-Phase-2** is the cheap path to a
  Linux SMP boot. SMP-after-Phase-2 is the right answer for
  tape-out-grade silicon. Do both, in that order, as separate
  sub-plans M.A and M.B below.
- Hart count: parameterise N from the start, validate at N=2 first.
  The dual-port RAM macro caps useful performance near N=2 — N=4 needs
  a banked RAM or an L2.

---

## A. Survey findings

### A.1 What's already SMP-ready

| Subsystem | Where | Status |
|-----------|-------|--------|
| PMP CSRs | `csr_unit.sv:587-606` | Per-core. No change needed. |
| MMU + TLB + PTW | `mmu_sv32.sv` | Per-core. SFENCE is local, IPI shootdown is SW. |
| Privilege state (M/S split, deleg, sstatus, satp, etc.) | `csr_unit.sv` | Per-core. |
| Sstc (`stimecmp`) | `csr_unit.sv` | Per-core — kernel ticks don't fight for shared CLINT mtimecmp. |
| PLIC `NUM_CONTEXTS` parameterisation | `plic_rv.sv:24,102` | Already parametric, but ctx_e/ctx_c are 1-bit picks (line 62, 64) — must widen for >2 contexts. |
| `mip[9]` SEIP composition | `csr_unit.sv:555,584,619` | Already ORs ext IRQ in per-core. |

### A.2 What's single-hart-baked-in

| What | Where | Severity |
|------|-------|----------|
| `mhartid = 32'h0` literal | `csr_unit.sv:562` | trivial |
| No `hart_id_i` port on core_top | `core_top.sv:5-47` | trivial |
| CLINT 1× msip + 1× mtimecmp | `clint.sv:37-39` | medium |
| PLIC ctx_e/ctx_c are 1-bit selectors | `plic_rv.sv:62,64` | medium |
| Single-master mem_bus, no arbitrating fabric | `buses.sv`, `soc_top.sv:51-52` | **HIGH — addressed by revamp Phase 1** |
| Reservation lives inside `amo_unit`, no bus snoop | `amo_unit.sv:41-43,170-186` | **HIGH** |
| Dual-port RAM (1 R + 1 RW) | `ram_dp.sv` | **HIGH — caps perf at ~2 harts** |
| OpenSBI `hart_count=1`, no HSM ops | `platform.c:90,102,167` | medium |
| DTS one cpu, no cpu-map, no per-hart intc | `ntiny.dts:55-75` | medium |
| Tracer hardcodes `hart_id_i=0` | `tb_tracer.sv:113` | low |
| tohost monitor on `dmem_bus`, not per-hart | `tb_soc_top.v:172-187` | low |

### A.3 Bus revamp interactions (the new section)

The following items in `bus_revamp_plan.md` directly affect this plan:

- **Phase 1 (arbiter with grants)** — the right shape for an
  N-master interconnect already. The original multicore draft
  proposed a separate `dmem_arbiter.sv`; that's redundant with the
  revamp's `dmem_arb`. **Use the revamp's arbiter, widen its master
  count from 3 to (3·N).** Per-hart masters are core2avl, amo_unit,
  PTW; with N=2 that's 6 masters on the dmem arbiter.
- **Phase 1 audit checklist** items (`core2avl + PTW race`, `iPTW +
  fetch race`, `Misaligned access split during PTW`, `AMO during
  sfence`) — every one of these becomes harder under SMP because
  remote-hart traffic is a new pre-emption source. The audit must
  be completed *before* SMP enable.
- **Phase 2 (write-back L1I/L1D, VIPT)** — fundamentally changes
  coherency. Reservation tracking moves from "snoop the RAM port" to
  "live at the cache line, killed by MESI invalidation."
- **Phase 2 reservation-at-line-granularity** — already designed for
  cache eviction. Extending to "killed by remote-hart snoop" is a
  small delta on top of the revamp's design.
- **Phase 3 (AXI/DRAM)** — orthogonal to multicore. A bigger memory
  doesn't change hart count. Boot stub stays at low addr, just need
  to confirm hart 1's reset PC also lands in BootROM not DRAM.
- **Phase 4 (coherence + multicore)** — that's this document.

---

## B. Two sub-plans

The right sequencing depends on what the user wants first: a Linux
SMP demo, or a tape-out-grade SMP design.

### B.M.A — "Cheap SMP" — runs Linux SMP without write-back caches

Targets: Linux 2-hart boot to userspace, `nr_cpus=2`, IPI working.
Prerequisite: bus revamp Phase 1 (arbiter w/ grants) only. Phase 2
(caches) NOT required.

This works because today's D-cache (`dcache.sv:82-86`) **already
bypasses itself on reads** — every load goes to RAM. With write-
through stores, RAM is the architectural state. Two harts hitting the
same RAM port through the arbiter see a coherent memory by
construction. The only correctness gap is LR/SC reservations, which
need a bus-snooping tracker.

### B.M.B — "Tape-out SMP" — write-back caches + MESI snoop

Targets: production silicon with N=2 (or N=4 with banked RAM/L2).
Prerequisite: bus revamp Phase 2 (write-back L1I/L1D) plus this
plan's coherence overlay.

Needs: per-line MESI state in L1D, snoop bus between L1Ds, snoop-
invalidate as a reservation kill source, write-allocate refill that
participates in coherence.

---

## C. The full integrated phasing

Each phase is sized to a single commit per the user's
peripheral-standardisation cadence (RTL + SW + test together).

### C.0 — Pre-work that overlaps revamp Phase 0/1

These can land alongside the bus revamp without committing to SMP:

**M.0.a — Hartid as a port (revamp-independent, NUM_HARTS=1)**
- `core_top` gets `input [31:0] hart_id_i`.
- `csr_unit.sv:562` reads from that port instead of literal 0.
- `soc_top.sv` ties `hart_id_i = 32'h0`.
- DV tracer takes `hart_id_i` from the core.
- Linux boot regression. RISCOF must stay 204/5.

**M.0.b — Reservation hoist out of `amo_unit` (revamp Phase 0/1
companion)**
- New module `design/uncore/reservation_set/src/resv_set.sv`. For N=1
  it's behaviourally identical to today (one hart, reservation killed
  by local SC, local flush, or remote stores — the latter is a no-op
  with N=1).
- `amo_unit.sv` keeps its FSM but the resv register and snoop logic
  move out. `amo_unit` consumes `sc_match_i` from the new module.
- This integrates well with revamp Phase 1: the reservation tracker
  watches **post-arbiter store traffic from the dmem_arb's slave
  side**, not each master's outgoing stream. That way it sees
  exactly the stores that committed.
- LR/SC bare-metal regression. Linux boot regression.

### C.1 — Revamp Phase 1 happens (or completes)

**M.1 — Use the revamp's `dmem_arb` as the multi-hart fabric**
- `dmem_arb` is built per `bus_revamp_plan.md` Phase 1 with three
  master slots (core2avl, amo_unit, PTW).
- Generalise its master count: replace the fixed 3-master interface
  with `parameter NUM_MASTERS`, instantiate as `3*NUM_HARTS` when SMP
  lands. For N=1 it's still 3 masters.
- Hold-grant: when an AMO wins grant for AMO_READ, the arbiter must
  hold the grant through the AMO_WRITE in the next cycle (or the
  next granted access leaks). This is the multi-hart equivalent of
  the AMO/PTW interlock the user already debugged.
- Same hold-grant requirement for PTW's PTE-read → A/D-write
  sequence (Svadu). With one hart this is trivial; with two harts
  it's the load-bearing interlock for cross-hart PTW correctness.
- The revamp's audit checklist items (core2avl+PTW race, misaligned
  splits, AMO during sfence) **must be cleared at this phase** — they
  become reproducible bugs once a second hart pre-empts.

### C.2 — Pre-SMP RTL parametrisation, NUM_HARTS=1

**M.2.a — Wrap core in generate, vectored interrupts**
- `soc_top.sv` core instantiation goes inside
  `generate for (genvar h=0; h<NUM_HARTS; h++)` block.
- All per-hart wires become `[NUM_HARTS]` vectors: MEIP, SEIP, MTIP,
  MSIP. For N=1 these are 1-element vectors.
- Linux boot regression.

**M.2.b — CLINT vectored**
- Rewrite `clint.sv` storage as `logic msip [NUM_HARTS]`,
  `logic [63:0] mtimecmp [NUM_HARTS]`. mtime stays scalar (system-
  wide per RISC-V spec).
- Address decode: `0x0000 + 4*h` → msip[h]; `0x4000 + 8*h` →
  mtimecmp[h]; `0xBFF8` → mtime.
- Outputs become vectored `[NUM_HARTS]` for timer_irq_o / soft_irq_o.
- N=1 regression: identical observable behaviour.

**M.2.c — PLIC widened**
- `NUM_CONTEXTS` becomes `2*NUM_HARTS`.
- `ctx_e` / `ctx_c` extraction (`plic_rv.sv:62,64`) widens from 1-bit
  picks to `$clog2(NUM_CONTEXTS)` slices.
- Per-context outputs: flat `[NUM_CONTEXTS]` vector internally,
  fanned out per-hart in `soc_top.sv` to MEIP/SEIP per hart.
- Gateway-lock arbitration (`plic_rv.sv:83-94`) already handles
  contention between contexts — verify with N=2 testbench.
- N=1 regression: identical observable behaviour.

### C.3 — Reservation-set bus-snooping prep

**M.3 — `resv_set` snoops post-arbiter store stream**
- Inputs per hart: `lr_set_i, lr_addr_i, sc_query_i, sc_addr_i,
  sc_clear_i`.
- Output per hart: `sc_match_o`, `resv_kill_remote_o` (debug).
- Snoop input: post-arbiter `store_addr, store_valid` (after
  `dmem_arb` grants the master).
- For each hart, kill its reservation if `store_valid && store_addr
  matches reserved line && grant_owner != self`.
- For N=1 the kill condition `grant_owner != self` is always false
  for own stores. Behaviourally identical to today.
- Granule: word address (matches today's `resv_addr == addr_i`
  comparison in `amo_unit.sv:85`). Spec allows ≥4B granule.
- Note: this is the SMP-A path. For SMP-B (write-back caches) the
  reservation moves into the L1D — see C.7.

### C.4 — Flip NUM_HARTS=2 in sim

**M.4.a — RTL flip**
- `soc_top.sv` parameter default → 2.
- TB `tb_soc_top.v` rebuilds with NUM_HARTS=2.
- Tohost monitor: watch the post-arbiter slave bus, not per-hart.
- Tracer: `tb_tracer.sv` becomes a generate loop, one instance per
  hart, separate log files (`logs/trace_h0.log`, `logs/trace_h1.log`).
- Per-hart UART logging: prefix `[h0]/[h1]` based on which hart wrote
  TXDATA, or split into separate files.
- New TB probe — **AMO contention probe**: log every (LR.W, hart,
  addr, cycle) and (store, hart, addr, cycle). Checker flags
  unexpected SC successes/failures. Required because the
  `xas_load`-class livelocks (single-hart, 88M cycles per
  `core_top.sv:2614`) become more reproducible with 2 harts.

**M.4.b — Boot stub + OpenSBI HSM**
- Boot stub (in BootROM source — likely
  `flows/simulation/testbench/bootmem.v` or its hex generator):
  prefix with `csrr a0, mhartid; bnez a0, park`. Park loop:
  `1: wfi; csrr t0, mip; andi t0, t0, MIP_MSIP; beqz t0, 1b; j _start`.
- `software/linux/opensbi-platform/platform.c`:
  - `mswi.hart_count = 2`
  - `mtimer.hart_count = 2`
  - `plic.context_map[1] = { 2, 3 }`
  - `platform.hart_count = 2`
  - HSM ops: rely on OpenSBI's default ACLINT-MSWI HSM if
    `aclint_mswi_cold_init(&mswi)` is already called; else add
    `.hart_start = ntiny_hart_start`.
- `software/linux/ntiny.dts`:
  - Add `cpu1: cpu@1 { ... }` mirror of cpu0 with `cpu1_intc`.
  - Add `cpu-map { cluster0 { core0 { cpu = <&cpu0>; }; core1 { cpu
    = <&cpu1>; }; }; }` under `cpus`.
  - CLINT `interrupts-extended` adds `<&cpu1_intc 3>, <&cpu1_intc 7>`.
  - PLIC `interrupts-extended` adds `<&cpu1_intc 11>, <&cpu1_intc 9>`.
  - `riscv,ndev` stays 6.
- Bare-metal verification, in order:
  1. **Boot release**: hart 0 writes msip[1], hart 1 wakes from WFI
     in park loop, increments a counter, halts.
  2. **CLINT IPI ping-pong**: harts trade msip writes, count to N.
  3. **AMO contention**: both harts increment a shared counter via
     LR/SC loop, expect final = 2·N_iter, no corruption.
  4. **PLIC IPI/contention**: peripheral source toggles, both contexts
     enabled, exactly one claim wins.
  5. **OpenSBI HSM** cold boot: hart 0 reaches `final_init`, sends
     MSWI to hart 1, hart 1 returns from WFI into HSM resume path.

### C.5 — Linux SMP boot (sub-plan SMP-A complete)

**M.5.a — Boot to login shell**
- Kernel rebuild with `CONFIG_SMP=y`, `CONFIG_NR_CPUS=2`. Verify the
  current kernel's `ntiny_defconfig` accepts SMP without other deps.
  Linux 6.6 RV32 SMP works (FU540-class).
- Bootargs: `nr_cpus=2`.
- Expected `dmesg`:
  - `CPU0` and `CPU1` come online
  - At least one IPI exchanged (rcu, scheduler)
  - Userspace reaches login

**M.5.b — Workload**
- `dd if=/dev/zero of=/dev/null bs=1M count=100 &` ×2. Both harts
  contribute CPU time per `top`. Shakes scheduler IPIs.

**M.5.c — Stress**
- `find / -type f | xargs cat > /dev/null` on both harts. Hits RCU,
  slab, page allocator. **The xas_load livelock at 88M cycles
  single-hart manifests differently with 2 harts** — keep the AMO
  contention probe armed.
- 1B-cycle soak with no oops = SMP-A complete.

### C.6 — Bus revamp Phase 2 (caches) lands

This is the bus revamp's own work. Reference
`bus_revamp_plan.md` Phase 2 for the L1I/L1D design (4 KB, 4-way,
32 B lines, VIPT, write-back + write-allocate, reservation at line
granularity).

**The crucial multicore implication**: once L1D is write-back, RAM
is no longer the coherence point. Two harts each with their own
write-back L1D will silently diverge unless coherence is added.

If SMP-A is already running when Phase 2 lands, **SMP must be
disabled for the duration of the cache integration**. Otherwise the
combination produces silent data corruption that is extremely hard
to debug (each hart's view of memory is internally consistent, only
inter-hart shared state diverges).

### C.7 — SMP-B coherence overlay on the new cache hierarchy

**M.7.a — MESI snoop bus**
- Each L1D adds 2 bits per line for MESI state (M=modified,
  E=exclusive, S=shared, I=invalid).
- A snoop bus carries: refill addr (read miss), writeback addr
  (eviction), invalidation request (write to S line).
- Snoop responses: each L1D reports whether it has the line and in
  what state.
- For N=2 a snoop bus is appropriate. For N>4 a directory at L2 is
  more scalable — out of scope.
- The "snoop the post-arbiter store stream" approach from SMP-A is
  retired here — coherence is enforced at the L1D, not at the RAM
  port.

**M.7.b — Reservation moves into L1D**
- LR.W: brings line into L1D in E state, sets reservation =
  {valid, line_addr}.
- SC.W: success iff reservation valid && line still in cache && in
  E or M state. Returns the line to M.
- Reservation killed by:
  - Local trap / xRET / local flush_i (matches today's behaviour)
  - Cache eviction of the reserved line (covers most natural
    progress requirements)
  - Snoop invalidation from another hart (the SMP correctness
    case — another hart's write to the same line forces local
    invalidation, which kills the reservation)
- This is exactly the design `bus_revamp_plan.md` §"Atomic semantics
  with cache" sketches; the multicore extension is just adding the
  third kill source.

**M.7.c — Forward progress**
- Spec requires LR/SC to make forward progress. With MESI snoops,
  two harts in a tight LR/SC loop on the same line can ping-pong
  invalidations and make zero progress. Mitigations:
  - Implementation-defined "reservation hold window" — a hart that
    just executed LR holds the line in E state for K cycles before
    snoops can downgrade it. K=8 is typical.
  - Bounded retry: if a hart's SC fails N times, hardware exception
    or back-off counter. Linux RCU + atomics testing reveals this
    quickly.

**M.7.d — Snoop-induced reservation kill regression**
- TB probe from M.4.a's AMO contention probe extends to log snoop
  events. Verify reservation is killed exactly when expected:
  remote-hart store to the reserved line.
- Stress test: both harts run `for(;;) atomic_inc(&shared)` for 1B
  cycles. Final count = 2 × per-hart loop count, no lost updates.

### C.8 — Optional N=4 (post tape-out)

**M.8 — Banked RAM or L2 cache**
- The dual-port RAM (`ram_dp.sv`) caps useful performance near N=2.
  For N=4: either bank the RAM (4 banks × 2 ports each, addressed
  by hash of physical addr bits) or add a unified L2 (per
  `bus_revamp_plan.md` Phase 2 optional extension).
- L1 MESI snoop scales fine to N=4 on a shared bus — the bottleneck
  is the RAM port, not the snoop.
- DTS, OpenSBI, kernel config bump to N=4.
- Out of scope for first SMP tape-out.

---

## D. Risks specific to ntiny

1. **AMO/PTW/bus race relapse (cross-hart variant)**. The user spent
   88M cycles debugging the single-hart `xas_load` livelock — root
   cause was AMO consuming PTW's rvalid (`amo_unit.sv` history,
   `core_top.sv:2576-2640`). The bus revamp Phase 1 fixes the
   architectural cause via grant signals. **Adding a second hart
   pre-empting through the same arbiter is a new pre-emption
   source**: hart 0's AMO_READ wins grant; hart 0 PTW completes
   between AMO_READ and AMO_WRITE; hart 1's AMO wins next grant;
   bus state machine has handed off twice in three cycles. Mitigation:
   (a) revamp Phase 1's hold-grant for AMO RMW is mandatory; (b)
   add an assertion on the arbiter: `assert(rvalid[h] |->
   last_grant_when_request_accepted == h)`.

2. **BPU + variable IF latency**. The user has multiple BPU race
   memories (`project_bpu_*`). With two harts contending the imem
   arbiter, fetch latency becomes variable. Any BPU update path that
   assumed steady IF cadence may desync. Mitigation: re-audit
   `bpu.sv` and `core_top.sv:328-345` for IF-latency assumptions.
   Pre-SMP, run a single-hart Linux boot with **artificial IF stall
   injection** (random stalls of 1-3 cycles) to model arbiter
   back-pressure.

3. **MMU/Svadu PTE A/D race across harts**. RISC-V spec requires
   A/D updates atomic to other accesses to the same PTE. With two
   MMUs both doing Svadu and a shared RAM port, the arbiter must
   hold the grant across the PTE read → A/D write pair, OR Svadu must
   be disabled in SMP and Linux falls back to SW A/D. **Conservative
   first cut: disable Svadu (`menvcfgh.ADUE=0`) for SMP-A**, re-enable
   in SMP-B once L1D + MESI handles PTE coherence cleanly (PTW reads
   PTEs through L1D, MESI handles the cross-hart conflict). This
   simplification gets Linux SMP up faster.

4. **Page-aliasing class bugs amplify under SMP**. The
   `kernel-user page aliasing` memory shows latent bugs around
   PA 0x80cf0470 with kernel `__memcpy` writing through an alias.
   Two harts double the kernel allocator pressure → these bugs
   become reproducible per boot rather than intermittent. Mitigation:
   keep the existing page-write probes armed for SMP bring-up. If a
   latent bug fires, **prioritise root-causing it** (per the user's
   "Proper Fix Always" feedback) rather than tuning around it.

5. **AMO during cross-hart sfence**. Bus revamp audit item: AMO
   in flight when sfence arrives doesn't currently abort because
   `amo_unit.flush_i` only sees `interrupt_valid`. With two harts,
   hart 0's sfence (now a remote IPI flushing hart 1's TLB) can
   coincide with hart 1's AMO. The reservation must survive the
   sfence (sfence doesn't change addresses, only TLB) but the
   AMO bus transaction must not get confused if hart 1 takes the
   IPI mid-RMW. Mitigation: extend `amo_unit.flush_i` to include
   IPI-driven trap entry; verify with a unit test (TB-injected IPI
   during AMO loop).

6. **Boot stub source unclear**. The hart-1 park-loop prefix needs
   to land somewhere — likely
   `flows/simulation/testbench/bootmem.v` or its generator. Pin
   this down in M.4.b before flipping NUM_HARTS=2.

7. **Tape-out RAM topology cap**. Dual-port SRAM macro caps useful
   performance near N=2. **For N>2, the silicon plan needs a banked
   RAM or an L2.** This is a synthesis-side question, not RTL —
   but worth aligning with whoever owns the floorplan before
   committing to N>2 in synthesis.

8. **CLIC ordering**. CLIC is on the post-Linux roadmap
   (`docs/roadmap.md:46`) and replaces PLIC entirely.
   Do **not** bundle CLIC with SMP — too much test surface.
   Recommended order: SMP-A → CLIC (single-hart) → SMP-B with
   coherent caches → CLIC across harts. PLIC fan-out infrastructure
   added in M.2.c is wasted when CLIC arrives, but the cost is one
   commit's worth of refactoring vs. the verification risk of
   landing both at once.

9. **DV tracer scaling**. Per `project_dv_tracer_extension.md` the
   user already plans a tracer upgrade. Per-hart tracer files at
   M.4.a should align with that effort — coordinate to avoid
   double-rework.

---

## E. Verification matrix (consolidated)

| Phase | Gate | Test |
|-------|------|------|
| M.0.a | RISCOF 204/5 | Existing |
| M.0.a | Linux 6.6 boot | Existing |
| M.0.b | LR/SC bare-metal | New unit test |
| M.0.b | Linux boot regression | Existing |
| M.1   | Bus revamp Phase 1 audit checklist clear | Per `bus_revamp_plan.md:298-316` |
| M.2   | All above still pass at NUM_HARTS=1 | Existing |
| M.4.a | Tracer per-hart logs | New TB feature |
| M.4.b | Boot release | New bare-metal test |
| M.4.b | CLINT IPI ping-pong | New bare-metal test |
| M.4.b | AMO contention | New bare-metal test, AMO probe armed |
| M.4.b | PLIC contention | New bare-metal test |
| M.4.b | OpenSBI HSM cold boot | New SBI test |
| M.5.a | Linux SMP boot to login | `nr_cpus=2` |
| M.5.b | 2-hart workload | dd ×2, top shows balance |
| M.5.c | 2-hart stress | find/cat ×2, 1B-cycle soak |
| M.5.c | QEMU comparison | Same `initramfs.cpio` on `qemu -smp 2`, diff dmesg |
| M.7   | MESI snoop reservation kill | New TB probe |
| M.7   | Atomic-counter stress | 1B-cycle, no lost updates |
| M.7   | Linux SMP-B boot | Same as M.5 with caches enabled |

---

## F. Open questions for the user

1. **SMP-A first, or wait for SMP-B?** SMP-A gets a Linux SMP demo
   in ~6 commits, SMP-B is tape-out-grade but requires bus revamp
   Phase 2 to land first. My recommendation: SMP-A first as a
   demonstrator + verification harness, SMP-B for silicon.
2. **Target hart count for next tape-out**: 2 or 4? RTL will be
   parametric; silicon caps at N≈2 without RAM banking or L2.
3. **CLIC ordering**: SMP-A → CLIC → SMP-B is my recommendation.
   Acceptable?
4. **Svadu in SMP-A**: disable for first cut (SW A/D fallback) and
   re-enable in SMP-B with cache-coherent PTE access? Or invest in
   the arbiter atomic-RMW grant-hold to keep Svadu live in SMP-A?
5. **Boot stub source**: which file holds the BootROM hex? (Need
   for M.4.b to add the hartid park-loop prefix.)
6. **`ntiny_defconfig` SMP-readiness**: does the current Linux 6.6
   build flip `CONFIG_SMP=y` cleanly, or do other dependencies need
   pulling in?
7. **DV tracer alignment**: should M.4.a's per-hart tracer integrate
   with the planned `project_dv_tracer_extension` work, or land
   independently?

---

## G. Critical files (where work lands)

Primary:
- `design/soc_top/src/soc_top.sv` — generate-loop wrap, vectored intc fan-out
- `design/core/amo_unit/src/amo_unit.sv` — resv hoist
- `design/core/csr_unit/src/csr_unit.sv:562` — mhartid wiring
- `design/uncore/clint/src/clint.sv` — vectored msip/mtimecmp
- `design/uncore/plic/src/plic_rv.sv` — wider ctx_e/ctx_c
- `design/interconnect/dmem_arb.sv` (NEW, from bus revamp Phase 1)
  — widen master count to 3·NUM_HARTS
- `design/uncore/reservation_set/src/resv_set.sv` (NEW)
- `software/linux/opensbi-platform/platform.c` — hart_count, context_map, HSM
- `software/linux/ntiny.dts` — cpu1, cpu-map, intc fan-out
- BootROM source (TBD, likely `flows/simulation/testbench/bootmem.v`)
  — hart-1 park-loop prefix

Secondary:
- `flows/simulation/testbench/tb_soc_top.v` — tohost monitor on
  arbiter slave bus
- `flows/simulation/testbench/tb_tracer.sv` — generate per hart
- `design/core/include/core_pkg.sv` — NUM_HARTS, vectored typedefs
- `design/memory/src/dcache.sv`, `icache.sv` — MESI extension (SMP-B
  only, after bus revamp Phase 2)

For SMP-B (post bus revamp Phase 2):
- L1D MESI state, snoop bus — design from scratch on top of revamp
  Phase 2 cache RTL
