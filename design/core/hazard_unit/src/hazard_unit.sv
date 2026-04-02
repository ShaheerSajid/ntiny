import common_pkg::*;
import core_pkg::*;

// ── Hazard Unit ─────────────────────────────────────────────────────────────
// Centralises all pipeline stall, flush, and post-trap bookkeeping that was
// previously scattered across core_top.  Pure-refactor: behaviour is identical
// to the original inline logic.
//
// Stall chain (combinational):   iwb_stall → imem_stall → ie_stall → if_id_stall
// Flush priority (combinational): based on {if_id_stall|resume|trap, ie_stall, imem_stall, iwb_stall}
// Registered state:               post_trap, refetch_after_trap, insn_valid_id
//
module hazard_unit (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── External stall sources ──────────────────────────────────────────
    input  onebit_sig_e alu_stall_i,       // MUL/DIV in progress
    input  onebit_sig_e amo_stall_i,       // atomic memory op FSM
    input  onebit_sig_e mmu_i_stall_i,     // instruction TLB / PTW
    input  onebit_sig_e mmu_d_stall_i,     // data TLB / PTW
    input  logic        dmem_req_i,        // data-bus request pending
    input  logic        dmem_ready_i,      // data-bus ready
    input  onebit_sig_e insert_bubble_i,   // structural hazard (stall_line)

    // ── Control-flow events ─────────────────────────────────────────────
    input  onebit_sig_e interrupt_valid_i,  // trap/interrupt firing
    input  logic        resumeack_i,        // debug resume

    // ── IE-stage exception flag ─────────────────────────────────────────
    input  logic        exception_from_ie_i,

    // ── Processor state ─────────────────────────────────────────────────
    input  logic        halted_i,           // debug halted (pstate == HALTED)

    // ── CSR ret-hazard detection inputs ─────────────────────────────────
    input  logic        id_mret_i,          // ctrl_bus_if_id.mret
    input  logic        id_sret_i,          // ctrl_bus_if_id.sret
    input  logic        illegal_mret_i,
    input  logic        illegal_sret_i,
    input  csr_op_e     ie_csr_op_i,        // ctrl_bus_ie.csr_op
    input  logic [11:0] ie_csr_addr_i,      // ctrl_bus_ie.csr_addr

    // ── Stall outputs ───────────────────────────────────────────────────
    output onebit_sig_e if_id_stall_o,
    output onebit_sig_e ie_stall_o,
    output onebit_sig_e imem_stall_o,
    output onebit_sig_e iwb_stall_o,

    // ── Flush outputs ───────────────────────────────────────────────────
    output onebit_sig_e ie_flush_o,
    output onebit_sig_e imem_flush_o,
    output onebit_sig_e iwb_flush_o,

    // ── Post-trap / stale ───────────────────────────────────────────────
    output logic        post_trap_o,
    output logic        stale_id_o,

    // ── Instruction validity ────────────────────────────────────────────
    output logic        insn_valid_id_o,

    // ── Fetch control ───────────────────────────────────────────────────
    output logic        refetch_after_trap_o,

    // ── CSR ret hazard ──────────────────────────────────────────────────
    output logic        csr_ret_hazard_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Stall chain (combinational)
// ═══════════════════════════════════════════════════════════════════════════
wire dmem_busy = dmem_req_i & ~dmem_ready_i;

assign iwb_stall_o  = onebit_sig_e'(1'b0);
assign imem_stall_o = onebit_sig_e'(iwb_stall_o);
assign ie_stall_o   = onebit_sig_e'(imem_stall_o | alu_stall_i | dmem_busy |
                                     amo_stall_i  | mmu_d_stall_i);

// CSR read-after-write hazard: mret/sret in ID reads epc, but preceding
// CSR write in IE hasn't committed yet.
assign csr_ret_hazard_o = ((id_mret_i && !illegal_mret_i) ||
                           (id_sret_i && !illegal_sret_i)) &&
                          ie_csr_op_i != NO_CSR_OP &&
                          ((id_mret_i && ie_csr_addr_i == 12'h341) ||
                           (id_sret_i && ie_csr_addr_i == 12'h141));

assign if_id_stall_o = onebit_sig_e'(ie_stall_o | insert_bubble_i |
                                      refetch_after_trap_o | halted_i |
                                      mmu_i_stall_i | csr_ret_hazard_o);

// ═══════════════════════════════════════════════════════════════════════════
// Flush logic (combinational)
// ═══════════════════════════════════════════════════════════════════════════
always_comb begin
    case ({if_id_stall_o | resumeack_i | interrupt_valid_i,
           ie_stall_o, imem_stall_o, iwb_stall_o})
        4'b1000: begin
            ie_flush_o   = TRUE;
            imem_flush_o = onebit_sig_e'(exception_from_ie_i);
            iwb_flush_o  = FALSE;
        end
        4'b1100: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b010;
        4'b1110: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b001;
        default: {ie_flush_o, imem_flush_o, iwb_flush_o} = 3'b000;
    endcase
end

// ═══════════════════════════════════════════════════════════════════════════
// Registered state
// ═══════════════════════════════════════════════════════════════════════════

// ── Post-trap: marks instruction in ID as stale after a trap fires ───────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        post_trap_o <= 1'b0;
    else if (interrupt_valid_i)
        post_trap_o <= 1'b1;
    else if (!if_id_stall_o)
        post_trap_o <= 1'b0;
end
assign stale_id_o = post_trap_o;

// ── Instruction validity in ID stage ─────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        insn_valid_id_o <= 1'b0;
    else if (interrupt_valid_i)
        insn_valid_id_o <= 1'b0;
    else if (!if_id_stall_o)
        insn_valid_id_o <= 1'b1;
end

// ── Refetch after trap ───────────────────────────────────────────────────
// When a trap fires during a stall, the fetch for the handler was never
// issued. Insert one stall cycle to re-issue the fetch at handler_addr.
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        refetch_after_trap_o <= 1'b0;
    else
        refetch_after_trap_o <= interrupt_valid_i & if_id_stall_o;
end

endmodule
