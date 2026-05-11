# OoO concepts — refresher (tied to our code)

A focused refresher on out-of-order execution mapped to **our M1
pipeline**. Each concept points at the file/lines that implement it so
you can flip between theory and the actual RTL.

Pre-req: you've seen a 5-stage in-order pipeline and know what RAW /
WAR / WAW hazards are.

---

## 1. Why OoO exists at all

In-order pipelines stall whenever one instruction needs a result the
previous one hasn't produced yet. That's a **RAW** (read-after-write)
hazard. Bypass networks help a bit, but multi-cycle producers (loads,
multiplies, FP ops) still force the rest of the pipeline to wait.

**Insight:** there are usually independent instructions *behind* the
stalled one that could run right now. OoO lets those run while the
slow one is in flight.

But to do that safely, you have to handle:

- **WAR / WAW** (false dependencies) — two instructions writing the
  same architectural register, or one reading after another writes,
  shouldn't constrain execution order if we use *different storage*
  for each in-flight value.
- **Precise exceptions** — if an older instruction faults, all younger
  in-flight instructions must be discarded as if they never ran.

The two big ideas that fix this:

| Idea | Solves | Our module |
|------|--------|------------|
| Register renaming via a rename map (**RAT**) | WAR / WAW | [rat.sv](../src/rat.sv) |
| In-order retire via a reorder buffer (**ROB**) | precise exceptions + branch recovery | [rob.sv](../src/rob.sv) |

Once you have these two, you can let execution itself happen out of
order (Reservation Stations + CDB), which is M2's job — at M1 we fold
that operand storage into the ROB.

---

## 2. Register renaming (the RAT)

### The problem

```asm
add  x5, x1, x2     # produces x5_v1
add  x6, x5, x3     # reads x5_v1
add  x5, x7, x8     # produces x5_v2 — WAW with first add
add  x9, x5, x4     # reads x5_v2
```

If both `add`s into `x5` share one architectural register slot, the
second can't even start until the first commits. But really, the two
`x5`s are *different values* that happen to share a name.

### The fix

Each in-flight instruction gets its own private slot for its
destination. The **Register Alias Table (RAT)** tells the rest of the
pipeline "if you want the latest value of arch reg X, here's where
to find it."

Two cases per arch register:
- **Not busy** — latest value is in the arch regfile. Read from there.
- **Busy** — latest value is in (or will be in) an in-flight slot at
  some index. Read from there.

In our code, the per-arch-reg storage is at
[rat.sv:53-54](../src/rat.sv#L53-L54):

```sv
logic                       busy_q [0:31];     // per arch reg
logic [OOO_ROB_IDX_W-1:0]   tag_q  [0:31];     // points at ROB slot
```

When the dispatch stage processes a new instruction:
1. **Read** RAT[rs1] and RAT[rs2] to figure out where the latest
   values live.
2. If the instruction has a destination, **write** RAT[rd] := {busy=1,
   tag = the ROB slot we just allocated}. Future readers of this arch
   reg will be steered to our slot.

x0 stays hardwired to "not busy" so writes to x0 are silently ignored
(check `rs1_addr_i == 5'd0` in [rat.sv:57](../src/rat.sv#L57) and the
`write_addr_i != 5'd0` guard in [rat.sv:83](../src/rat.sv#L83)).

### What happens at commit

When the oldest in-flight instruction commits, it writes its result
into the arch regfile. The RAT entry that *still points at* its ROB
slot should now say "not busy — read arch regfile."

But there's a subtlety: a younger rename may have overwritten that
RAT entry since. In that case the RAT entry doesn't point at the
retiring slot anymore — and we must **not** clear it (we'd lose the
newer rename).

Our conditional-clear: [rat.sv:75-79](../src/rat.sv#L75-L79):

```sv
if (clear_en_i && clear_addr_i != 5'd0
    && busy_q[clear_addr_i]
    && tag_q[clear_addr_i] == clear_check_idx_i) begin
    busy_q[clear_addr_i] <= 1'b0;
end
```

### Why this kills WAR/WAW

In the four-instruction example above:
- 1st `add x5,...` → RAT[x5] := {busy, ROB-slot-A}.
- 2nd `add x6, x5, ...` reads RAT[x5] = busy@slot-A. It depends on
  slot-A's result. *Real RAW — captured.*
- 3rd `add x5, x7, ...` → RAT[x5] := {busy, ROB-slot-B}. Old slot-A
  is unaffected.
- 4th `add x9, x5, ...` reads RAT[x5] = busy@slot-B. Slot-B is
  independent of slot-A. Can execute as soon as x7 and x8 are ready,
  even before slot-A finishes.

The WAW (1st vs 3rd) is gone — they use different storage. The WAR
(2nd reading x5 vs 3rd writing x5) is gone for the same reason.

---

## 3. The Reorder Buffer (ROB)

### What it is

A FIFO ring buffer of in-flight instructions. Three pointers walk
around it:

| Pointer | Advances on | Purpose |
|---------|-------------|---------|
| `head_q` | commit | Oldest still-in-flight |
| `issue_ptr_q` | issue | Oldest not-yet-issued |
| `tail_q` | dispatch | Next free slot |

Invariant: `head_q ≤ issue_ptr_q ≤ tail_q` (modular).

Code: [rob.sv:92-95](../src/rob.sv#L92-L95).

### What each slot stores

Look at the packed struct in [rob.sv:77-90](../src/rob.sv#L77-L90):

```sv
typedef struct packed {
    logic                        busy;        // slot occupied
    logic                        issued;      // already sent to FU
    logic                        ready;       // result has been wb'd
    uop_t                        uop;         // decoded op
    logic [31:0]                 rs1_value;   // operand A storage
    logic                        rs1_ready;   // operand A captured?
    logic [OOO_ROB_IDX_W-1:0]    rs1_tag;     // who we're waiting on
    logic [31:0]                 rs2_value;   // operand B same
    logic                        rs2_ready;
    logic [OOO_ROB_IDX_W-1:0]    rs2_tag;
    logic [31:0]                 result;      // produced by EX
} slot_t;
```

At M1 the slot **also stores operand state** (`rs1_value`, `rs1_tag`,
`rs1_ready`). That's normally the job of Reservation Stations (§4) —
we fold them in for M1 because there's only one FU and one issue
slot, so a dedicated RS bank is overkill. M2 will split it out.

### What the ROB buys you

- **In-order commit.** No matter what order results come back from
  the FUs, the head pointer only retires the oldest. The arch state
  (regfile, memory if you go further) only ever sees results in
  program order.
- **Precise exceptions.** If a faulting instruction reaches the head,
  squash all younger entries before letting the arch state move on.
- **Branch recovery.** A mispredicted branch at the head can squash
  everything younger and redirect fetch (M3 will refine this).

---

## 4. Reservation Stations + the Common Data Bus (CDB)

### The classical picture (Tomasulo, ~1967, IBM 360/91)

Between the dispatch stage and the FUs, you place small per-FU
buffers called **Reservation Stations (RS)**. Each RS slot can hold
one waiting instruction with:
- the operation type
- two operand slots, each storing *either* a value or a tag

If both operands are ready, the slot can **fire** to its FU. When
an FU produces a result, it broadcasts `{tag, value}` on the
**Common Data Bus (CDB)**. Every RS slot watches the CDB; any slot
waiting on that tag captures the value and clears its wait bit.

This is **wakeup**. The key property: a slot doesn't care *when* its
producer finishes — it just listens for its tag and grabs the value
when it shows up.

### At M1 we fold RS into ROB

Look at our wakeup logic in [rob.sv:134-172](../src/rob.sv#L134-L172).
The `if (wb1_en_i)` / `if (wb2_en_i)` blocks scan every busy ROB
slot. If a slot is waiting (`!rs1_ready`) and its tag matches the
writeback's index, it captures the result. That's exactly RS wakeup,
just living in ROB storage.

We have **two writeback ports** because at M1 a single-cycle ALU op
and a multi-cycle memory op can complete the same cycle (ALU
dispatched one cycle after the memunit kick finishes in one cycle for
a store). One CDB-wide port would drop one of them. M2's real CDB
arbitration replaces this hack.

### When does a slot first fire?

Whenever it's at `issue_ptr_q` (the oldest non-issued) AND both
operands are ready. Conditional in
[rob.sv:108-109](../src/rob.sv#L108-L109):

```sv
assign issue_valid_o = islot.busy & ~islot.issued
                     & islot.rs1_ready & islot.rs2_ready;
```

At M1 we issue only from `issue_ptr` (in-order issue). At M2 the
scheduler will pick the *oldest ready* RS slot regardless of position
— that's where the "OoO" of OoO issue lives.

---

## 5. The five phases — and how they map to our pipeline

A modern OoO core has these five logical phases:

| Phase | What it does | Our code |
|-------|--------------|----------|
| **Fetch** | Drive PC, get instr bits back | [fetch.sv](../src/fetch.sv) |
| **Decode + Rename + Dispatch** | Turn instr bits → uop; rename via RAT; allocate a ROB slot | [decode.sv](../src/decode.sv) + dispatch logic in [core_ooo_top.sv:200-230](../src/core_ooo_top.sv#L200-L230) |
| **Issue + Execute + Writeback** | Pick a ready slot from RS/ROB; run on an FU; broadcast result on CDB | [rob.sv](../src/rob.sv) issue/wb + [execute.sv](../src/execute.sv) + [memunit.sv](../src/memunit.sv) |
| **Commit** | Drain ROB head in order; update arch regfile / memory; clear RAT | top's commit block + [rat.sv:75-79](../src/rat.sv#L75-L79) |

Note that dispatch and rename are usually one stage — every instruction
gets renamed at dispatch, and that's also when its ROB slot is
allocated. In our top, those happen in the same combinational block.

### Same-cycle wakeup ("rs1_resolved_now")

A subtle case: the producer writes back the *same cycle* the consumer
dispatches. The consumer's ROB slot is not yet busy (alloc takes
effect at the next clock edge), so the CDB wakeup loop in
[rob.sv:134-172](../src/rob.sv#L134-L172) skips it. Without
intervention, the consumer would forever wait for a wakeup that
already happened.

Fix: at dispatch, peek at the producer's ROB slot AND at the live wb
buses, and if either says "ready" or "matches this cycle's wb tag",
capture the value directly. See
[core_ooo_top.sv:196-230](../src/core_ooo_top.sv#L196-L230).

### Why issue_ptr is separate from head

If issue and commit shared one pointer, IPC would bottom out at 0.5:
one cycle issues an instruction, the next cycle commits it; head
advances; only then can the next instruction issue. With a separate
`issue_ptr_q`, issue and commit happen *in the same cycle for
different instructions* — issue advances independently.

This is also why the *ALU result for instruction K+1* can write back
the same cycle *the memory result for instruction K-3* finishes — they
got issued in different cycles and pass through their FUs at
different speeds.

---

## 6. Branch handling (the M1 version)

Branches still resolve in EX. When EX detects a taken branch:

1. **Redirect fetch** — `ex_redirect=1, ex_redirect_pc=target`.
2. **Squash the wrong-path ROB entries** — everything that's been
   dispatched *behind* the branch is on the mispredicted shadow. They
   must be discarded.
3. **Clear the RAT** — those squashed instructions had updated RAT
   entries that now point at dead ROB slots.

Our code does this by passing `rob_issue_idx` (the branch's slot) to
the ROB as `flush_after_idx_i`. The ROB squashes entries strictly
between `flush_after_idx` and `tail` — *not* the branch itself, which
still needs to commit normally (it produced `pc+4` if JAL/JALR).
Implementation: [rob.sv:215-235](../src/rob.sv#L215-L235).

### What M1 doesn't handle yet

Wholesale RAT flush is correct but blunt. M3 introduces **RAT
snapshots at branch dispatch**: every branch captures a copy of the
RAT, and on mispredict we restore that snapshot. That preserves
renames for older in-flight instructions that don't depend on the
branch — the wholesale flush throws them away.

Why isn't this a correctness bug at M1? Because at M1 issue is
in-order from `issue_ptr` — older instructions have either already
been issued (their operand values were captured at *their* dispatch,
before the wholesale flush) or are still ahead of the branch in the
ROB and therefore their renames are unaffected. The flush only takes
out the *renames that the squashed entries created*, all of which
are now moot.

---

## 7. Tomasulo vs PRF+ROB (so you know what we picked)

You'll see two big-picture flavors of OoO in textbooks:

**Tomasulo (what we're building, IBM 360/91 → many academic cores):**
- RS slots store *values* (and tags while waiting).
- ROB has a `result` field per slot; commit copies that to arch regfile.
- Tag space = ROB index space.

**PRF + ROB (Intel P6+, Apple/ARM, RISC-V BOOM):**
- One big physical register file holds *all* values, both committed
  and speculative.
- ROB just tracks control (which arch reg this slot writes, exception
  bits, retirement order); no value storage.
- Rename map: arch reg → physical reg index.
- On commit, just "retire" the mapping; no value copy.
- Tag space = physical register space (often much larger than ROB).

PRF+ROB has lower latency at retirement (no value copy) and scales
better to wide issue. Tomasulo is *much* easier to bring up — fewer
moving parts, ROB and RS share a tag space, no separate free-list of
physical regs. We picked Tomasulo for v1 (see
[ooo_v1_spec.md](ooo_v1_spec.md)).

---

## 8. Cheat sheet — every concept → its line in our code

| Concept | Where to look |
|---------|---------------|
| RAT entry: `{busy_q, tag_q}` arrays | [rat.sv:53-54](../src/rat.sv#L53-L54) |
| RAT lookup at dispatch | [rat.sv:57-60](../src/rat.sv#L57-L60) |
| RAT write at dispatch | [rat.sv:82-86](../src/rat.sv#L82-L86) |
| RAT conditional clear at commit | [rat.sv:75-79](../src/rat.sv#L75-L79) |
| ROB slot struct (incl. folded RS) | [rob.sv:77-90](../src/rob.sv#L77-L90) |
| Head / issue_ptr / tail | [rob.sv:92-95](../src/rob.sv#L92-L95) |
| Issue view | [rob.sv:108-113](../src/rob.sv#L108-L113) |
| Commit view | [rob.sv:116-119](../src/rob.sv#L116-L119) |
| CDB wakeup loop | [rob.sv:134-172](../src/rob.sv#L134-L172) |
| Tail-side alloc (dispatch) | [rob.sv:182-208](../src/rob.sv#L182-L208) |
| Branch flush range | [rob.sv:215-235](../src/rob.sv#L215-L235) |
| Dispatch rename + peek + same-cycle wb resolve | [core_ooo_top.sv:196-230](../src/core_ooo_top.sv#L196-L230) |
| Single-cycle ALU wb path | [execute.sv:79-83](../src/execute.sv#L79-L83) |
| Multi-cycle mem wb path | [memunit.sv:155-157](../src/memunit.sv#L155-L157) |
| Commit → arch regfile write | [core_ooo_top.sv:342-352](../src/core_ooo_top.sv#L342-L352) |

---

## 9. Where this all leads (M2 → M8)

| Milestone | What it adds |
|-----------|--------------|
| M2 | Split RS out of ROB; multiple FUs (ALU, branch, mul/div); a real CDB with arbitration. **OoO issue starts here.** |
| M3 | Branch prediction + RAT snapshots / precise mispredict recovery |
| M4 | Real LSQ: speculative loads, commit-time stores, store→load forwarding |
| M5 | F extension — FP RAT + FP regfile + FPU FUs |
| M6 | B extension — Zba/Zbb/Zbc/Zbs |
| M7 | M-mode privilege + traps |
| M8 | Benchmarks + Vivado synth |

You don't need any of those to grasp M1. Once M1's "rename + ROB +
in-order issue, OoO completion" is in your head, M2 is just "let
issue go out of order too." Everything else is incremental.
