# Fetch / c_controller / Interrupt / Stall Revamp Plan

Status: design draft. Target: post-RISCOF milestone, after Linux boots end-to-end
on the current minimal `ret_pulse` SRET fix. Informed by bugs 13–15 in
[linux_boot_bugs_and_fixes.md](linux_boot_bugs_and_fixes.md), the OpenSBI hang
debug session (April 7), and the cold-ITLB SRET trace.

---

## Table of contents

1. [Why revamp](#1-why-revamp)
2. [Architectural goals](#2-architectural-goals)
3. [New block diagram](#3-new-block-diagram)
4. [Module specs](#4-module-specs)
   - [4.1 Redirect Arbiter](#41-redirect-arbiter)
   - [4.2 Fetch Issue Unit](#42-fetch-issue-unit)
   - [4.3 Fetch Buffer](#43-fetch-buffer)
   - [4.4 Compressed Aligner](#44-compressed-aligner)
   - [4.5 Decode Producer](#45-decode-producer)
5. [Stall and flush primitives](#5-stall-and-flush-primitives)
6. [Interrupt / trap / xRET handling](#6-interrupt--trap--xret-handling)
7. [Sequence diagrams](#7-sequence-diagrams)
8. [Test plan](#8-test-plan)
9. [Migration strategy](#9-migration-strategy)
10. [Risk register](#10-risk-register)
11. [Temporary workaround: disable C extension](#11-temporary-workaround-disable-c-extension)
12. [Recommendation](#12-recommendation)

---

## 1. Why revamp

The current fetch subsystem grew organically and now has three tightly-coupled
PC-ish state machines sharing the same stall domain with no clean ownership:

1. **`main program_counter`** (in `core_top.sv`) — holds *next fetch vaddr*.
2. **`c_program_counter_inst` / `apc`** (in `c_controller.sv`) — holds
   *address of instruction currently in ID*.
3. **alignment FSM** (ALIGN / MISALIGN / BRANCH in `c_controller.sv`) —
   tracks which 16-bit half of the current fetch word is "next".

Plus three pipeline-control shims that keep accreting special cases:

4. **`refetch_after_trap`** in `hazard_unit` — 1-cycle "use pc_out" override
   to avoid skipping handler[0] after a trap.
5. **`trap_sequencer`** — SRET_WAIT FSM that suppresses stale i_faults during
   SRET ITLB stalls.
6. Per-instruction bypass muxes in both PCs (`interrupt_valid`, `ret_pulse`,
   `insert_bubble`, `reset_i`, `halted_i`, `icache_stall_i`, …).

### Observed symptoms of the current design

| # | Symptom | Root cause | Bandaid |
|---|---------|------------|---------|
| 14 | Trap-entry handler[0] skipped on user-mode trap | `refetch_after_trap` gated by `if_id_stall_o` | one-line drop the gate |
| 15 | SRET-to-U cold-ITLB deadlock | apc/main PC bypassed only on `interrupt_valid`, not `ret_fire`/`sret_fire` | added `ret_pulse` bypass |
| 13 | SRET drops priv mid-DTLB walk | `ret_fire` not gated by `!ie_stall` | gated; added `ie_stall_i` to `privilege_unit` |
| — | Stale i_fault overwrites sepc during SRET ITLB stall | i_fault registered between SRET decode and ITLB walk completion | new `trap_sequencer` SRET_WAIT FSM |
| — | OpenSBI hung in `sbi_hart_hang` after `refetch_after_ret` was added | duplicate fetch caused c_controller to decode stale `ins_buffer` + new `instruction_i` as a bogus CSR write | reverted `refetch_after_ret`, kept only the PC bypass |
| — | Forced FSM advance on `ret_pulse` decoded stale data as random instructions | FSM and instruction_i out of sync when stall_i is high | reverted FSM forcing |
| 16 | Trap_sequencer SRET_WAIT permanently suppresses post-commit page fault → user-mode deadlock | exit condition `!mmu_i_stall && !ret_valid` deadlocks (both stuck high in cold ITLB SRET) | gate suppression by `!ret_side_effects_done` |
| **18** | **Recursive trap loop in `_save_context`** — kernel boot reaches user, takes page fault on `_start`, traps to handler. **csrrw at handle_exception[0] is fetched but its decode is NOP_CSR_OP**. csrrw doesn't write sscratch, doesn't write tp. bnez tp falls through to `_restore_kernel_tpsp` which corrupts `TI_KERNEL_SP` with the stale user sp. Next iteration loads corrupt sp → store fault → loop. | **The c_controller's `instruction_pipe` at the cycle `pc_id == handler_addr` is STALE** (= leftover from before the trap), because the imem fetch for the trap target hasn't returned yet. The IE register wall latches `ctrl_bus_if_id` (= the stale-decoded NOP) at the `!ie_stall` cycle, BEFORE the actual handler[0] bytes arrive from the icache. Equivalent to bug #14 but at the IE wall layer instead of the IF stage. Compounds with: `icache_stall_i` is hardcoded to 0 in `hazard_unit_inst` instantiation, and the core driver of `imem_port` ignores `ready` and `rvalid` per OBI protocol. The pipeline thinks the fetch completes immediately when it actually takes multiple cycles. | **Cannot bandaid cleanly.** Tried Option A (gate IE wall by `insn_valid_id`) — drops the csrrw entirely because pc_id advances past it before the latch. Tried Option B (gate IE wall by a new `imem_in_flight` flag) — would need to plumb `imem_port.rvalid` through `hazard_unit` AND hold `pc_id` at the trap target until rvalid. Both fixes converge on the same observation: the IF stage **needs an explicit "fetch in flight" state** with a fetch buffer that only releases instructions to ID once the corresponding rdata has arrived. **= the revamp.** |

The common thread is that **the IF stage has no explicit "fetch request in
flight" concept.** It tracks the *current decode PC* and the *next PC to fetch*,
but there is no bookkeeping for "I asked for address X, the rdata for X has not
come back yet, do not advance until it does." Every bug so far has been a
different manifestation of that missing state.

A second related thread: **the c_controller's alignment FSM is tightly coupled
to the external if_id_stall signal**, and to the external `redirect_i`. This
makes it hard to reason about what `apc_out` and `instruction_o` *mean* on any
given cycle when a redirect, an ITLB stall, and a state transition all coincide.
Every fix attempt that tried to "force" the FSM into a known state (my
`ret_pulse_i` BRANCH/ALIGN forcing, the earlier `refetch_after_ret` sticky
flag) broke a different scenario because the FSM's contract isn't precise.

A third thread (uncovered while debugging bug #18): **the imem bus protocol is
not actually being honored.** `design/buses/src/buses.sv` defines `mem_bus`
as an OBI-style valid/ready protocol with `req`, `ready`, `rvalid`, `rdata`.
The icache slave correctly drives `ready` and `rvalid`, but the core master
in `core_top.sv` does this:

```sv
assign imem_port.req = refetch_after_trap | (~if_id_stall & ~c_stall);
.instruction_i (reset_i ? 32'b0 : imem_port.rdata),
```

— the master ignores `ready` (so a back-pressuring icache is silently dropped)
and ignores `rvalid` (so `imem_port.rdata` is treated as combinational, while
the protocol guarantees it appears 1 cycle after acceptance and only for the
duration of the rvalid pulse). The `c_controller`'s `instruction_i` is just
`imem_port.rdata` directly, so when the icache hasn't returned a fresh result
the c_controller is decoding stale bits — exactly the cycle window that bug
#18 lives in. Compounding this: `hazard_unit_inst` in core_top.sv has:

```sv
.icache_stall_i (1'b0),  // transparent cache: no stall
```

— the only stall source that could legitimately tell the pipeline "the imem
fetch has not returned yet" is hardcoded to zero. So `if_id_stall` doesn't
include the imem-in-flight cycles at all. The pipeline thinks every fetch
completes the same cycle the request goes out, and the c_controller-stale-
decode + IE-wall-latch race in bug #18 is the inevitable result.

The fetch revamp doesn't just clean up the c_controller's FSM — it also has
to fix the bus protocol layer below it (Fetch Issue Unit must check `ready`
before declaring a request "issued", and Fetch Buffer must only push entries
on `rvalid`). Both are already in the §4 module specs but should be flagged
as critical, not nice-to-have.

---

## 2. Architectural goals

1. **One unambiguous source of truth** for "what is the next instruction to
   present to the decoder."
2. **Redirects are a single primitive**, not per-source bypass muxes. Every
   redirect (trap entry, xRET, branch mispredict, debug resume, reset) flows
   through the same arbitrated path.
3. **ITLB misses / PTW walks on the fetch path are a regular case**, not an
   exception that needs a separate rescue FSM per redirect source.
4. **Compressed (C) support is cleanly isolated** behind a "pull next
   instruction from the fetch stream" interface — the rest of the pipeline
   should not know whether the current instruction was 16- or 32-bit, or
   whether it straddled a fetch word.
5. **Stalls and flushes have explicit ownership** — every stall source has a
   single producer, every flush has a single point of arbitration with a
   documented priority table.
6. **Easy to bolt on a BTB/BPU later** without another round of bypass muxes.

---

## 3. New block diagram

```
   ┌──────────────────────┐
   │  Redirect Arbiter    │  (purely combinational, single cycle)
   │                      │
   │  inputs (priority    │
   │  high → low):        │
   │   • trap_one_shot    │  ← interrupt_ctrl trap_valid
   │   • xret_one_shot    │  ← privilege_unit (ret_fire | sret_fire)
   │   • branch_mispredict│  ← bpu_mispredict
   │   • debug_resume     │  ← debug_ctrl resumeack
   │   • reset_redirect   │  ← reset_i edge
   │                      │
   │  outputs:            │
   │   • redirect_valid_o │
   │   • redirect_target_o│ ← mux of {handler_addr, sepc/mepc, branch_target,
   │   • redirect_kind_o  │     dpc, RESET_VECTOR}
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │  Fetch Issue Unit    │  (state machine + fetch_pc register)
   │                      │
   │  states:             │
   │   • IDLE             │ — buffer not full, no in-flight fetch
   │   • REQ              │ — driving imem.req=1 with addr=fetch_pc
   │   • WAIT             │ — req acknowledged, waiting for rdata
   │   • FAULT            │ — MMU returned a fault for the in-flight fetch
   │                      │
   │  owns:               │
   │   • fetch_pc[31:0]   │ — vaddr of the next fetch
   │   • inflight_pc[31:0]│ — vaddr of the in-flight fetch (for fault attribution)
   │                      │
   │  on redirect_valid:  │
   │   • abort in-flight  │ (signal MMU to discard PTW, drop imem.req)
   │   • fetch_pc <= target
   │   • flush fetch buffer
   │                      │
   │  outputs to MMU:     │
   │   • i_vaddr_o, i_req_o
   │  outputs to imem:    │
   │   • imem.req, imem.addr (= MMU(i_vaddr) once translated)
   └──────────┬───────────┘
              │ rdata + fault metadata
              ▼
   ┌──────────────────────┐
   │  Fetch Buffer        │  (2-deep FIFO of {word, vaddr, fault, fault_cause})
   │                      │
   │  push when imem      │
   │   returns rvalid     │
   │  pop when aligner    │
   │   consumes 1+ halves │
   │                      │
   │  flush on redirect   │
   └──────────┬───────────┘
              │ head entry
              ▼
   ┌──────────────────────┐
   │  Compressed Aligner  │  (combinational + tiny state)
   │                      │
   │  state:              │
   │   • half_index[1:0]  │ — which half-word in the buffer head we are at
   │                      │
   │  output to ID:       │
   │   • instruction_o    │ — full 32-bit insn or expanded compressed
   │   • pc_id_o          │ — vaddr of `instruction_o`
   │   • valid_o          │ — buffer has enough halves for this insn
   │   • fault_o          │ — instruction page fault on this insn
   │   • fault_cause_o    │
   └──────────┬───────────┘
              │
              ▼
   ┌──────────────────────┐
   │  Decode Producer     │  (thin glue: decoder + ID stage register wall)
   │                      │
   │  inputs:             │
   │   • instruction_o    │ from aligner
   │   • valid_o          │
   │   • fault_o          │
   │  output:             │
   │   • ctrl_bus_if_id   │
   │   • pc_id            │
   │   • insn_valid_id    │
   └──────────────────────┘
```

Compared to today, the key wins:

- `pc_out` (main PC) is replaced by `fetch_pc` inside the Fetch Issue Unit.
- `apc` (c_controller's PC) is replaced by `pc_id_o` from the Compressed
  Aligner, computed from the buffer head + `half_index`.
- `refetch_after_trap`, `refetch_after_ret`, the FSM-vs-stall race in
  `c_controller`, and the `trap_sequencer.SRET_WAIT` rescue all disappear.

---

## 4. Module specs

### 4.1 Redirect Arbiter

**Purpose:** single point that decides what address the next fetch should go to.

**File:** `design/core/fetch/src/redirect_arbiter.sv` (new)

```sv
typedef enum logic [2:0] {
    RDR_NONE       = 3'd0,
    RDR_RESET      = 3'd1,
    RDR_DEBUG      = 3'd2,
    RDR_TRAP       = 3'd3,
    RDR_XRET       = 3'd4,
    RDR_BRANCH     = 3'd5
} redirect_kind_e;

module redirect_arbiter (
    // Sources (one-shot or level — see notes per signal)
    input  logic        reset_i,
    input  logic        debug_resume_i,        // pulse
    input  logic        trap_valid_i,          // pulse from interrupt_ctrl
    input  logic [31:0] trap_target_i,         // mtvec/stvec base + cause*4
    input  logic        ret_fire_i,            // pulse from privilege_unit
    input  logic        sret_fire_i,           // pulse from privilege_unit
    input  logic [31:0] mepc_i,                // for MRET
    input  logic [31:0] sepc_i,                // for SRET
    input  logic        bpu_mispredict_i,      // level: high while ID has a mispredicted branch
    input  logic [31:0] branch_target_i,
    input  logic [31:0] dpc_i,                 // debug PC
    input  logic [31:0] reset_vector_i,        // 0x80000000 / 0x00001000 (BOOT)

    output logic            redirect_valid_o,
    output logic [31:0]     redirect_target_o,
    output redirect_kind_e  redirect_kind_o
);
```

**Priority** (high → low, single cycle):

```
reset_i              → RESET, target = reset_vector_i
debug_resume_i       → DEBUG, target = dpc_i
trap_valid_i         → TRAP,  target = trap_target_i
sret_fire_i          → XRET,  target = sepc_i
ret_fire_i           → XRET,  target = mepc_i
bpu_mispredict_i     → BRANCH,target = branch_target_i
(none)               → NONE,  redirect_valid_o = 0
```

**Edge-case rules:**

- xRET sources are one-shots from `privilege_unit` and are ALREADY gated by
  `!ie_stall_i` and `!ret_side_effects_done_o`. The arbiter does not need to
  re-gate them.
- `bpu_mispredict_i` is a *level* signal (true while a mispredicted branch is
  in ID). To prevent the arbiter from re-firing the same mispredict every
  cycle, the Fetch Issue Unit's REQ→WAIT FSM uses `redirect_kind_o ==
  RDR_BRANCH && redirect_target_o == fetch_pc` to drop the redirect after the
  first cycle. (Alternative: edge-detect at the source.)
- `trap_valid_i` and xRET pulses are mutually exclusive in practice
  (privilege_unit gates xRET on `!interrupt_valid_i`), so the priority above
  is mostly redundant — but documented for clarity.

### 4.2 Fetch Issue Unit

**Purpose:** owns `fetch_pc`, drives MMU `i_vaddr` + imem `req`, manages the
in-flight fetch lifecycle.

**File:** `design/core/fetch/src/fetch_issue.sv` (new)

```sv
typedef enum logic [1:0] {
    FIU_IDLE,
    FIU_REQ,
    FIU_WAIT,
    FIU_FAULT
} fiu_state_e;

module fetch_issue (
    input  logic        clk_i,
    input  logic        reset_i,

    // Redirect from arbiter
    input  logic            redirect_valid_i,
    input  logic [31:0]     redirect_target_i,
    input  redirect_kind_e  redirect_kind_i,

    // Fetch buffer status
    input  logic        buffer_full_i,
    output logic        buffer_push_o,
    output logic [31:0] buffer_push_word_o,
    output logic [31:0] buffer_push_vaddr_o,
    output logic        buffer_push_fault_o,
    output logic [4:0]  buffer_push_cause_o,
    output logic        buffer_flush_o,        // pulse on redirect

    // MMU instruction-side
    output logic        mmu_i_req_o,
    output logic [31:0] mmu_i_vaddr_o,
    input  logic [31:0] mmu_i_paddr_i,
    input  logic        mmu_i_stall_i,
    input  logic        mmu_i_fault_i,
    input  logic [4:0]  mmu_i_cause_i,
    output logic        mmu_i_abort_o,         // tell PTW to drop in-flight walk

    // imem (icache)
    output logic        imem_req_o,
    output logic [31:0] imem_addr_o,
    input  logic        imem_rvalid_i,
    input  logic [31:0] imem_rdata_i,

    // Status
    output logic        in_flight_o            // for hazard_unit / debug
);
```

**FSM:**

```
FIU_IDLE:
    if (redirect_valid_i)        next = FIU_REQ;  fetch_pc <= target
    else if (!buffer_full_i)     next = FIU_REQ;
    else                         stay

FIU_REQ:
    drive mmu_i_req_o = 1, mmu_i_vaddr_o = fetch_pc
    if (mmu_i_stall_i)           stay (PTW walking)
    else if (mmu_i_fault_i)      next = FIU_FAULT
    else                         drive imem_req_o = 1, imem_addr_o = mmu_i_paddr_i
                                 next = FIU_WAIT
    if (redirect_valid_i)        abort: mmu_i_abort_o = 1, next = FIU_REQ, fetch_pc <= target

FIU_WAIT:
    waiting for imem_rvalid_i
    if (imem_rvalid_i)           buffer_push_o = 1 with imem_rdata_i
                                 fetch_pc <= fetch_pc + 4
                                 next = FIU_IDLE (or REQ if !buffer_full)
    if (redirect_valid_i)        abort: imem.req=0, drop rdata, next = FIU_REQ, fetch_pc <= target

FIU_FAULT:
    push faulted entry to buffer with fault=1, cause = mmu_i_cause_i, vaddr = inflight_pc
    next = FIU_IDLE (don't issue more fetches until redirect)
    if (redirect_valid_i)        next = FIU_REQ, fetch_pc <= target
```

**Key properties:**

- On redirect, the FSM **always** drops to `FIU_REQ` with the new `fetch_pc`,
  flushes the buffer, and aborts any in-flight MMU walk. There is exactly one
  redirect entry point — no per-source bypasses anywhere.
- `fetch_pc` is the *next* fetch address. After a successful rvalid, it
  increments by 4. Compressed alignment is the buffer/aligner's problem, not
  the issue unit's.
- A page fault is a buffer entry, not a direct trap signal. The aligner
  propagates it to the decoder when (and only when) the faulting instruction
  is consumed. This is what kills the "stale i_fault" race that needed
  `trap_sequencer.SRET_WAIT`.

### 4.3 Fetch Buffer

**Purpose:** decouples imem rvalid timing from the aligner. Holds at least 2
fetch words so a 32-bit instruction straddling a word boundary can always be
assembled.

**File:** `design/core/fetch/src/fetch_buffer.sv` (new)

```sv
typedef struct packed {
    logic [31:0] word;
    logic [31:0] vaddr;          // base vaddr of this word (always 4-byte aligned)
    logic        fault;
    logic [4:0]  cause;          // cause when fault=1
} fetch_buffer_entry_t;

module fetch_buffer #(
    parameter int DEPTH = 2
) (
    input  logic clk_i,
    input  logic reset_i,
    input  logic flush_i,

    // Push from issue unit
    input  logic              push_i,
    input  fetch_buffer_entry_t push_entry_i,
    output logic              full_o,

    // Pop from aligner
    input  logic              pop_i,
    output fetch_buffer_entry_t head_entry_o,
    output fetch_buffer_entry_t next_entry_o,   // for cross-word peek
    output logic              empty_o,
    output logic [1:0]        count_o
);
```

**Notes:**

- DEPTH=2 is the minimum to support 32-bit instructions straddling word
  boundaries (compressed enabled). DEPTH=4 buys a small amount of fetch
  prefetching headroom. Pick 2 to start.
- `flush_i` clears the buffer in one cycle (combinational reset of
  read/write pointers and entry-valid bits).
- `head_entry_o` is the oldest entry (used for the first/lower half of an
  instruction). `next_entry_o` is the second-oldest (used for the upper half
  when a 32-bit instruction straddles).

### 4.4 Compressed Aligner

**Purpose:** consumes halves from the fetch buffer head and emits whole
instructions. Replaces the entire `c_controller` alignment FSM.

**File:** `design/core/fetch/src/compressed_aligner.sv` (new)

```sv
module compressed_aligner (
    input  logic clk_i,
    input  logic reset_i,
    input  logic flush_i,                 // pulse on redirect, resets half_index

    // Buffer interface
    input  fetch_buffer_entry_t head_i,
    input  fetch_buffer_entry_t next_i,
    input  logic                 head_valid_i,
    input  logic                 next_valid_i,
    output logic                 pop_o,    // 1 when consuming the head entry

    // Redirect — used to reseat half_index when sepc/mepc[1] = 1
    input  logic        redirect_valid_i,
    input  logic [31:0] redirect_target_i,

    // Output to decoder
    output logic [31:0] instruction_o,
    output logic [31:0] pc_id_o,
    output logic        instruction_valid_o,
    output logic        instruction_fault_o,
    output logic [4:0]  instruction_cause_o,
    output logic        is_compressed_o     // for predicted_pc and tracing
);
```

**Internal state:**

```sv
logic half_index;   // 0 = lower half of head, 1 = upper half
                    // (we track only one bit because half_index + word index
                    //  is captured by which entry we're popping)
```

**Combinational behaviour (per cycle):**

```
case (half_index)
    0: begin
        // Looking at the lower half of head
        lower16 = head_i.word[15:0]
        if (lower16[1:0] == 2'b11 || lower16 == 16'h0000) begin
            // 32-bit instruction or NOP — need both halves of head
            if (head_valid_i) begin
                instruction_o = head_i.word
                pc_id_o       = head_i.vaddr
                valid_o       = 1
                fault_o       = head_i.fault
                pop_o         = 1
                next_half_index = 0   // advance to next word
            end
        end else begin
            // 16-bit compressed at head[15:0]
            if (head_valid_i) begin
                instruction_o = expand_c(lower16)
                pc_id_o       = head_i.vaddr
                valid_o       = 1
                fault_o       = head_i.fault
                pop_o         = 0     // don't consume head yet — upper half is next
                next_half_index = 1
            end
        end
    end

    1: begin
        // Looking at upper half of head
        upper16 = head_i.word[31:16]
        if (upper16[1:0] == 2'b11) begin
            // 32-bit instruction straddles head and next
            if (head_valid_i && next_valid_i) begin
                instruction_o = {next_i.word[15:0], upper16}
                pc_id_o       = head_i.vaddr + 32'd2
                valid_o       = 1
                // fault attribution: if EITHER half faulted, the insn faults
                fault_o       = head_i.fault | next_i.fault
                cause_o       = head_i.fault ? head_i.cause : next_i.cause
                pop_o         = 1     // consume head, next becomes new head
                next_half_index = 1   // we're now at upper half of new head
                                      // (because the bottom 16 of next are
                                      //  the upper of this insn — already used)
                // wait — see refinement below
            end
        end else begin
            // 16-bit compressed at head[31:16]
            instruction_o = expand_c(upper16)
            pc_id_o       = head_i.vaddr + 32'd2
            valid_o       = 1
            fault_o       = head_i.fault
            pop_o         = 1
            next_half_index = 0
        end
    end
endcase
```

**Refinement for the straddled case:** when we consume `head[31:16]` (upper)
+ `next[15:0]` (lower of next as the upper of the straddled insn), we should
pop `head` AND advance `half_index` so the next emission looks at
`next[31:16]` (which becomes the new head's upper half). The sketched
"next_half_index = 1" handles this: after `pop_o`, the new head is what
`next` was, and we're looking at *its* upper half. Verify with a test that
covers the sequence:

```
addr 0x100: bytes [16-bit compressed][16-bit lower of 32]   ← word A
addr 0x104: bytes [16-bit upper of 32][16-bit compressed]   ← word B
addr 0x108: bytes [...]                                     ← word C
```

Expected emissions:
- (half=0, head=A) → 16-bit compressed at 0x100
- (half=1, head=A) → 32-bit @ 0x102 (straddled with B[15:0]); pop A
- (half=1, head=B) → 16-bit compressed at 0x106; pop B
- (half=0, head=C) → next instruction at 0x108

**Redirect handling:**

```sv
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i || flush_i)
        half_index <= 1'b0;
    else if (redirect_valid_i)
        half_index <= redirect_target_i[1];
    else if (instruction_valid_o)
        half_index <= next_half_index;
end
```

This is the key simplification: **`half_index` is reseated atomically by the
redirect**, the buffer is flushed atomically, and the next valid instruction
emerges naturally once the issue unit has filled the buffer with the
post-redirect words. No `BRANCH`/`MISALIGN` state machine, no apc/PC
inconsistency, no FSM-vs-stall race.

### 4.5 Decode Producer

**Purpose:** thin glue between the aligner and the existing ID stage register
wall + decoder. Mostly unchanged from today's wiring.

```
instruction_pipe   = aligner.instruction_o
pc_id              = aligner.pc_id_o
insn_valid_id      = aligner.instruction_valid_o & !id_flush
                     // id_flush from hazard_unit covers ie_stall back-pressure
ctrl_bus_if_id     = decoder(instruction_pipe)
i_fault_at_id      = aligner.instruction_fault_o    // routed to interrupt_ctrl
```

When `i_fault_at_id` is set, `interrupt_ctrl` raises a trap with the fault
metadata. This is the *only* path for instruction page faults — `mmu_i_fault`
no longer goes directly to `interrupt_ctrl`, it goes through the buffer.
That removes the "stale fault" hazard entirely.

---

## 5. Stall and flush primitives

The new model has **three** stalls (down from 4 today: `if_id_stall`,
`ie_stall`, `imem_stall`, `iwb_stall`):

| Name | Owner | Source | Effect |
|------|-------|--------|--------|
| `if_back_pressure` | hazard_unit | aligner.valid==0 OR `ie_stall` | hold ID stage |
| `ie_stall` | hazard_unit | alu_stall, dmem busy, AMO, mmu_d_stall, misalign, pmp_d_fault, d_page_fault, csr_ret_hazard | hold IE register wall |
| `back_pipeline_stalls` | hazard_unit | iwb wb pressure (typically zero in our design) | hold IMEM/IWB wall |

`if_back_pressure` no longer leaks "is the fetch path itself blocked" into ID
— the aligner just doesn't emit a valid instruction when its buffer is empty,
which is structurally identical to a stall but doesn't need an external signal
race.

**Flushes** (single-cycle pulses):

| Name | Triggered by | Effect |
|------|--------------|--------|
| `if_flush` | `redirect_valid` (any kind) | aligner clears `half_index`, buffer drops all entries, fetch_issue aborts in-flight |
| `id_flush` | `redirect_valid` from trap/xret/branch (NOT debug-resume) | ID stage drops the in-flight instruction (becomes NOP at IE register wall) |
| `ie_flush` | `redirect_valid && (kind != debug)` | IE stage drops |
| `imem_flush`, `iwb_flush` | based on cause and pipeline state, like today | drop downstream stages |

Concrete flush priority (when multiple sources fire on the same cycle):

```
1. reset_i               (highest)
2. redirect_kind == TRAP
3. redirect_kind == XRET
4. redirect_kind == BRANCH
5. redirect_kind == DEBUG
```

This matches the redirect arbiter's priority.

---

## 6. Interrupt / trap / xRET handling

### Trap entry

1. `interrupt_ctrl` decides a trap fires (cause computed from pending faults
   + interrupts).
2. `trap_valid_o` pulses for one cycle. CSR commits epc/cause/status.
3. Redirect arbiter sees `trap_valid_i`, emits `redirect_valid` with target =
   `mtvec` or `stvec` (vectored mode handled inside the arbiter).
4. Fetch issue unit aborts in-flight, flushes buffer, latches new `fetch_pc`.
5. Aligner clears `half_index`. Buffer empty.
6. Next cycle: fetch issue unit issues a fetch for the trap target. ITLB
   walk completes (warm or cold doesn't matter — the buffer waits), word is
   pushed to buffer, aligner emits the trap handler's first instruction.

**No `refetch_after_trap`. No "use pc_out instead of pc_in" mux.** The
trap target is captured by the redirect arbiter and committed to `fetch_pc`
in one cycle.

### xRET commit (warm or cold target)

1. `privilege_unit` decides xRET commits (gated by `!ie_stall`,
   `!csr_ret_hazard`, `!ret_side_effects_done`, `!interrupt_valid`).
2. CSR commits priv change, restores xPIE/xPP semantics.
3. `ret_fire` / `sret_fire` pulses. Redirect arbiter emits `redirect_valid`
   with target = `mepc` / `sepc`.
4. Fetch issue unit aborts in-flight (the SRET instruction's continuation
   fetch, which is irrelevant now), flushes buffer, latches `fetch_pc` =
   `sepc/mepc`.
5. Aligner reseats `half_index = sepc[1]`. Buffer empty.
6. Next cycle: fetch issue starts the fetch. **If the ITLB misses on the
   target, the fetch issue FSM goes IDLE→REQ and stays in REQ until the PTW
   completes.** No external "I'm waiting for SRET to land" tracking is
   needed — the FSM has the state.
7. PTW completes, ITLB filled, fetch happens, word pushed to buffer, aligner
   emits the first user-mode instruction.

**No `refetch_after_ret`. No `ret_pulse` PC bypass. No `trap_sequencer`
SRET_WAIT.** The cold-ITLB SRET case is the same code path as the warm case,
just with more cycles in `FIU_REQ`.

### Branch mispredict

1. `bpu_mispredict_i` goes high (from branch_comp in ID, against
   `predicted_taken` from the ID/IF interface).
2. Redirect arbiter emits `redirect_valid` with target = `branch_target`.
3. Fetch issue aborts, buffer flushes, aligner reseats.
4. Next fetch issues at branch target.

The level-vs-pulse caveat (section 4.1) is handled by either an edge detector
in the source or by the FIU dropping `redirect_valid` once `fetch_pc` matches
`branch_target`. Pick edge detection for simplicity.

### Debug halt / resume

Halt: `pstate == HALTED` causes hazard_unit to assert a stall on the
ID/IE/IMEM/IWB walls. The fetch issue unit can still service any in-flight
fetch, but stops issuing new ones because the buffer fills up and back-
pressures the FSM into `FIU_IDLE`. No special "halted" gating in the fetch
unit itself.

Resume: `debug_resume_i` pulses. Arbiter emits `redirect_valid` with target =
`dpc`. Same path as any other redirect.

### Reset

`reset_i` clears the FIU FSM to `FIU_IDLE` with `fetch_pc = RESET_VECTOR`,
empties the buffer, clears `half_index`. The first non-reset cycle naturally
transitions to `FIU_REQ` and starts fetching. No "fetch on reset" hack needed.

---

## 7. Sequence diagrams

### 7.1 Cold-ITLB SRET-to-U with target at half-word offset

```
cyc | event                                    | fetch_pc | buf | aligner state
----+-----------------------------------------+----------+-----+----------------
N   | SRET in ID, sret_fire pulses             | <SRET+4>| {SRET word} | half=1
N+1 | redirect_valid → arbiter emits SRET XRET | sepc    | {}  | half=sepc[1]
    | (FIU aborts in-flight, buffer flushes)
N+1 | FIU enters REQ state, drives mmu_vaddr   | sepc    | {}  | (waiting)
N+1 | mmu_i_stall=1 (cold ITLB → PTW starts)
... PTW walks for K cycles
N+K | PTW completes, mmu_i_stall=0
N+K | FIU drives imem.req=1, addr=phys(sepc)
N+K | FIU enters WAIT state
N+K+1| imem_rvalid=1, FIU pushes {word, sepc, fault=0}
    | buffer = {[sepc word]}
N+K+1| FIU back to REQ for sepc+4
N+K+2| aligner sees head, half=1 (from sepc[1]=1):
    | upper16 = head.word[31:16] (= first half of insn at sepc)
    | if 32-bit (upper16[1:0]==11): need next entry → not yet valid → wait
    | if 16-bit compressed: emit, pop, next-half=0
N+K+2| FIU finishes second word fetch (faster — same page now ITLB-warm)
    | buffer = {[sepc word], [sepc+4 word]}
N+K+3| aligner: head_valid && next_valid → emit straddled 32-bit, pop head
    | first user instruction emitted at pc_id = sepc
```

The key contrast with today: **no manual bypass, no force, no trap_sequencer**.
Just one clean path. The cold-ITLB latency shows up as cycles in `FIU_REQ`.

### 7.2 Trap during instruction fetch (target page not mapped)

```
cyc | event
----+---------------------------------------------------------------
N   | FIU in REQ state for fetch_pc=X
N   | mmu_i_fault=1 (PTW returned page fault)
N+1 | FIU enters FAULT state, pushes {word=X, vaddr=X, fault=1, cause=12}
N+1 | FIU back to IDLE (don't issue more fetches until redirect)
... aligner pops the faulted entry when it gets to it
N+M | aligner emits instruction_valid && instruction_fault=1
N+M | interrupt_ctrl sees the fault on the ID-stage instruction, decides
    | "ah, instruction page fault on the instruction we're about to execute"
    | → trap_valid pulses
N+M+1| redirect → mtvec, FIU flushes buffer, fetches from mtvec
```

No way for a fault to "leak" — it travels with its instruction through the
buffer.

### 7.3 OpenSBI early init MRET to S-mode (warm case)

```
cyc | event
----+---------------------------------------------------------------
N   | MRET in ID, ret_fire pulses
N+1 | redirect → fetch_pc=mepc, buffer flush, aligner half=mepc[1]
N+1 | FIU REQ for mepc; ITLB warm → mmu_i_stall=0; imem.req=1
N+2 | imem_rvalid → push word, FIU back to REQ for mepc+4
N+2 | aligner emits first kernel instruction
```

The duplicate-fetch problem that bit my early `refetch_after_ret` attempt
cannot occur here because the FIU's REQ state is the *only* place a fetch is
issued, and it always advances `fetch_pc` after a successful rvalid.

---

## 8. Test plan

Each module + the integrated subsystem need targeted tests. Existing RISCOF
+ Linux boot is the system-level regression gate; the unit tests below are
the white-box gates.

### 8.1 Module-level (assertion-driven, runs in Verilator)

**redirect_arbiter:**
- `T1` priority: assert that when both `trap_valid_i` and `sret_fire_i` are
  high, `redirect_kind_o == RDR_TRAP`.
- `T2` xret priority: when `ret_fire_i` and `sret_fire_i` are both high (can't
  happen in real flow but defensive), assert SRET wins.
- `T3` no-redirect: when all sources low, `redirect_valid_o == 0`.
- `T4` reset: assert `redirect_kind_o == RDR_RESET` while `reset_i == 1`.

**fetch_issue:**
- `T5` cold-ITLB: assert FSM stays in `FIU_REQ` while `mmu_i_stall_i` is high
  and the FSM never issues an `imem.req` with a stale `mmu_i_paddr_i`.
- `T6` redirect mid-WAIT: drop `imem_rvalid_i` cleanly, latch new `fetch_pc`,
  return to REQ, no bogus push.
- `T7` redirect mid-FAULT: drop the pending fault push, return to REQ.
- `T8` sequential progression: after a successful rvalid, `fetch_pc`
  increments by exactly 4.

**fetch_buffer:**
- `T9` straddled 32-bit: push two words, peek both via `head_o` and
  `next_o`, verify content + vaddrs.
- `T10` flush: assert single-cycle clear.
- `T11` full→empty cycle: push DEPTH entries, pop all, verify ordering.

**compressed_aligner:**
- `T12` 32-bit aligned: push one word containing a 32-bit insn, emit + pop.
- `T13` 16-bit + 16-bit in one word: push, emit two compressed insns from
  the same head, second emission has `pc_id = head.vaddr + 2`.
- `T14` straddled 32-bit: scenario from §4.4 refinement.
- `T15` redirect to half-aligned: assert `half_index` reseats correctly,
  next emission has `pc_id = redirect_target`.
- `T16` fault propagation: faulted buffer entry → `instruction_fault_o`
  pulses on the matching emission.
- `T17` straddled fault: only the *upper* word faulted; assert the
  straddled-32-bit emission carries the upper's cause.

### 8.2 Integration scenarios

**Cold ITLB on every redirect kind:**
- `S1` Trap to mtvec where mtvec page is cold.
- `S2` SRET to U-mode where user page is cold.
- `S3` MRET to S-mode where S-mode kernel is at a cold page (RVlinux init).
- `S4` Branch mispredict where branch target is in a cold page.
- `S5` Debug resume where DPC is on a cold page.

For each, assert:
- The correct first instruction reaches ID exactly once (no skipping, no
  duplication).
- `pc_id` matches the redirect target (or target+2 for straddled).
- No spurious `interrupt_valid` pulses during the redirect → fetch transition.

**Compressed edge cases:**
- `S6` xRET target at `vaddr[1]=1` where the upper half starts a 32-bit
  insn that straddles into the next page (next page is unmapped → fault on
  the straddled insn's upper half should trap with the *straddled* PC, not
  the next page's address).
- `S7` BPU mispredict to a 16-bit compressed instruction at `vaddr[1]=1`.

**Trap-during-fetch:**
- `S8` Page fault on the fetch right after a redirect. The fault should be
  attributed to the post-redirect target, not pre-redirect leftovers.

### 8.3 Regression gates

- RISCOF 191/198 (or whatever the current baseline is) must remain green.
- Linux boot must reach the same milestone it reached on the with-C minimal
  fix (currently: `Run /init as init process` → user code at `0x947d7024`).
- The xRET stress test (`riscv-dv directed/sret_itlb_miss.S`,
  `csr_branch_hazard.S`, `trap_csr_branch.S`) must all pass.

---

## 9. Migration strategy

This is a multi-week central-datapath replacement; do it AFTER:
- Linux boots end-to-end on the current minimal `ret_pulse` SRET fix.
- RISCOF passes the current 191/198 baseline cleanly.
- The current code is checkpointed and tagged in git.

### Phase 1: parallel arbiter (no behaviour change, ~1-2 days)

1. Add `redirect_arbiter.sv` driven by the existing signals
   (`interrupt_valid`, `ret_fire`, `sret_fire`, `bpu_mispredict`,
   `resumeack`).
2. Wire its outputs to a set of *observation* signals (no functional use).
3. Add an SVA assertion: `redirect_valid_o` matches the existing
   `(pc_sel != PC_plus_4)` every cycle.
4. Run RISCOF + Linux boot. Any assertion failure is a bug in the arbiter
   (or the existing system has a case I missed).

### Phase 2: parallel fetch buffer + aligner (~1 week)

5. Add `fetch_buffer.sv` and `compressed_aligner.sv`. Drive them from the
   *existing* fetch path (snoop `imem_port.rdata` and `imem_port.req`).
6. Compare `aligner.instruction_o` against the existing
   `c_controller.instruction_o` every cycle with an assertion.
7. Compare `aligner.pc_id_o` against `c_controller.instruction_addr_o`.
8. Iterate until the parallel path matches for a full RISCOF run.
9. **Do not switch the decoder over yet.** This phase is purely cross-check.

### Phase 3: switch the decoder (~2-3 days)

10. Wire the decoder to read from the new aligner. The c_controller is now
    dead but still in the netlist for one more validation pass.
11. Run RISCOF + Linux. Both must pass.
12. Once stable for two full runs, delete the c_controller files.

### Phase 4: replace main PC with fetch issue unit (~3-5 days)

13. Add `fetch_issue.sv`. Drive it from the new `redirect_arbiter`.
14. Switch `imem_port.req` / `imem_port.addr` and the MMU `i_vaddr_i` to
    come from the fetch issue unit instead of the existing `pc_in`/`pc_out`
    + bypass mux mess.
15. Delete:
    - `refetch_after_trap` from `hazard_unit` (the buffer + arbiter handle
      it)
    - `ret_pulse` PC bypass in `core_top.sv`
    - The interrupt-bypass on the main `program_counter` stall
    - The whole `program_counter_inst` instance — `fetch_pc` lives inside
      the fetch issue unit
16. Run RISCOF + Linux. **Each removal is its own commit with its own
    regression run** so we can bisect cleanly if anything breaks.

### Phase 5: tidy `hazard_unit` and `trap_sequencer` (~1-2 days)

17. Drop `trap_sequencer.SRET_WAIT` — the buffer flush makes it redundant.
    Verify with `riscv-dv directed/sret_itlb_miss.S` that no stale i_fault
    fires.
18. Simplify `hazard_unit`'s flush matrix now that the IF stage owns its
    own pipeline state.
19. Update `linux_boot_bugs_and_fixes.md` with a post-mortem section
    explaining how the new design closes bugs 13–15 by construction.

### Phase 6: integration test pass (~2-3 days)

20. Run all 17 unit tests from §8.1 in CI.
21. Run all 8 integration scenarios from §8.2.
22. Run RISCOF, Linux boot, save_context test, sret_itlb_miss test.
23. If anything fails, do not merge until fixed.

### Phase 7: real I/D caches with miss handling (~1 week, optional, post-pipeline)

The current `design/memory/src/icache.sv` and `design/memory/src/dcache.sv`
are **transparent pass-throughs**: they always assert `ready=1`, always
forward to the backing SRAM, and always return data with the same 1-cycle
latency. The "cache" arrays exist but are dead weight on the data path —
the rdata mux falls through to `mem_rdata_i` on every access.

This is a *consequence* of the no-IF/ID-register architecture. A real cache
that stalls on miss has no place to park the in-flight instruction in the
current pipeline (`if_id_stall_o` doesn't actually hold `imem_port.rdata`,
as bug #18's bandaid failure proved). The fetch buffer in Phase 2 is what
finally gives downstream logic a place to wait while a miss fills.

Once Phases 1-6 are merged and the FIU/buffer/aligner pipeline is in place:

24. **icache rewrite**: replace the transparent passthrough with a proper
    direct-mapped cache that asserts `ready=0` on miss while it issues a
    backing-store request. The FIU's `FIU_REQ` state already handles this
    correctly — it stays in REQ until `imem_port.ready && imem_port.rvalid`
    arrives. Add a fill FSM and a miss-status holding register (MSHR-lite,
    1 outstanding miss is enough for an in-order core).
25. **dcache rewrite**: same pattern on the load/store path. Stores are
    write-through (current model is fine). Loads need to back-pressure the
    IE stage's `mmu_d_stall_i` until the fill returns. The hazard_unit
    already handles `mmu_d_stall_i` correctly, so this is mostly a slave-
    side change.
26. **FENCE.I and FENCE**: today flush all entries in 1 cycle. Keep the
    same semantics; the new caches just have non-trivial valid bits to
    clear.
27. **RISCOF + Linux gate**: the cache rewrite is the highest-risk part of
    the revamp because it changes timing across the entire memory system.
    Run RISCOF + Linux + sret_itlb_miss + the riscv-dv directed tests
    after each cache change in isolation.

**Cache phase is optional** in the sense that it can ship later — the
fetch revamp (phases 1-6) closes bugs 13-18 by itself. The cache revamp is
a *quality* improvement: real hit/miss behaviour, reduced power, more
realistic ASIC characterization. But it should not block the pipeline
revamp from merging.

**Total estimate:** 2-3 weeks for phases 1-6, +1 week for phase 7. Phases
1-3 can run in parallel with other tasks because the new code is purely
additive.

---

## 10. Risk register

| # | Risk | Mitigation |
|---|------|------------|
| R1 | Parallel cross-check assertions miss a corner case, hiding a bug until phase 3 | Ensure RISCOF + Linux boot are both run with assertions enabled in phase 2; treat any missed corner case as a phase-2 escape and add a unit test |
| R2 | The straddled 32-bit instruction case in the aligner is fragile | Phase 2 cross-check catches it; also add unit tests T14, S6 |
| R3 | The MMU's "abort PTW" interface doesn't exist yet; the FIU's redirect mid-walk will leak a stale PTW result | Either add a real abort signal, OR have the FIU track which `mmu_vaddr_i` it issued and discard mismatched results; pick the latter to avoid an MMU change |
| R4 | A redirect during `FIU_FAULT` might double-push a fault entry | Unit test T7 covers this; FSM transition `FAULT → REQ` on redirect must clear the pending push |
| R5 | The fetch buffer becoming empty for K cycles during a cold ITLB walk back-pressures ID, which back-pressures IE — make sure none of the IE-stage hazards (CSR forwarding, AMO, etc.) deadlock in this case | Run Linux boot tests (longest exerciser of cold-ITLB walks) in phase 4 |
| R6 | BPU integration becomes harder, not easier | Section 4.1 explicitly leaves BTB integration as "another redirect source" — verify in design review |
| R7 | Phase 4 (PC replacement) has a long bisect window if it breaks | Each removal in phase 4 is its own commit; commit 4a, 4b, 4c separately so a bad commit can be reverted in isolation |
| R8 | RISCOF regressions surface late | Run full RISCOF suite at the end of every phase, not just phase 6 |

---

## 11. Temporary workaround: disable C extension

**Context:** [ultraembedded/riscv32_linux_from_scratch `kernel_config_rv32ima`](https://github.com/ultraembedded/riscv32_linux_from_scratch/blob/master/configs/kernel_config_rv32ima)
deliberately disables the C extension. Every compressed-instruction path we
have is a source of alignment FSM edge cases; dropping C sidesteps all of
them at the cost of a slightly larger kernel image.

This is **not a fix**. It's a parallel-track sanity check that lets us boot
Linux on a kernel that doesn't exercise the c_controller's MISALIGN/BRANCH
states, so we can verify the *rest* of the pipeline (xRET fix, MMU, traps,
SBI handoff) is correct independently of the compressed-decoding edge cases.

### What to change

1. **Kernel defconfig** — already done at
   [software/linux/ntiny_no_c_defconfig](software/linux/ntiny_no_c_defconfig).
   Key lines:
   ```
   # CONFIG_RISCV_ISA_C is not set
   # CONFIG_EFI is not set
   CONFIG_RISCV_SBI_V01=y
   CONFIG_HVC_RISCV_SBI=y
   CONFIG_SERIAL_EARLYCON_RISCV_SBI=y
   CONFIG_INITRAMFS_SOURCE="<path to initramfs.cpio.gz>"
   ```
   The first three are required because EFI_STUB selects RISCV_ISA_C, the
   second three because HVC_RISCV_SBI/EARLYCON_RISCV_SBI depend on
   RISCV_SBI_V01 (and Kconfig defaults silently drop them otherwise — bug
   #12). The initramfs path must be explicit or kernel_init panics.
2. **OpenSBI build** — `PLATFORM_RISCV_ISA=rv32ima_zicsr_zifencei`. Already
   wired in [software/linux/build_no_c.sh](software/linux/build_no_c.sh).
3. **Hardware:** leave the C extension enabled in RTL — we still want it for
   OpenSBI compressed-aware paths in the with-C build, and for compressed
   RISCOF tests. The kernel just won't emit any 16-bit instructions, and
   `apc` stays in ALIGN forever for kernel code.

### Verification

```sh
PATH=/opt/riscv-linux/bin:$PATH riscv32-unknown-linux-gnu-readelf -h \
  ~/Downloads/linux/vmlinux | grep Flags
# expected: "Flags:  0x0"  (RVC bit not set)

riscv32-unknown-linux-gnu-objdump -d ~/Downloads/linux/vmlinux \
  | awk '/^c[0-9a-f]{7}:/ {n=index($0,"\t"); rest=substr($0,n+1)
                            m=index(rest,"\t"); enc=substr(rest,1,m-1)
                            gsub(/ /,"",enc)
                            if (length(enc)==4 && $0 !~ /\.insn/) print}'
# expected: empty (no real 16-bit compressed instructions)
```

The current no-C build passes both checks (verified April 7).

### Caveats

- Userspace (busybox/glibc/ld-linux) is still C-enabled because the toolchain
  default is `rv32imac`. This workaround only sidesteps c_controller edge
  cases on **kernel** code — once Linux SRETs to user, all the compressed
  edge cases come back. To get a fully C-free system, the libc + busybox
  would need rebuilding too (significant effort, separate task).
- The long-term design target stays RV32IMAC. This is a *bridge*, not a
  destination.

---

## 11.5. Attempted bandaid for bug #18 (FAILED — reverted 2026-04-07)

**Context:** Bug #18 is "the IE register wall latches a NOP for handler[0]
because the c_controller's `instruction_pipe` decodes stale `imem_port.rdata`
at the cycle the trap-target apc is captured." The proper fix is the Fetch
Issue Unit FSM in §4 with explicit `IDLE/REQ/WAIT/FAULT` "fetch in flight"
tracking — when a fetch is outstanding, the aligner does not advance and the
ID-stage instruction stays gated until `rvalid` returns.

The bandaid below was attempted as a stop-gap but **DID NOT WORK** — the
recursive `handle_exception` loop returned identically. Reverted in the same
session. The failure is documented here as a record so future attempts don't
re-tread the same wrong path.

The bandaid added a single 1-bit register in
[design/core/core_top/src/core_top.sv](../design/core/core_top/src/core_top.sv):

```sv
logic imem_pending_post_trap;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        imem_pending_post_trap <= 1'b0;
    else if (interrupt_valid)
        imem_pending_post_trap <= 1'b1;
    else if (imem_port.rvalid)
        imem_pending_post_trap <= 1'b0;
end
```

It was wired into `hazard_unit_inst.icache_stall_i` (which used to be
hardcoded to `1'b0`). `if_id_stall_o` already ORs `icache_stall_i` into the
stall vector, so the *intent* was to extend the IF/ID stall window across
the entire trap-target round trip: from the cycle `interrupt_valid` fires
through the first imem `rvalid` *after* the trap.

### Why it failed

The bandaid assumed that "stalling `if_id_stall`" would also "hold the
instruction word steady at the c_controller's input." It does not.

ntiny has **no IF/ID pipeline register** — the imem SRAM's output register is
absorbed into the pipeline as the IF/ID stage register. `imem_port.rdata`
feeds the c_controller and decoder *combinationally*. So:

1. Stalling `if_id_stall` only delays the *IE register wall* from latching
   the decoded ctrl_bus. It does NOT hold `imem_port.rdata`.
2. While the stall is high, `imem_port.rdata` continues to change as the
   SRAM presents whatever it presents each cycle (the next sequential
   word's data, or zeros, or whatever the OBI slave is driving).
3. When the stall releases, the c_controller decodes whatever happens to be
   on `rdata` at that moment, and the IE wall latches *that* — not
   necessarily the trap-target instruction.

The bandaid simply moved the race window without closing it. Verilator
rebuild + with-MMU Linux re-run produced the **identical** recursive
`handle_exception` loop that bug #18 originally caused:
```
PC[162529280] pc=c0002428 priv=1
PC[163577856] pc=c000240c priv=1
PC[164626432] pc=c000241c priv=1
PC[165675008] pc=c0002428 priv=1   ← repeats
```

### Lesson

Any fix for bug #18 must hold the **instruction word**, not the IE register
wall. That requires a structural change:

- **A real IF/ID register** that captures `rdata` on `rvalid=1` and decouples
  decode from the bus (paying +1 branch penalty unless a BPU compensates), or
- **A fetch buffer** between `imem_port` and the c_controller that pushes on
  `rvalid` and pops only when the consumer is ready (this is what §4.3 of
  this plan specifies), or
- **Gating the c_controller's clock enable** by an explicit "fetch in flight"
  signal so its internal state doesn't advance until rvalid returns
  (equivalent to the FIU FSM in §4.2).

All three are part of the revamp. There is no purely-stall-based fix that
works in this architecture.

---

## 12. Recommendation

In order:

1. **Ship the minimal `ret_pulse` PC bypass fix** ✅ (done; Linux boots
   through OpenSBI, kernel init, and SRET-to-U).
2. **Get Linux to a userspace shell prompt on the with-C build.** Currently
   stuck at ld-linux `_start` (`0x947d7024`); root cause unknown. Capture a
   VCD around the user-mode entry and trace the fault loop / wrong-paddr
   theories from the analysis log.
3. **In parallel, run the no-C kernel** ([software/linux/build_no_c.sh](software/linux/build_no_c.sh))
   as a sanity check. If it reaches userspace cleanly, the with-C hang is
   compressed-instruction-related and prioritises the revamp.
4. **Run RISCOF** to confirm the minimal SRET fix didn't regress the
   191/198 baseline.
5. **Commit the current state** as the "Linux boots to userspace" checkpoint
   and tag it in git.
6. **Start Phase 1 of the revamp** on a `fetch-revamp` branch. Don't merge
   until phases 1-6 all pass and the assertion-based parallel cross-checks
   are clean.

This minimises the window where main is broken and keeps the revamp risk
contained to a branch. The whole revamp eliminates four classes of bugs (14,
15, the stale-fault race, and the FSM-vs-stall race) by construction, not
by bandaids — which is the only way to stop them recurring as we add new
features (BPU/BTB, V extension, hypervisor, …) on top of the current
foundation.
