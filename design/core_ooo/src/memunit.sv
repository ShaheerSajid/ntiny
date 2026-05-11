// OoO core v1 — memory unit (M1: single-outstanding, in-order).
//
// At M1 the memunit also carries the ROB index of the in-flight op
// so that the load/store completion can be steered to the right
// ROB entry on the writeback path. Both LOAD and STORE produce an
// `op_done_o` pulse — STORE's result is just zero (the ROB entry
// has no rd to write but still needs `ready` set so it can commit).
//
// M4 will replace this with a real load-store queue.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module memunit
(
    input  logic              clk_i,
    input  logic              reset_i,
    input  logic              flush_i,

    // dispatch — kick on the cycle an EX-issuing LOAD/STORE fires
    input  onebit_sig_e       kick_i,
    input  fu_type_e          fu_i,           // FU_LOAD or FU_STORE
    input  logic [31:0]       addr_i,
    input  logic [31:0]       store_data_i,
    input  load_store_width_e width_i,
    input  onebit_sig_e       mem_unsigned_i,
    input  logic [OOO_ROB_IDX_W-1:0] rob_idx_i,

    // bus
    mem_bus.master            dmem_port,

    // completion → ROB writeback
    output onebit_sig_e       op_done_o,
    output logic [OOO_ROB_IDX_W-1:0] op_done_rob_idx_o,
    output logic [31:0]       op_done_result_o,
    output onebit_sig_e       busy_o
);

    typedef enum logic [1:0] { IDLE, REQ, WAIT_RVALID } state_e;
    state_e state_q;

    logic [31:0]                addr_q;
    logic [31:0]                store_data_q;
    load_store_width_e          width_q;
    onebit_sig_e                unsigned_q;
    logic [OOO_ROB_IDX_W-1:0]   rob_idx_q;
    fu_type_e                   fu_q;

    wire is_load  = (fu_q == FU_LOAD);
    wire is_store = (fu_q == FU_STORE);

    // ── byte enable + aligned store data ──────────────────────
    logic [3:0]  be;
    logic [31:0] wdata_aligned;
    always_comb begin
        be            = 4'b0000;
        wdata_aligned = 32'b0;
        unique case (width_q)
            BYTE: begin
                be[addr_q[1:0]] = 1'b1;
                wdata_aligned   = {4{store_data_q[7:0]}};
            end
            HALF: begin
                be              = (addr_q[1] == 1'b0) ? 4'b0011 : 4'b1100;
                wdata_aligned   = {2{store_data_q[15:0]}};
            end
            WORD: begin
                be              = 4'b1111;
                wdata_aligned   = store_data_q;
            end
            default: begin
                be              = 4'b0000;
                wdata_aligned   = 32'b0;
            end
        endcase
    end

    // ── bus drive ─────────────────────────────────────────────
    wire fire = (state_q == REQ);

    assign dmem_port.req   = fire;
    assign dmem_port.we    = fire && is_store;
    assign dmem_port.addr  = {addr_q[31:2], 2'b00};
    assign dmem_port.be    = be;
    assign dmem_port.wdata = wdata_aligned;

    // ── FSM ───────────────────────────────────────────────────
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            state_q      <= IDLE;
            addr_q       <= '0;
            store_data_q <= '0;
            width_q      <= NO_WIDTH;
            unsigned_q   <= FALSE;
            rob_idx_q    <= '0;
            fu_q         <= FU_NONE;
        end else if (flush_i) begin
            state_q      <= IDLE;
        end else begin
            unique case (state_q)
                IDLE: if (kick_i == TRUE) begin
                    state_q      <= REQ;
                    addr_q       <= addr_i;
                    store_data_q <= store_data_i;
                    width_q      <= width_i;
                    unsigned_q   <= mem_unsigned_i;
                    rob_idx_q    <= rob_idx_i;
                    fu_q         <= fu_i;
                end
                REQ: if (dmem_port.ready) begin
                    state_q <= (fu_q == FU_LOAD) ? WAIT_RVALID : IDLE;
                end
                WAIT_RVALID: if (dmem_port.rvalid) begin
                    state_q <= IDLE;
                end
                default: state_q <= IDLE;
            endcase
        end
    end

    // ── LOAD result formatting ────────────────────────────────
    wire [31:0] raw = dmem_port.rdata;
    logic [7:0]  byte_sel;
    logic [15:0] half_sel;
    always_comb begin
        unique case (addr_q[1:0])
            2'b00: byte_sel = raw[7:0];
            2'b01: byte_sel = raw[15:8];
            2'b10: byte_sel = raw[23:16];
            2'b11: byte_sel = raw[31:24];
        endcase
        half_sel = (addr_q[1] == 1'b0) ? raw[15:0] : raw[31:16];
    end

    logic [31:0] load_data;
    always_comb begin
        unique case (width_q)
            BYTE: load_data = (unsigned_q == TRUE) ? {24'b0, byte_sel}
                                                   : {{24{byte_sel[7]}},  byte_sel};
            HALF: load_data = (unsigned_q == TRUE) ? {16'b0, half_sel}
                                                   : {{16{half_sel[15]}}, half_sel};
            WORD: load_data = raw;
            default: load_data = 32'b0;
        endcase
    end

    // ── completion pulses ────────────────────────────────────
    // LOAD: pulse when rvalid arrives in WAIT_RVALID.
    // STORE: pulse when ready accepts the write in REQ (transition
    // back to IDLE).
    wire load_done  = is_load  && state_q == WAIT_RVALID && dmem_port.rvalid;
    wire store_done = is_store && state_q == REQ         && dmem_port.ready;

    assign op_done_o         = onebit_sig_e'(load_done || store_done);
    assign op_done_rob_idx_o = rob_idx_q;
    assign op_done_result_o  = is_load ? load_data : 32'b0;
    assign busy_o            = onebit_sig_e'(state_q != IDLE);

endmodule
