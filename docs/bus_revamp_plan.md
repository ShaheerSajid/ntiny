# Bus + Memory Architecture Revamp Plan

Date: 2026-04-30
Author: Audit + plan triggered by AMO/PTW race that caused the Linux 6.6 xas_load livelock and likely contributes to 6.12 NULL-prev.

## TL;DR

Current ntiny SoC has a single shared `dmem_port` (Avalon-style) muxed
between three masters by static priority (PTW > AMO > core load/store)
**without grant signals back to the masters**. The `amo_unit` was blind
to whether its request was actually on the bus, and consumed PTW's
response signals as its own — corrupting `read_data_q` and producing
silently-wrong atomics. This pattern can recur for any new master added
to the shared bus, and the architecture is also unprepared for caches
or DRAM.

This document proposes a phased revamp:

1. **Phase 0 (DONE 2026-04-30)** — point-fix `amo_unit` stall input
2. **Phase 1** — proper bus arbiter with grant signals (no fundamental
   protocol change yet)
3. **Phase 2** — cache hierarchy: L1I, L1D with MMU integration
4. **Phase 3** — memory hierarchy with AXI to DRAM controller (LPDDR
   or DDR3 depending on tape-out target)
5. **Phase 4** — coherence + multicore readiness (long term)

## Current architecture

```
                core_top
   ┌─────────────────────────────────────────┐
   │                                          │
   │   IF/ID/IE/IMEM/IWB pipeline             │
   │     │       │        │                   │
   │   core2avl  amo_unit  PTW (in MMU)       │  ← three masters
   │     │       │          │                  │
   │     ▼       ▼          ▼                  │
   │   ┌───────────────────────────────┐      │
   │   │  static priority mux           │      │
   │   │  ptw_active ? PTW              │      │
   │   │  : amo_active ? AMO            │      │
   │   │  : core2avl                    │      │
   │   └────────────────┬───────────────┘      │
   │                    │ dmem_port             │
   └────────────────────┼──────────────────────┘
                         │  (avalon: req/we/wdata/addr/be → SoC,
                         │           ready/rvalid/rdata ← SoC)
                         ▼
                   soc_top (RAM, peripherals)
```

### Issues with this architecture

#### Issue 1 — masters consume responses they didn't earn ★ (THE BUG)
- The mux drives `dmem_port.req`, `we`, `wdata`, `addr`, `be` from
  whichever master ptw_active/amo_active selects.
- But `dmem_port.ready`, `rvalid`, `rdata` are **shared-fan-out**: every
  master sees them.
- `amo_unit.dbus_stall_i = ~rvalid` for AMO_READ. When PTW had the bus
  and PTW's read returned, amo_unit sees `~rvalid=0` and advances —
  capturing PTW's `rdata` (a PTE word) into `read_data_q`.
- Subsequent AMO writeback computes `(PTE_word OP rs2_q)` and stores it
  back at the AMO's address. Refcount underflow. Linux livelock.
- **Same bug class possible for `core2avl`** if a regular load fires
  while PTW is active and PTW's response leaks. Not yet observed but
  the pattern is identical.

#### Issue 2 — no end-to-end backpressure
- Each master tracks its own state machine and assumes the bus will
  respond when it asks. No shared notion of "outstanding requests".
- If a higher-priority master pre-empts mid-transaction, the lower
  master has no signal that says "your previous req was dropped".

#### Issue 3 — flush coordination is ad-hoc
- amo_unit.flush_i = `interrupt_valid` (only)
- PTW.flush_i = `interrupt_valid | branch_taken | wb_xret_fire`
- core2avl has no flush — it relies on `mem_op` being NOPped upstream
- These were patched piecewise; new masters or new flush sources
  require touching every client.

#### Issue 4 — no hooks for caches
- The dmem_port goes straight to SoC RAM. Adding an L1D requires:
  - Cache hit/miss handling
  - Cache fill (refill from L2/DRAM, multi-cycle)
  - Writeback / flush
  - MMU coordination (translate before cache lookup, or VIPT)
- The current single-cycle (or short-burst) AMO/load/store FSMs have
  no notion of multi-cycle stalls beyond `dmem_port.ready/rvalid`.

#### Issue 5 — atomic semantics inside a cache
- LR/SC reservation is currently a single-bit register inside amo_unit
  with the address. With caches, the reservation must align with cache
  line granularity and survive cache evictions correctly. The
  RVA22 / Zalrsc spec gives implementation freedom but requires forward
  progress.

#### Issue 6 — instruction side risks (probably benign today)
- imem_port has its own fan-out to PTW (instruction-side) and the
  instruction fetch path. PTW.flush_i covers it. But the same
  "consume-someone-else's-response" race is theoretically possible if
  iPTW and core fetches share rvalid. Today they're sequential
  (instruction PTW gates fetch), so likely safe — verify in audit.

#### Issue 7 — MMU is a master, not a slave-of-arbiter
- PTW is embedded in the MMU and drives the bus directly.
- This makes adding caches awkward: the cache should be between MMU
  and DRAM, but if PTW is ABOVE the cache, PTW reads PTEs from DRAM
  every time (slow). If PTW is BELOW the cache, PTW data goes through
  the cache (good for performance) but cache must be physical-tagged.

## Phase 0 (DONE) — point fix for the AMO/PTW race

Patch in `core_top.sv` (commit pending):
```sv
logic ptw_active_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) ptw_active_q <= 1'b0;
    else         ptw_active_q <= ptw_active;
end
wire ptw_owns_bus = ptw_active | ptw_active_q;

amo_unit amo_unit_inst (
    ...
    .dbus_stall_i (ptw_owns_bus |
                   (amo_dbus_read ? ~dmem_port.rvalid : ~dmem_port.ready)),
    ...
);
```

The 1-cycle latch covers the residual rvalid/rdata that can persist
one cycle past `ptw_active` falling. Verified: `AMO_ADVANCE_IN_PTW`
event count drops from many to zero. 6.6 boot reaches `/init` and
goes idle past the prior 88M-cycle livelock.

This is a **band-aid** for the symptom, not the architecture. Phase 1
removes the need for it.

## Phase 1 — proper bus arbiter

### Goals
- Each master sees `req` accepted OR not (grant signal)
- Each master only consumes responses tagged for it
- New masters plug in without touching existing ones
- No regression in cycle count or perf

### Design

Introduce `dmem_arb` module:
```
masters → dmem_arb → dmem_port → SoC

masters: { core2avl, amo_unit, ptw }, each with:
   .req_o          // master wants to access
   .we_o           // write/read
   .addr_o         // physical address
   .wdata_o        // write data
   .be_o           // byte enable
   .grant_i        // arbiter granted me this cycle
   .rvalid_i       // read response is FOR ME
   .ready_i        // request accepted FOR ME
   .rdata_i        // read data
```

The arbiter:
- Picks a master each cycle based on priority (PTW > AMO > core2avl)
  or round-robin (configurable)
- Drives `dmem_port` from the granted master
- Tracks **outstanding requests** — when a request is accepted by SoC
  (`dmem_port.ready=1`), record which master owns the response. When
  `rvalid=1` later, route `rdata` to that master.
- For pipelined SoC (multiple outstanding reads), use a small FIFO of
  pending master IDs.

### Master changes
- `amo_unit`: replace direct `dbus_stall_i` consumption with `.grant_i`
  + `.rvalid_i` + `.ready_i`. Stall while `!grant && req=1` (waiting
  for arbiter), advance only on master's own response.
- `core2avl`: same.
- `mmu_sv32` PTW: same (today PTW uses `ptw_rvalid = rvalid & ptw_req_prev`,
  which is essentially this pattern manually inlined — formalize it).

### Migration plan
1. Create `dmem_arb.sv` with the wider master interface but internally
   identical static-priority behavior.
2. Wrap each existing master in a thin shim that maps its old signals
   to the new interface (preserves bug-for-bug behavior).
3. Switch one master at a time to native interface, with regression
   tests after each.
4. Remove the `ptw_active_q` band-aid.
5. Remove the `amo_active`/`ptw_active` flags from the global mux.

### Tests / verification
- All RISCOF tests (must stay 204/5)
- CoreMark / Dhrystone (perf regression check ≤ 1%)
- Linux 6.6 boot to /init
- Linux 6.12 boot (will reveal whether 6.12 NULL-prev is HW or SW)
- Targeted unit test: AMO RMW concurrent with PTW writeback (forced
  via testbench)

## Phase 2 — cache hierarchy

### L1I (instruction cache)

- 4 KB, 4-way set-associative, 32-byte lines (typical for low-power
  embedded RV32). Direct-mapped is also acceptable.
- VIPT (virtually-indexed, physically-tagged) so MMU translation
  proceeds in parallel with index lookup. With 32-byte lines and
  4 KB / 4-way = 1 KB per way = 32 sets, index uses bits [9:5] which
  is below the 4 KB page boundary → safe for VIPT.
- Refill from L2 (or DRAM directly if no L2) on miss.
- No coherence (single core, instruction cache is read-only).
- Already-existing `imem_port` is a simple sram interface; the L1I sits
  between fetch and `imem_port`.

### L1D (data cache)

- 4 KB, 4-way set-associative, 32-byte lines. Write-back +
  write-allocate.
- VIPT same as L1I.
- Implements:
  - Read-modify-write for partial-word stores (sb/sh)
  - Atomic ops: AMO/LR/SC service the cache line, NOT raw memory.
    Reservation lives at line granularity. SC-success conditions:
    same line, no eviction since LR.
- Cache fill / writeback uses the dmem arbiter (Phase 1) to talk to L2/DRAM.
- MMU PTW: PTE reads should also go through L1D so page tables get
  cached (huge perf win). But PTW writes (Svadu A/D) need careful
  ordering — do them as cache-line-locked writes or use a small PTW
  cache (TLB itself caches PTEs, so this may be moot).

### MMU integration

- TLB (already present) stays in MMU. PTW becomes a master of L1D:
  - PTE read: load from L1D, fill if miss
  - A/D writeback (Svadu): write through to L1D + writeback to memory
- If sharing L1D between core load/store and PTW, MUST handle the
  case where load/store is in flight to the same line — this is what
  Phase 1's arbiter handles cleanly.

### Atomic semantics with cache

- LR.W: read line into cache (allocate if miss), set reservation =
  {valid, line_addr}.
- SC.W: check line still in cache + reservation valid + addr matches.
  If yes, write to cache (mark dirty), return 0. If no, return 1.
- Reservation invalidated by:
  - Cache eviction of the reserved line
  - Trap / xRET (matches today's behavior)
  - Any write to the reserved line by another master (single core: N/A)
- AMO.W (RMW): operates on cache line. Take the line, modify in place,
  mark dirty. Atomic from the core's perspective because nothing else
  touches the cache.

## Phase 3 — DRAM + memory hierarchy

### Target: AXI-to-DRAM bridge

- Behind L1I + L1D (and optionally L2), use an AXI4 master interface
  to a DRAM controller.
- For simulation: use a behavioral DRAM model (e.g., DRAMsim3 via DPI)
  to validate timing.
- For tapeout: the DRAM controller is vendor-specific. For TSMC 65nm
  + LPDDR2, MIG (Xilinx) doesn't apply; we'd write a minimal DDR2/3
  controller or license one.

### Optional L2

- 64 KB or 128 KB unified, 8-way. Inclusive of L1s.
- Single L2 → easy single-port. Read miss / write-back to DRAM.
- Skip L2 for v1, add later if profiling shows DRAM latency dominates.

### Address map cleanup

- mem_map.json already centralizes addresses. Need to add:
  - DRAM region (e.g., 0x80000000 – 0x9FFFFFFF for 512 MB)
  - L2 SRAM region (if any)
  - Cache control / flush MMIO (sfence-like for cache mgmt)
- PMP rules need updating to reflect new regions.

### Bootstrap

- BootROM still at low address, copies firmware to DRAM, jumps to it.
- Must be careful: caches must be init'd (invalidated) before first
  fetch from DRAM.

## Phase 4 — coherence / multicore (LONG TERM)

- Out of scope for v1, but document the constraints:
  - Cache coherence protocol (MESI most likely)
  - Inter-processor interrupts (already have CLINT)
  - Snoop bus or directory
  - LR/SC must be cache-coherent across cores (use AMO at L2 or
    a global lock unit)
- Decision: design Phase 1 arbiter and Phase 2 caches with hooks for
  coherence (e.g., line state bits with room for MESI), but don't
  implement coherence yet.

## Audit checklist (still TODO)

Beyond the AMO/PTW race we just fixed:

- [ ] **core2avl + PTW race**: same response-leak bug class. Verify
  with a probe similar to the AMO/PTW one.
- [ ] **iPTW + fetch race**: instruction-side equivalent. Probably safe
  because instr-side PTW gates fetch via `mmu_i_stall`, but verify.
- [ ] **Misaligned access split during PTW**: core2avl splits a
  cross-word access into two requests. If PTW pre-empts between the
  two halves, what happens? Today probably handled by stall propagation
  but worth a unit test.
- [ ] **AMO during MMU sfence**: sfence_vma flushes TLB; what if AMO is
  in flight? amo_unit's flush_i sees `interrupt_valid` only — sfence
  doesn't trap, so amo_unit doesn't abort. Is this safe?
- [ ] **PMP fault during AMO**: similar to page fault — does amo_unit
  see the fault and abort cleanly?
- [ ] **D-cache aliasing**: not yet a problem (no cache), but Phase 2
  must avoid VIPT aliasing.

## Dependencies / tooling

- AXI verification IP for sim
- DRAMsim3 (or similar) for DRAM model
- Cache simulation tooling (cachegrind-equivalent for RV32 binaries)
- A way to run the kernel boot reliably without 1.5 hours of CPU per
  iteration — possibly a smaller test harness with kernel snippets

## Estimate

| Phase | Effort | Risk |
|-------|--------|------|
| 0 (point fix)   | DONE       | low (verified)         |
| 1 (arbiter)     | 1-2 weeks  | medium (refactor)      |
| 2 (caches)      | 4-6 weeks  | high (new logic + verif) |
| 3 (DRAM/AXI)    | 3-4 weeks  | high (vendor IP)       |
| 4 (coherence)   | open       | very high              |

Phase 1 is the prerequisite for Phase 2/3 and removes the entire
class of "consume-someone-else's-response" bugs. Recommend
prioritizing it over more point-fixes.
