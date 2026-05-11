# OoO core v1 — design spec

Date: 2026-05-11
Status: M0 — skeleton

This document is the long-running spec for the ntiny out-of-order core.
It mirrors the role `docs/bus_revamp_plan.md` plays for the Tier-1 bus
work — milestones, design decisions, and follow-ups live here so a
future session can pick up without re-reading the whole codebase.

## TL;DR

A classical Tomasulo (per-FU reservation stations + ROB) RV32 core,
1-wide fetch/dispatch/retire, bare-metal, built side-by-side with the
existing in-order core so the in-order core remains the regression
oracle.

## Scope (v1)

### ISA
- **RV32IMFB**
  - I — base integer
  - M — mul/div
  - F — single-precision FP (reuse `design/core/fpu/PakFPU/`)
  - B — Zba + Zbb + Zbc + Zbs (reuse `design/core/alu/{zba_zbb,zbs,clmul}.sv`)
- **No A** — no AMO, no LR/SC. LSQ stays simple.
- **No C** — no compressed. Fetch is 32-bit aligned, no boundary logic.
- **No D** — double-precision deferred.

### Privilege / system
- **M-mode only.** No S/U. No MMU. No PMP for v1.
- Trap support: mstatus / mtvec / mepc / mcause / mtval / mscratch.
- ecall / ebreak / illegal-instr / misaligned exceptions.
- Interrupts: mie / mip + a CLINT-driven timer + machine software irq.
- mret returns to M-mode.

### Memory
- Physical addressing only — no translation.
- Same `mem_bus` (OBI-style req/ready/rvalid) interface as the in-order
  core, so the existing SoC top can swap cores by parameter.

## Microarchitecture

### Pipeline
```
 ┌──────┐  ┌────────┐  ┌──────────────┐  ┌────────────────┐  ┌─────────────┐  ┌────────┐
 │ Fetch│→ │ Decode │→ │ Rename +     │→ │ Issue (RS      │→ │ Execute     │→ │ Commit │
 │ (+BP)│  │        │  │ Dispatch     │  │ wake-up + sel) │  │ (FU array)  │  │ (ROB   │
 │      │  │        │  │ → ROB + RS   │  │                │  │ → CDB       │  │ retire)│
 └──────┘  └────────┘  └──────────────┘  └────────────────┘  └─────────────┘  └────────┘
                                                                   │  ▲
                                                                   ▼  │
                                                                 CDB broadcast → wakes RS
```

### Sizing — v1 defaults (parameterised so they can be retuned)

| Structure        | v1 size  | Notes |
|------------------|----------|-------|
| ROB              | 16       | In-order alloc at dispatch, in-order retire at commit |
| Int RAT          | 32       | arch reg → ROB tag (or "in arch regfile") |
| FP  RAT          | 32       | same, separate namespace |
| Int ALU RS       | 4        | 1-cycle ALU + Zba/Zbb/Zbs |
| Branch RS        | 2        | Resolves direction/target, kicks recovery |
| Mul/Div RS       | 2        | Multi-cycle; reuses existing `divider.sv` + a multiplier |
| FPU RS           | 4        | Multi-cycle; PakFPU FUs |
| LSQ              | 8        | Stores commit-then-write; loads check older stores |
| CDB              | 1 (arbed)| FU priority: branch > ALU > mul/div > FPU |
| Int arch regfile | 32 × 32  | Written on ROB retire only |
| FP  arch regfile | 32 × 32  | Same |

### Tomasulo specifics
- **Tag = ROB index.** No separate physical-regfile tag space.
- **Operand storage:** RS slots hold values once produced, OR a tag if
  still waiting. Classic Tomasulo, not PRF-style.
- **CDB wakeup:** every RS compares each waiting tag against the CDB tag
  every cycle; on match, captures the value and clears the wait bit.
- **Issue policy:** age-ordered (oldest-ready first); 1 op per FU per
  cycle.

### Branch recovery
- **RAT snapshot per dispatched branch.** Snapshot the int+FP RAT,
  the ROB tail pointer, and the LSQ tail pointer at dispatch time.
- On mispredict: squash all ROB entries younger than the branch,
  restore the snapshotted RAT/tail pointers, redirect fetch.
- This is cheap at 1-wide. Will revisit at >2-wide (RAT walk-back from
  ROB might be preferable then).

### Precise exceptions
- Faults are tagged into the ROB entry of the faulting op.
- Commit pulls only the ROB head; if the head is faulting, the trap
  handler logic kicks in:
  - Flush younger ROB entries and the front-end.
  - Restore RAT from the *committed* arch regfile state (no snapshot
    needed because everything younger is squashed).
  - Update mepc/mcause/mtval/mstatus, jump to mtvec.

### Memory ordering / LSQ
- **Stores: in-order to memory.** Address generated at issue, written
  into LSQ entry; data written when produced; *memory write occurs at
  commit only*.
- **Loads: speculative.** At issue, address generated; LSQ checks older
  stores in program order for a full-address match.
  - Hit → store-to-load forwarding (data may be available or pending —
    if pending, the load waits via the store's ROB tag).
  - Miss → bus read.
- No memory dependence prediction in v1; loads wait for all older
  store addresses to be resolved before issuing (conservative).

## Reused modules (instantiated, not modified)

- `design/core/alu/src/alu.sv` — integer ALU body (wrap inside an FU)
- `design/core/alu/src/zba_zbb.sv` — Zba/Zbb ops
- `design/core/alu/src/zbs.sv`     — Zbs ops
- `design/core/alu/src/clmul.sv`   — Zbc carry-less mul
- `design/core/alu/src/divider.sv` — integer divider
- `design/core/fpu/PakFPU/src/fp_top.sv` and friends — F FUs
- `design/core/regfile/src/reg_file.sv` — arch regfile pattern (may be
  copied & specialized rather than instantiated; decide at M1)

CSR unit is *not* reused as-is — `csr_unit.sv` is 1000s of lines
covering M/S/U + Debug. We'll write a minimal M-only CSR file as part
of M7.

## Milestones

Each milestone = one sub-branch off `ooo-core`, merged when its gate
passes. Gates are listed inline.

### M0 — Skeleton + decoder + arch regfile (in-order, no OoO)
Goal: a single-issue in-order pipeline lives in `core_ooo/` and runs
the smallest RV32I program end-to-end.

- IF (PC + imem_port master, no prediction).
- Decode (RV32I subset only — no M, F, B yet).
- Arch regfile (32 × 32 int).
- In-order single-stage execute (instantiates `alu.sv`).
- LSQ stub (one outstanding, in-order, no forwarding).
- Writeback to arch regfile in next cycle.

**Gate:** RISCOF rv32i passes on `core_ooo`. (Equivalent to "we have a
working in-order RV32I core in the new directory.")

### M1 — Rename + ROB + in-order dispatch/issue/retire
Goal: add the rename/ROB infrastructure that OoO will need, even
though everything is still in-order at this point.

- Int RAT (32 entries).
- ROB (16 entries, in-order alloc/retire).
- Dispatch: rename rs1/rs2 via RAT, alloc ROB slot, write rd→ROB
  mapping into RAT.
- Single in-order FU still; result writes ROB entry + clears RAT entry
  on retire.

**Gate:** RISCOF rv32i still green; ROB occupancy probe shows entries
allocated and retired.

### M2 — Reservation stations + CDB → true OoO execute
Goal: Tomasulo is alive.

- Multiple FUs (int ALU, mul/div).
- Per-FU RS with wake-up + select.
- CDB broadcast.
- Dispatch routes by op type to the right RS.

**Gate:** RISCOF rv32im green; a hand-crafted dep-chain test shows ops
retire in program order while *issuing* out-of-order.

### M3 — Branch prediction + speculation + recovery
- Predict-not-taken first.
- RAT snapshot at dispatch of each branch.
- Squash + restore on mispredict.
- Later (still inside M3): 2-bit BHT predictor (port from
  `design/core/bpu/src/bpu.sv` as a reference).

**Gate:** Branchy microbenchmark runs to completion; mispredict-recovery
probe confirms RAT/ROB/LSQ are restored precisely.

### M4 — LSQ: speculative loads + commit-time stores
- Loads issue OoO, check LSQ.
- Stores write memory only at commit.
- Store-to-load forwarding (full-address match in v1).

**Gate:** RISCOF rv32im (memory-heavy) green; store→load forwarding
unit test passes.

### M5 — F extension
- FP RAT + FP regfile.
- FP RS with FP FUs (instantiate PakFPU modules).
- FP loads/stores share LSQ.
- May bump CDB to 2-wide if FPU contention shows up in IPC traces.

**Gate:** RISCOF rv32imf green; a few FP kernels run.

### M6 — B extension
- Decoder extensions.
- ALU FU instantiates `zba_zbb.sv` + `zbs.sv` + `clmul.sv`.

**Gate:** RISCOF rv32im_zba_zbb_zbc_zbs green.

### M7 — M-mode privilege + traps
- Minimal CSR file (machine-mode subset of `csr_unit.sv`).
- Exception flagging in ROB, drained at commit.
- mret, ecall, ebreak, illegal-instr, misaligned.
- Timer + machine-software interrupts via CLINT (reuse SoC's CLINT).

**Gate:** Hand-crafted M-mode trap testsuite + RISCOF priv tests pass.

### M8 — Benchmarks + synth
- CoreMark / Dhrystone — IPC vs the in-order core baseline.
- Vivado synth on Zybo Z7-20 (Z7-10 is over-utilised at the in-order
  core already — known from prior session).
- LUT / FF / Fmax delta vs in-order.

## Open decisions deferred until later milestones

- **CDB width** — 1 vs 2. Defer to M5 (FPU will reveal whether
  arbitration loss is material).
- **RS layout** — distributed per-FU (current sketch) vs unified
  scheduler. Decide at the start of M2.
- **Mul/Div microarch** — reuse `divider.sv` and pair with a Booth
  multiplier, or build one combined unit. Decide at M2.
- **Wakeup style** — tag-broadcast (sketched) vs matrix scheduler.
  Tag-broadcast is fine at 1-wide; matrix is a 2-wide-and-above topic.
- **ROB size** — start at 16; bump to 32 in M5 if multi-cycle FPU
  starves dispatch.
- **CSR ordering** — serialise (drain pipeline before issue + after
  commit) in v1. Re-examine in v2 if it hurts IPC.

## Testing strategy

- **Reference oracle:** the in-order core on the same SoC. Same test
  binaries run on both; final committed arch state must match.
- **RISCOF:** runs against the new core at each milestone. ISA subset
  grows: rv32i (M0–M4) → rv32im (M2+) → rv32imf (M5+) → rv32imf_b (M6+)
  → priv (M7).
- **Microarch probes:** SV bind modules in sim assert that the OoO
  behavior we expect is actually happening — e.g. an "OoO completion
  observed" probe in M2.
- **Unit tests:** small directed tests per structure (ROB, RS, LSQ),
  written in CocoTB or as SV testbenches.

## Build / config

- Top-level SoC switch (parameter or define) chooses which core to
  instantiate. The two cores expose the same `mem_bus` master ports
  + interrupt inputs + fence_i output.
- For v1, debug (JTAG) and abstract-memory-access (`am_*` / `ar_*`)
  ports on `core_ooo_top` are tied off — added back when there's a
  reason.
