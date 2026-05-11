// Minimal testbench for the OoO core (M0).
//
// Wires `core_ooo_top` to two `mem_bus.slave` RAMs (imem + dmem),
// both backed by `ram.hex`. Halt is signalled by the program writing
// any value to address 0x0000F000 — the testbench observes the write
// and asserts `done_o` to the Verilator main.
//
// No SoC peripherals, no CSRs, no MMU. The OoO core at M0 is
// bare-metal RV32I only and runs from physical 0x00000000.

`timescale 1ns/10ps

import common_pkg::*;
import core_pkg::*;
import core_ooo_pkg::*;

module tb_ooo
(
    input  logic       clk,
    input  logic       reset,
    output logic [31:0] pc_o,
    output logic        done_o,
    output logic [31:0] halt_value_o
);

    localparam int RAM_WORDS = 4096;             // 16 KB
    localparam logic [31:0] HALT_ADDR = 32'h0000_F000;

    // ── busses ────────────────────────────────────────────────
    mem_bus imem_bus();
    mem_bus dmem_bus();

    // ── core ──────────────────────────────────────────────────
    core_ooo_top core_inst (
        .clk_i      (clk),
        .reset_i    (reset),
        .imem_port  (imem_bus),
        .dmem_port  (dmem_bus),

        .resumeack_o(), .running_o(), .halted_o(),
        .haltreq_i  (FALSE), .resumereq_i(FALSE),

        .ar_en_i(FALSE), .ar_wr_i(FALSE), .ar_ad_i('0),
        .ar_done_o(), .ar_di_i('0), .ar_do_o(),

        .am_en_i(FALSE), .am_wr_i(FALSE), .am_st_i('0),
        .am_ad_i('0), .am_di_i('0), .am_do_o(), .am_done_o(),

        .ext_itr_i  (1'b0),
        .s_ext_itr_i(1'b0),
        .timer_itr_i(1'b0),
        .soft_itr_i (1'b0),
        .mtime_i    (64'b0),

        .fence_i_o  ()
    );

    // ── single shared backing store (imem == dmem) ────────────
    logic [31:0] mem [0:RAM_WORDS-1];
    initial begin
        for (int i = 0; i < RAM_WORDS; i++) mem[i] = 32'h0;
        $readmemh("ram.hex", mem);
    end

    // ── imem slave (read-only, 1-cycle rvalid) ────────────────
    logic [31:0] imem_rdata_q;
    logic        imem_rvalid_q;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            imem_rdata_q  <= '0;
            imem_rvalid_q <= 1'b0;
        end else begin
            imem_rvalid_q <= imem_bus.req & imem_bus.ready & ~imem_bus.we;
            if (imem_bus.req & imem_bus.ready & ~imem_bus.we) begin
                imem_rdata_q <= mem[imem_bus.addr[31:2] % RAM_WORDS];
            end
        end
    end
    assign imem_bus.ready  = 1'b1;
    assign imem_bus.rdata  = imem_rdata_q;
    assign imem_bus.rvalid = imem_rvalid_q;

    // ── dmem slave (read/write, 1-cycle rvalid for reads) ─────
    logic [31:0] dmem_rdata_q;
    logic        dmem_rvalid_q;

    // Track halt: any write to HALT_ADDR ends the sim.
    logic        halt_q;
    logic [31:0] halt_value_q;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            dmem_rdata_q  <= '0;
            dmem_rvalid_q <= 1'b0;
            halt_q        <= 1'b0;
            halt_value_q  <= '0;
        end else begin
            dmem_rvalid_q <= dmem_bus.req & dmem_bus.ready & ~dmem_bus.we;
            if (dmem_bus.req & dmem_bus.ready & ~dmem_bus.we) begin
                dmem_rdata_q <= mem[dmem_bus.addr[31:2] % RAM_WORDS];
            end
            if (dmem_bus.req & dmem_bus.ready & dmem_bus.we) begin
                // Byte-enable lane masking
                if (dmem_bus.addr == HALT_ADDR) begin
                    halt_q       <= 1'b1;
                    halt_value_q <= dmem_bus.wdata;
                end else begin
                    automatic logic [31:0] cur = mem[dmem_bus.addr[31:2] % RAM_WORDS];
                    if (dmem_bus.be[0]) cur[ 7: 0] = dmem_bus.wdata[ 7: 0];
                    if (dmem_bus.be[1]) cur[15: 8] = dmem_bus.wdata[15: 8];
                    if (dmem_bus.be[2]) cur[23:16] = dmem_bus.wdata[23:16];
                    if (dmem_bus.be[3]) cur[31:24] = dmem_bus.wdata[31:24];
                    mem[dmem_bus.addr[31:2] % RAM_WORDS] <= cur;
                end
            end
        end
    end
    assign dmem_bus.ready  = 1'b1;
    assign dmem_bus.rdata  = dmem_rdata_q;
    assign dmem_bus.rvalid = dmem_rvalid_q;

    // ── observables for Verilator ─────────────────────────────
    assign pc_o         = core_inst.fetch_inst.pc_q;
    assign done_o       = halt_q;
    assign halt_value_o = halt_value_q;

endmodule
