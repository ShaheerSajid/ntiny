// OoO core v1 — Load-Store Queue (M4).
//
// Replaces the M2-A "head-gated LSU RS" with a proper LSQ. Per the
// v1 spec:
//   - Stores write memory at COMMIT, not at issue. Holds them in
//     the LSQ from dispatch to commit; ROB.ready is set by the LSQ
//     when memunit accepts the store, so commit drains the entry.
//   - Loads issue OoO once their address is resolved AND every
//     older store has a known address (no memory dependence
//     prediction at v1 — conservative wait on unresolved stores).
//   - Store-to-load forwarding: a load whose address matches an
//     older in-flight store's address forwards the store's data
//     directly (no memory access). If the matching store's data
//     hasn't arrived yet, the load waits via the store's tag.
//
// LSQ is a circular buffer indexed by alloc order = program order
// (matches in-order dispatch + in-order ROB). head=oldest in-
// flight, tail=next free. count=fill.
//
// One read port to memunit (one in-flight memory op at a time —
// matches memunit's M0 simplification). One forwarding write port
// to the CDB (LOAD result from older store, no memunit roundtrip).
//
// Operand wakeup mirrors rs.sv exactly — 3 wb broadcast ports
// matching the CDB.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module lsq
#(
    parameter int DEPTH = 4,
    parameter int IDX_W = $clog2(DEPTH)
)
(
    input  logic                        clk_i,
    input  logic                        reset_i,

    // Branch-squash range. On mispredict, the top asserts
    // squash_en_i and provides (flush_after_idx, flush_tail) — any
    // LSQ entry whose rob_idx falls in that circular range is
    // invalidated. Same predicate as the ALU/MULDIV RS squash
    // masks but computed internally so we don't need to expose a
    // per-slot rob_idx array.
    input  logic                        squash_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    flush_after_idx_i,
    input  logic [OOO_ROB_IDX_W-1:0]    flush_tail_i,

    // ── alloc (dispatch) ─────────────────────────────────────
    input  logic                        alloc_en_i,
    output logic                        full_o,
    input  uop_t                        alloc_uop_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rob_idx_i,
    // rs1 (address base) — present for both LOAD + STORE.
    input  logic [31:0]                 alloc_rs1_value_i,
    input  logic                        alloc_rs1_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs1_tag_i,
    // rs2 (store data) — only meaningful for STORE.
    input  logic [31:0]                 alloc_rs2_value_i,
    input  logic                        alloc_rs2_busy_i,
    input  logic [OOO_ROB_IDX_W-1:0]    alloc_rs2_tag_i,

    // ── CDB wakeup (3 broadcast ports) ───────────────────────
    input  logic                        wb1_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb1_idx_i,
    input  logic [31:0]                 wb1_result_i,
    input  logic                        wb2_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb2_idx_i,
    input  logic [31:0]                 wb2_result_i,
    input  logic                        wb3_en_i,
    input  logic [OOO_ROB_IDX_W-1:0]    wb3_idx_i,
    input  logic [31:0]                 wb3_result_i,

    // ── ROB head (gates store memory write at commit) ───────
    input  logic [OOO_ROB_IDX_W-1:0]    rob_head_idx_i,

    // ── memunit kick / completion ───────────────────────────
    output onebit_sig_e                 mem_kick_o,
    output fu_type_e                    mem_fu_o,
    output logic [31:0]                 mem_addr_o,
    output logic [31:0]                 mem_store_data_o,
    output load_store_width_e           mem_width_o,
    output onebit_sig_e                 mem_unsigned_o,
    output logic [OOO_ROB_IDX_W-1:0]    mem_rob_idx_o,
    input  onebit_sig_e                 mem_busy_i,
    input  onebit_sig_e                 mem_done_i,
    input  logic [OOO_ROB_IDX_W-1:0]    mem_done_idx_i,
    input  logic [31:0]                 mem_done_result_i,

    // ── store-to-load forwarding → muxed onto wb2 by top ─────
    // (gated internally to not conflict with mem_done_i on wb2)
    output onebit_sig_e                 fwd_en_o,
    output logic [OOO_ROB_IDX_W-1:0]    fwd_idx_o,
    output logic [31:0]                 fwd_result_o
);

    typedef struct packed {
        logic                        valid;
        logic                        is_store;        // 1 = STORE, 0 = LOAD
        logic [OOO_ROB_IDX_W-1:0]    rob_idx;
        logic [OOO_ROB_IDX_W-1:0]    rs1_tag;         // base reg
        logic                        rs1_ready;
        logic [31:0]                 rs1_val;
        logic [OOO_ROB_IDX_W-1:0]    rs2_tag;         // store data
        logic                        rs2_ready;
        logic [31:0]                 rs2_val;
        logic [31:0]                 imm;             // alu_imm (S-imm or I-imm)
        load_store_width_e           ls_width;
        logic                        mem_unsigned;
        logic                        addr_done;       // addr computed
        logic [31:0]                 addr;
        logic                        mem_issued;      // sent to memunit
        logic                        completed;       // memunit done OR forwarded
    } slot_t;

    slot_t                       entry_q [0:DEPTH-1];
    logic [IDX_W-1:0]            head_q;
    logic [IDX_W-1:0]            tail_q;

    // Computed squash mask (per-slot).
    function automatic logic is_younger(
        logic [OOO_ROB_IDX_W-1:0] idx,
        logic [OOO_ROB_IDX_W-1:0] after,
        logic [OOO_ROB_IDX_W-1:0] upto
    );
        logic [OOO_ROB_IDX_W-1:0] d_idx;
        logic [OOO_ROB_IDX_W-1:0] d_upto;
        d_idx  = idx  - after - 1'b1;
        d_upto = upto - after - 1'b1;
        return (d_idx < d_upto);
    endfunction

    logic [DEPTH-1:0] squash_mask;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            squash_mask[i] = squash_en_i && entry_q[i].valid
                             && is_younger(entry_q[i].rob_idx,
                                           flush_after_idx_i,
                                           flush_tail_i);
        end
    end

    // Fill count from a popcount over valid bits — cheap at DEPTH=4
    // and avoids the alloc/dealloc/squash delta tracking footguns.
    integer count_v_int;
    logic [IDX_W:0] count_v;
    always_comb begin
        count_v_int = 0;
        for (int i = 0; i < DEPTH; i++) begin
            if (entry_q[i].valid) count_v_int++;
        end
        count_v = count_v_int[IDX_W:0];
    end
    assign full_o = (count_v == DEPTH[IDX_W:0]);

    // ── alloc (next-cycle update) ────────────────────────────
    wire is_store_alloc = (alloc_uop_i.fu == FU_STORE);
    wire alloc_addr_known = !alloc_rs1_busy_i;
    wire [31:0] alloc_addr = alloc_rs1_value_i + alloc_uop_i.alu_imm;

    // ── per-slot derived state ───────────────────────────────
    logic [DEPTH-1:0] valid_v;
    logic [DEPTH-1:0] is_store_v;
    logic [DEPTH-1:0] addr_done_v;
    logic [DEPTH-1:0] data_done_v;
    logic [DEPTH-1:0] mem_issued_v;
    logic [DEPTH-1:0] completed_v;
    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            valid_v[i]       = entry_q[i].valid;
            is_store_v[i]    = entry_q[i].is_store;
            addr_done_v[i]   = entry_q[i].addr_done;
            data_done_v[i]   = entry_q[i].rs2_ready;
            mem_issued_v[i]  = entry_q[i].mem_issued;
            completed_v[i]   = entry_q[i].completed;
        end
    end

    // ── "older than slot i" mask (program order = ring order
    //    starting from head). Slot j is older than i if j is
    //    closer to head in the ring sense.
    function automatic logic older_than(input int unsigned j, input int unsigned i);
        // distance from head: dj = (j - head) mod DEPTH; di = (i - head) mod DEPTH
        // j is older if dj < di.
        int unsigned dj, di;
        dj = (j + DEPTH - head_q) % DEPTH;
        di = (i + DEPTH - head_q) % DEPTH;
        return (dj < di);
    endfunction

    // ── load issue selection ─────────────────────────────────
    // For each LOAD entry, decide if it can issue this cycle.
    // Rules (v1 — conservative; full store-to-load forwarding
    // with byte-merge defers to v2):
    //   1. valid && !is_store && !mem_issued && !completed && addr_done
    //   2. all older stores must be addr_done (memory disambiguation)
    //   3. no older store may word-overlap this load
    //      (addr[31:2] match) — sub-word writes prevent safe
    //      same-word forwarding; we just wait for the store to
    //      drain through memunit and free its LSQ slot.
    //   4. otherwise issue to memunit (if memunit is not busy)
    logic [DEPTH-1:0] load_can_issue;

    always_comb begin
        for (int i = 0; i < DEPTH; i++) begin
            load_can_issue[i] = 1'b0;

            if (valid_v[i] && !is_store_v[i]
                && !mem_issued_v[i] && !completed_v[i]
                && addr_done_v[i]) begin

                automatic logic blocked = 1'b0;

                for (int j = 0; j < DEPTH; j++) begin
                    if (j != i && valid_v[j] && is_store_v[j]
                        && older_than(j, i)) begin
                        if (!addr_done_v[j]) begin
                            blocked = 1'b1;
                        end else if (entry_q[j].addr[31:2]
                                     == entry_q[i].addr[31:2]) begin
                            blocked = 1'b1;
                        end
                    end
                end

                load_can_issue[i] = !blocked;
            end
        end
    end

    // Pick oldest load to issue to memunit (age-ordered).
    logic [IDX_W-1:0] sel_load_idx;
    logic             sel_load_valid;
    always_comb begin
        sel_load_idx   = '0;
        sel_load_valid = 1'b0;
        for (int k = 0; k < DEPTH; k++) begin
            int unsigned ix;
            ix = (head_q + k) % DEPTH;
            if (load_can_issue[ix] && !sel_load_valid) begin
                sel_load_idx   = ix[IDX_W-1:0];
                sel_load_valid = 1'b1;
            end
        end
    end

    // ── store issue selection ────────────────────────────────
    // STORE issues to memunit only when at ROB head (precise
    // commit-time write) AND addr+data are ready AND memunit free.
    logic head_is_store_ready;
    logic [IDX_W-1:0] head_slot_idx;
    always_comb begin
        head_is_store_ready = 1'b0;
        head_slot_idx       = '0;
        for (int k = 0; k < DEPTH; k++) begin
            int unsigned ix;
            ix = (head_q + k) % DEPTH;
            if (k == 0 && valid_v[ix] && is_store_v[ix]
                && addr_done_v[ix] && data_done_v[ix]
                && !mem_issued_v[ix]
                && entry_q[ix].rob_idx == rob_head_idx_i) begin
                head_is_store_ready = 1'b1;
                head_slot_idx       = ix[IDX_W-1:0];
            end
        end
    end

    // ── memunit drive ────────────────────────────────────────
    // Priority: STORE-at-head > LOAD-issue. (Store commit drains
    // the ROB head; loads can wait one more cycle.)
    logic mem_issue_store;
    logic mem_issue_load;
    logic [IDX_W-1:0] mem_issue_slot;
    always_comb begin
        mem_issue_store = head_is_store_ready && !mem_busy_i;
        mem_issue_load  = !mem_issue_store && sel_load_valid && !mem_busy_i;
        mem_issue_slot  = mem_issue_store ? head_slot_idx
                        : (mem_issue_load ? sel_load_idx : '0);
    end

    assign mem_kick_o       = onebit_sig_e'(mem_issue_store || mem_issue_load);
    assign mem_fu_o         = mem_issue_store ? FU_STORE : FU_LOAD;
    assign mem_addr_o       = entry_q[mem_issue_slot].addr;
    assign mem_store_data_o = entry_q[mem_issue_slot].rs2_val;
    assign mem_width_o      = entry_q[mem_issue_slot].ls_width;
    assign mem_unsigned_o   = onebit_sig_e'(entry_q[mem_issue_slot].mem_unsigned);
    assign mem_rob_idx_o    = entry_q[mem_issue_slot].rob_idx;

    // Store-to-load forwarding deferred — v1 LSQ waits on
    // word-overlap rather than forwarding, so fwd outputs stay
    // tied off. Kept on the port list so the top's wb2 mux
    // doesn't need to change when v2 enables forwarding.
    assign fwd_en_o     = FALSE;
    assign fwd_idx_o    = '0;
    assign fwd_result_o = '0;

    // ── sequential update ────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < DEPTH; i++) entry_q[i] <= '0;
            head_q  <= '0;
            tail_q  <= '0;
        end else begin
            // Per-slot squash from younger-than-branch mask.
            // Squashed slots vacate; tail rewinds. We do this BEFORE
            // wakeup/issue updates so a squashed slot doesn't
            // accidentally drive memory.
            for (int i = 0; i < DEPTH; i++) begin
                if (squash_mask[i]) entry_q[i].valid <= 1'b0;
            end

            // CDB wakeup (3 ports) — operand resolution.
            for (int i = 0; i < DEPTH; i++) begin
                if (entry_q[i].valid && !squash_mask[i]) begin
                    // rs1 wake → addr compute
                    if (!entry_q[i].rs1_ready) begin
                        if (wb1_en_i && entry_q[i].rs1_tag == wb1_idx_i) begin
                            entry_q[i].rs1_ready <= 1'b1;
                            entry_q[i].rs1_val   <= wb1_result_i;
                            entry_q[i].addr      <= wb1_result_i + entry_q[i].imm;
                            entry_q[i].addr_done <= 1'b1;
                        end else if (wb2_en_i && entry_q[i].rs1_tag == wb2_idx_i) begin
                            entry_q[i].rs1_ready <= 1'b1;
                            entry_q[i].rs1_val   <= wb2_result_i;
                            entry_q[i].addr      <= wb2_result_i + entry_q[i].imm;
                            entry_q[i].addr_done <= 1'b1;
                        end else if (wb3_en_i && entry_q[i].rs1_tag == wb3_idx_i) begin
                            entry_q[i].rs1_ready <= 1'b1;
                            entry_q[i].rs1_val   <= wb3_result_i;
                            entry_q[i].addr      <= wb3_result_i + entry_q[i].imm;
                            entry_q[i].addr_done <= 1'b1;
                        end
                    end
                    // rs2 wake (stores)
                    if (!entry_q[i].rs2_ready) begin
                        if (wb1_en_i && entry_q[i].rs2_tag == wb1_idx_i) begin
                            entry_q[i].rs2_ready <= 1'b1;
                            entry_q[i].rs2_val   <= wb1_result_i;
                        end else if (wb2_en_i && entry_q[i].rs2_tag == wb2_idx_i) begin
                            entry_q[i].rs2_ready <= 1'b1;
                            entry_q[i].rs2_val   <= wb2_result_i;
                        end else if (wb3_en_i && entry_q[i].rs2_tag == wb3_idx_i) begin
                            entry_q[i].rs2_ready <= 1'b1;
                            entry_q[i].rs2_val   <= wb3_result_i;
                        end
                    end
                end
            end

            // Memunit kick → mark mem_issued (in-flight).
            if (mem_kick_o == TRUE) begin
                entry_q[mem_issue_slot].mem_issued <= 1'b1;
            end

            // Memunit completion: LOAD → completed=1; STORE → also
            // completed=1 (we'll free the slot at commit).
            if (mem_done_i == TRUE) begin
                for (int i = 0; i < DEPTH; i++) begin
                    if (entry_q[i].valid
                        && entry_q[i].mem_issued
                        && entry_q[i].rob_idx == mem_done_idx_i) begin
                        entry_q[i].completed <= 1'b1;
                    end
                end
            end

            // (Store-to-load forwarding completion deferred to v2.)

            // ── alloc ────────────────────────────────────────
            if (alloc_en_i && !full_o) begin
                entry_q[tail_q].valid        <= 1'b1;
                entry_q[tail_q].is_store     <= is_store_alloc;
                entry_q[tail_q].rob_idx      <= alloc_rob_idx_i;
                entry_q[tail_q].imm          <= alloc_uop_i.alu_imm;
                entry_q[tail_q].ls_width     <= alloc_uop_i.ls_width;
                entry_q[tail_q].mem_unsigned <= (alloc_uop_i.mem_unsigned == TRUE);
                entry_q[tail_q].mem_issued   <= 1'b0;
                entry_q[tail_q].completed    <= 1'b0;
                // rs1 (base addr)
                if (alloc_addr_known) begin
                    entry_q[tail_q].rs1_ready <= 1'b1;
                    entry_q[tail_q].rs1_val   <= alloc_rs1_value_i;
                    entry_q[tail_q].rs1_tag   <= '0;
                    entry_q[tail_q].addr      <= alloc_addr;
                    entry_q[tail_q].addr_done <= 1'b1;
                end else begin
                    entry_q[tail_q].rs1_ready <= 1'b0;
                    entry_q[tail_q].rs1_val   <= '0;
                    entry_q[tail_q].rs1_tag   <= alloc_rs1_tag_i;
                    entry_q[tail_q].addr      <= '0;
                    entry_q[tail_q].addr_done <= 1'b0;
                end
                // rs2 (store data) — alloc_rs2_busy_i is meaningless
                // for LOADs (we'll just store rs2 ready=1 with 0).
                if (is_store_alloc) begin
                    if (!alloc_rs2_busy_i) begin
                        entry_q[tail_q].rs2_ready <= 1'b1;
                        entry_q[tail_q].rs2_val   <= alloc_rs2_value_i;
                        entry_q[tail_q].rs2_tag   <= '0;
                    end else begin
                        entry_q[tail_q].rs2_ready <= 1'b0;
                        entry_q[tail_q].rs2_val   <= '0;
                        entry_q[tail_q].rs2_tag   <= alloc_rs2_tag_i;
                    end
                end else begin
                    entry_q[tail_q].rs2_ready <= 1'b1;
                    entry_q[tail_q].rs2_val   <= '0;
                    entry_q[tail_q].rs2_tag   <= '0;
                end
                // Natural IDX_W-bit overflow wraps mod DEPTH (when
                // DEPTH is a power of 2, which it is by $clog2).
                tail_q <= tail_q + 1'b1;
            end

            // ── dealloc head when completed ──────────────────
            // LOADs: dealloc when completed (memunit replied or
            // forwarded). STOREs: dealloc when completed AND we're
            // the actual head (the store has been written to memory
            // AND ROB has retired this entry — we use mem_done as
            // the trigger).
            //
            // We dealloc one slot per cycle, conservatively, to
            // avoid same-cycle multi-pop complexity.
            if (entry_q[head_q].valid && entry_q[head_q].completed
                && !squash_mask[head_q]) begin
                entry_q[head_q].valid <= 1'b0;
                head_q <= head_q + 1'b1;
            end

        end
    end

endmodule
