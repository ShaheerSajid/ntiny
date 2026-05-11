// OoO core v1 — memory unit (M0: single-outstanding, in-order)
//
// M0 contract: one LOAD or STORE at a time. Asserts dmem.req on the
// kick cycle, holds it until accepted, then waits for rvalid (LOAD
// only). Stalls the core while busy. No store-to-load forwarding,
// no LSQ — that lands in M4.
//
// Sign-extension of sub-word loads happens here so the writeback mux
// in the top can take a single 32-bit value.

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module memunit
(
    input  logic              clk_i,
    input  logic              reset_i,
    input  logic              flush_i,

    // dispatch — kick on the cycle a LOAD/STORE is issued
    input  onebit_sig_e       kick_i,         // 1-cycle pulse from EX
    input  fu_type_e          fu_i,           // FU_LOAD or FU_STORE
    input  logic [31:0]       addr_i,
    input  logic [31:0]       store_data_i,
    input  load_store_width_e width_i,
    input  onebit_sig_e       mem_unsigned_i,
    input  logic [4:0]        rd_i,

    // bus
    mem_bus.master            dmem_port,

    // result (LOAD)
    output logic [31:0]       load_data_o,
    output logic [4:0]        load_rd_o,
    output onebit_sig_e       load_valid_o,   // 1-cycle pulse when LOAD writeback ready
    output onebit_sig_e       busy_o          // assert while a request is in flight
);

    typedef enum logic [1:0] { IDLE, REQ, WAIT_RVALID } state_e;
    state_e state_q;

    logic [31:0]       addr_q;
    logic [31:0]       store_data_q;
    load_store_width_e width_q;
    onebit_sig_e       unsigned_q;
    logic [4:0]        rd_q;
    fu_type_e          fu_q;

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
                be[addr_q[1:0]]                  = 1'b1;
                wdata_aligned                    = {4{store_data_q[7:0]}};
            end
            HALF: begin
                if (addr_q[1] == 1'b0) be       = 4'b0011;
                else                   be       = 4'b1100;
                wdata_aligned                    = {2{store_data_q[15:0]}};
            end
            WORD: begin
                be                               = 4'b1111;
                wdata_aligned                    = store_data_q;
            end
            default: begin
                be                               = 4'b0000;
                wdata_aligned                    = 32'b0;
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
            rd_q         <= '0;
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
                    rd_q         <= rd_i;
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

    assign load_data_o  = load_data;
    assign load_rd_o    = rd_q;
    assign load_valid_o = onebit_sig_e'(state_q == WAIT_RVALID && dmem_port.rvalid && is_load);
    assign busy_o       = onebit_sig_e'(state_q != IDLE);

endmodule
