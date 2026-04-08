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
    output logic                 is_compressed_o
);

    logic        half_index_q;
    logic        next_half_index;
    logic        pop_internal;
    logic [15:0] expand_in;
    logic [31:0] expand_out;

    // Reuse the existing c_dec compressed-to-32-bit expander
    c_dec aligner_c_dec_inst (
        .ins_16 (expand_in),
        .ins_32 (expand_out)
    );

    // ── Combinational emit ─────────────────────────────────────────────
    always_comb begin
        // Defaults: no emission
        instruction_o        = 32'b0;
        pc_id_o              = 32'b0;
        instruction_valid_o  = 1'b0;
        instruction_fault_o  = 1'b0;
        instruction_cause_o  = 5'b0;
        is_compressed_o      = 1'b0;
        pop_internal         = 1'b0;
        next_half_index      = half_index_q;
        expand_in            = 16'b0;

        if (head_valid_i) begin
            case (half_index_q)
                1'b0: begin
                    // Lower half of head
                    if (head_i.word[1:0] == 2'b11) begin
                        // 32-bit aligned at head[15:0]
                        instruction_o       = head_i.word;
                        pc_id_o             = head_i.vaddr;
                        instruction_valid_o = 1'b1;
                        instruction_fault_o = head_i.fault;
                        instruction_cause_o = head_i.cause;
                        is_compressed_o     = 1'b0;
                        pop_internal        = 1'b1;
                        next_half_index     = 1'b0;
                    end else begin
                        // 16-bit compressed at head[15:0]
                        expand_in           = head_i.word[15:0];
                        instruction_o       = expand_out;
                        pc_id_o             = head_i.vaddr;
                        instruction_valid_o = 1'b1;
                        instruction_fault_o = head_i.fault;
                        instruction_cause_o = head_i.cause;
                        is_compressed_o     = 1'b1;
                        pop_internal        = 1'b0;  // upper half still in head
                        next_half_index     = 1'b1;
                    end
                end

                1'b1: begin
                    // Upper half of head
                    if (head_i.word[17:16] == 2'b11) begin
                        // 32-bit straddled across head[31:16]+next[15:0]
                        if (next_valid_i) begin
                            instruction_o       = {next_i.word[15:0], head_i.word[31:16]};
                            pc_id_o             = head_i.vaddr + 32'd2;
                            instruction_valid_o = 1'b1;
                            instruction_fault_o = head_i.fault | next_i.fault;
                            instruction_cause_o = head_i.fault ? head_i.cause : next_i.cause;
                            is_compressed_o     = 1'b0;
                            pop_internal        = 1'b1;
                            // After popping head, next becomes the new head.
                            // We've already consumed bits [15:0] of "next" as
                            // the upper half of the straddled insn, so the
                            // next instruction starts at bits [31:16] of the
                            // new head → half_index = 1.
                            next_half_index     = 1'b1;
                        end
                        // else: wait for next entry — instruction_valid_o stays 0
                    end else begin
                        // 16-bit compressed at head[31:16]
                        expand_in           = head_i.word[31:16];
                        instruction_o       = expand_out;
                        pc_id_o             = head_i.vaddr + 32'd2;
                        instruction_valid_o = 1'b1;
                        instruction_fault_o = head_i.fault;
                        instruction_cause_o = head_i.cause;
                        is_compressed_o     = 1'b1;
                        pop_internal        = 1'b1;
                        next_half_index     = 1'b0;
                    end
                end
            endcase
        end
    end

    // Pop is gated by consumer take and emission validity
    assign pop_o = pop_internal && consumer_take_i && instruction_valid_o;

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
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i)
            half_index_q <= 1'b0;
        else if (redirect_valid_i)
            half_index_q <= redirect_target_i[1];
        else if (flush_i)
            half_index_q <= 1'b0;
        else if (instruction_valid_o && consumer_take_i)
            half_index_q <= next_half_index;
    end

endmodule
