// ── Compressed Aligner ──────────────────────────────────────────────────
// Phase 2.2 of the fetch / c_controller / interrupt / stall revamp.
// See docs/fetch_revamp_plan.md §4.4 (spec) and §9 Phase 2 (migration).
//
// PURPOSE
//   Replaces the c_controller's ALIGN/MISALIGN/BRANCH FSM with a single-
//   bit `half_index` state plus combinational lookup into a fetch buffer
//   that holds at least 2 words. Emits one decoded RV32 instruction per
//   cycle when the buffer has enough halves and the consumer is taking.
//
//   Key simplification vs c_controller:
//     - No internal `ins_buffer` register: the upper half of a straddled
//       32-bit instruction lives in the FETCH BUFFER's head/next entries,
//       not in private state inside this module
//     - No "fake NOP" injection on BRANCH+upper_32bit bubbles: this
//       module just doesn't emit (instruction_valid_o = 0) until the
//       next buffer entry arrives, and the consumer naturally stalls
//     - Redirect handling is one register update (half_index reseat),
//       not a separate FSM state
//
// PHASE 2.2 STATUS
//   This module is INSTANTIATED IN PARALLEL with the existing
//   c_controller in core_top.sv. It reads from the same parallel
//   fetch_buffer (also a snoop). Its outputs are NOT consumed by any
//   functional path. An SVA cross-check assertion in core_top.sv
//   compares this module's instruction_o + pc_id_o against the
//   c_controller's instruction_pipe + pc_id on every cycle the
//   consumer takes (i.e. !if_id_stall) AND both paths emit a real
//   instruction (skipping the c_controller's BRANCH-bubble cycles
//   where it injects a NOP while we wait for next buffer entry).
//
// SEMANTICS
//   - half_index = 0: looking at lower half of head (head.word[15:0])
//   - half_index = 1: looking at upper half of head (head.word[31:16])
//   - On a 32-bit instruction at head[15:0]: emit head.word, pop head,
//     half stays at 0 (we advance to the next word)
//   - On a 16-bit compressed at head[15:0]: emit expand_c(head[15:0]),
//     do NOT pop (upper half is still in head), advance half to 1
//   - On a 32-bit straddled at head[31:16]+next[15:0]: emit the
//     combined word, pop head, half stays at 1 (we now look at upper
//     half of the new head, which was next)
//   - On a 16-bit compressed at head[31:16]: emit expand_c(head[31:16]),
//     pop head, half goes back to 0
//   - On redirect: half_index reseats to redirect_target[1]
//   - On flush: half_index resets to 0 (the buffer flush is the
//     orthogonal operation, handled by the buffer module)

module compressed_aligner
    import fetch_pkg::*;
(
    input  logic                 clk_i,
    input  logic                 reset_i,
    input  logic                 flush_i,             // pulse on redirect
    input  logic                 consumer_take_i,     // 1 when consumer will consume this cycle's emit

    // ── Buffer interface (peek) ─────────────────────────────────────────
    input  fetch_buffer_entry_t  head_i,
    input  fetch_buffer_entry_t  next_i,
    input  logic                 head_valid_i,
    input  logic                 next_valid_i,
    output logic                 pop_o,               // 1 when consumer takes & we are done with head

    // ── Redirect (reseats half_index) ───────────────────────────────────
    input  logic                 redirect_valid_i,
    input  logic [31:0]          redirect_target_i,

    // ── Output to decoder ───────────────────────────────────────────────
    output logic [31:0]          instruction_o,
    output logic [31:0]          pc_id_o,
    output logic                 instruction_valid_o,
    output logic                 instruction_fault_o,
    output logic [4:0]           instruction_cause_o,
    output logic                 is_compressed_o,
    // BPU at IF: forward the prediction stored in the head entry to ID.
    // Only meaningful when instruction_valid_o is high.
    output logic                 pred_taken_o,
    output logic [31:0]          pred_target_o
);

    logic        half_index_q;
    logic        next_half_index;
    logic        pop_internal;
    logic [15:0] expand_in;
    logic [31:0] expand_out;
    logic        instruction_valid_raw;  // pre-squash emit (internal)

    // ── Post-branch squash FSM ─────────────────────────────────────────
    // When the aligner emits an IF-stage predicted-taken branch, any
    // remaining halves of the current entry and any subsequent entries
    // in the fetch_buffer are WRONG-PATH (the BPU redirect fires at IF
    // without flushing the buffer, so pre-redirect residue stays).
    //
    // In squash:
    //   - instruction_valid_o = 0 (don't emit anything)
    //   - pop_o drains the buffer autonomously (independent of consumer)
    //   - exit when the head entry's word matches the predicted target's
    //     word-aligned vaddr; reseat half_index_q to target[1]
    //
    // This is required for correctness when an RVC branch sits at the
    // lower half of a word: the upper half is wrong-path, and without
    // squash the aligner would emit garbage (worst case: a straddled
    // 32-bit instruction stitched across the current head and the next
    // buffer entry — which is already the target's word after the IF
    // redirect, producing a decode-level "mash-up" that corrupts regs).
    logic        squash_q;
    logic [31:0] squash_target_q;

    // Reuse the existing c_dec compressed-to-32-bit expander
    c_dec aligner_c_dec_inst (
        .ins_16 (expand_in),
        .ins_32 (expand_out)
    );

    // ── Combinational emit ─────────────────────────────────────────────
    // BPU pred is per-half: the head entry carries {pred_lo_*, pred_hi_*}
    // filled in at IF time for vaddr+0 and vaddr+2 respectively. The
    // aligner fires the prediction on the emit whose half_index matches
    // the predicted branch's half, ensuring a two-RVC word with a branch
    // at the upper half doesn't fire pred on the lower-half emit.
    //
    // Straddle case (32-bit branch at head[31:16]+next[15:0]) also fires
    // on half_index=1 and naturally consumes pred_hi_*.
    logic lo_consumed_q, hi_consumed_q;
    // squash_head_is_target is computed further down (in the squash-
    // gating block) but is referenced here in eff_half_idx. Forward-
    // declare so Vivado doesn't fall back to an implicit 1-bit net
    // (Synth 8-6901). The actual driver lives at the natural locality.
    wire        squash_head_is_target;
    // Effective half index: on the cycle when squash is exiting (head is
    // the predicted target's word), override the registered half_index_q
    // with squash_target_q[1]. This lets the aligner emit the target's
    // first instruction on the SAME cycle the target word arrives at
    // head, saving the 1-cycle squash-exit delay.
    wire        squash_exit_now = squash_q && squash_head_is_target;
    wire        eff_half_idx    = squash_exit_now ? squash_target_q[1]
                                                   : half_index_q;
    wire  use_lo = head_valid_i && (eff_half_idx == 1'b0);
    wire  use_hi = head_valid_i && (eff_half_idx == 1'b1);
    // BPU IF squash disabled (see core_top.sv bpu_if_redirect_fire). Without
    // the IF-stage redirect actually firing, signaling pred_taken_o would
    // make the aligner squash a path that nothing else is going to redirect
    // away from, deadlocking the squash drain. So gate it with the same
    // condition: tied to 0 here, re-enable together with bpu_if_redirect_fire.
    assign pred_taken_o  = 1'b0;
    assign pred_target_o = (eff_half_idx == 1'b0) ? head_i.pred_lo_target
                                                   : head_i.pred_hi_target;

    always_comb begin
        // Defaults: no emission
        instruction_o          = 32'b0;
        pc_id_o                = 32'b0;
        instruction_valid_raw  = 1'b0;
        instruction_fault_o    = 1'b0;
        instruction_cause_o    = 5'b0;
        is_compressed_o        = 1'b0;
        pop_internal           = 1'b0;
        next_half_index        = eff_half_idx;
        expand_in              = 16'b0;

        if (head_valid_i) begin
            case (eff_half_idx)
                1'b0: begin
                    // Lower half of head
                    if (head_i.word[1:0] == 2'b11) begin
                        // 32-bit aligned at head[15:0]
                        instruction_o         = head_i.word;
                        pc_id_o               = head_i.vaddr;
                        instruction_valid_raw = 1'b1;
                        instruction_fault_o   = head_i.fault;
                        instruction_cause_o   = head_i.cause;
                        is_compressed_o       = 1'b0;
                        pop_internal          = 1'b1;
                        next_half_index       = 1'b0;
                    end else begin
                        // 16-bit compressed at head[15:0]
                        expand_in             = head_i.word[15:0];
                        instruction_o         = expand_out;
                        pc_id_o               = head_i.vaddr;
                        instruction_valid_raw = 1'b1;
                        instruction_fault_o   = head_i.fault;
                        instruction_cause_o   = head_i.cause;
                        is_compressed_o       = 1'b1;
                        pop_internal          = 1'b0;  // upper half still in head
                        next_half_index       = 1'b1;
                    end
                end

                1'b1: begin
                    // Upper half of head
                    if (head_i.word[17:16] == 2'b11) begin
                        // 32-bit straddled across head[31:16]+next[15:0]
                        if (next_valid_i) begin
                            instruction_o         = {next_i.word[15:0], head_i.word[31:16]};
                            pc_id_o               = head_i.vaddr + 32'd2;
                            instruction_valid_raw = 1'b1;
                            instruction_fault_o   = head_i.fault | next_i.fault;
                            instruction_cause_o   = head_i.fault ? head_i.cause : next_i.cause;
                            is_compressed_o       = 1'b0;
                            pop_internal          = 1'b1;
                            // After popping head, next becomes the new head.
                            // We've already consumed bits [15:0] of "next" as
                            // the upper half of the straddled insn, so the
                            // next instruction starts at bits [31:16] of the
                            // new head → half_index = 1.
                            next_half_index       = 1'b1;
                        end
                        // else: wait for next entry — instruction_valid_raw stays 0
                    end else begin
                        // 16-bit compressed at head[31:16]
                        expand_in             = head_i.word[31:16];
                        instruction_o         = expand_out;
                        pc_id_o               = head_i.vaddr + 32'd2;
                        instruction_valid_raw = 1'b1;
                        instruction_fault_o   = head_i.fault;
                        instruction_cause_o   = head_i.cause;
                        is_compressed_o       = 1'b1;
                        pop_internal          = 1'b1;
                        next_half_index       = 1'b0;
                    end
                end
            endcase
        end
    end

    // ── Squash gating ─────────────────────────────────────────────────
    // In squash state: suppress all emits and drain the buffer, UNLESS
    // the head is the predicted target's word — in that case we're
    // exiting squash and want to emit target's first instruction on the
    // same cycle (see eff_half_idx override above).
    wire [31:0] squash_target_word     = {squash_target_q[31:2], 2'b00};
    assign      squash_head_is_target  = head_valid_i
                                      && (head_i.vaddr == squash_target_word);
    // "Really squashed" = squash_q is set AND head is NOT yet the target.
    // On the exit cycle (squash_q=1, head=target), eff_squash=0 so emit
    // and pop behave normally, emitting target's first instruction.
    wire        eff_squash = squash_q && !squash_head_is_target;
    // Enter squash when the current emit is a predicted-taken branch.
    wire        enter_squash = !squash_q
                            && instruction_valid_raw
                            && consumer_take_i
                            && pred_taken_o;

    assign instruction_valid_o = eff_squash ? 1'b0 : instruction_valid_raw;

    // Pop: in real-squash, drain the buffer autonomously (not gated by
    // consumer_take_i, since the consumer sees instruction_valid_o=0).
    // On the exit cycle, pop per normal emit rules.
    assign pop_o = eff_squash ? head_valid_i
                               : (pop_internal && consumer_take_i && instruction_valid_raw);

    // ── half_index state update ────────────────────────────────────────
    // Priority: reset > redirect > flush > consumed-emit advance
    //
    // redirect_valid_i must take priority over flush_i because in the
    // top-level wiring `fetch_flush = arb_redirect_valid` (the same
    // signal). On a redirect to a half-aligned target the aligner needs
    // to reseat half_index = redirect_target[1] (= 1), but if `flush_i`
    // ran first it would reset half_index to 0 and the upper-half
    // instruction at the target would be misaligned.
    //
    // The flush_i branch is retained for explicit non-redirect flushes
    // (e.g. reset path or future debug halt resync), but in the current
    // wiring it is dominated by the redirect path.
    //
    // Combinational squash exit: on the cycle when squash_head_is_target
    // is true, eff_half_idx already reflects squash_target_q[1] (see
    // above), and the normal emit path (instruction_valid_o &&
    // consumer_take_i) drives next_half_index to the correct post-emit
    // value. So the normal emit-advance clause handles the exit case —
    // we only need a fallback for "squash exit without emit" (e.g., the
    // rare straddle-stall where target's upper half is a 32-bit straddle
    // waiting for the NEXT next_valid_i).
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            half_index_q <= 1'b0;
        else if (redirect_valid_i)
            half_index_q <= redirect_target_i[1];
        else if (flush_i)
            half_index_q <= 1'b0;
        else if (instruction_valid_o && consumer_take_i)
            half_index_q <= next_half_index;
        else if (squash_q && squash_head_is_target)
            half_index_q <= squash_target_q[1];
    end

    // Per-half consumed flags. Clear on pop (new head arrives) or any
    // flush/redirect. Each flag sets only when the matching half emits.
    // Priority: pop clears > emit sets > squash-exit-without-emit clears.
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i || flush_i || redirect_valid_i) begin
            lo_consumed_q <= 1'b0;
            hi_consumed_q <= 1'b0;
        end else if (pop_o) begin
            lo_consumed_q <= 1'b0;
            hi_consumed_q <= 1'b0;
        end else if (instruction_valid_o && consumer_take_i) begin
            if (use_lo) lo_consumed_q <= 1'b1;
            if (use_hi) hi_consumed_q <= 1'b1;
        end else if (squash_q && squash_head_is_target) begin
            // Squash exit without emit (rare straddle-stall case).
            lo_consumed_q <= 1'b0;
            hi_consumed_q <= 1'b0;
        end
    end

    // ── Squash state register ──────────────────────────────────────────
    // Cleared by async reset, flush, or an external redirect (those
    // already reseat the aligner). Set on the cycle a predicted-taken
    // branch emits. Cleared once the buffer head is the predicted
    // target's word. Async reset and sync clear (flush_i /
    // redirect_valid_i) are split into nested branches so Vivado's
    // sync/async register inference doesn't fire CRITICAL WARNING
    // [Synth 8-5413] (mixing async reset with synchronous control on
    // the same condition).
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            squash_q        <= 1'b0;
            squash_target_q <= 32'b0;
        end else if (flush_i || redirect_valid_i) begin
            squash_q        <= 1'b0;
            squash_target_q <= 32'b0;
        end else if (enter_squash) begin
            squash_q        <= 1'b1;
            squash_target_q <= pred_target_o;
        end else if (squash_q && squash_head_is_target) begin
            squash_q <= 1'b0;
        end
    end

endmodule
