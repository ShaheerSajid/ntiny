// OoO core v1 — minimal M-mode CSR file (M7-minimal).
//
// Implements the 6 CSRs the RISCOF arch-test env touches at boot:
//   mstatus    (only MIE/MPIE bits modelled; others RAZ)
//   mtvec      (MODE = direct only; vector tail in [31:2])
//   mepc       (40-bit-truncated to 32; RV32 anyway)
//   mcause
//   mtval
//   mscratch
// Plus read-only:
//   misa       (= our supported extensions)
//   mhartid    (= 0)
// Any other CSR address reads as 0 / writes WI. Enough for the env
// trap-prolog macros to assemble + execute without faulting.
//
// CSR ops are serialised at the top — dispatch stalls until the CSR
// op commits, so this module only sees one transaction at a time.
// The R/M/W is done atomically at COMMIT (no operand-tag tracking).
//
// Traps + mret are NOT implemented here yet (M7-full milestone) —
// trap_take_i is an unused stub left on the port list so a future
// M7-full commit can wire it without re-touching the integration.

import common_pkg::*;
import core_ooo_pkg::*;

module csr_unit
(
    input  logic        clk_i,
    input  logic        reset_i,

    // ── CSR R/M/W (driven by the top at commit when uop is FU_CSR)
    input  logic        op_en_i,            // pulse one cycle on commit
    input  csr_uop_e     op_i,
    input  logic [11:0] csr_addr_i,
    input  logic [31:0] rs1_value_i,        // for OOO_CSR_RW/RS/RC
    input  logic [4:0]  uimm5_i,            // for OOO_CSR_RWI/RSI/RCI
    output logic [31:0] rd_value_o,         // old CSR value (combinational)

    // ── trap take (M7-full stub — unused for now) ───────────
    input  logic        trap_take_i,
    input  logic [31:0] trap_pc_i,          // mepc value
    input  logic [4:0]  trap_cause_i,
    input  logic [31:0] trap_tval_i,

    // ── mret (M7-full stub — unused for now) ────────────────
    input  logic        mret_en_i,

    // ── reads for the pipeline ──────────────────────────────
    output logic [31:0] mtvec_o,
    output logic [31:0] mepc_o,
    output logic        mstatus_mie_o
);

    // ── CSR address constants (M-mode subset) ───────────────
    localparam [11:0] CSR_MSTATUS  = 12'h300;
    localparam [11:0] CSR_MISA     = 12'h301;
    localparam [11:0] CSR_MTVEC    = 12'h305;
    localparam [11:0] CSR_MSCRATCH = 12'h340;
    localparam [11:0] CSR_MEPC     = 12'h341;
    localparam [11:0] CSR_MCAUSE   = 12'h342;
    localparam [11:0] CSR_MTVAL    = 12'h343;
    localparam [11:0] CSR_MHARTID  = 12'hF14;

    // ── state ────────────────────────────────────────────────
    // mstatus: only MIE (bit 3) and MPIE (bit 7) are live; the
    // rest reads as 0. Reset = MIE=0, MPIE=0.
    logic        mstatus_mie_q, mstatus_mpie_q;
    logic [31:0] mtvec_q;
    logic [31:0] mepc_q;
    logic [4:0]  mcause_code_q;        // low 5 bits of mcause
    logic        mcause_int_q;         // bit 31 (interrupt vs exception)
    logic [31:0] mtval_q;
    logic [31:0] mscratch_q;

    // ── MISA / hartid constants ──────────────────────────────
    // MXL=01 (32-bit, bits 31:30), bits 8 (I) + 12 (M) set in the
    // extension bitmap. We don't expose B/F/D — spike's --isa is
    // what matters for RISCOF anyway.
    wire [31:0] misa_value    = 32'h4000_1100;
    wire [31:0] mhartid_value = 32'b0;

    // ── combinational read ──────────────────────────────────
    logic [31:0] csr_read;
    always_comb begin
        unique case (csr_addr_i)
            CSR_MSTATUS:  csr_read = {24'b0,
                                      1'b0,             // bit 7 reserved upper
                                      mstatus_mpie_q,   // MPIE bit 7
                                      3'b0,             // bits 6:4
                                      mstatus_mie_q,    // MIE bit 3
                                      3'b0};            // bits 2:0
            CSR_MISA:     csr_read = misa_value;
            CSR_MTVEC:    csr_read = mtvec_q;
            CSR_MSCRATCH: csr_read = mscratch_q;
            CSR_MEPC:     csr_read = mepc_q;
            CSR_MCAUSE:   csr_read = {mcause_int_q, 26'b0, mcause_code_q};
            CSR_MTVAL:    csr_read = mtval_q;
            CSR_MHARTID:  csr_read = mhartid_value;
            default:      csr_read = 32'b0;             // RAZ
        endcase
    end

    assign rd_value_o     = csr_read;
    assign mtvec_o        = mtvec_q;
    assign mepc_o         = mepc_q;
    assign mstatus_mie_o  = mstatus_mie_q;

    // ── compute write value per CSR op ──────────────────────
    wire [31:0] uimm5_ext = {27'b0, uimm5_i};
    logic [31:0] write_value;
    logic        write_en;
    always_comb begin
        write_en    = 1'b0;
        write_value = csr_read;
        if (op_en_i) begin
            unique case (op_i)
                OOO_CSR_RW:  begin write_en = 1'b1; write_value = rs1_value_i;          end
                OOO_CSR_RS:  begin write_en = (rs1_value_i != 32'b0);
                                write_value = csr_read | rs1_value_i;               end
                OOO_CSR_RC:  begin write_en = (rs1_value_i != 32'b0);
                                write_value = csr_read & ~rs1_value_i;              end
                OOO_CSR_RWI: begin write_en = 1'b1; write_value = uimm5_ext;            end
                OOO_CSR_RSI: begin write_en = (uimm5_i != 5'b0);
                                write_value = csr_read | uimm5_ext;                 end
                OOO_CSR_RCI: begin write_en = (uimm5_i != 5'b0);
                                write_value = csr_read & ~uimm5_ext;                end
                default: ;
            endcase
        end
    end

    // ── sequential update ───────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            mstatus_mie_q  <= 1'b0;
            mstatus_mpie_q <= 1'b0;
            mtvec_q        <= '0;
            mepc_q         <= '0;
            mcause_code_q  <= '0;
            mcause_int_q   <= 1'b0;
            mtval_q        <= '0;
            mscratch_q     <= '0;
        end else begin
            // M7-full: trap_take wins, mret runs second. Both stubbed
            // for now (M7-minimal).
            if (trap_take_i) begin
                mepc_q         <= trap_pc_i;
                mcause_code_q  <= trap_cause_i;
                mcause_int_q   <= 1'b0;
                mtval_q        <= trap_tval_i;
                mstatus_mpie_q <= mstatus_mie_q;
                mstatus_mie_q  <= 1'b0;
            end else if (mret_en_i) begin
                mstatus_mie_q  <= mstatus_mpie_q;
                mstatus_mpie_q <= 1'b1;
            end else if (write_en) begin
                unique case (csr_addr_i)
                    CSR_MSTATUS: begin
                        mstatus_mie_q  <= write_value[3];
                        mstatus_mpie_q <= write_value[7];
                    end
                    CSR_MTVEC:    mtvec_q       <= write_value;
                    CSR_MSCRATCH: mscratch_q    <= write_value;
                    CSR_MEPC:     mepc_q        <= write_value;
                    CSR_MCAUSE: begin
                        mcause_int_q  <= write_value[31];
                        mcause_code_q <= write_value[4:0];
                    end
                    CSR_MTVAL:    mtval_q       <= write_value;
                    default: ;                      // unknown CSR → WI
                endcase
            end
        end
    end

endmodule
