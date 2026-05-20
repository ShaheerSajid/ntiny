// ── dmem_arb ─────────────────────────────────────────────────────────────
// Phase 1a of the bus revamp (see docs/bus_revamp_plan.md):
// drop-in extraction of the static-priority data-bus mux that previously
// lived inline in core_top.sv. Functionally bit-identical to the old
// inline mux — this commit moves the same logic into its own module so
// subsequent sub-commits (1b–1f) can add grant signals, per-master response
// routing, and finally retire the Phase 0 ptw_active_q bandaid without
// touching core_top again.
//
// Priority (highest to lowest): PTW > AMO > core2avl. The suppression
// flags (ptw_active / amo_active / d_xlat_pending / mmu_d_*_fault) are
// passed in from core_top exactly as the old inline ternary chain used
// them; the arb does NOT recompute them.
//
// Forward-compat note: per-master `grant_*_o` outputs are produced
// already so master modules can start consuming them in 1c–1e without
// another port-list churn. In 1a they are observable but no master is
// wired to them yet.
//
// Address path note: AMO and core2avl share the MMU-translated
// `data_paddr_i` because both feed the same d-translate stage upstream
// (core_top computes `d_vaddr_pre = amo_active ? amo_addr : c2a_addr`
// and the MMU outputs the translated PA into `d_paddr`). PTW supplies
// its own physical address directly.
//
module dmem_arb (
    input  logic        clk_i,
    input  logic        reset_i,

    // PTW (master 0, highest priority)
    input  logic        ptw_req_i,
    input  logic        ptw_we_i,
    input  logic [31:0] ptw_addr_i,
    input  logic [31:0] ptw_wdata_i,
    output logic        ptw_grant_o,
    output logic        ptw_ready_o,
    output logic        ptw_rvalid_o,
    output logic [31:0] ptw_rdata_o,

    // AMO (master 1)
    input  logic        amo_req_i,
    input  logic        amo_we_i,
    input  logic [3:0]  amo_be_i,
    input  logic [31:0] amo_wdata_i,
    output logic        amo_grant_o,
    output logic        amo_ready_o,
    output logic        amo_rvalid_o,
    output logic [31:0] amo_rdata_o,

    // core2avl (master 2, lowest priority — the regular load/store path)
    input  logic        c2a_req_i,
    input  logic        c2a_we_i,
    input  logic [3:0]  c2a_be_i,
    input  logic [31:0] c2a_wdata_i,
    output logic        c2a_grant_o,
    output logic        c2a_ready_o,
    output logic        c2a_rvalid_o,
    output logic [31:0] c2a_rdata_o,

    // Shared MMU-translated PA for AMO + core2avl.
    input  logic [31:0] data_paddr_i,

    // Active / suppression flags from core_top — preserved verbatim from
    // the old inline mux so this remains a pure extraction.
    input  logic        ptw_active_i,
    input  logic        amo_active_i,
    input  logic        d_xlat_pending_i,         // mmu_d_stall
    input  logic        mmu_d_access_fault_i,
    input  logic        mmu_d_fault_i,

    // Downstream slave port. The shared fan-out of ready/rvalid/rdata
    // back to masters is intentionally still handled in core_top in 1a;
    // 1b routes them per-master via the grant flags above.
    mem_bus.master      bus
);

    // PTW always uses full-word writes (32-bit PTE) — preserved from the
    // old inline mux which forced be = 4'b1111 on the PTW path.
    localparam logic [3:0] PTW_BE = 4'b1111;

    // Suppression: c2a + amo are blocked while translation is in flight
    // or while a PMP/page fault is firing. PTW is unaffected (it's
    // gated only by ptw_active).
    wire suppress_data = mmu_d_access_fault_i | mmu_d_fault_i | d_xlat_pending_i;

    // ── Grants (priority encoder) ───────────────────────────────────────
    // PTW wins whenever ptw_active is asserted. Then AMO. Then c2a.
    // The grant signals are computed combinationally and asserted in the
    // cycle a request would be driven to the slave.
    assign ptw_grant_o = ptw_active_i;
    assign amo_grant_o = ~ptw_active_i & amo_active_i & ~suppress_data;
    assign c2a_grant_o = ~ptw_active_i & ~amo_active_i & ~suppress_data;

    // ── Slave-port drivers ──────────────────────────────────────────────
    // Identical to the old inline ternary chain at core_top.sv (commit
    // pre-1a). Kept structurally close so a diff is easy to read.
    assign bus.addr  = ptw_active_i ? ptw_addr_i : data_paddr_i;
    assign bus.be    = ptw_active_i ? PTW_BE     :
                       amo_active_i ? amo_be_i   :
                                      c2a_be_i;
    assign bus.req   = ptw_active_i  ? ptw_req_i :
                       suppress_data ? 1'b0      :
                       amo_active_i  ? amo_req_i :
                                       c2a_req_i;
    assign bus.we    = ptw_active_i  ? ptw_we_i  :
                       suppress_data ? 1'b0      :
                       amo_active_i  ? amo_we_i  :
                                       c2a_we_i;
    assign bus.wdata = ptw_active_i ? ptw_wdata_i :
                       amo_active_i ? amo_wdata_i :
                                      c2a_wdata_i;

    // ── Per-master response routing ─────────────────────────────────────
    // ntiny's downstream slave (RAM/peripheral) is in-order, single-
    // outstanding per master, with `ready` always high (no real
    // back-pressure today) and `rvalid` arriving exactly one cycle
    // after a read request is accepted. So tracking the "pending read
    // master" with a 2-bit registered state is enough — no FIFO.
    //
    // pending_rd_master_q stores the grant ID of the most recent
    // accepted read. When bus.rvalid fires, that master gets it; in
    // the same cycle a new read can be accepted, overwriting the
    // state because the response was just consumed.
    typedef enum logic [1:0] {
        M_NONE = 2'd0,
        M_PTW  = 2'd1,
        M_AMO  = 2'd2,
        M_C2A  = 2'd3
    } master_id_e;

    master_id_e pending_rd_master_q;
    wire        read_accepted = bus.req & ~bus.we & bus.ready;
    master_id_e granted_master;
    always_comb begin
        if      (ptw_grant_o) granted_master = M_PTW;
        else if (amo_grant_o) granted_master = M_AMO;
        else if (c2a_grant_o) granted_master = M_C2A;
        else                  granted_master = M_NONE;
    end

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            pending_rd_master_q <= M_NONE;
        end else if (read_accepted) begin
            pending_rd_master_q <= granted_master;
        end else if (bus.rvalid) begin
            pending_rd_master_q <= M_NONE;
        end
    end

    // Per-master ready: a master can have its request accepted only when
    // it currently holds the grant and the slave is ready. Forward-compat
    // signal — not yet consumed by any master (1c–1e wire them in).
    assign ptw_ready_o = ptw_grant_o & bus.ready;
    assign amo_ready_o = amo_grant_o & bus.ready;
    assign c2a_ready_o = c2a_grant_o & bus.ready;

    // Per-master rvalid: the slave's rvalid is routed to whichever master
    // owns the outstanding read this cycle.
    assign ptw_rvalid_o = (pending_rd_master_q == M_PTW) & bus.rvalid;
    assign amo_rvalid_o = (pending_rd_master_q == M_AMO) & bus.rvalid;
    assign c2a_rvalid_o = (pending_rd_master_q == M_C2A) & bus.rvalid;

    // rdata is broadcast (the per-master rvalid above is the timing-and-
    // ownership gate).
    assign ptw_rdata_o = bus.rdata;
    assign amo_rdata_o = bus.rdata;
    assign c2a_rdata_o = bus.rdata;

endmodule
