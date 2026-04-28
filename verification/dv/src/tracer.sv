// Copyright 2018 ETH Zurich and University of Bologna, see also CREDITS.md.
// Copyright 2020 Lampro Mellon
// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

// ─────────────────────────────────────────────────────────────────────────────
// dv_tracer — retired-instruction trace logger
// ─────────────────────────────────────────────────────────────────────────────
//
// Consumes a subset of the RVFI (RISC-V Formal Interface) signals plus
// extension inputs (priv level, trap commit, xret commit) and emits two
// human-readable log files per hart:
//
//   trace_core_<HART>.log       — one line per retired instruction
//                                 (cycle, priv, PC, insn word, disasm,
//                                  reg/mem accessed values)
//   trace_core_<HART>_traps.log — one line per trap entry / xret commit
//
// Conceptually aligned with the unratified RISC-V Hart-Trace Interface
// (HTI). The HTI is a hart-to-encoder hardware contract; we don't emit
// HTI packets — instead we capture the same information the encoder
// would receive, formatted for human inspection.
//
// File-name base defaults to "trace_core". Override via the runtime
// plusarg `+tracer_file_base=...`.
//
// Window control (all optional, default = always-on):
//   +tracer_start_cycle=N    start logging at cycle N (default 0)
//   +tracer_stop_cycle=N     stop logging at cycle N (default ~0)
//   +tracer_start_pc=HEX     arm tracer when retired PC == HEX
//                            (default 0 = pre-armed)
//   +tracer_stop_pc=HEX      disarm when retired PC == HEX
//                            (default 0 = never)
//
// Cycle window and PC triggers are AND'd. PC triggers act on retired
// PC; when start_pc != 0 the tracer starts disarmed.
// ─────────────────────────────────────────────────────────────────────────────

import tracer_pkg::*;
module tracer (
  input logic        clk_i,
  input logic        rst_ni,
  input logic [31:0] hart_id_i,

  // ── RVFI subset ────────────────────────────────────────────────────
  // Reference: https://github.com/SymbioticEDA/riscv-formal/blob/master/docs/rvfi.md
  // (rvfi_order/trap/halt/intr/mode are not consumed by this tracer.)
  input logic        rvfi_valid,
  input logic [31:0] rvfi_insn_t,
  input logic [ 4:0] rvfi_rs1_addr_t,
  input logic [ 4:0] rvfi_rs2_addr_t,
  input logic [ 4:0] rvfi_rs3_addr_t,
  input logic [31:0] rvfi_rs1_rdata_t,
  input logic [31:0] rvfi_rs2_rdata_t,
  input logic [31:0] rvfi_rs3_rdata_t,
  input logic [ 4:0] rvfi_rd_addr_t,
  input logic [31:0] rvfi_rd_wdata_t,
  input logic [31:0] rvfi_pc_rdata_t,
  input logic [31:0] rvfi_pc_wdata_t,
  input logic [31:0] rvfi_mem_addr,
  input logic [ 3:0] rvfi_mem_rmask,
  input logic [ 3:0] rvfi_mem_wmask,
  input logic [31:0] rvfi_mem_rdata,
  input logic [31:0] rvfi_mem_wdata,

  // ── Trace extension: privilege + trap events ───────────────────────
  // Backward compatible: tying these to 0 disables the extension log.
  input logic [ 1:0] priv_i,
  input logic        trap_valid_i,        // sync exception OR async interrupt firing this cycle
  input logic [31:0] trap_cause_i,        // mcause/scause value
  input logic [31:0] trap_epc_i,          // captured EPC
  input logic [31:0] trap_tval_i,         // mtval/stval
  input logic        trap_to_s_i,         // 1 = delegated to S-mode
  input logic        xret_fire_i,         // mret or sret committed at IWB this cycle
  input logic        xret_is_sret_i,      // 1 = sret, 0 = mret
  input logic [31:0] xret_target_i        // resume PC (sepc or mepc)
);

logic [31:0] rvfi_insn;
logic [ 4:0] rvfi_rs1_addr;
logic [ 4:0] rvfi_rs2_addr;
logic [ 4:0] rvfi_rs3_addr;
logic [31:0] rvfi_rs1_rdata;
logic [31:0] rvfi_rs2_rdata;
logic [31:0] rvfi_rs3_rdata;
logic [ 4:0] rvfi_rd_addr;
logic [31:0] rvfi_rd_wdata;
logic [31:0] rvfi_pc_rdata;
logic [31:0] rvfi_pc_wdata;

  

  int          file_handle; //,file_handle_nb;
  string       file_name;
  int          file_handle_traps;
  string       file_name_traps;

  // ── Window control (2026-04-28) ──────────────────────────────────
  // Plusargs (all optional; defaults = always-on, full trace):
  //   +tracer_start_cycle=N   start logging at cycle N (default 0)
  //   +tracer_stop_cycle=N    stop logging at cycle N (default ~0)
  //   +tracer_start_pc=HEX    arm tracer when PC == HEX (default 0 = pre-armed)
  //   +tracer_stop_pc=HEX     disarm tracer when PC == HEX (default 0 = never)
  //
  // PC triggers act on retired-instruction PC. When start_pc is set,
  // tracer starts disarmed and arms on the first hit. stop_pc disarms.
  // start_pc/stop_pc can be combined with the cycle window (AND).
  int unsigned trace_start_cycle = 0;
  int unsigned trace_stop_cycle  = 32'hFFFFFFFF;
  logic [31:0] trace_start_pc = 32'h0;
  logic [31:0] trace_stop_pc  = 32'h0;
  logic        trace_armed = 1'b1;   // when start_pc != 0, gets reset to 0 in initial
  initial begin
    void'($value$plusargs("tracer_start_cycle=%d", trace_start_cycle));
    void'($value$plusargs("tracer_stop_cycle=%d",  trace_stop_cycle));
    void'($value$plusargs("tracer_start_pc=%h",    trace_start_pc));
    void'($value$plusargs("tracer_stop_pc=%h",     trace_stop_pc));
    if (trace_start_pc != 32'h0)
      trace_armed = 1'b0;            // wait for PC trigger
    $display("%m: tracer window: armed=%0d start_cyc=%0d stop_cyc=%0d start_pc=%08h stop_pc=%08h",
             trace_armed, trace_start_cycle, trace_stop_cycle, trace_start_pc, trace_stop_pc);
  end
  wire trace_in_cycle_window = (cycle >= trace_start_cycle) && (cycle <= trace_stop_cycle);
  wire trace_log_now = trace_armed && trace_in_cycle_window;

  int unsigned cycle;
  string       decoded_str;
  logic        insn_is_compressed;

  // Data items accessed during this instruction (bitmask in data_accessed)
  localparam RS1 = (1 << 0);
  localparam RS2 = (1 << 1);
  localparam RS3 = (1 << 2);
  localparam RD  = (1 << 3);
  localparam MEM = (1 << 4);
  logic [4:0] data_accessed;
  logic       rs1_float, rs2_float, rs3_float, rd_float;

  // ── Helpers ────────────────────────────────────────────────────────

  // Format a register name with optional float prefix; left-aligned to
  // 3 chars so columns line up.
  function automatic string reg_str(input logic float, input logic [4:0] addr);
    string p = float ? "f" : "x";
    return (addr < 10) ? $sformatf(" %s%0d", p, addr)
                       : $sformatf("%s%0d", p, addr);
  endfunction

  // Existing compatibility wrappers used by some decode_*_insn functions.
  function automatic string reg_addr_to_str(input logic [4:0] addr);
    return reg_str(1'b0, addr);
  endfunction
  function automatic string reg_f_addr_to_str(input logic [4:0] addr);
    return reg_str(1'b1, addr);
  endfunction

  // Print one register's name+value to the main trace file.
  // sep distinguishes source (":") from destination ("=") for readability.
  function automatic void print_reg(input logic float, input logic [4:0] addr,
                                     input logic [31:0] data, input string sep);
    $fwrite(file_handle, " %s%s0x%08x", reg_str(float, addr), sep, data);
  endfunction

  function automatic void printbuffer_dumpline();
    string rvfi_insn_str;

    if (file_handle == 32'h0) begin
      string file_name_base = "trace_core";
      void'($value$plusargs("tracer_file_base=%s", file_name_base));
      $sformat(file_name, "%s_%h.log", file_name_base, hart_id_i);
      $display("%m: Writing execution trace to %s", file_name);
      file_handle = $fopen(file_name, "w");
      $fwrite(file_handle, "\t\tTime\t\t\tCycle\tPriv\tPC\t\tInsn\tDecoded instruction\tRegister and memory contents\n");
    end

    // Compressed: four hex digits; uncompressed: eight.
    rvfi_insn_str = insn_is_compressed ? $sformatf("%h", rvfi_insn[15:0])
                                        : $sformatf("%h", rvfi_insn);

    $fwrite(file_handle, "%15t\t%d\t%0d\t%h\t%s\t%s\t",
            $time, cycle, priv_i, rvfi_pc_rdata, rvfi_insn_str, decoded_str);

    if (data_accessed & RS1) print_reg(rs1_float, rvfi_rs1_addr, rvfi_rs1_rdata, ":");
    if (data_accessed & RS2) print_reg(rs2_float, rvfi_rs2_addr, rvfi_rs2_rdata, ":");
    if (data_accessed & RS3) print_reg(rs3_float, rvfi_rs3_addr, rvfi_rs3_rdata, ":");
    if (data_accessed & RD) begin
      // Skip RD print for x0 (writes are no-ops); always print for float.
      if (rd_float || rvfi_rd_addr != 0)
        print_reg(rd_float, rvfi_rd_addr, rvfi_rd_wdata, "=");
    end
    if (data_accessed & MEM) begin
      $fwrite(file_handle, " PA:0x%08x", rvfi_mem_addr);
      if (rvfi_mem_rmask != 4'b0) $fwrite(file_handle, " store:0x%08x", rvfi_mem_wdata);
      if (rvfi_mem_wmask != 4'b0) $fwrite(file_handle, " load:0x%08x",  rvfi_mem_rdata);
    end

    $fwrite(file_handle, "\n");
  endfunction

  // Get a CSR name for a CSR address.
  // Strategy: handle range-encoded blocks (HPM, PMP) algorithmically;
  // fall through to a single case for the remaining named CSRs.
  function automatic string get_csr_name(input logic [11:0] csr_addr);
    // Performance-monitor counters (29 entries each, low + high halves)
    if (csr_addr inside {[12'd3075:12'd3103]})
      return $sformatf("hpmcounter%0d",  csr_addr - 12'd3072);
    if (csr_addr inside {[12'd3203:12'd3231]})
      return $sformatf("hpmcounter%0dh", csr_addr - 12'd3200);
    if (csr_addr inside {[12'd2819:12'd2847]})
      return $sformatf("mhpmcounter%0d",  csr_addr - 12'd2816);
    if (csr_addr inside {[12'd2947:12'd2975]})
      return $sformatf("mhpmcounter%0dh", csr_addr - 12'd2944);
    if (csr_addr inside {[12'd803 :12'd831 ]})
      return $sformatf("mhpmevent%0d",    csr_addr - 12'd800);
    // PMP address registers
    if (csr_addr inside {[12'd944 :12'd959 ]})
      return $sformatf("pmpaddr%0d",      csr_addr - 12'd944);

    unique case (csr_addr)
      12'd0: return "ustatus";
      12'd4: return "uie";
      12'd5: return "utvec";
      12'd64: return "uscratch";
      12'd65: return "uepc";
      12'd66: return "ucause";
      12'd67: return "utval";
      12'd68: return "uip";
      12'd1: return "fflags";
      12'd2: return "frm";
      12'd3: return "fcsr";
      12'd3072: return "cycle";
      12'd3073: return "time";
      12'd3074: return "instret";
      12'd3200: return "cycleh";
      12'd3201: return "timeh";
      12'd3202: return "instreth";
      // S-mode
      12'd256: return "sstatus";    12'd258: return "sedeleg";
      12'd259: return "sideleg";    12'd260: return "sie";
      12'd261: return "stvec";      12'd262: return "scounteren";
      12'd320: return "sscratch";   12'd321: return "sepc";
      12'd322: return "scause";     12'd323: return "stval";
      12'd324: return "sip";        12'd384: return "satp";
      // M-mode
      12'd768: return "mstatus";    12'd769: return "misa";
      12'd770: return "medeleg";    12'd771: return "mideleg";
      12'd772: return "mie";        12'd773: return "mtvec";
      12'd774: return "mcounteren"; 12'd800: return "mucounteren";
      12'd801: return "mscounteren";12'd802: return "mhcounteren";
      12'd832: return "mscratch";   12'd833: return "mepc";
      12'd834: return "mcause";     12'd835: return "mtval";
      12'd836: return "mip";        12'd2816: return "mcycle";
      12'd2818: return "minstret";  12'd2944: return "mcycleh";
      12'd2946: return "minstreth";
      12'd3857: return "mvendorid"; 12'd3858: return "marchid";
      12'd3859: return "mimpid";    12'd3860: return "mhartid";
      // PMP cfg
      12'd928: return "pmpcfg0";    12'd929: return "pmpcfg1";
      12'd930: return "pmpcfg2";    12'd931: return "pmpcfg3";
      // Debug
      12'd1952: return "tselect";   12'd1953: return "tdata1";
      12'd1954: return "tdata2";    12'd1955: return "tdata3";
      12'd1968: return "dcsr";      12'd1969: return "dpc";
      12'd1970: return "dscratch";
      // H-mode (hypervisor — placeholder names, deprecated layout)
      12'd512: return "hstatus";    12'd514: return "hedeleg";
      12'd515: return "hideleg";    12'd516: return "hie";
      12'd517: return "htvec";      12'd576: return "hscratch";
      12'd577: return "hepc";       12'd578: return "hcause";
      12'd579: return "hbadaddr";   12'd580: return "hip";
      12'd896: return "mbase";      12'd897: return "mbound";
      12'd898: return "mibase";     12'd899: return "mibound";
      12'd900: return "mdbase";     12'd901: return "mdbound";
      default: return $sformatf("0x%x", csr_addr);
    endcase
  endfunction
  
  


	///////////////////////////////////////////////////////////
	//		Decode functions for B_Type Instructions
	///////////////////////////////////////////////////////////


  function automatic void decode_r1_insn(input string mnemonic);
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d", mnemonic, rvfi_rd_addr, rvfi_rs1_addr);
  endfunction

  function automatic void decode_mnemonic(input string mnemonic);
    decoded_str = mnemonic;
  endfunction

  function automatic void decode_r_insn(input string mnemonic);
    data_accessed = RS1 | RS2 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,x%0d", mnemonic, rvfi_rd_addr, rvfi_rs1_addr,
        rvfi_rs2_addr);
  endfunction

    function automatic void decode_r3_insn(input string mnemonic);
    data_accessed = RS1 | RS2 | RS3 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,x%0d,x%0d", mnemonic, rvfi_rd_addr, rvfi_rs1_addr,
        rvfi_rs2_addr, rvfi_rs3_addr);
  endfunction

  function automatic void decode_i_insn(input string mnemonic);
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,%0d", mnemonic, rvfi_rd_addr, rvfi_rs1_addr,
                    $signed({{20 {rvfi_insn[31]}}, rvfi_insn[31:20]}));
  endfunction

  function automatic void decode_i_shift_insn(input string mnemonic);
    // SLLI, SRLI, SRAI, SROI, SLOI, RORI
    logic [4:0] shamt;
    shamt = {rvfi_insn[24:20]};
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,0x%0x", mnemonic, rvfi_rd_addr, rvfi_rs1_addr, shamt);
  endfunction


  function automatic void decode_i_jalr_insn(input string mnemonic);
    // JALR
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,%0d", mnemonic, rvfi_rd_addr, rvfi_rs1_addr,
        $signed({{20 {rvfi_insn[31]}}, rvfi_insn[31:20]}));
  endfunction

  function automatic void decode_u_insn(input string mnemonic);
    data_accessed = RD;
    decoded_str = $sformatf("%s\tx%0d,0x%0x", mnemonic, rvfi_rd_addr, {rvfi_insn[31:12]});
  endfunction

  function automatic void decode_j_insn(input string mnemonic);
    // JAL
    data_accessed = RD;
    decoded_str = $sformatf("%s\tx%0d,%0x", mnemonic, rvfi_rd_addr, rvfi_pc_wdata);
  endfunction

  function automatic void decode_b_insn(input string mnemonic);
    logic [31:0] branch_target;
    logic [31:0] imm;

    // We cannot use rvfi_pc_wdata for conditional jumps.
    imm = $signed({ {19 {rvfi_insn[31]}}, rvfi_insn[31], rvfi_insn[7],
             rvfi_insn[30:25], rvfi_insn[11:8], 1'b0 });
    branch_target = rvfi_pc_rdata + imm;

    data_accessed = RS1 | RS2;  //HHH: data_accessed = RS1 | RS2 | RD;
    decoded_str = $sformatf("%s\tx%0d,x%0d,%0x", mnemonic, rvfi_rs1_addr, rvfi_rs2_addr, branch_target);
  endfunction

  function automatic void decode_csr_insn(input string mnemonic);
    logic [11:0] csr;
    string csr_name;
    csr = rvfi_insn[31:20];
    csr_name = get_csr_name(csr);

    data_accessed = RD;

    if (!rvfi_insn[14]) begin
      data_accessed |= RS1;
      decoded_str = $sformatf("%s\tx%0d,%s,x%0d", mnemonic, rvfi_rd_addr, csr_name, rvfi_rs1_addr);
    end else begin
      decoded_str = $sformatf("%s\tx%0d,%s,%0d", mnemonic, rvfi_rd_addr, csr_name, { 27'b0, rvfi_insn[19:15]});
    end
  endfunction

  function automatic void decode_cr_insn(input string mnemonic);
    if (rvfi_rs2_addr == 5'b0) begin
      if (rvfi_insn[12] == 1'b1) begin
        // C.JALR
        data_accessed = RS1 | RD;
      end else begin
        // C.JR
        data_accessed = RS1;
      end
      decoded_str = $sformatf("%s\tx%0d", mnemonic, rvfi_rs1_addr);
    end else begin
      data_accessed = RS1 | RS2 | RD; // RS1 == RD
      decoded_str = $sformatf("%s\tx%0d,x%0d", mnemonic, rvfi_rd_addr, rvfi_rs2_addr);
    end
  endfunction

  function automatic void decode_ci_cli_insn(input string mnemonic);
    logic [5:0] imm;
    imm = {rvfi_insn[12], rvfi_insn[6:2]};
    data_accessed = RD;
    decoded_str = $sformatf("%s\tx%0d,%0d", mnemonic, rvfi_rd_addr, $signed(imm));
  endfunction

  function automatic void decode_ci_caddi_insn(input string mnemonic);
    logic [5:0] nzimm;
    nzimm = {rvfi_insn[12], rvfi_insn[6:2]};
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,%0d", mnemonic, rvfi_rd_addr, $signed(nzimm));
  endfunction

  function automatic void decode_ci_caddi16sp_insn(input string mnemonic);
    logic [9:0] nzimm;
    nzimm = {rvfi_insn[12], rvfi_insn[4:3], rvfi_insn[5], rvfi_insn[2], rvfi_insn[6], 4'b0};
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,%0d", mnemonic, rvfi_rd_addr, $signed(nzimm));
  endfunction

  function automatic void decode_ci_clui_insn(input string mnemonic);
    logic [5:0] nzimm;
    nzimm = {rvfi_insn[12], rvfi_insn[6:2]};
    data_accessed = RD;
    decoded_str = $sformatf("%s\tx%0d,0x%0x", mnemonic, rvfi_rd_addr, 20'($signed(nzimm)));
  endfunction

  function automatic void decode_ci_cslli_insn(input string mnemonic);
    logic [5:0] shamt;
    shamt = {rvfi_insn[12], rvfi_insn[6:2]};
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,0x%0x", mnemonic, rvfi_rd_addr, shamt);
  endfunction

  function automatic void decode_ciw_insn(input string mnemonic);
    // C.ADDI4SPN
    logic [9:0] nzuimm;
    nzuimm = {rvfi_insn[10:7], rvfi_insn[12:11], rvfi_insn[5], rvfi_insn[6], 2'b00};
    data_accessed = RD;
    decoded_str = $sformatf("%s\tx%0d,x2,%0d", mnemonic, rvfi_rd_addr, nzuimm);
  endfunction

  function automatic void decode_cb_sr_insn(input string mnemonic);
    logic [5:0] shamt;
    shamt = {rvfi_insn[12], rvfi_insn[6:2]};
    data_accessed = RS1 | RD;
    decoded_str = $sformatf("%s\tx%0d,0x%0x", mnemonic, rvfi_rd_addr, shamt);
  endfunction

  function automatic void decode_cb_insn(input string mnemonic);
    logic [7:0] imm;
    logic [31:0] jump_target;
    if (rvfi_insn[15:13] == 3'b110 || rvfi_insn[15:13] == 3'b111) begin
      // C.BNEZ and C.BEQZ
      // We cannot use rvfi_pc_wdata for conditional jumps.
      imm = {rvfi_insn[12], rvfi_insn[6:5], rvfi_insn[2], rvfi_insn[11:10], rvfi_insn[4:3]};
      jump_target = rvfi_pc_rdata + 32'($signed({imm, 1'b0}));
      data_accessed = RS1;
      decoded_str = $sformatf("%s\tx%0d,%0x", mnemonic, rvfi_rs1_addr, jump_target);
    end else if (rvfi_insn[15:13] == 3'b100) begin
      // C.ANDI
      imm = {{2{rvfi_insn[12]}}, rvfi_insn[12], rvfi_insn[6:2]};
      data_accessed = RS1 | RD; // RS1 == RD
      decoded_str = $sformatf("%s\tx%0d,%0d", mnemonic, rvfi_rd_addr, $signed(imm));
    end else begin
      imm = {rvfi_insn[12], rvfi_insn[6:2], 2'b00};
      data_accessed = RS1;
      decoded_str = $sformatf("%s\tx%0d,0x%0x", mnemonic, rvfi_rs1_addr, imm);
    end
  endfunction

  function automatic void decode_cs_insn(input string mnemonic);
    data_accessed = RS1 | RS2 | RD; // RS1 == RD
    decoded_str = $sformatf("%s\tx%0d,x%0d", mnemonic, rvfi_rd_addr, rvfi_rs2_addr);
  endfunction

  function automatic void decode_cj_insn(input string mnemonic);
    if (rvfi_insn[15:13] == 3'b001) begin
      // C.JAL
      data_accessed = RD;
    end
    decoded_str = $sformatf("%s\t%0x", mnemonic, rvfi_pc_wdata);
  endfunction

  function automatic void decode_compressed_load_insn(input string mnemonic);
    logic [7:0] imm;

    if (rvfi_insn[1:0] == OPCODE_C0) begin
      // C.LW
      imm = {1'b0, rvfi_insn[5], rvfi_insn[12:10], rvfi_insn[6], 2'b00};
    end else begin
      // C.LWSP
      imm = {rvfi_insn[3:2], rvfi_insn[12], rvfi_insn[6:4], 2'b00};
    end
    data_accessed = RS1 | RD | MEM;
    decoded_str = $sformatf("%s\tx%0d,%0d(x%0d)", mnemonic, rvfi_rd_addr, imm, rvfi_rs1_addr);
  endfunction

  function automatic void decode_compressed_store_insn(input string mnemonic);
    logic [7:0] imm;
    if (rvfi_insn[1:0] == OPCODE_C0) begin
      // C.SW
      imm = {1'b0, rvfi_insn[5], rvfi_insn[12:10], rvfi_insn[6], 2'b00};
    end else begin
      // C.SWSP
      imm = {rvfi_insn[8:7], rvfi_insn[12:9], 2'b00};
    end
    data_accessed = RS1 | RS2 | MEM;
    decoded_str = $sformatf("%s\tx%0d,%0d(x%0d)", mnemonic, rvfi_rs2_addr, imm, rvfi_rs1_addr);
  endfunction

  function automatic void decode_load_insn();
    string      mnemonic;

    /*
    Gives wrong results in Verilator < 4.020.
    See https://github.com/lowRISC/ibex/issues/372 and
    https://www.veripool.org/issues/1536-Verilator-Misoptimization-in-if-and-case-with-default-statement-inside-a-function

    unique case (rvfi_insn[14:12])
      3'b000: mnemonic = "lb";
      3'b001: mnemonic = "lh";
      3'b010: mnemonic = "lw";
      3'b100: mnemonic = "lbu";
      3'b101: mnemonic = "lhu";
      default: begin
        decode_mnemonic("INVALID");
        return;
      end
    endcase
    */
    logic [2:0] size;
    size = rvfi_insn[14:12];
    if (size == 3'b000) begin
      mnemonic = "lb";
    end else if (size == 3'b001) begin
      mnemonic = "lh";
    end else if (size == 3'b010) begin
      mnemonic = "lw";
    end else if (size == 3'b100) begin
      mnemonic = "lbu";
    end else if (size == 3'b101) begin
      mnemonic = "lhu";
    end else begin
      decode_mnemonic("INVALID");
      return;
    end


    data_accessed = RD | RS1 | MEM;
    decoded_str = $sformatf("%s\tx%0d,%0d(x%0d)", mnemonic, rvfi_rd_addr,
                    $signed({{20 {rvfi_insn[31]}}, rvfi_insn[31:20]}), rvfi_rs1_addr);
  endfunction

  function automatic void decode_store_insn();
    string    mnemonic;

    unique case (rvfi_insn[13:12])
      2'b00:  mnemonic = "sb";
      2'b01:  mnemonic = "sh";
      2'b10:  mnemonic = "sw";
      default: begin
        decode_mnemonic("INVALID");
        return;
      end
    endcase

    if (!rvfi_insn[14]) begin
      // regular store
      data_accessed = RS1 | RS2 | MEM;
      decoded_str = $sformatf("%s\tx%0d,%0d(x%0d)", mnemonic, rvfi_rs2_addr,
                      $signed({ {20 {rvfi_insn[31]}}, rvfi_insn[31:25], rvfi_insn[11:7] }), rvfi_rs1_addr);
    end else begin
      decode_mnemonic("INVALID");
    end
  endfunction


  function automatic void decode_fload_insn();
    string      mnemonic;

    /*
    Gives wrong results in Verilator < 4.020.
    See https://github.com/lowRISC/ibex/issues/372 and
    https://www.veripool.org/issues/1536-Verilator-Misoptimization-in-if-and-case-with-default-statement-inside-a-function

    unique case (rvfi_insn[14:12])
      3'b000: mnemonic = "lb";
      3'b001: mnemonic = "lh";
      3'b010: mnemonic = "lw";
      3'b100: mnemonic = "lbu";
      3'b101: mnemonic = "lhu";
      default: begin
        decode_mnemonic("INVALID");
        return;
      end
    endcase
    */
    logic [2:0] size;
    size = rvfi_insn[14:12];
    if (size == 3'b000) begin
      mnemonic = "lb";
    end else if (size == 3'b001) begin
      mnemonic = "lh";
    end else if (size == 3'b010) begin
      mnemonic = "lw";
    end else if (size == 3'b100) begin
      mnemonic = "lbu";
    end else if (size == 3'b101) begin
      mnemonic = "lhu";
    end else begin
      decode_mnemonic("INVALID");
      return;
    end


    data_accessed = RD | RS1 | MEM;
    decoded_str = $sformatf("%s\tf%0d,%0d(x%0d)", mnemonic, rvfi_rd_addr,
                    $signed({{20 {rvfi_insn[31]}}, rvfi_insn[31:20]}), rvfi_rs1_addr);
  endfunction

  function automatic void decode_fstore_insn();
    string    mnemonic;

    unique case (rvfi_insn[13:12])
      2'b00:  mnemonic = "sb";
      2'b01:  mnemonic = "sh";
      2'b10:  mnemonic = "sw";
      default: begin
        decode_mnemonic("INVALID");
        return;
      end
    endcase

    if (!rvfi_insn[14]) begin
      // regular store
      data_accessed = RS1 | RS2 | MEM;
      decoded_str = $sformatf("%s\tf%0d,%0d(x%0d)", mnemonic, rvfi_rs2_addr,
                      $signed({ {20 {rvfi_insn[31]}}, rvfi_insn[31:25], rvfi_insn[11:7] }), rvfi_rs1_addr);
    end else begin
      decode_mnemonic("INVALID");
    end
  endfunction

  function automatic void decode_compressed_fload_insn(input string mnemonic);
    logic [7:0] imm;

    if (rvfi_insn[1:0] == OPCODE_C0) begin
      // C.LW
      imm = {1'b0, rvfi_insn[5], rvfi_insn[12:10], rvfi_insn[6], 2'b00};
    end else begin
      // C.LWSP
      imm = {rvfi_insn[3:2], rvfi_insn[12], rvfi_insn[6:4], 2'b00};
    end
    data_accessed = RS1 | RD | MEM;
    decoded_str = $sformatf("%s\tf%0d,%0d(x%0d)", mnemonic, rvfi_rd_addr, imm, rvfi_rs1_addr);
  endfunction

  function automatic void decode_compressed_fstore_insn(input string mnemonic);
    logic [7:0] imm;
    if (rvfi_insn[1:0] == OPCODE_C0) begin
      // C.SW
      imm = {1'b0, rvfi_insn[5], rvfi_insn[12:10], rvfi_insn[6], 2'b00};
    end else begin
      // C.SWSP
      imm = {rvfi_insn[8:7], rvfi_insn[12:9], 2'b00};
    end
    data_accessed = RS1 | RS2 | MEM;
    decoded_str = $sformatf("%s\tf%0d,%0d(x%0d)", mnemonic, rvfi_rs2_addr, imm, rvfi_rs1_addr);
  endfunction


  function automatic string get_fence_description(logic [3:0] bits);
    string desc = "";
    if (bits[3]) begin
      desc = {desc, "i"};
    end
    if (bits[2]) begin
      desc = {desc, "o"};
    end
    if (bits[1]) begin
      desc = {desc, "r"};
    end
    if (bits[0]) begin
      desc = {desc, "w"};
    end
    return desc;
  endfunction

  function automatic void decode_fence();
    string predecessor;
    string successor;
    predecessor = get_fence_description(rvfi_insn[27:24]);
    successor = get_fence_description(rvfi_insn[23:20]);
    decoded_str = $sformatf("fence\t%s,%s", predecessor, successor);
  endfunction

  // cycle counter
  always_ff @(negedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      cycle <= 0;
    end else begin
      cycle <= cycle + 1;
    end
  end

  // close output file for writing
  /*final begin
    if (file_handle != 32'h0) begin
      $fclose(file_handle);
    end
    if (file_handle_nb != 32'h0) begin
      $fclose(file_handle_nb);
    end
  end*/
int i=0;

  // ── Trap event logger ──────────────────────────────────────────────
  // Writes one line per trap entry / xret. This file is independent
  // of the main retired-instruction trace and is much smaller, since
  // only trap-related events are logged.
  //
  // Format (for trap entry):
  //   @<cycle> TRAP cause=<cause> epc=<epc> tval=<tval> to_s=<0|1> from_priv=<priv>
  // Format (for xret):
  //   @<cycle> XRET kind=<mret|sret> target=<resume_pc> from_priv=<priv>
  //
  // Subject to the same window control as the main trace.
  always @(posedge clk_i) begin : trap_logger_blk
    static string trap_base;
    if (rst_ni && trace_log_now) begin
      if (file_handle_traps == 32'h0) begin
        trap_base = "trace_core";
        $value$plusargs("tracer_file_base=%s", trap_base);
        $sformat(file_name_traps, "%s_%h_traps.log", trap_base, hart_id_i);
        file_handle_traps = $fopen(file_name_traps, "w");
        $fwrite(file_handle_traps, "// trap-event log: TRAP entries and XRET commits\n");
      end
      if (trap_valid_i) begin
        $fwrite(file_handle_traps,
                "@%0d TRAP cause=%08h epc=%08h tval=%08h to_s=%0d from_priv=%0d\n",
                cycle, trap_cause_i, trap_epc_i, trap_tval_i, trap_to_s_i, priv_i);
        $fflush(file_handle_traps);
      end
      if (xret_fire_i) begin
        $fwrite(file_handle_traps,
                "@%0d XRET kind=%s target=%08h from_priv=%0d\n",
                cycle, xret_is_sret_i ? "sret" : "mret", xret_target_i, priv_i);
        $fflush(file_handle_traps);
      end
    end
  end

  // ── PC-trigger arming (start_pc / stop_pc) ─────────────────────────
  // Update trace_armed based on retired-instruction PC. start_pc arms
  // (latch high until stop_pc); stop_pc disarms. If both are set, the
  // tracer logs every cycle between matching start/stop pairs.
  // Reads rvfi_pc_rdata_t directly (not the local rvfi_pc_rdata, which
  // is only updated inside the main trace block when armed).
  wire [31:0] trace_arm_pc = rvfi_pc_rdata_t[31:0];
  always @(posedge clk_i) begin
    if (rst_ni && rvfi_valid) begin
      if (trace_start_pc != 32'h0 && trace_arm_pc == trace_start_pc)
        trace_armed <= 1'b1;
      if (trace_stop_pc  != 32'h0 && trace_arm_pc == trace_stop_pc)
        trace_armed <= 1'b0;
    end
  end

  // log execution
  ///////////////////////////////////////////////////////////////////////
  always @(posedge clk_i) begin

    //nonblock load trace
    //nb_valid <= rvtop.swerv.dec.dec_nonblock_load_wen;
    //nb_addr  <= rvtop.swerv.dec.dec_nonblock_load_waddr;
    //nb_data  <= rvtop.swerv.dec.lsu_nonblock_load_data;

    //RVFI Trace
  	//for(int i=0; i<2; i++) begin
		if (rvfi_valid && trace_log_now) begin
			rvfi_insn = rvfi_insn_t[31+i*32 -:32]; 
  		rvfi_pc_rdata = rvfi_pc_rdata_t[31+i*32 -:32];
  			
      // TODO: Get rs1_addr and rs2_addr from independent of instruction binary from tb_top.sv   			
  		// rvfi_rs1_addr = rvfi_rs1_addr_t[4+i*5 -:5];
			// rvfi_rs2_addr = rvfi_rs2_addr_t[4+i*5 -:5];
  		rvfi_rs1_addr = rvfi_insn[19:15];
			rvfi_rs2_addr = rvfi_insn[24:20];
      rvfi_rs3_addr = rvfi_insn[31:27];

			rvfi_rs1_rdata = rvfi_rs1_rdata_t[31+i*32 -:32];
			rvfi_rs2_rdata = rvfi_rs2_rdata_t[31+i*32 -:32]; 
      rvfi_rs3_rdata = rvfi_rs3_rdata_t[31+i*32 -:32]; 
			rvfi_rd_addr = rvfi_rd_addr_t[4+i*5 -:5];
			rvfi_rd_wdata = rvfi_rd_wdata_t[31+i*32 -:32];
			rvfi_pc_wdata = rvfi_pc_wdata_t;
			
			decoded_str = "";
			data_accessed = 5'h0;
			insn_is_compressed = 0;

      rs1_float = 0;
      rs2_float = 0;
      rs3_float = 0;
      rd_float = 0;

			// Check for compressed instructions
			if (rvfi_insn[1:0] != 2'b11) begin
			  insn_is_compressed = 1;
			  // Separate case to avoid overlapping decoding
			  if (rvfi_insn[15:13] == 3'b100 && rvfi_insn[1:0] == 2'b10) begin
          rvfi_rs1_addr = rvfi_insn[11:7];
          rvfi_rs2_addr = rvfi_insn[6:2];
          if (rvfi_insn[12]) begin 
            if (rvfi_insn[11:2] == 10'h0) begin
              decode_mnemonic("c.ebreak");
            end else if (rvfi_insn[6:2] == 5'b0) begin
              decode_cr_insn("c.jalr");
            end else begin
              decode_cr_insn("c.add");
            end
          end else begin
            if (rvfi_insn[6:2] == 5'h0) begin
              decode_cr_insn("c.jr");
            end else begin
              decode_cr_insn("c.mv");
            end
          end
			  end else begin
				unique casez (rvfi_insn[15:0])
				  // C0 Opcodes
				  INSN_CADDI4SPN: begin
				    if (rvfi_insn[12:2] == 11'h0) begin
				      // Align with pseudo-mnemonic used by GNU binutils and LLVM's MC layer
				      decode_mnemonic("c.unimp");
				    end else begin
				      decode_ciw_insn("c.addi4spn");
				    end
				  end
				  INSN_CLW: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_compressed_load_insn("c.lw");
          end
          INSN_CSW: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_compressed_store_insn("c.sw");
          end
          // C1 Opcodes
				  INSN_CADDI:      decode_ci_caddi_insn("c.addi");
				  INSN_CJAL:       decode_cj_insn("c.jal");
				  INSN_CJ:         decode_cj_insn("c.j");
				  INSN_CLI:        decode_ci_cli_insn("c.li");
				  INSN_CLUI: begin
				    // These two instructions share opcode
				    if (rvfi_insn[11:7] == 5'd2) begin
				      decode_ci_caddi16sp_insn("c.addi16sp");
				    end else begin
				      decode_ci_clui_insn("c.lui");
				    end
				  end
				  INSN_CSRLI:      decode_cb_sr_insn("c.srli");
				  INSN_CSRAI:      decode_cb_sr_insn("c.srai");
				  INSN_CANDI:      decode_cb_insn("c.andi");
				  INSN_CSUB: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_cs_insn("c.sub");
          end
				  INSN_CXOR: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_cs_insn("c.xor");
          end
          INSN_COR: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_cs_insn("c.or");
          end
          INSN_CAND: begin
            /* verilator lint_off WIDTH */
            rvfi_rs2_addr = 8 + rvfi_insn[4:2];
            /* verilator lint_on WIDTH */
            decode_cs_insn("c.and");
          end
				  INSN_CBEQZ:      decode_cb_insn("c.beqz");
				  INSN_CBNEZ:      decode_cb_insn("c.bnez");
				  // C2 Opcodes
				  INSN_CSLLI:      decode_ci_cslli_insn("c.slli");
				  INSN_CLWSP:      decode_compressed_load_insn("c.lwsp");
				  INSN_SWSP: begin      
            rvfi_rs2_addr = rvfi_insn[6:2];    
            decode_compressed_store_insn("c.swsp");
          end
				  default:         decode_mnemonic("INVALID");
				endcase
			  end
			end else begin  /////////////////////   32-Bit INSTRUCTIONS ////////////////////////

      rvfi_rs1_addr = rvfi_insn[19:15];
			rvfi_rs2_addr = rvfi_insn[24:20];
      rvfi_rs3_addr = rvfi_insn[31:27];

			  unique casez (rvfi_insn)
				// Regular opcodes
				INSN_LUI:        decode_u_insn("lui");
				INSN_AUIPC:      decode_u_insn("auipc");
				INSN_JAL:        decode_j_insn("jal");
				INSN_JALR:       decode_i_jalr_insn("jalr");
				// BRANCH
				INSN_BEQ:        decode_b_insn("beq");
				INSN_BNE:        decode_b_insn("bne");
				INSN_BLT:        decode_b_insn("blt");
				INSN_BGE:        decode_b_insn("bge");
				INSN_BLTU:       decode_b_insn("bltu");
				INSN_BGEU:       decode_b_insn("bgeu");
				// OPIMM
				INSN_ADDI: begin
				  if (rvfi_insn == 32'h00_00_00_13) begin
				    // TODO: objdump doesn't decode this as nop currently, even though it would be helpful
				    // Decide what to do here: diverge from objdump, or make the trace less readable to
				    // users.
				    //decode_mnemonic("nop");
				    decode_i_insn("addi");
				  end else begin
				    decode_i_insn("addi");
				  end
				end
				INSN_SLTI:       decode_i_insn("slti");
				INSN_SLTIU:      decode_i_insn("sltiu");
				INSN_XORI:       decode_i_insn("xori");
				INSN_ORI:        decode_i_insn("ori");
				INSN_ANDI:       decode_i_insn("andi");
				INSN_SLLI:       decode_i_shift_insn("slli");
				INSN_SRLI:       decode_i_shift_insn("srli");
				INSN_SRAI:       decode_i_shift_insn("srai");
				// OP
				INSN_ADD:        decode_r_insn("add");
				INSN_SUB:        decode_r_insn("sub");
				INSN_SLL:        decode_r_insn("sll");
				INSN_SLT:        decode_r_insn("slt");
				INSN_SLTU:       decode_r_insn("sltu");
				INSN_XOR:        decode_r_insn("xor");
				INSN_SRL:        decode_r_insn("srl");
				INSN_SRA:        decode_r_insn("sra");
				INSN_OR:         decode_r_insn("or");
				INSN_AND:        decode_r_insn("and");
				// SYSTEM (CSR manipulation)
				INSN_CSRRW:      decode_csr_insn("csrrw");
				INSN_CSRRS:      decode_csr_insn("csrrs");
				INSN_CSRRC:      decode_csr_insn("csrrc");
				INSN_CSRRWI:     decode_csr_insn("csrrwi");
				INSN_CSRRSI:     decode_csr_insn("csrrsi");
				INSN_CSRRCI:     decode_csr_insn("csrrci");
				// SYSTEM (others)
				INSN_ECALL:      decode_mnemonic("ecall");
				INSN_EBREAK:     decode_mnemonic("ebreak");
				INSN_MRET:       decode_mnemonic("mret");
				INSN_DRET:       decode_mnemonic("dret");
				INSN_WFI:        decode_mnemonic("wfi");
				// RV32M
				INSN_PMUL:       decode_r_insn("mul");
				INSN_PMUH:       decode_r_insn("mulh");
				INSN_PMULHSU:    decode_r_insn("mulhsu");
				INSN_PMULHU:     decode_r_insn("mulhu");
				INSN_DIV:        decode_r_insn("div");
				INSN_DIVU:       decode_r_insn("divu");
				INSN_REM:        decode_r_insn("rem");
				INSN_REMU:       decode_r_insn("remu");
				// LOAD & STORE
				INSN_LOAD:       decode_load_insn();
				INSN_STORE:      decode_store_insn();
				// MISC-MEM
				INSN_FENCE:      decode_fence();
				INSN_FENCEI:     decode_mnemonic("fence.i");

		
				// RV32B
        INSN_SHA1ADD:    decode_r_insn("sha1add");
        INSN_SHA2ADD:    decode_r_insn("sha2add");
        INSN_SHA3ADD:    decode_r_insn("sha3add");
				INSN_RORI:       decode_i_shift_insn("rori");
				INSN_ROL:        decode_r_insn("rol");
				INSN_ROR:        decode_r_insn("ror");
				INSN_MIN:        decode_r_insn("min");
				INSN_MAX:        decode_r_insn("max");
				INSN_MINU:       decode_r_insn("minu");
				INSN_MAXU:       decode_r_insn("maxu");
				INSN_XNOR:       decode_r_insn("xnor");
				INSN_ORN:        decode_r_insn("orn");
				INSN_ANDN:       decode_r_insn("andn");
				INSN_ORCB:       decode_r_insn("orcb");
				INSN_CLZ:        decode_r1_insn("clz");
				INSN_CTZ:        decode_r1_insn("ctz");
				INSN_PCNT:       decode_r1_insn("pcnt");
				INSN_REV8:       decode_r1_insn("rev8");
        INSN_ZEXTH:      decode_r1_insn("zexth");
				INSN_SEXTB:      decode_r1_insn("sextb");
				INSN_SEXTH:      decode_r1_insn("sexth");

        //F
        INSN_CFLW: begin
          rvfi_rs2_addr = 8 + rvfi_insn[4:2];
          decode_compressed_fload_insn("c.flw");
          rd_float = 1;
          end
        INSN_CFSW: begin
          rvfi_rs2_addr = 8 + rvfi_insn[4:2];
          decode_compressed_fstore_insn("c.fsw");
          rs2_float = 1;
        end
        INSN_CFLWSP: begin
          decode_compressed_fload_insn("s.flwsp");
          rd_float = 1;
        end
        INSN_FSWSP: begin      
          rvfi_rs2_addr = rvfi_insn[6:2];    
          decode_compressed_fstore_insn("c.fswsp");
          rs2_float = 1;
        end
        INSN_FLW:begin
               decode_fload_insn();
              rd_float = 1;
        end
        INSN_FSW:  begin
             decode_fstore_insn();
            rs2_float = 1;
        end
        INSN_FMADDS:   begin
            data_accessed = RS1 | RS2 | RS3 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d,f%0d", "fmadd.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr,rvfi_rs3_addr);
            rs1_float = 1;
      rs2_float = 1;
      rs3_float = 1;
      rd_float = 1;
        end  
        INSN_FMSUBS:   begin
            data_accessed = RS1 | RS2 | RS3 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d,f%0d", "fmsub.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr,rvfi_rs3_addr);
             rs1_float = 1;
      rs2_float = 1;
      rs3_float = 1;
      rd_float = 1;
        end  
        INSN_FNMSUBS:   begin
            data_accessed = RS1 | RS2 | RS3 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d,f%0d", "fnmsub.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr,rvfi_rs3_addr);
             rs1_float = 1;
      rs2_float = 1;
      rs3_float = 1;
      rd_float = 1;
        end 
        INSN_FNMADDS:   begin
            data_accessed = RS1 | RS2 | RS3 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d,f%0d", "fnmadd.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr,rvfi_rs3_addr);
             rs1_float = 1;
      rs2_float = 1;
      rs3_float = 1;
      rd_float = 1;
        end 
        INSN_FADDS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fadd.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end
        INSN_FSUBS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fsub.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end   
        INSN_FMULS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fmul.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end   
        INSN_FDIVS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fdiv.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end      
        INSN_FSQRTS:begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d", "fsqrt.s", rvfi_rd_addr, rvfi_rs1_addr);
             rs1_float = 1;
      rd_float = 1;
        end
        INSN_FSGNJS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fsgnj.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end     
        INSN_FSGNJNS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fsgnjn.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end    
        INSN_FSGNJXS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fsgnjx.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end    
        INSN_FMINS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fmin.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end      
        INSN_FMAXS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tf%0d,f%0d,f%0d", "fmax.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
      rd_float = 1;
        end      
        INSN_FCVTWS:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d", "fcvt.w.s", rvfi_rd_addr, rvfi_rs1_addr);
             rs1_float = 1;
        end  
        INSN_FCVTWUS:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d", "fcvt.wu.s", rvfi_rd_addr, rvfi_rs1_addr);
             rs1_float = 1;
        end   
        INSN_FMVXW:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d", "fmv.x.w", rvfi_rd_addr, rvfi_rs1_addr);
             rs1_float = 1;
        end     
        INSN_FCLASSS:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d", "fclass.s", rvfi_rd_addr, rvfi_rs1_addr);
             rs1_float = 1;
        end   
        INSN_FEQS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d,f%0d", "feq.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
             rs1_float = 1;
      rs2_float = 1;
        end          
        INSN_FLTS:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d,f%0d", "flt.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
              rs1_float = 1;
      rs2_float = 1;
        end          
        INSN_FLES:   begin
            data_accessed = RS1 | RS2 | RD;
            decoded_str = $sformatf("%s\tx%0d,f%0d,f%0d", "fle.s", rvfi_rd_addr, rvfi_rs1_addr,rvfi_rs2_addr);
            rs1_float = 1;
      rs2_float = 1;
        end          
        INSN_FCVTSW:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tf%0d,x%0d", "fcvt.s.w", rvfi_rd_addr, rvfi_rs1_addr);
      rd_float = 1;
        end       
        INSN_FCVTSWU:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tf%0d,x%0d", "fcvt.s.wu", rvfi_rd_addr, rvfi_rs1_addr);
             rd_float = 1;
        end      
        INSN_FMVWX:  begin
            data_accessed = RS1 | RD;
            decoded_str = $sformatf("%s\tf%0d,x%0d", "fmv.w.x", rvfi_rd_addr, rvfi_rs1_addr);
             rd_float = 1;
        end        
		
				default:         decode_mnemonic("INVALID");
			  endcase
			end
			printbuffer_dumpline();		
		 end
	//end	
  //print_nb_dump();
		    i =0;
  end	

endmodule
