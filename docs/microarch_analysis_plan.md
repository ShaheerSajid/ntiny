# ntiny Core — Deep Analysis, Re-comment & Microarchitecture Documentation Plan

> Purpose: a self-contained brief so a **fresh chat** can run the deep code
> review, microprogram-based bug hunt, re-commenting, and microarchitecture
> diagramming of the ntiny core. Read this top-to-bottom first.

---

## 0. Where we are (context for the fresh session)

The active arc is **stall-tolerance**: making the core tolerate variable RAM
`ready`/`rvalid` latency (`+define+RAM_RANDOM_DELAY`, the `ram_dp_delayed` sim
model) so a real cache / AXI / DRAM slave can land later. Baseline RAM is
always-ready, 1-cycle.

**Fixes landed in the immediately-preceding session (all on `tier1-roadmap`,
working tree — NOT yet committed):**

1. **D-side load-response routing** — `design/soc_top/src/soc_top.sv`
   (`rd_inflight_q`/`rd_to_ram_q`): route the d-bus read response by the
   *outstanding* read's slave, not the live address (which drifts under stall).
2. **LSU formatting-latch freeze** — `design/core/core_top/src/core_top.sv`
   (`core2avl.stall_i = iwb_stall`): hold `be_iwb`/`mode_iwb` while a load waits.
3. **Stalling icache rewrite** — `design/memory/src/icache.sv` ("Phase 2b-iii"):
   single-outstanding stalling slave; captures the fill address instead of using
   the drifting `cpu_addr_i`. Fixed the branch/jump class under random RAM.
4. **IWB drain** — `core_top.sv` (the `else` arm of the IWB pipeline register):
   during `iwb_stall`, drain IWB to a bubble so a held instruction retires ONCE
   instead of re-committing every stall cycle. Fixed the trap-handler replay.
5. **Branch/JALR resolution gate** — `core_top.sv`
   (`branch_taken_valid = bpu_mispredict & ~iwb_stall`): don't resolve a
   branch/JALR redirect while it forwards from a still-in-flight load (stale
   operand → garbage target). Fixed `ecall`.

**Status:** baseline RISCOF **247/5/3** maintained at every step; random-RAM
moved from a hard load-deadlock to passing the branch/jump class and `ecall`.
Re-measure current numbers with `make -C verification/riscof run` and
`make -C verification/riscof run_random_ram`.

Full running notes: `~/.claude/.../memory/project_pipeline_stall_tolerance_wip.md`
and the `project_*` memories it links.

---

## 1. The central thesis to validate and document

> **Every stall-tolerance bug so far is the same bug:** the pipeline was
> *statically scheduled* around a memory that returns data in exactly one
> cycle. With single-cycle memory, "the load's data is on the bus exactly when
> the load reaches the stage that needs it," so **no dynamic interlock is
> needed** — correctness falls out of the fixed schedule. Variable latency
> breaks that invariant in *every* place a memory result is produced or
> consumed, so each site needs an explicit "data-not-ready-yet" handshake.

This is why "just more wait time" is deceptively invasive: it is not one stall
point, it is the removal of a global timing assumption that was implicitly
relied on by forwarding, branch/JALR resolution, the commit/retire gate, the
fetch-buffer push, the arbiter response routing, and the cache. BPU/cache add
*structure* but preserve the 1-cycle response contract; variable latency
changes the *contract*.

The analysis should produce a crisp, evidence-backed writeup of:
- the exact list of sites that assumed 1-cycle memory,
- for each, what the assumption was and what the dynamic-latency fix is,
- the general pattern (a "latency-tolerance checklist" for future slaves:
  AXI burst master Phase 3a, DRAM model Phase 3b).

---

## 2. Workstreams (do in this order; each gates the next)

### A. Code comprehension + re-commenting  *(primary deliverable)*
Read each block of the core, confirm what it does against the RTL (and against
a microprogram where unsure), and **rewrite comments** to be accurate and
teach the design. Target files, in dependency order:

1. `design/core/core_top/src/core_top.sv` — the spine. Sub-blocks:
   - PC / `pc_sel` redirect mux + `redirect_arbiter` priority
   - fetch producer (`i_vaddr`, `inflight_q`, `inflight_vaddr_q`,
     `first_fetch_pending_q`, `redirect_deferred`, `pending_target_*`)
   - `fetch_buffer` push/pop (`fb_push_raw`, dedup, fault ride-through)
   - `compressed_aligner` interface
   - forwarding (`forwarding_logic`, `opA/opB/opC_forwarded`, `imem_forwarded`)
   - IE branch/JALR resolution (`branch_taken`, `bpu_mispredict`,
     `branch_recovery_target`, the new `~iwb_stall` gate)
   - IE→IMEM→IWB pipeline registers + the new IWB drain
   - d-side: `core2avl`, `amo_unit`, `dmem_arb`, `c2a_load_pending_q`
2. `design/core/hazard_unit/src/hazard_unit.sv` — the stall chain
   (`iwb_stall → imem_stall → ie_stall → if_id_stall`) and flush priority.
3. `design/memory/src/icache.sv` — the new stalling FSM (already re-commented;
   verify wording).
4. `design/interconnect/src/dmem_arb.sv` — per-master grant + `pending_rd_master_q`.
5. `design/soc_top/src/soc_top.sv` — address decode, dcache, RAM mux,
   `rd_inflight_q` response routing, tohost monitor.
6. `design/memory/src/{ram_dp,ram_dp_delayed,dcache}.sv` — slave timing models.
7. `design/core/avalon_master/src/core2avl.sv` — LSU misalign FSM + IWB format.

**Re-comment rules:** comments explain *why* and *the timing contract*, not the
syntax. Every stall/redirect signal gets a one-line "asserted when / consumed
by / 1-cycle-memory assumption (if any)". Keep diffs comment-only in this pass
(no behaviour change) so they can be committed safely and reviewed fast.

### B. Bug hunt — read + **microprograms**  *(find the rest of the frontier)*
The remaining random-RAM failures are the trap / CSR / PMP / Sv32-PTW class.
Hunt for more 1-cycle-memory assumptions and data hazards. Method:
- For each suspect (forwarding from a pending load into ALU/CSR/AMO/PTW; async
  trap coincident with a pending load; back-to-back loads; load→branch;
  load→store-address; PTW read under d-stall), write a **minimal bare-metal
  microprogram** that isolates it and run it under both RAM models. A
  divergence between baseline and random RAM on a 5-10 instruction kernel is a
  clean, fast repro (vs a 600-instruction RISCOF test).
- Microprogram flow (see §4) gives full DV_TRACER output; diff baseline vs
  random traces to localize.

### C. Microarchitecture diagrams  *(Mermaid — see §3)*
### D. Documentation deliverables  *(see §5)*

---

## 3. Diagram method — **Mermaid** (decided)

Use **Mermaid** for all structural/FSM diagrams. Rationale: renders natively in
GitHub + the VSCode markdown preview, produces clean orthogonal boxes/arrows
with auto-layout (no hand-placed shapes to distort), diffs as text, lives next
to the code. For cycle-by-cycle *timing* where Mermaid is weak, use **markdown
pipe-tables** (one column per cycle) — they render perfectly and diff cleanly.
(Optional: WaveDrom JSON for true waveforms only if a renderer is available;
default to tables to avoid a tooling dependency.)

Mermaid diagram types to use:
- `flowchart LR/TD` — datapath / block diagrams (stages, buses, masters/slaves).
- `stateDiagram-v2` — FSMs (icache S_IDLE/S_FILL, core2avl IDLE/SECOND,
  ram_dp_delayed P_IDLE/P_PEND, redirect/fetch producer states).
- `sequenceDiagram` — handshake protocols over time (CPU↔icache↔RAM req/ready/
  rvalid; dmem_arb master arbitration; a load's life from IE to writeback).
- markdown tables — pipeline occupancy per cycle (IF/ID/IE/IMEM/IWB columns)
  for the canonical hazard scenarios (load-use, miss-stall, redirect-on-stall).

Keep each diagram small and single-purpose; many small diagrams beat one giant
one. Validate each renders (Mermaid syntax) before moving on.

---

## 4. Microprogram test harness (how to repro fast)

Per `feedback_baremetal_test_flow`: `split.py` is dead. Use the ram.hex flow:
```
# build a tiny .S/.c → .bin, then:
python3 software/tools/hex_text.py build/X.bin flows/simulation/ram.hex
```
Build the two models (RAM size now correctly 32 MB after the Makefile fix —
see `feedback`/the Makefile `$(VERILATOR_RISCOF_DEFINES)` change):
```
cd flows/simulation
make verilator_build              # always-ready RAM (baseline)
make verilator_build_random_ram   # +RAM_RANDOM_DELAY
```
Run + capture trace (DV_TRACER on):
```
timeout 30 ./Vtb_soc_top --timeout 2000000 +sig_file=/tmp/s.sig \
    +sig_begin=<hex> +sig_end=<hex>
# trace: logs/trace_core_00000000.log ; traps: ..._traps.log
```
Localize a bug: diff `awk '{$1=$2="";print}'` of baseline-vs-random traces.
**Caveat learned the hard way:** an aborted sim (e.g. `$readmem` bounds) leaves
a STALE trace file — always confirm `head -2` of the trace matches the program
(`head -1 ram.hex` vs the disasm at reset PC) before trusting a diff. Also note
the DV_TRACER operand-value display can be stale (forwarding artifact); trust
the *result* register write and the PC stream, not the printed rs1/rs2.

Suggested microprogram seeds (each ~5-12 instrs, M-mode, write result to a
signature word, then tohost):
- `lw` → `add` (load-use into ALU)
- `lw` → `jalr` (load-use into jump target)  ← the ecall bug, isolated
- `lw` → `beq` (load-use into branch direction)
- `lw` → `sw` with loaded address (load-use into store address)
- two back-to-back `lw` (load-after-load pending overlap)
- `lw` then `csrrw` using the value (load-use into CSR)
- `amoadd.w` followed by a dependent op (AMO result latency)
- a tight loop crossing a cache line boundary (icache fill mid-loop)
Each should produce *identical* signatures under both RAM models; any
difference is a bug to root-cause and add to the §1 site list.

---

## 5. Documentation deliverables (target files)

Create a `docs/microarch/` folder:
- `00-overview.md` — pipeline stages, the 1-cycle-memory thesis (§1), index.
- `01-datapath.md` — Mermaid block diagram of IF/ID/IE/IMEM/IWB + buses +
  masters (PTW/AMO/c2a) + dmem_arb + icache/dcache + RAM.
- `02-fetch-redirect.md` — PC mux priority, redirect arbiter, fetch producer +
  inflight tracking, fetch_buffer, aligner. FSMs + a redirect-during-stall
  timing table.
- `03-hazards-forwarding.md` — forwarding paths, the stall chain, load-use
  interlock, and the canonical hazard timing tables (baseline vs random).
- `04-memory-subsystem.md` — icache/dcache FSMs, dmem_arb ownership, slave
  handshake sequence diagrams, the RAM models.
- `05-latency-tolerance-checklist.md` — the distilled "what every site that
  touches a memory result must do under variable latency" (the reusable thesis
  output; the spec the future AXI/DRAM work must satisfy).
- `06-known-frontier.md` — current random-RAM pass/fail, remaining bug classes,
  open questions.

Each doc: prose + Mermaid + tables, cross-linked. Keep code re-comments (A) and
docs (D) consistent — the doc is the "why", the comment is the local "why".

---

## 6. Sequencing / milestones

1. **M0 — Commit the current fixes** (clean checkpoint) BEFORE analysis, so the
   re-comment/diagram work starts from a known-green tree. Run both suites,
   confirm baseline 247/5/3, commit with a clear message.
2. **M1 — Datapath map** (`01-datapath.md`) + read-through of `core_top` top to
   bottom; produces the block diagram + a signal glossary.
3. **M2 — Re-comment pass A** on `core_top` + `hazard_unit` (comment-only diff).
4. **M3 — Fetch/redirect doc + FSMs** (`02`) and **hazards doc** (`03`) with the
   timing tables; re-comment the fetch + forwarding blocks.
5. **M4 — Memory subsystem doc** (`04`) + re-comment icache/dcache/arb/soc.
6. **M5 — Microprogram bug hunt** (§4 seeds); each finding → fix (verify
   baseline stays green) + add to `05` checklist and `06` frontier.
7. **M6 — Latency-tolerance checklist** (`05`) distilled from M1-M5; this is the
   spec for Phase 3a/3b.

Milestones M1-M4 are mostly understanding/documentation (low risk); M5 changes
behaviour (gate every change on baseline 247/5/3 + the random suite).

---

## 7. Verification discipline (non-negotiable)

- Baseline RISCOF must stay **247/5/3** after every behavioural change.
- Random-RAM suite is the frontier metric; never let it regress.
- One RISCOF/microprogram test at a time when debugging (`feedback_single_test`,
  `feedback_focused_debug`).
- No bandaids / no disabling features to dodge timing (`feedback_proper_fix`,
  `feedback_panic_on_regressions`).
- Always confirm the build RAM size is 32 MB and the trace is fresh (§4 caveat).
- Re-comment passes are comment-only diffs (no behaviour change) — easy to review.

---

## 8. Quick reference

- Run sims: see `memory/reference_how_to_run_sims.md` (canonical commands).
- Build targets (in `flows/simulation`): `verilator_build`,
  `verilator_build_random_ram`, `verilator_build_bench`.
- Suites: `make -C verification/riscof run` and `... run_random_ram`.
- Key files: `core_top.sv`, `hazard_unit.sv`, `icache.sv`, `dcache.sv`,
  `dmem_arb.sv`, `soc_top.sv`, `core2avl.sv`, `ram_dp_delayed.sv`.
- Stall chain: `iwb_stall → imem_stall → ie_stall → if_id_stall` (hazard_unit).
- The "1-cycle memory" assumption lived in: forwarding (`readdata_imem`),
  branch/JALR resolve, IWB commit gate, fetch inflight/push, dmem_arb response
  routing, soc_top rvalid mux, the transparent icache. (Confirm/expand this list
  during the analysis — it IS the thesis.)
