import common_pkg::*;
import core_pkg::*;
import debug_pkg::*;

// ── Debug Controller ────────────────────────────────────────────────────────
// Owns the debug FSM (RUNNING/HALTED/RESUME), debug CSRs (DCSR, DPC), and
// abstract register/memory access routing.  Extracted from core_top for
// separation of concerns.
//
// The 6 pipeline mux overrides (regfile, CSR, memory) remain in core_top
// but use clean outputs from this module (halted_o, dbg_override_o, etc.).
//
// Spec notes (RISC-V Debug Spec 0.13):
//   - DCSR is at 0x7B0, DPC at 0x7B1 (debug CSR space, accessible only via
//     abstract register access when halted)
//   - DSCRATCH0/1 (0x7B2/0x7B3) not implemented
//   - Abstract register writes to integer/FP registers not implemented
//     (reads only — sufficient for OpenOCD register inspection)
//
module debug_ctrl (
    input  logic        clk_i,
    input  logic        reset_i,

    // ── External debug interface (from DM) ──────────────────────────────
    input  onebit_sig_e haltreq_i,
    input  onebit_sig_e resumereq_i,
    // Abstract register access
    input  onebit_sig_e ar_en_i,
    input  onebit_sig_e ar_wr_i,
    input  [15:0]       ar_ad_i,
    input  [31:0]       ar_di_i,
    // Abstract memory access
    input  onebit_sig_e am_en_i,
    input  logic        dmem_ready_i,

    // ── Pipeline state (for halt triggers) ──────────────────────────────
    input  logic        id_ebreak_i,        // ctrl_bus_if_id.ebreak
    input  logic        c_busy_i,           // c_controller busy
    input  [31:0]       pc_id_i,            // ID-stage PC
    input  [31:0]       next_insn_addr_i,   // from c_controller

    // ── Read data sources (for AR passthrough) ──────────────────────────
    input  [31:0]       csr_result_i,       // CSR read result
    input  [31:0]       rs1_int_i,          // integer regfile read
    input  [31:0]       rs1_float_i,        // FP regfile read
    input  [31:0]       readdata_imem_i,    // memory read result

    // ── Core status outputs ─────────────────────────────────────────────
    output onebit_sig_e resumeack_o,
    output onebit_sig_e running_o,
    output onebit_sig_e halted_o,           // HALTED || RESUME

    // ── Debug CSR outputs (consumed by pipeline) ────────────────────────
    output logic [31:0] dpc_o,
    output logic        dcsr_ebreak_o,      // dcsr[15]: ebreak enters debug
    output logic        dcsr_stopcount_o,   // dcsr[10]: stop counters when halted
    output logic        dcsr_step_o,        // dcsr[2]: single-step mode

    // ── Abstract register outputs ───────────────────────────────────────
    output logic [31:0] ar_do_o,
    output onebit_sig_e ar_done_o,

    // ── Abstract memory outputs ─────────────────────────────────────────
    output logic [31:0] am_do_o,
    output onebit_sig_e am_done_o,

    // ── Debug override signals (for core_top muxes) ─────────────────────
    output logic        dbg_rf_override_o,  // halted & ar_en (regfile/CSR mux)
    output logic        dbg_mem_override_o  // halted & am_en (memory mux)
);

// ═══════════════════════════════════════════════════════════════════════════
// Debug FSM
// ═══════════════════════════════════════════════════════════════════════════
enum logic [1:0] {RUNNING, HALTED, RESUME} pstate, nstate;

wire debug_step = dcsr_step_o;
wire ebreak_halt = (id_ebreak_i == TRUE) && dcsr_ebreak_o;

always_comb begin
    case (pstate)
        RUNNING: nstate = (haltreq_i || ebreak_halt || (debug_step && !c_busy_i))
                          ? HALTED : RUNNING;
        HALTED:  nstate = resumereq_i ? RESUME : HALTED;
        RESUME:  nstate = resumereq_i ? RESUME : RUNNING;
        default: nstate = RUNNING;
    endcase
end

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        pstate <= RUNNING;
    else
        pstate <= nstate;
end

assign resumeack_o = onebit_sig_e'(pstate == RESUME);
assign running_o   = onebit_sig_e'(pstate == RUNNING);
assign halted_o    = onebit_sig_e'((pstate == HALTED) || (pstate == RESUME));

// Override signals for core_top muxes
assign dbg_rf_override_o  = (pstate == HALTED) & ar_en_i;
assign dbg_mem_override_o = (pstate == HALTED) & am_en_i;

// ═══════════════════════════════════════════════════════════════════════════
// Debug CSRs
// ═══════════════════════════════════════════════════════════════════════════

// ── DCSR (0x7B0) ────────────────────────────────────────────────────────
logic [31:0] dcsr;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        dcsr <= 0;
    else if (ar_en_i && ar_wr_i && (ar_ad_i == 16'h07b0))
        dcsr <= ar_di_i;
end

assign dcsr_ebreak_o    = dcsr[15];
assign dcsr_stopcount_o = dcsr[10];
assign dcsr_step_o      = dcsr[2];

// ── Debug cause ─────────────────────────────────────────────────────────
dcause_e debug_cause;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        debug_cause <= NO_DBG_CAUSE;
    else if (pstate == RUNNING && ebreak_halt)
        debug_cause <= DBG_EBREAK;
    else if (pstate == RUNNING && haltreq_i)
        debug_cause <= DBG_HALTREQ;
    else if (pstate == RUNNING && debug_step)
        debug_cause <= DBG_STEP;
end

// ── DPC (0x7B1) ─────────────────────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        dpc_o <= 0;
    else if (ar_en_i && ar_wr_i && (ar_ad_i == 16'h07b1))
        dpc_o <= ar_di_i;
    else if (pstate == RUNNING && ebreak_halt)
        dpc_o <= pc_id_i;
    else if (pstate == RUNNING && (haltreq_i || debug_step))
        dpc_o <= next_insn_addr_i;
end

// ═══════════════════════════════════════════════════════════════════════════
// Abstract register read logic
// ═══════════════════════════════════════════════════════════════════════════
// DCSR read: packed per Debug Spec (xdebugver=4, prv=3, step/ebreakm bits)
wire [31:0] dcsr_read = {4'd4, 12'd0, dcsr[15], 1'b0, dcsr[13:9],
                          debug_cause, 1'b0, dcsr[4], 1'b0, dcsr[2], 2'd3};

onebit_sig_e ar_done_r;
onebit_sig_e am_done_r;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        ar_do_o   <= 0;
        ar_done_r <= FALSE;
        am_done_r <= FALSE;
    end else begin
        // AR data output mux
        if (ar_ad_i < 32'h1000)
            case (ar_ad_i)
                16'h07b0: ar_do_o <= dcsr_read;
                16'h07b1: ar_do_o <= dpc_o;
                default:  ar_do_o <= csr_result_i;
            endcase
        else if (ar_ad_i >= 32'h1000 && ar_ad_i <= 32'h101f)
            ar_do_o <= rs1_int_i;
        else if (ar_ad_i >= 32'h1020 && ar_ad_i <= 32'h103f)
            ar_do_o <= rs1_float_i;

        ar_done_r <= ar_en_i;
        am_done_r <= onebit_sig_e'(am_en_i & dmem_ready_i);
    end
end

assign ar_done_o = ar_done_r;
assign am_do_o   = readdata_imem_i;
assign am_done_o = am_done_r;

endmodule
