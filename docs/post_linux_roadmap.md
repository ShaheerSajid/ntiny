# Post-Linux-Boot Hardware Roadmap

Linux fully boots to a busybox userspace on ntiny as of fetch-revamp
Phase 4.13. This doc tracks the **next** wave of hardware work, in
priority/dependency order.

Cross-references:
- `docs/bit_extensions_plan.md` — already-detailed Zba/Zbb/Zbc/Zbs plan
- `docs/fetch_revamp_plan.md` — fetch-unit revamp (mostly done)
- `~/.claude/projects/.../memory/project_zkr_jitterentropy.md` — Zkr context
- `~/.claude/projects/.../memory/project_core_revamp_plan.md` §14 — BPU plan

---

## Group A — Bit Manipulation Completion

**Status today**: Zba (3 insns) + Zbb (21 insns) implemented in
`design/core/alu/src/zba_zbb.sv`. MISA bit B already cleared (commit
`8337012`). Linux's runtime alternative-patcher correctly skips
Zbc/Zbs because the device tree doesn't advertise them.

### A.1 — Verification pass on Zba+Zbb
- Run all 21 Zba/Zbb RISCOF tests (`verification/riscof/.../rv32i_m/B/`)
- Fix any silent codegen quirks; baseline must be 21/21 before
  adding more.
- **Cost**: 1-2 sessions
- **Output**: Green CI on Zba+Zbb

### A.2 — Zbc (3 instructions, ~150 lines RTL)
- New `design/core/alu/src/zbc.sv` — combinational carryless multiply
  (XLEN-wide, polynomial GF(2)).
- Decoder: add `clmul`, `clmulh`, `clmulr` to `decoder.sv` OP_R block.
- ALU: extend `bit_op_e`, route into existing `bit_result` mux.
- Verify against the 3 Zbc compliance tests.
- **Performance choice**: combinational works for low MHz; revisit as
  2-cycle later if timing-critical.
- **Cost**: 1 session

### A.3 — Zbs (8 instructions, ~80 lines RTL)
- All 8 ops are trivial single-bit shift+mask.
- Inline into `zba_zbb.sv` (rename to `bitmanip.sv`) or new file.
- Decoder: add 4 R-type + 4 I-type encodings.
- Verify against 8 Zbs compliance tests.
- **Cost**: 1 session

### A.4 — Advertise everything
- DT: extend `software/linux/ntiny.dts` `riscv,isa` and
  `riscv,isa-extensions` strings to include `_zba_zbb_zbc_zbs`.
- MISA bit B stays cleared (Linux uses DT string, not MISA-B).
- Verify Linux dmesg: `riscv: ELF capabilities acim_zba_zbb_zbc_zbs`.
- **Cost**: 0.5 session

### A.5 — Optional: Zicond (2 instructions)
- `czero.eqz`, `czero.nez` — conditional move primitives. Useful for
  branchless code, ~30 lines RTL.
- Foundation for future If-conversion in compiler.
- **Cost**: 0.5 session

---

## Group B — Random / Crypto Extensions

**Status today**: `rng_seed.sv` implements xoshiro128**, wired to seed
CSR (0x015), Zkr-spec compliant. Linux 6.6 has **no Zkr support**
upstream (added in v6.10), so the kernel ignores it and jitterentropy
fails its variance test in deterministic sim.

### B.1 — MMIO RNG peripheral *(easiest, no kernel bump)*
- Wrap existing `rng_seed.sv` in a tiny APB peripheral exposing one
  32-bit read register at `0x10070000`.
- Add DT node:
  ```
  rng@10070000 {
      compatible = "timeriomem_rng";
      reg = <0x10070000 0x4>;
      period = <1>;
      quality = <1000>;
  };
  ```
- Linux 6.6's `drivers/char/hw_random/timeriomem-rng.c` will pull
  bytes during early seeding → jitterentropy never runs.
- **Cost**: 1 session

### B.2 — Linux 6.10+ kernel bump
- Move from Linux 6.6 → 6.12 LTS or newer.
- Native Zkr support: `CONFIG_RISCV_ISA_ZKR=y`,
  `random.trust_cpu=on` cmdline.
- Will likely re-expose latent bugs we fixed only on 6.6 — its own
  testing budget. Defer until B.1 ships.
- Pairs naturally with **A.4** since 6.10+ also has better hwprobe
  and isa-extensions parsing.
- **Cost**: 1-2 sessions

### B.3 — Real silicon TRNG note (docs only)
- xoshiro is deterministic; for production silicon replace with
  ring-oscillator TRNG using xoshiro as whitening mixer. Already
  noted in `rng_seed.sv` header comment. Docs-only for now.

---

## Group C — Branch Prediction Completion

**Status today**: BPU scaffolding landed in commit `9acd167` —
`predicted_taken`, `predicted_pc`, `bpu_mispredict` infrastructure
exists, default policy is **static not-taken**. The compressed_aligner
already feeds `predicted_pc_id` and the redirect path treats
mispredictions correctly (verified by Phase 4.13 fixes).

Baseline benchmarks (commit `104fc7e`, no BPU):
- 1.87 DMIPS/MHz (Dhrystone)
- 3.49 CoreMark/MHz

### C.1 — BHT (2-bit counters)
- New `bpu.sv` with a 256-entry × 2-bit counter table.
- Index by `pc_id[9:2] XOR (low GHR bits)` for dispersion.
- Update on branch resolution at IE stage (we already track
  `branch_taken`).
- Trade-off study: 256 vs 512 vs 1024 entries (area vs hit rate).
  Pick smallest that gets ~85% on Dhrystone/CoreMark.
- **Output**: predict the *taken* bit.
- **Cost**: 2 sessions

### C.2 — BTB
- 16- or 32-entry direct-mapped BTB to feed `predicted_pc` for taken
  branches.
- Tag check at IF stage (combinational from icache rdata).
- On hit + BHT-says-taken → fetch from BTB target.
- On miss → use sequential PC, BHT contributes nothing useful.
- Add a small valid bit + LRU bit if we go beyond direct-mapped.
- **Cost**: 1-2 sessions

### C.3 — RAS (Return Address Stack)
- 4- to 8-entry return address stack.
- Push on `jal ra, ...` and `jalr ra, ra, off`.
- Pop on `jalr x0, ra, 0` (= `ret`).
- Feed RAS top into `predicted_pc` for return instructions, overriding BTB.
- Huge win on call-heavy kernel code paths.
- **Cost**: 1 session

### C.4 — Benchmark + tune
- Re-run Dhrystone + CoreMark.
- **Target**: ≥10% improvement on both.
- Add a `--bpu-stats` UART dump (predicted vs mispredicted) so we can
  tune the table sizes.
- **Cost**: 0.5 session

---

## Suggested execution order

1. **A.1** — Zba/Zbb verify (quick sanity, no risk)
2. **A.2 + A.3** — Zbc + Zbs (small, contained ALU additions)
3. **A.4** — DT advertise (once Zbc/Zbs are in)
4. **B.1** — MMIO RNG (silences jitterentropy on 6.6, no kernel changes)
5. **C.1** — BHT (start the BPU build-out, lowest risk piece)
6. **C.2 + C.3** — BTB + RAS (share predicted-PC mux)
7. **C.4** — BPU benchmark + tune
8. **B.2** — Kernel bump (last; will surface new issues, doesn't block anything else)

---

## End state (after all Group A + B + C)

- **ISA**: full RV32IMACSU + Zba+Zbb+Zbc+Zbs+Zicond+Zkr
- **Linux**: native Zkr + extension hwprobe + working hwrng
- **Performance**: target ~4.0+ CoreMark/MHz (BPU + bitmanip in libc routines)
- **Sim throughput**: jitterentropy gone, fast initramfs, sub-100M-cycle
  cold boot to login

## What's NOT in this plan

These exist as separate items in memory and are tracked there:

- **PMP RISCOF cluster** — `project_pmp_status.md` (5 misalign + 2
  pmp-on-pte tests still failing). Independent of this roadmap.
- **CLIC** — `project_core_revamp_plan.md` §12. Replaces interrupt_ctrl.
  Big architectural change; defer until BPU is in.
- **RISCOF ACT-4 upgrade** — `project_riscof_upgrade.md`. Test
  framework bump; independent of HW changes.
- **Caches** — already on. Future tuning is a separate effort.
