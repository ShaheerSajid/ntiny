# Post-Linux Roadmap

Linux boots to busybox userspace (fetch-revamp Phase 4.13, 39 bugs fixed).

## Group A — Bit Manipulation (Zbc + Zbs)

| Task | What | Cost |
|------|------|------|
| A.1 | Verify Zba+Zbb against RISCOF (21 tests) | 1 session |
| A.2 | Zbc: `clmul/clmulh/clmulr` (carry-less multiply, ~150 lines) | 1 session |
| A.3 | Zbs: `bclr/bext/binv/bset` + imm variants (~80 lines) | 1 session |
| A.4 | DT: advertise `_zba_zbb_zbc_zbs` | 0.5 session |
| A.5 | Optional: Zicond `czero.eqz/nez` (~30 lines) | 0.5 session |

Existing: `design/core/alu/src/zba_zbb.sv`, decoder already handles Zba+Zbb.
Plan detail: `docs/bit_extensions_plan.md`.

## Group B — Random / Crypto

| Task | What | Cost |
|------|------|------|
| B.1 | MMIO RNG: wrap `rng_seed.sv` as timeriomem-rng APB peripheral | 1 session |
| B.2 | Kernel bump to 6.12+ for native Zkr support | 1-2 sessions |

B.1 silences jitterentropy on 6.6 without kernel changes.

## Group C — Branch Prediction

| Task | What | Cost |
|------|------|------|
| C.1 | BHT: 256-entry × 2-bit counter table in `bpu.sv` | 2 sessions |
| C.2 | BTB: 16-32 entry direct-mapped, tag check at IF | 1-2 sessions |
| C.3 | RAS: 4-8 entry return address stack | 1 session |
| C.4 | Benchmark + tune (target ≥10% on Dhrystone/CoreMark) | 0.5 session |

Scaffolding exists (commit `9acd167`): `predicted_taken`, `predicted_pc`, `bpu_mispredict`.
Baseline: 1.87 DMIPS/MHz, 3.49 CoreMark/MHz.

## Order

A.1 → A.2+A.3 → A.4 → B.1 → C.1 → C.2+C.3 → C.4 → B.2

## Not in this plan

- PMP RISCOF (5 misalign + 2 pmp-on-pte) — independent
- CLIC — after BPU
- RISCOF ACT-4 upgrade — independent
