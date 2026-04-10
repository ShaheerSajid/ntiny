// ── Fetch Buffer ────────────────────────────────────────────────────────
// Phase 2.1 of the fetch / c_controller / interrupt / stall revamp.
// See docs/fetch_revamp_plan.md §4.3 (spec) and §9 Phase 2 (migration).
//
// PURPOSE
//   Decouple imem rvalid timing from the instruction aligner. Holds at
//   least 2 fetch words so a 32-bit instruction straddling a word
//   boundary can always be assembled from {head, next}.
//
//   In the final pipeline, this buffer + the FIU's "fetch in flight"
//   tracking is what closes bug #18: instruction words are only made
//   visible to the consumer once their `rvalid` has actually arrived.
//   No combinational read of stale `imem_port.rdata` is possible.
//
// PHASE 2.1 STATUS
//   The buffer is INSTANTIATED IN PARALLEL with the existing
//   c_controller-based fetch path in core_top.sv. It snoops the live
//   imem_port traffic (push on rvalid with the registered in-flight
//   vaddr; pop on c_controller's instruction-emit cycle). Its outputs
//   are NOT consumed by any functional path. A self-consistency
//   assertion in core_top.sv verifies that every push entry's vaddr
//   matches the address the corresponding `imem_port.req` cycle drove
//   on `imem_port.addr`. Phase 2.2 adds the compressed_aligner on top.
//
// PROTOCOL
//   - push on the cycle imem_port.rvalid is high (snoop)
//   - the producer must register the vaddr at REQ time and present it
//     at PUSH time, since `imem_port.addr` is the *next* fetch's address
//     by the time rvalid arrives
//   - pop dequeues the head; head→next slides forward
//   - flush clears all entries in 1 cycle (combinational reset of
//     read/write pointers and entry-valid bits)
//   - full_o asserts when count==DEPTH; the producer must back-pressure
//     itself by holding off the next imem.req (the FIU does this in
//     the final design; the snoop wrapper doesn't have this control,
//     so an `overflow_o` flag is exposed for the assertion to catch
//     any time the snoop pushes into a full buffer)

module fetch_buffer
    import fetch_pkg::*;
#(
    parameter int DEPTH = 2
) (
    input  logic clk_i,
    input  logic reset_i,
    input  logic flush_i,         // single-cycle clear

    // ── Push (from FIU / snoop) ─────────────────────────────────────────
    input  logic                push_i,
    input  fetch_buffer_entry_t push_entry_i,
    output logic                full_o,
    output logic                overflow_o,   // assertion: push while full

    // ── Pop (from aligner) ──────────────────────────────────────────────
    input  logic                pop_i,
    output fetch_buffer_entry_t head_entry_o,
    output fetch_buffer_entry_t next_entry_o, // for cross-word peek
    output logic                head_valid_o,
    output logic                next_valid_o,
    output logic                empty_o,
    output logic [$clog2(DEPTH+1)-1:0] count_o
);

    // ── Storage ─────────────────────────────────────────────────────────
    // Tiny FIFO; for DEPTH=2 we just keep two entry slots and a count.
    fetch_buffer_entry_t entries [0:DEPTH-1];
    logic [$clog2(DEPTH+1)-1:0] count_q;

    // ── Combinational reads ─────────────────────────────────────────────
    assign empty_o      = (count_q == '0);
    assign full_o       = (count_q == DEPTH[$clog2(DEPTH+1)-1:0]);
    assign count_o      = count_q;
    assign head_entry_o = entries[0];
    assign next_entry_o = entries[1];
    assign head_valid_o = (count_q >= 1);
    assign next_valid_o = (count_q >= 2);

    // ── Overflow detect (push while full and not popping) ───────────────
    assign overflow_o = push_i && full_o && !pop_i;

    // ── State update ────────────────────────────────────────────────────
    integer i;
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                entries[i].word  <= 32'b0;
                entries[i].vaddr <= 32'b0;
                entries[i].fault <= 1'b0;
                entries[i].cause <= 5'b0;
            end
            count_q <= '0;
        end else if (flush_i) begin
            // single-cycle clear: reset count AND scrub fault flags so a
            // stale fault=1 cannot leak through the aligner if a wrong-path
            // rvalid pushes into the buffer before the redirect's handler
            // fetch overwrites the entry (pmp_check_on_pa root cause:
            // see inflight_i_fault_q comments in core_top.sv).
            count_q <= '0;
            for (i = 0; i < DEPTH; i = i + 1)
                entries[i].fault <= 1'b0;
        end else begin
            // Decode push/pop combinations
            case ({push_i, pop_i})
                2'b00: ; // idle
                2'b01: begin
                    // pop only: shift entries down, decrement count
                    if (count_q > 0) begin
                        for (i = 0; i < DEPTH-1; i = i + 1)
                            entries[i] <= entries[i+1];
                        count_q <= count_q - 1'b1;
                    end
                end
                2'b10: begin
                    // push only: append at the tail (count_q index)
                    if (!full_o) begin
                        entries[count_q] <= push_entry_i;
                        count_q <= count_q + 1'b1;
                    end
                    // overflow case: drop the push (overflow_o asserted
                    // combinationally; the assertion in core_top.sv catches it)
                end
                2'b11: begin
                    // push and pop: shift down then write to (count_q-1) slot
                    // i.e. effectively replace head, count stays the same
                    if (count_q > 0) begin
                        for (i = 0; i < DEPTH-1; i = i + 1)
                            entries[i] <= entries[i+1];
                        entries[count_q-1] <= push_entry_i;
                        // count unchanged
                    end else begin
                        // popping an empty buffer is undefined; treat as
                        // push-only into slot 0
                        entries[0] <= push_entry_i;
                        count_q <= 1'b1;
                    end
                end
            endcase
        end
    end

endmodule
