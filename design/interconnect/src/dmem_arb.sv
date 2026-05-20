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
    // PTW (master 0, highest priority)
    input  logic        ptw_req_i,
    input  logic        ptw_we_i,
    input  logic [31:0] ptw_addr_i,
    input  logic [31:0] ptw_wdata_i,
    output logic        ptw_grant_o,

    // AMO (master 1)
    input  logic        amo_req_i,
    input  logic        amo_we_i,
    input  logic [3:0]  amo_be_i,
    input  logic [31:0] amo_wdata_i,
    output logic        amo_grant_o,

    // core2avl (master 2, lowest priority — the regular load/store path)
    input  logic        c2a_req_i,
    input  logic        c2a_we_i,
    input  logic [3:0]  c2a_be_i,
    input  logic [31:0] c2a_wdata_i,
    output logic        c2a_grant_o,

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

endmodule
