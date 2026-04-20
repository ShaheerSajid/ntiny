// ── Fetch Subsystem Package ─────────────────────────────────────────────
// Phase 2.1+ of the fetch / c_controller / interrupt / stall revamp.
// See docs/fetch_revamp_plan.md §4.3 / §4.4.
//
// Shared types between fetch_buffer, compressed_aligner, and (eventually)
// fetch_issue_unit. Kept in its own package so the fetch subsystem can
// evolve without polluting core_pkg.

package fetch_pkg;

    // One slot in the fetch buffer.
    //
    //   word   — 32-bit fetch word (full imem.rdata)
    //   vaddr  — 4-byte-aligned base virtual address of this word, captured
    //            at imem.req time (NOT at rvalid time, since pc_in advances
    //            in the meantime)
    //   fault  — instruction page fault flag for this word; the aligner
    //            propagates it to the decoder when the consuming insn is
    //            actually emitted (Phase 2 leaves this 0 — fault propagation
    //            arrives in Phase 4 with the FIU)
    //   cause  — RISC-V trap cause when fault=1
    //   pred_lo_taken / pred_lo_target — IF-stage BPU verdict at vaddr+0.
    //   pred_hi_taken / pred_hi_target — IF-stage BPU verdict at vaddr+2.
    //                  Per-half tracking so the aligner fires prediction on
    //                  the ACTUAL branch's emit, not the other half-word. The
    //                  hi pair also covers 32-bit straddled branches (head
    //                  [31:16] + next[15:0]) — the straddle emits at
    //                  half_index=1, consuming pred_hi_*.
    typedef struct packed {
        logic [31:0] word;
        logic [31:0] vaddr;
        logic        fault;
        logic [4:0]  cause;
        logic        pred_lo_taken;
        logic        pred_hi_taken;
        logic [31:0] pred_lo_target;
        logic [31:0] pred_hi_target;
    } fetch_buffer_entry_t;

endpackage
