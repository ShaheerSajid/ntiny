import common_pkg::*;
import core_pkg::*;

// ── Privilege Unit ──────────────────────────────────────────────────────────
// Centralises privilege-related combinational checks. Phase 4.6 trap revamp
// reduced this module to just the illegal-instruction detector — the
// xRET commit logic (ret_valid / ret_fire / sret_fire / ret_side_effects)
// moved to wb_trap_unit (IWB-stage commit) in Phase 4.3, eliminating the
// csr_ret_hazard race entirely. mmu_priv override is also gone — by the
// time the redirect target's fetch happens, csr_unit's priv_level has
// already updated, so a plain `priv_level` view is correct.
//
// Owns:
//   - Illegal instruction detection (CSR priv, MRET/SRET priv, TVM)
//
module privilege_unit (
    // ── Current privilege state (from CSR unit) ─────────────────────────
    input  logic [1:0]  priv_level_i,
    input  logic [31:0] status_csr_i,      // MSTATUS register

    // ── Decoded instruction info (from ID stage ctrl_bus_if_id) ─────────
    input  logic        id_mret_i,         // .mret
    input  logic        id_sret_i,         // .sret
    input  logic        id_sfence_vma_i,   // .sfence_vma
    input  csr_op_e     id_csr_op_i,       // .csr_op
    input  logic [11:0] id_csr_addr_i,     // .csr_addr

    // ── Illegal instruction outputs ─────────────────────────────────────
    output logic        illegal_mret_o,
    output logic        illegal_sret_o,
    output logic        illegal_insn_id_o
);

// ═══════════════════════════════════════════════════════════════════════════
// Privilege violation detection (combinational, ID stage)
// ═══════════════════════════════════════════════════════════════════════════

// CSR access privilege check: CSR address[9:8] = minimum required privilege
wire csr_access = (id_csr_op_i == WRITE_CSR) ||
                  (id_csr_op_i == SET_CSR) ||
                  (id_csr_op_i == CLEAR_CSR);
wire illegal_csr_priv = csr_access && (priv_level_i < id_csr_addr_i[9:8]);

// MRET requires M-mode; SRET requires at least S-mode. With Phase 4.3
// xRET commits at IWB so by the time the carrier reaches IWB the
// priv_level is whatever it should be — the old `ret_side_effects_done`
// guard is no longer needed.
assign illegal_mret_o = (id_mret_i == TRUE) && (priv_level_i != 2'b11);
assign illegal_sret_o = (id_sret_i == TRUE) && (priv_level_i < 2'b01);

// TVM enforcement: SATP access or SFENCE.VMA from S-mode when mstatus.TVM=1
wire tvm_active         = status_csr_i[20] && (priv_level_i == 2'b01);
wire illegal_satp_tvm   = tvm_active && csr_access && (id_csr_addr_i == 12'h180);
wire illegal_sfence_tvm = tvm_active && (id_sfence_vma_i == TRUE);

assign illegal_insn_id_o = illegal_csr_priv | illegal_mret_o | illegal_sret_o
                         | illegal_satp_tvm | illegal_sfence_tvm;

// Note: PLIC claim/complete is now fully memory-mapped (no sideband signals).
// Software reads PLIC claim register to claim, writes to complete.

endmodule
