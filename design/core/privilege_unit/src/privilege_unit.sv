import common_pkg::*;
import core_pkg::*;

// ── Privilege Unit ──────────────────────────────────────────────────────────
// Centralises all privilege-related combinational checks and registered state
// that was previously scattered across core_top.  Pure-refactor: behaviour is
// identical to the original inline logic.
//
// Owns:
//   - Illegal instruction detection (CSR priv, MRET/SRET priv, TVM)
//   - MRET/SRET fire signals and ret_side_effects_done one-shot
//   - Effective privilege for instruction-side MMU (mmu_priv)
//   - ret_valid computation
//
module privilege_unit (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── Current privilege state (from CSR unit) ─────────────────────────
    input  logic [1:0]  priv_level_i,
    input  logic [31:0] status_csr_i,      // MSTATUS register

    // ── Decoded instruction info (from ID stage ctrl_bus_if_id) ─────────
    input  logic        id_mret_i,         // .mret
    input  logic        id_sret_i,         // .sret
    input  logic        id_sfence_vma_i,   // .sfence_vma
    input  csr_op_e     id_csr_op_i,       // .csr_op
    input  logic [11:0] id_csr_addr_i,     // .csr_addr

    // ── Pipeline state ──────────────────────────────────────────────────
    input  logic        insn_valid_id_i,   // from hazard_unit
    input  logic        csr_ret_hazard_i,  // from hazard_unit
    input  onebit_sig_e interrupt_valid_i,  // trap firing

    // ── Illegal instruction outputs ─────────────────────────────────────
    output logic        illegal_mret_o,
    output logic        illegal_sret_o,
    output logic        illegal_insn_id_o,

    // ── Return instruction control ──────────────────────────────────────
    output onebit_sig_e ret_valid_o,
    output logic        ret_fire_o,        // to CSR unit .ret_i
    output logic        sret_fire_o,       // to CSR unit .sret_i
    output logic        ret_side_effects_done_o,

    // ── Effective privilege for instruction-side MMU ─────────────────────
    output logic [1:0]  mmu_priv_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Privilege violation detection (combinational, ID stage)
// ═══════════════════════════════════════════════════════════════════════════

// CSR access privilege check: CSR address[9:8] = minimum required privilege
wire csr_access = (id_csr_op_i == WRITE_CSR) ||
                  (id_csr_op_i == SET_CSR) ||
                  (id_csr_op_i == CLEAR_CSR);
wire illegal_csr_priv = csr_access && (priv_level_i < id_csr_addr_i[9:8]);

// MRET requires M-mode; SRET requires at least S-mode.
// Once ret_side_effects_done, the xRET has already committed its CSR side
// effects from ID — don't flag as illegal due to the (now-updated) priv level.
assign illegal_mret_o = (id_mret_i == TRUE) && (priv_level_i != 2'b11) &&
                         !ret_side_effects_done_o;
assign illegal_sret_o = (id_sret_i == TRUE) && (priv_level_i < 2'b01) &&
                         !ret_side_effects_done_o;

// TVM enforcement: SATP access or SFENCE.VMA from S-mode when mstatus.TVM=1
wire tvm_active         = status_csr_i[20] && (priv_level_i == 2'b01);
wire illegal_satp_tvm   = tvm_active && csr_access && (id_csr_addr_i == 12'h180);
wire illegal_sfence_tvm = tvm_active && (id_sfence_vma_i == TRUE);

assign illegal_insn_id_o = illegal_csr_priv | illegal_mret_o | illegal_sret_o
                         | illegal_satp_tvm | illegal_sfence_tvm;

// ═══════════════════════════════════════════════════════════════════════════
// MRET/SRET return instruction control
// ═══════════════════════════════════════════════════════════════════════════

assign ret_valid_o = onebit_sig_e'(((id_mret_i && !illegal_mret_o) ||
                                    (id_sret_i && !illegal_sret_o)) && insn_valid_id_i);

assign ret_fire_o  = id_mret_i && insn_valid_id_i && !illegal_mret_o &&
                     !ret_side_effects_done_o && !csr_ret_hazard_i && !interrupt_valid_i;
assign sret_fire_o = id_sret_i && insn_valid_id_i && !illegal_sret_o &&
                     !ret_side_effects_done_o && !csr_ret_hazard_i && !interrupt_valid_i;

// One-shot flag: commit xRET CSR side effects on the first valid cycle,
// then hold until the xRET leaves ID (or a trap fires).
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        ret_side_effects_done_o <= 1'b0;
    else if (interrupt_valid_i)
        ret_side_effects_done_o <= 1'b0;
    else if (ret_valid_o && !csr_ret_hazard_i && !ret_side_effects_done_o)
        ret_side_effects_done_o <= 1'b1;
    else if (!ret_valid_o)
        ret_side_effects_done_o <= 1'b0;
end

// ═══════════════════════════════════════════════════════════════════════════
// Effective privilege for instruction-side MMU (MRET/SRET override)
// ═══════════════════════════════════════════════════════════════════════════
// On MRET/SRET the fetch address is the return target (mepc/sepc) which lives
// in the target privilege's address space.  Override mmu_priv with the target
// privilege so the MMU resolves the correct physical address.
wire [1:0] ret_target_priv = id_mret_i ? status_csr_i[12:11] :   // MRET: MPP
                                          {1'b0, status_csr_i[8]}; // SRET: SPP

assign mmu_priv_o = (ret_valid_o && !csr_ret_hazard_i && !ret_side_effects_done_o)
                    ? ret_target_priv : priv_level_i;

// Note: PLIC claim/complete is now fully memory-mapped (no sideband signals).
// Software reads PLIC claim register to claim, writes to complete.

endmodule
