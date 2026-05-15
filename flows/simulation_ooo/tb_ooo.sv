// Minimal testbench for the OoO core.
//
// Wires `core_ooo_top` to two `mem_bus.slave` RAMs (imem + dmem),
// both backed by `ram.hex`. Halt is signalled by the program writing
// any value to address 0x0000F000 — the testbench observes the write
// and asserts `done_o` to the Verilator main.
//
// ── RISCOF mode (plusarg-gated) ──────────────────────────────────
// When `+sig_file=<path>` is supplied, the testbench:
//   * Reads `+sig_begin=<hex>` / `+sig_end=<hex>` for the signature
//     address range (the [begin_signature..end_signature) symbols
//     extracted from the test's ELF by run_test.sh).
//   * Treats a write to `+tohost=<hex>` (default 0x0F000000) as the
//     completion signal instead of (or in addition to) the directed-
//     battery's 0xF000 halt write.
//   * On completion, dumps the [begin..end) signature region as
//     8-hex-digits-per-line text to `<path>` and asserts done.
//   * Reads `+ram_hex=<path>` to override the default `ram.hex`.
//   * Reads `+reset_pc=<hex>` to set the OoO core's reset PC
//     (default 0). RISCOF tests are linked at 0x80000000.
// The directed test battery passes none of these plusargs, so the
// existing behavior is preserved.

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

`ifndef RAM_WORDS
`define RAM_WORDS 65536          // 256 KB default — fits all rv32i/m archtest cases
`endif

    localparam int RAM_WORDS = `RAM_WORDS;
    localparam logic [31:0] HALT_ADDR_DEFAULT = 32'h0000_F000;

    // ── plusargs (sampled at reset deassert) ──────────────────
    string   sig_file_s;
    bit      have_sig_file;
    bit [31:0] sig_begin;
    bit [31:0] sig_end;
    bit [31:0] tohost_addr;
    string   ram_hex_s;
    bit [31:0] reset_pc_v;

    initial begin
        if ($value$plusargs("ram_hex=%s", ram_hex_s)) begin /* override below */ end
        else                                                  ram_hex_s = "ram.hex";
        if ($value$plusargs("reset_pc=%h", reset_pc_v)) begin /* override */ end
        else                                                  reset_pc_v = 32'h0;
        if ($value$plusargs("tohost=%h", tohost_addr)) begin /* override */ end
        else                                                  tohost_addr = HALT_ADDR_DEFAULT;
        have_sig_file = $value$plusargs("sig_file=%s", sig_file_s);
        if (!$value$plusargs("sig_begin=%h", sig_begin)) sig_begin = 32'h0;
        if (!$value$plusargs("sig_end=%h",   sig_end))   sig_end   = 32'h0;
    end

    // ── busses ────────────────────────────────────────────────
    mem_bus imem_bus();
    mem_bus dmem_bus();

    // ── core ──────────────────────────────────────────────────
    core_ooo_top core_inst (
        .clk_i      (clk),
        .reset_i    (reset),
        .reset_pc_i (reset_pc_v),
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
        $readmemh(ram_hex_s, mem);
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
                // Tohost write triggers halt regardless of value
                // (RISCOF writes 1 on completion; directed battery
                // writes 0xdeadbeef). Both flow through here.
                if (dmem_bus.addr == tohost_addr) begin
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

    // ── signature dump on halt (RISCOF mode) ──────────────────
    // On the cycle halt_q rises, walk the signature range and write
    // each 32-bit word as 8 hex digits to the file. We do this in
    // an always_ff to keep file ops out of the busy combinational
    // paths and to avoid double-firing.
    int  sig_fp;
    bit  sig_dumped;
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            sig_dumped <= 1'b0;
        end else if (halt_q && have_sig_file && !sig_dumped) begin
            sig_dumped <= 1'b1;
            sig_fp = $fopen(sig_file_s, "w");
            if (sig_fp == 0) begin
                $display("ERROR: cannot open %s for writing", sig_file_s);
            end else begin
                for (logic [31:0] a = sig_begin; a < sig_end; a += 4) begin
                    $fdisplay(sig_fp, "%08x", mem[a[31:2] % RAM_WORDS]);
                end
                $fclose(sig_fp);
                $display("SIG_DUMP: %0d words to %s",
                         (sig_end - sig_begin) / 4, sig_file_s);
            end
        end
    end

    // ── observables for Verilator ─────────────────────────────
    assign pc_o         = core_inst.fetch_inst.pc_q;
    assign done_o       = halt_q;
    assign halt_value_o = halt_value_q;

endmodule
