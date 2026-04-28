import common_pkg::*;
import debug_pkg::*;
import core_pkg::*;

module core_top
(
	input logic	clk_i,
	input logic	reset_i,

	//instruction port
	mem_bus.master imem_port,
	//data port
	mem_bus.master dmem_port,

	output onebit_sig_e resumeack_o,
	output onebit_sig_e running_o,
	output onebit_sig_e halted_o,

	input onebit_sig_e haltreq_i,
	input onebit_sig_e resumereq_i,

	input onebit_sig_e ar_en_i,
	input onebit_sig_e ar_wr_i,
	input [15:0] ar_ad_i,
	output onebit_sig_e ar_done_o,
	input [31:0] ar_di_i,
	output logic [31:0] ar_do_o,

	input onebit_sig_e am_en_i,
	input onebit_sig_e am_wr_i,
	input [3:0] am_st_i,
	input [31:0] am_ad_i,
	input [31:0] am_di_i,
	output [31:0] am_do_o,
	output onebit_sig_e am_done_o,


  input ext_itr_i,
  input timer_itr_i,
  input soft_itr_i,
  input [63:0] mtime_i,       // CLINT mtime for TIME/TIMEH CSRs


  // Cache control
  output logic fence_i_o              // FENCE.I executed — flush I-cache (and D-cache for coherency)
);


//reset
// NOP control bundle — CTRL_BUS_NOP() defined in core_pkg.sv

//pc and fetch
logic [31:0] branch_target_address;
logic [31:0] imem_forwarded_data;
logic [31:0] opA_forwarded_data;
logic [31:0] opB_forwarded_data;
logic [31:0] opC_forwarded_data;
logic [31:0] write_back_data;

pc_sel_e pc_sel;
logic [31:0] pc_in;
logic [31:0] pc_out;
logic [31:0] pc_id;
logic [31:0] pc_ie;
logic [31:0] pc_imem;
logic [31:0] pc_iwb;

logic [31:0] imm_id;
logic [31:0] imm_ie;
logic [31:0] imm_imem;
logic [31:0] imm_iwb;

onebit_sig_e branch_taken;
onebit_sig_e bpu_mispredict;       // BPU: prediction != resolution
logic [31:0] predicted_pc_id;      // BPU: fall-through PC at ID stage
logic [31:0] predicted_target_id;  // BPU: predicted branch target at ID (meaningful when predicted_taken=TRUE)
logic [31:0] predicted_target_ie;  // flopped through ID->IE for target-mismatch check
logic [31:0] predicted_pc_ie;      // BPU: fall-through PC flopped into IE
onebit_sig_e interrupt_valid;
onebit_sig_e debug_valid;
ctrl_bus_e ctrl_bus_if_id;
ctrl_bus_e ctrl_bus_if_id_raw;  // BPU Step 2: decoder output before predicted_taken override
ctrl_bus_e ctrl_bus_ie;
ctrl_bus_e ctrl_bus_imem;
ctrl_bus_e ctrl_bus_iwb;

logic [31:0] rs1_int;
logic [31:0] rs1_float;
logic [31:0] rs1_id;
logic [31:0] rs1_forwarded_id;
logic [31:0] rs1_forwarded_ie;

logic [31:0] rs2_int;
logic [31:0] rs2_float;
logic [31:0] rs2_id;
logic [31:0] rs2_forwarded_id;
logic [31:0] rs2_forwarded_ie;

logic [31:0] rs3_float;
logic [31:0] rs3_id;
logic [31:0] rs3_forwarded_id;
logic [31:0] rs3_forwarded_ie;

forward_sel_e forwarda_id;
forward_sel_e forwardb_id;
forward_sel_e forwardc_id;
forward_sel_e forwarda_ie;
forward_sel_e forwardb_ie;
forward_sel_e forwardc_ie;
logic [31:0] alu_operand_a;
logic [31:0] alu_operand_b;
logic [31:0] alu_operand_c;
logic [31:0] alu_result;
logic [31:0] csr_result;
float_status_e float_status;
roundmode_e frm;
onebit_sig_e alu_stall;
logic        misalign_stall;

logic [31:0] exec_result_ie;
logic [31:0] exec_result_imem;
logic [31:0] exec_result_iwb;

logic [31:0] readdata_imem;
logic [31:0] readdata_iwb;

onebit_sig_e if_id_stall;
onebit_sig_e ie_stall;
onebit_sig_e imem_stall;
onebit_sig_e iwb_stall;

onebit_sig_e ie_flush;
onebit_sig_e imem_flush;
onebit_sig_e iwb_flush;

onebit_sig_e insert_bubble;
logic [31:0] instruction_pipe;
logic [31:0] ins_addr_pipe;
onebit_sig_e c_stall;
onebit_sig_e c_valid;
onebit_sig_e c_valid_ie;

logic trap_true;
logic async_trap;   // async interrupt only (for CSR write suppression)
logic [31:0]ip_csr;
logic [31:0]ie_csr;
logic [31:0]vec_csr;
logic [31:0]mtvec_csr;       // Phase 4 trap revamp: unmuxed mtvec for wb_trap_unit
logic [31:0]stvec_csr;       // Phase 4 trap revamp: unmuxed stvec for wb_trap_unit
// Phase 4 trap revamp: pure level-signal interrupt status from interrupt_ctrl
logic        interrupt_pending;
logic [4:0]  interrupt_cause;
logic        interrupt_to_s_lvl;
// Phase 4 trap revamp: wb_trap_unit outputs (parallel/observe-only in Phase 4.2,
// drive the redirect_arbiter/csr_unit in Phase 4.3 onward).
logic            wb_trap_fire;
logic            wb_xret_fire;
logic            wb_dret_fire;
// OR of all WB-commit events. Used by hazard_unit to flush IF/ID/IE/IMEM
// (the carrier in IWB commits its CSR side effects on the same cycle).
//
// Phase 4.15: drop wb_trap_fire from this OR. wb_trap_unit is still
// observe-only for traps (kill_iwb_o is NOT wired); the trap actually
// commits via the legacy interrupt_ctrl path which expects IWB to retire
// normally. Including wb_trap_fire here forced iwb_flush=TRUE on async
// traps → the IMEM→IWB register-wall transition NOP'd → the IMEM-stage
// instruction's writeback was lost. Smoking gun (Linux boot, 2026-04-28):
// timer trap fired with c.addi16sp sp,64 at IMEM in vsnprintf string()
// epilogue; iwb_flush killed sp+=64; on sret kernel resumed with sp
// pointing 64 bytes below vsnprintf's frame; c.lwsp ra,92(sp) loaded
// garbage (ffff0a00); c.jr ra jumped to ffff0a00 → Oops.
//
// xret/dret stay in this OR — they DO commit at IWB and need the flush
// to kill the wrong-path-1 that would otherwise propagate from IMEM.
wire             wb_event_fire = wb_xret_fire | wb_dret_fire;
logic [4:0]      wb_cause;
logic [31:0]     wb_tval;
logic [31:0]     wb_epc;
logic            wb_trap_to_s;
logic            wb_is_async;
logic            wb_redirect_valid;
logic [31:0]     wb_redirect_target;
redirect_kind_e  wb_redirect_kind;
logic            wb_kill_iwb;
logic [31:0]status_csr;
logic [31:0]handler_addr;
logic [31:0]ecause_csr;
logic [31:0]epc_csr;
logic [31:0]mtval_csr;
logic [31:0]interrupt_src;
logic [31:0]epc;
logic [31:0]sepc;
logic [1:0] priv_level;
logic [31:0]medeleg;
logic [31:0]mideleg;
logic       trap_to_s;
logic [31:0]satp_csr;
logic       menvcfg_adue;
logic [31:0] pmpcfg_csr  [4];
logic [31:0] pmpaddr_csr [16];

// MMU signals
logic [31:0] i_paddr, d_paddr;
logic        mmu_i_stall, mmu_d_stall;
logic        mmu_i_fault, mmu_d_fault;
logic [31:0] mmu_i_fault_addr, mmu_d_fault_addr;
logic        mmu_i_access_fault, mmu_d_access_fault;
logic [31:0] mmu_i_access_fault_addr, mmu_d_access_fault_addr;
// Phase 4.8: PTW-completion-only versions of i-side faults (see big
// comment near `inflight_i_fault_q`). Used to keep the legacy
// direct-to-trap_sequencer path firing for PTW-completion faults
// (which have no live imem.req cycle to ride the buffer) while the
// comb portion takes the fetch_buffer route.
logic        mmu_i_fault_ptw,        mmu_i_access_fault_ptw;
logic [31:0] mmu_i_fault_ptw_addr,   mmu_i_access_fault_ptw_addr;
logic [31:0] ptw_addr;
logic        ptw_req, ptw_active;
logic        ptw_we;
logic [31:0] ptw_wdata;
logic        d_store_for_mmu;

// Track whether PTW had a read request on the bus last cycle.
// rvalid from the RAM is pulsed 1 cycle after the read request — so we must
// only accept rvalid when it corresponds to the PTW's OWN request, not a
// stale rvalid left over from a prior core load/AMO that happened right
// before the PTW took over the dbus.
logic ptw_req_prev;
always_ff @(posedge clk_i or posedge reset_i)
    if (reset_i) ptw_req_prev <= 1'b0;
    else         ptw_req_prev <= ptw_req;
wire ptw_rvalid = dmem_port.rvalid & ptw_req_prev;

// Registered instruction page fault — breaks the combinational loop:
//   i_fault_o → trap_valid → interrupt_valid → mmu_priv → i_translate → i_fault_o
// ── Trap Sequencer ──────────────────────────────────────────────
// Centralized fault registration with proper clearing policies:
// - i_fault_r: clears on trap + branch/ret + SRET ITLB stall (FSM)
// - d_fault_r, i_access_fault_r, d_access_fault_r: clear on trap ONLY
logic        mmu_i_fault_r,      mmu_d_fault_r;
logic        mmu_d_fault_is_store_r;  // Bug 30: registered is-store flag
logic [31:0] mmu_i_fault_addr_r, mmu_d_fault_addr_r;
logic        mmu_i_access_fault_r,      mmu_d_access_fault_r;
logic [31:0] mmu_i_access_fault_addr_r, mmu_d_access_fault_addr_r;

// ── Phase 4.8: buffer-routed instruction-side faults ──
// Forward references to aligner_valid / aligner_fault / aligner_cause /
// aligner_pc_id (declared with the fetch_buffer block much later in the
// file) and branch_taken_valid / ret_valid_valid / debug_valid (declared
// with the pc_sel mux). SystemVerilog allows forward refs inside one
// module scope; the existing hazard_unit instantiation does the same.
//
// The fault rides through the fetch_buffer on the same entry as its
// rdata. It only fires here when the entry has reached the aligner head
// AND no older in-flight redirect (branch / xRET / debug-resume) is
// firing this cycle. The "older redirect wins" gate prevents the
// wrong-path PMP/page-fault bug for unconditional jumps (e.g. `j` at
// PC X with PC+4 in a no-perm region or on an A-bit-clear page; the
// speculative fetch's fault would otherwise fire as a trap before the
// jump can commit). See the big comment near `inflight_i_fault_q`.
// Suppress buffer-routed faults during xret pipeline transit:
// - xret_at_decode: the aligner emitted mret/sret THIS cycle. The
//   wrong-path entry behind it is now the buffer head — suppress its
//   fault immediately (1-cycle-before-DRAIN gap fix).
// - xret_draining: mret is in IE/IMEM/IWB, pipeline draining.
// Without these, a speculative PMP fault fires at M-mode priv before
// the mret commits → MPP=M → handler uses wrong save area base.
wire i_buf_fault_squash = branch_taken_valid | ret_valid_valid | debug_valid |
                          xret_at_decode | xret_draining;
wire i_buf_access_fault =
    aligner_valid && aligner_fault && (aligner_cause == 5'd1)  && !i_buf_fault_squash;
wire i_buf_page_fault =
    aligner_valid && aligner_fault && (aligner_cause == 5'd12) && !i_buf_fault_squash;

// privilege_unit forward declaration so trap_sequencer can read it
// (privilege_unit_inst is instantiated later in the file)
//
// Phase 4.6: trap_sequencer's xRET-related inputs (ret_valid_i, sret_i,
// ret_side_effects_done_i) are tied off — xRET commit moved to wb_trap_unit
// at IWB. trap_sequencer's surviving job is to register MMU faults so the
// legacy interrupt_ctrl path can read them stably.

trap_sequencer trap_seq_inst (
    .clk_i              (clk_i),
    .reset_i            (reset_i),
    // Pipeline events
    .interrupt_valid_i        (interrupt_valid),
    .ret_valid_i              (1'b0),                  // Phase 4.6: xRET at IWB
    .sret_i                   (1'b0),                  // Phase 4.6: xRET at IWB
    .ret_side_effects_done_i  (1'b0),                  // Phase 4.6: xRET at IWB
    .branch_taken_i           (branch_taken_valid),
    .if_id_stall_i            (if_id_stall),
    .mmu_i_stall_i            (mmu_i_stall),
    // Raw faults from MMU
    // Phase 4.8: i-side page fault has TWO sources after the wrong-path
    // bug fix (mirrors the access-fault path):
    //   (a) i_buf_page_fault — comb portion (formerly term1,
    //       `itlb_hit && !i_perm_ok`) routed through the fetch_buffer.
    //   (b) mmu_i_fault_ptw — PTW-completion portion (term2, fired
    //       when a PTW walk for instruction translation hits an
    //       invalid PTE). Goes through the legacy direct path.
    .mmu_i_fault_i              (i_buf_page_fault | mmu_i_fault_ptw),
    .mmu_i_fault_addr_i         (mmu_i_fault_ptw ? mmu_i_fault_ptw_addr
                                                 : aligner_pc_id),
    .mmu_d_fault_i              (mmu_d_fault),
    .mmu_d_fault_addr_i         (mmu_d_fault_addr),
    .mmu_d_fault_is_store_i     (d_store_for_mmu),  // Bug 30: latch is-store
    // Phase 4.8: i-side PMP access fault has TWO sources after the
    // wrong-path bug fix:
    //   (a) i_buf_access_fault — the comb portion of mmu_i_access_fault_o
    //       (formerly term1, `i_req_i && i_pmp_fault`) routed through
    //       the fetch_buffer / aligner so it fires from the same
    //       pipeline slot as the in-flight branch ahead of it.
    //   (b) mmu_i_access_fault_ptw — the PTW-completion portion
    //       (formerly term2, `ptw_state == PTW_FAULT && ptw_for_insn
    //       && ptw_pmp_fault_r`) which has no live imem.req cycle to
    //       ride the buffer and must keep firing through the legacy
    //       direct path. This path is what makes pmp_check_on_pte_*
    //       complete instead of hanging.
    // The address mux prefers the PTW source when both fire on the
    // same cycle (rare; only happens if a stale comb fault from a
    // wrong-path req coincides with a PTW completion).
    .mmu_i_access_fault_i       (i_buf_access_fault | mmu_i_access_fault_ptw),
    .mmu_i_access_fault_addr_i  (mmu_i_access_fault_ptw ? mmu_i_access_fault_ptw_addr
                                                        : aligner_pc_id),
    .mmu_d_access_fault_i       (mmu_d_access_fault),
    .mmu_d_access_fault_addr_i  (mmu_d_access_fault_addr),
    // Registered faults (to interrupt_ctrl)
    .i_fault_r_o                (mmu_i_fault_r),
    .i_fault_addr_r_o           (mmu_i_fault_addr_r),
    .d_fault_r_o                (mmu_d_fault_r),
    .d_fault_addr_r_o           (mmu_d_fault_addr_r),
    .d_fault_is_store_r_o       (mmu_d_fault_is_store_r),
    .i_access_fault_r_o         (mmu_i_access_fault_r),
    .i_access_fault_addr_r_o    (mmu_i_access_fault_addr_r),
    .d_access_fault_r_o         (mmu_d_access_fault_r),
    .d_access_fault_addr_r_o    (mmu_d_access_fault_addr_r)
);

// insn_valid_id, post_trap, stale_id — now driven by hazard_unit
logic insn_valid_id;
logic stale_id, stale_ie, stale_imem, stale_iwb;
logic post_trap;

// AMO unit signals
logic [31:0] amo_dbus_addr;
logic [3:0]  amo_dbus_byteenable;
logic        amo_dbus_read;
logic        amo_dbus_write;
logic [31:0] amo_dbus_writedata;
logic [31:0] amo_result;
onebit_sig_e amo_stall;
logic        amo_active;
logic        amo_in_progress;

// core2avl intermediate signals (muxed with AMO unit)
logic [31:0] c2a_address;
logic [3:0]  c2a_byteenable;
onebit_sig_e c2a_read;
onebit_sig_e c2a_write;
logic [31:0] c2a_writedata;

// Misaligned access detection (IE stage)
// misalign detection moved into interrupt_ctrl
logic exception_from_ie;
// ── Debug Controller ────────────────────────────────────────────────────
logic [31:0] dpc;
logic        dcsr_ebreak, dcsr_stopcount, dcsr_step;
logic        dbg_rf_override, dbg_mem_override;
onebit_sig_e c_busy;
logic [31:0] next_instruction_addr;

debug_ctrl debug_ctrl_inst (
    .clk_i            (clk_i),
    .reset_i          (reset_i),
    // External debug interface
    .haltreq_i        (haltreq_i),
    .resumereq_i      (resumereq_i),
    .ar_en_i          (ar_en_i),
    .ar_wr_i          (ar_wr_i),
    .ar_ad_i          (ar_ad_i),
    .ar_di_i          (ar_di_i),
    .am_en_i          (am_en_i),
    .dmem_ready_i     (dmem_port.ready),
    // Pipeline state
    .id_ebreak_i      (ctrl_bus_if_id.ebreak),
    .c_busy_i         (c_busy),
    .pc_id_i          (pc_id),
    .next_insn_addr_i (next_instruction_addr),
    // Read data sources
    .csr_result_i     (csr_result),
    .rs1_int_i        (rs1_int),
    .rs1_float_i      (rs1_float),
    .readdata_imem_i  (readdata_imem),
    // Core status
    .resumeack_o      (resumeack_o),
    .running_o        (running_o),
    .halted_o         (halted_o),
    // Debug CSR bits
    .dpc_o            (dpc),
    .dcsr_ebreak_o    (dcsr_ebreak),
    .dcsr_stopcount_o (dcsr_stopcount),
    .dcsr_step_o      (dcsr_step),
    // Abstract register/memory
    .ar_do_o          (ar_do_o),
    .ar_done_o        (ar_done_o),
    .am_do_o          (am_do_o),
    .am_done_o        (am_done_o),
    // Override signals
    .dbg_rf_override_o (dbg_rf_override),
    .dbg_mem_override_o(dbg_mem_override)
);

// ── Hazard Unit ─────────────────────────────────────────────────────────
// Centralised stall / flush / post-trap logic (was inline).
logic refetch_after_trap;

hazard_unit hazard_unit_inst (
    .clk_i              (clk_i),
    .reset_i            (reset_i),
    // External stall sources
    .alu_stall_i        (alu_stall),
    .amo_stall_i        (amo_stall),
    .misalign_stall_i   (misalign_stall),
    .icache_stall_i     (1'b0),          // transparent cache: no stall
    .mmu_i_stall_i      (mmu_i_stall),
    .mmu_d_stall_i      (mmu_d_stall),
    .pmp_d_fault_i      (mmu_d_access_fault),  // stall IE 1 cycle for registered trap
    .d_page_fault_i     (mmu_d_fault),         // stall IE 1 cycle for registered trap
    .dmem_req_i         (dmem_port.req),
    .dmem_ready_i       (dmem_port.ready),
    .insert_bubble_i    (insert_bubble),
    // Control flow
    .interrupt_valid_i  (interrupt_valid),
    .resumeack_i        (resumeack_o),
    // Phase 4 trap revamp: WB-stage event commit (xRET in 4.3, traps
    // and interrupts in 4.4/4.5).
    .wb_event_fire_i    (wb_event_fire),
    // Phase 3: aligner-not-ready stall + redirect for branch_squash_q.
    // aligner_valid and arb_redirect_valid are declared later in the
    // file (the fetch_buffer + redirect_arbiter blocks); SystemVerilog
    // forward references inside a single module scope are legal.
    .aligner_valid_i    (aligner_valid),
    .redirect_valid_i   (arb_redirect_valid),
    .redirect_kind_i    (arb_redirect_kind),
    .exception_from_ie_i(exception_from_ie),
    // Processor state
    .halted_i           (halted_o),
    // Stall outputs
    .if_id_stall_o      (if_id_stall),
    .ie_stall_o         (ie_stall),
    .imem_stall_o       (imem_stall),
    .iwb_stall_o        (iwb_stall),
    // Flush outputs
    .ie_flush_o         (ie_flush),
    .imem_flush_o       (imem_flush),
    .iwb_flush_o        (iwb_flush),
    // Post-trap / stale
    .post_trap_o        (post_trap),
    .stale_id_o         (stale_id),
    // Instruction validity
    .insn_valid_id_o    (insn_valid_id),
    // Fetch control
    .refetch_after_trap_o(refetch_after_trap)
);

assign interrupt_valid = onebit_sig_e'(trap_true);
assign debug_valid =  onebit_sig_e'(resumeack_o);

// ── Privilege Unit ──────────────────────────────────────────────────────
// Centralised privilege checks, xRET fire/one-shot, mmu_priv, PLIC protocol.
wire illegal_mret, illegal_sret, illegal_insn_id;
wire csr_invalid;  // unimplemented CSR accessed in IE stage

// Phase 4.6: privilege_unit reduced to illegal-instruction detection only.
// xRET commit moved to wb_trap_unit (Phase 4.3); mmu_priv override removed
// (priv_level updates at the cycle the xRET commits in IWB, so the
// next-fetch path uses the right priv naturally — no override needed).
privilege_unit privilege_unit_inst (
    // Current privilege state
    .priv_level_i       (priv_level),
    .status_csr_i       (status_csr),
    // Decoded instruction (ID stage)
    .id_mret_i          (ctrl_bus_if_id.mret),
    .id_sret_i          (ctrl_bus_if_id.sret),
    .id_sfence_vma_i    (ctrl_bus_if_id.sfence_vma),
    .id_csr_op_i        (ctrl_bus_if_id.csr_op),
    .id_csr_addr_i      (ctrl_bus_if_id.csr_addr),
    // Illegal instruction outputs
    .illegal_mret_o     (illegal_mret),
    .illegal_sret_o     (illegal_sret),
    .illegal_insn_id_o  (illegal_insn_id)
);

// ── xret_fetch_ctrl FSM ─────────────────────────────────────────────────
// Sequences the post-xRET (mret/sret) instruction fetch when the target
// is in a lower privilege mode that uses Sv32 translation.
//
// Problem: on the wb_xret_fire cycle, priv_level hasn't clocked yet.
// The fetch issues at M-mode priv → no Sv32 → PA=VA (wrong). Any
// combinational override of mmu_priv creates races with the ITLB stall,
// PTW abort, and fault paths.
//
// Solution: a 3-state FSM that sequences the fetch cleanly:
//   IDLE         — normal operation
//   XRET_WAIT    — entered on wb_xret_fire; suppress fetch for 1 cycle
//                   so priv_level can clock to the target value
//   XRET_FETCH   — drive i_vaddr from the saved target VA; the MMU now
//                   sees the correct priv and can start a PTW if the
//                   ITLB misses; when fb_push accepts the target word
//                   (or a trap fires), return to IDLE
//
// The FSM controls:
//   xret_hold_pc   — stall program_counter (hold pc_out at target)
//   xret_drive_va  — override i_vaddr to use xret_target_q
//   xret_suppress  — suppress imem_port.req (in XRET_WAIT only)
//   xret_drop_push — drop the stale rvalid from the wrong-priv fetch
typedef enum logic [2:0] {
    XRET_IDLE    = 3'd0,
    XRET_DRAIN   = 3'd1,
    XRET_WAIT    = 3'd2,
    XRET_FETCH   = 3'd3,
    XRET_ADVANCE = 3'd4
} xret_fsm_e;

// The FSM has 5 states:
//
//   IDLE       — normal operation
//
//   XRET_DRAIN — entered the cycle AFTER the aligner emits an mret/sret.
//                The mret is now in IE; all buffer entries behind it are
//                wrong-path (fetched speculatively at the old privilege).
//                Actions: flush the buffer, suppress fetches, suppress
//                buffer-routed faults, NOP the IE register wall.
//                Stay here until the mret commits at IWB (wb_xret_fire).
//
//   XRET_WAIT  — entered on wb_xret_fire. The priv CSR update clocks at
//                the edge. Suppress fetch for 1 cycle so priv settles.
//
//   XRET_FETCH — priv has settled. Drive i_vaddr from xret_target_q.
//                The MMU sees the correct priv and translates correctly.
//                Wait for fb_push (target word accepted) then → IDLE.
//
xret_fsm_e xret_state, xret_next;
logic [31:0] xret_target_q;

// Detect mret/sret at aligner output (decode time, forward ref to ctrl_bus_if_id)
wire xret_at_decode = aligner_valid && !ie_stall &&
                      (ctrl_bus_if_id.mret == TRUE || ctrl_bus_if_id.sret == TRUE);

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        xret_state    <= XRET_IDLE;
        xret_target_q <= 32'b0;
    end else begin
        xret_state <= xret_next;
        if (wb_xret_fire)
            xret_target_q <= pc_in;  // pc_in = epc/sepc on xret cycle
    end
end

always_comb begin
    xret_next = xret_state;
    case (xret_state)
        XRET_IDLE:
            // Enter DRAIN the cycle after the aligner emits mret/sret.
            // The mret enters IE at the current edge; next cycle the
            // buffer head is the first wrong-path instruction.
            if (xret_at_decode)
                xret_next = XRET_DRAIN;
        XRET_DRAIN:
            // Wait for the mret to propagate IE → IMEM → IWB.
            // wb_xret_fire signals it has committed.
            if (wb_xret_fire)
                xret_next = XRET_WAIT;
        XRET_WAIT:
            // 1 cycle: priv has now settled at the clock edge.
            xret_next = XRET_FETCH;
        XRET_FETCH:
            // Stay here until the fetch completes or a trap takes over.
            if (fb_push || interrupt_valid)
                xret_next = XRET_ADVANCE;
        XRET_ADVANCE:
            // 1 cycle: xret_hold_pc is released, pc_out advances to
            // target+4. Suppress the normal fetch path so it doesn't
            // re-fetch at the old pc_out=target before the advance
            // propagates through program_counter.
            xret_next = XRET_IDLE;
        default:
            xret_next = XRET_IDLE;
    endcase
    // A trap/interrupt at any point aborts the sequence — the trap
    // handler takes over the fetch path.
    if (xret_state != XRET_IDLE && interrupt_valid)
        xret_next = XRET_IDLE;
end

// DRAIN: flush buffer, suppress faults, NOP IE captures, hold PC
// WAIT:  suppress fetch (priv settling), drop wrong-priv rvalid
// FETCH: drive target VA, wait for fb_push
wire xret_draining = (xret_state == XRET_DRAIN);
wire xret_fetching = (xret_state == XRET_FETCH);
wire xret_hold_pc  = xret_draining || (xret_state == XRET_WAIT) || xret_fetching;
wire xret_drive_va = (xret_state == XRET_FETCH);
// Phase 4.10b: XRET_ADVANCE was originally added to suppress a re-fetch
// of pc_out=target during the cycle pc_out advances to target+4 (Linux
// JAL bug at 0x80400002). With DEPTH=4 wider gate, however, suppressing
// imem.req in XRET_ADVANCE drops the legit fetch for target+4, causing
// the next instruction after every xret target to be silently skipped
// (cebreak-01 sw sp, 4(ra) at xret_target+4 never retires; OpenSBI
// breaks similarly on every M-mode mret).
//
// Fix: keep xret_drop_push (catches the duplicate-target rvalid that
// motivated Phase 4.10b) but remove xret_advance from xret_suppress so
// the producer can issue the legit target+4 fetch in this cycle.
// The fb_push_dup vaddr-dedup downstream is a second line of defense
// against any duplicate-target push that sneaks through.
wire xret_advance = (xret_state == XRET_ADVANCE);
wire xret_suppress = xret_draining || (xret_state == XRET_WAIT);
wire xret_drop_push= xret_draining || (xret_state == XRET_WAIT) || xret_advance;

// MMU instruction-side privilege view: just the live priv_level.
// No combinational override needed — the xret_fetch_ctrl FSM waits
// 1 cycle (XRET_WAIT) for priv_level to settle before issuing the
// fetch (XRET_FETCH), so the MMU naturally sees the correct priv.
wire [1:0] mmu_priv = priv_level;

// exception_from_ie now driven by interrupt_ctrl (misalign detection moved there)

// ── FENCE.I: flush I-cache + D-cache when instruction reaches IE ─
assign fence_i_o = (ctrl_bus_ie.fence_i == TRUE) && !stale_ie;

// ── BPU: mispredict detection ──────────────────────────────────
// Mispredict fires when branch resolution disagrees with prediction.
// Static not-taken: predicted_taken=0, so mispredict = branch_taken.
// Future BTB also catches: predicted_taken=1 but actually not-taken.
// Do NOT gate with insn_valid_id (see original comment about trap JAL redirect).
//
// Phase 3 (branch-in-IE): branch_taken is now produced by branch_comp
// at the IE stage, so the prediction it must be compared against is
// the IE-stage `predicted_taken` (latched into ctrl_bus_ie at the IE
// register wall). Was ctrl_bus_if_id.predicted_taken in the legacy.
// BPU Step 3 mispredict:
//   A) direction wrong (pred != actual)
//   B) direction right (both taken), but predicted target != actual target.
//      This can only happen for dynamic targets — i.e., a RAS-predicted
//      JALR where the callee actually returned somewhere else.
wire bpu_dir_mismatch = (branch_taken != ctrl_bus_ie.predicted_taken);
// Target-mismatch check for dynamic-target predictions (RAS). Required when
// RAS is predicting JALR returns: if RAS top differs from the actual return
// address (branch_target_address at IE), recover to branch_target_address.
wire bpu_tgt_mismatch = (branch_taken == TRUE)
                     && (ctrl_bus_ie.predicted_taken == TRUE)
                     && (branch_target_address != predicted_target_ie);
assign bpu_mispredict = onebit_sig_e'(bpu_dir_mismatch || bpu_tgt_mismatch);

wire branch_taken_valid = bpu_mispredict;

// Recovery target:
//   pred=T, actual=NT  -> predicted_pc_ie (fall-through)
//   pred=T, actual=T, wrong target -> branch_target_address (real target)
//   pred=NT, actual=T  -> branch_target_address
wire [31:0] branch_recovery_target =
	(bpu_dir_mismatch && (ctrl_bus_ie.predicted_taken == TRUE))
	    ? predicted_pc_ie
	    : branch_target_address;
// Phase 4.3: xRET commits at IWB via wb_trap_unit. The legacy `ret_valid`
// from privilege_unit (driven from ID) is no longer used as a redirect
// trigger — wb_xret_fire from IWB is the new source. ret_valid_valid stays
// as the wire name to minimise diff in the redirect_arbiter / pc_sel mux
// instantiation; only the source changes.
wire ret_valid_valid    = wb_xret_fire;

always_comb
begin
	// Priority: debug > interrupt/trap > branch > ret > RAS > BPU-IF > PC+4
	if (debug_valid)                pc_sel = BRANCH_DPC;
	else if (interrupt_valid)       pc_sel = INTERRUPT;
	else if (branch_taken_valid)    pc_sel = BRANCH_PC;
	else if (ret_valid_valid)       pc_sel = RET;
	else if (bpu_redirect_fire)     pc_sel = BPU_PRED;
	else if (bpu_if_redirect_fire)  pc_sel = BPU_IF;
	else                            pc_sel = PC_plus_4;
end
always_comb
begin
	case(pc_sel)
		PC_plus_4: pc_in = pc_out + 4;
		BRANCH_PC: pc_in = branch_recovery_target;
    INTERRUPT: pc_in = handler_addr;
    RET      : pc_in = (ctrl_bus_iwb.sret == TRUE) ? sepc : epc;
		BRANCH_DPC:pc_in = dpc;
		BPU_PRED : pc_in = bpu_redirect_target;
		BPU_IF   : pc_in = bpu_if_redirect_target;
		default: pc_in = pc_out + 4;
	endcase
end

// ── Redirect Arbiter (Phase 1: parallel observation only) ───────────────
// docs/fetch_revamp_plan.md §4.1 / §9 Phase 1.
// This module runs in parallel with the existing pc_sel/pc_in logic above.
// Its outputs are NOT consumed by any functional path — they exist only so
// the SVA assertions below can cross-check that the new arbiter produces
// the same redirect decision as the legacy mux on every cycle. Once
// validated by RISCOF + Linux, Phase 4 will switch the program counter to
// consume these signals and delete the legacy pc_sel logic.
logic            arb_redirect_valid;
logic [31:0]     arb_redirect_target;
redirect_kind_e  arb_redirect_kind;

redirect_arbiter redirect_arbiter_inst (
    .debug_resume_i  (debug_valid),
    .trap_valid_i    (interrupt_valid),
    .branch_taken_i  (branch_taken_valid),
    .ret_valid_i     (ret_valid_valid),
    // Phase 4.3: sret/mret distinction comes from the IWB carrier.
    .sret_select_i   (ctrl_bus_iwb.sret == TRUE),
    .bpu_pred_fire_i (bpu_redirect_fire),
    .bpu_if_fire_i   (bpu_if_redirect_fire),

    .handler_addr_i  (handler_addr),
    .branch_target_i (branch_recovery_target),
    .sepc_i          (sepc),
    .mepc_i          (epc),
    .dpc_i           (dpc),
    .bpu_pred_target_i (bpu_redirect_target),
    .bpu_if_target_i   (bpu_if_redirect_target),

    .redirect_valid_o  (arb_redirect_valid),
    .redirect_target_o (arb_redirect_target),
    .redirect_kind_o   (arb_redirect_kind)
);

// SVA cross-check: arbiter outputs must match the legacy pc_sel/pc_in mux
// every cycle (after reset). If these fire, either the arbiter has a bug
// or the legacy mux has a case the arbiter is missing. Both are blockers
// for Phase 1 → Phase 2 progression.
`ifndef SYNTHESIS
property p_arb_valid_matches_pc_sel;
    @(posedge clk_i) disable iff (reset_i)
        arb_redirect_valid == (pc_sel != PC_plus_4);
endproperty
property p_arb_target_matches_pc_in;
    @(posedge clk_i) disable iff (reset_i)
        arb_redirect_valid |-> (arb_redirect_target == pc_in);
endproperty
a_arb_valid_matches_pc_sel:  assert property (p_arb_valid_matches_pc_sel)
    else $error("redirect_arbiter: valid (%0b) != (pc_sel != PC_plus_4) (%0b), pc_sel=%0d",
                 arb_redirect_valid, (pc_sel != PC_plus_4), pc_sel);
a_arb_target_matches_pc_in:  assert property (p_arb_target_matches_pc_in)
    else $error("redirect_arbiter: target (%08x) != pc_in (%08x), kind=%0d, pc_sel=%0d",
                 arb_redirect_target, pc_in, arb_redirect_kind, pc_sel);
`endif

// ============================================================
// FETCH STAGE
// ============================================================

// xRET commit one-shot: combines MRET and SRET fire pulses from privilege_unit.
// Used to bypass main PC stall and c_controller stall so they latch sepc/mepc
// on the same cycle the CSR side effects commit (symmetric to interrupt_valid
// for trap entry). Without this, an SRET to a U-mode address whose page is
// cold in the ITLB deadlocks: if_id_stall stays high during the PTW walk and
// neither pc_out nor apc ever latch the return target.
// Phase 4.3: ret_pulse used to be the OR of privilege_unit's ret_fire/sret_fire
// (both fired from ID). Now the xRET commitment fires from wb_trap_unit at IWB.
wire ret_pulse = wb_xret_fire;

// Phase 3: producer-side stall sources.
//
// The producer (pc_out + imem_port.req) must NOT depend on the consumer-
// side stalls (if_id_stall, which now includes id_no_insn_stall =
// ~aligner_valid). Coupling them creates a chicken-and-egg deadlock:
// the buffer is empty → aligner_valid=0 → if_id_stall=1 → req=0 → no
// fetch → buffer stays empty.
//
// The producer should only stall when:
//   - the IE-side hazard chain is stalled (alu_stall, dmem busy, AMO,
//     mmu_d_stall, etc) — captured by ie_stall
//   - the icache cannot accept more (fetch_stall)
//   - the MMU instruction-side is doing a PTW walk (mmu_i_stall) — the
//     fetch can't issue while the translation is pending
//   - debug halted
//
// We deliberately exclude id_no_insn_stall from this set because the
// whole point of fetching is to refill the buffer when ID is dry.
// Phase 4.3: csr_ret_hazard is dead (xRET resolves at IWB so the
// older csrrw mepc/sepc has already committed by the time mret reads
// it). Removed from the producer stall list. The signal is still
// connected as a wire and tied to 0 by hazard_unit; cleanup pass
// will drop the wire entirely.
wire fetch_producer_stall = ie_stall | mmu_i_stall | halted_o |
                            refetch_after_trap |
                            insert_bubble | fetch_stall;

// ── Pending fetch target (deferred-redirect register) ──────────────────
//
// When a redirect (branch / xRET / trap / debug) lands on a virtually-
// mapped target whose ITLB entry is missing, the MMU stalls (mmu_i_stall=1)
// while it kicks off a PTW. The producer-side bus request is correctly
// suppressed (Phase 3.4 `~mmu_i_stall` guard), and the bypass forces
// `pc_out` to latch the redirect target on the same cycle.
//
// The next cycle, however, `pc_in = pc_out + 4` advances PAST the redirect
// target. Without intervention this leaks two ways:
//
//   1. The MMU's combinational `itlb_hit` is computed against the live
//      `i_vaddr_i = pc_in`, so even after its PTW completes for the
//      original redirect target the TLB hit check fails (now looking at
//      target+4) and the MMU starts a SECOND PTW for the wrong VA.
//
//   2. After PTW finishes and the bus fetches the target, sequential
//      fetches resume immediately (target+4, target+8, ...).
//
// Fix: latch the redirect target into a "pending fetch" register on the
// cycle of a deferred redirect, drive `i_vaddr` from it while pending,
// hold `pc_out` so the off-by-one doesn't break, and only clear the
// pending bit when the target instruction has REACHED IE — i.e., when
// `pc_ie == pending_target_q`.
//
// Duplicate-push problem (the _printk c.addi16sp sp,-64 sp drift bug):
// while pending_target_v_q is held, pc_out is held and i_vaddr is driven
// from pending_target_q, but `imem_port.req` keeps firing every cycle
// (gated only by fetch_producer_stall). Each cycle the producer issues
// a duplicate fetch to the same address, both rvalids push duplicate
// entries into the fetch_buffer, and the aligner emits each compressed
// instruction twice — c.addi16sp sp,-64 then commits twice, leaking
// 64 bytes of stack per deferred redirect.
//
// Fix (Phase 4.11): track whether the target's fetch_buffer push has
// already happened with `pending_pushed_q`, and gate `fb_push` on
// `~(pending_target_v_q && pending_pushed_q)`. This drops duplicate
// pushes WITHOUT blocking the producer (so the pipeline can't deadlock
// if a flush squashes the entry mid-flight — the next push naturally
// re-fills).
logic [31:0] pending_target_q;
logic        pending_target_v_q;
wire         redirect_deferred = arb_redirect_valid & mmu_i_stall;
wire         pending_target_drained = pending_target_v_q && (pc_ie == pending_target_q);
// Forward declaration: actual flop sits beside fb_push (after fetch_flush)
logic        pending_first_push_done_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        pending_target_q   <= 32'b0;
        pending_target_v_q <= 1'b0;
    end else if (redirect_deferred) begin
        // Capture (or re-capture on a nested redirect) the deferred target.
        pending_target_q   <= pc_in;
        pending_target_v_q <= 1'b1;
    end else if (fb_overflow && !pending_target_v_q) begin
        // DEPTH=4 overflow recovery: the fetch_buffer dropped this push
        // because it was full at rvalid time (common with BPU IF FIRE
        // where target fetch lands 1 cycle after a legitimate concurrent
        // push filled the last slot). Refetch by reusing the pending
        // target mechanism — captures the dropped word-aligned vaddr,
        // drives i_vaddr from it, and clears once the refetched word
        // reaches IE. Without this, the aligner's squash FSM can never
        // exit (it waits for head.vaddr==BPU_target which was dropped).
        //
        // Guard `!pending_target_v_q`: do NOT overwrite an already-pending
        // MMU-deferred redirect (would abandon the correct redirect
        // target and cause VM regressions).
        pending_target_q   <= fb_push_entry.vaddr;
        pending_target_v_q <= 1'b1;
    end else if (arb_redirect_valid) begin
        // Non-deferred redirect (mmu_i_stall=0) takes priority and is
        // fetched directly via the arb_red path of imem_port.req. The
        // old pending target is abandoned — without this branch,
        // pending_target_v_q would never clear and the producer would
        // never see normal pc_out advance.
        pending_target_v_q <= 1'b0;
    end else if (pending_target_drained) begin
        // Target instruction has reached IE — release the override.
        pending_target_v_q <= 1'b0;
    end
end

// Phase 4.13b: straddled-instruction support for half-aligned pending
// targets.
//
// A 4-byte instruction at a half-aligned VA (e.g. paging_init's
// `lui a0, 0x9dbfe` at c04046f6 after a sfence.vma triggers a deferred
// PTW redirect to that VA) STRADDLES two consecutive icache words. The
// compressed_aligner needs both `[word @ target & ~3, word @ (target+4) & ~3]`
// to assemble the instruction. While `pending_target_v_q` holds pc_out
// at the target, the producer can only fetch the FIRST word; the second
// word is unreachable, the aligner stalls, pc_ie never reaches the
// target, and the pipeline deadlocks.
//
// Fix: track whether the FIRST fb_push for the pending target has
// landed. For half-aligned targets only, release pc_out after the first
// push so the producer can advance to fetch the second word. For
// word-aligned targets we keep the original behaviour (hold until
// pc_ie==target) — that path is needed by vm_VA_all_ones (target at
// 0xfffffffc, target+4 wraps to 0 which is unmapped, the wrong-path
// fetch faults and squashes the legitimate target).
//
// pending_release_for_straddle is high once the first push for a
// half-aligned target has been observed. It releases both the pc_out
// hold and the i_vaddr override. The producer then advances normally,
// fetches the next word, the aligner assembles the straddled
// instruction, and pc_ie eventually reaches the target — clearing
// pending_target_v_q via the existing pending_target_drained path.
//
// pending_first_push_done_q is reset on:
//   - reset_i
//   - redirect_deferred (new pending session captured a fresh target)
//   - fetch_flush (fb was squashed; the entry is gone, allow re-fetch)
//   - pending_target_drained (session ended)
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        pending_first_push_done_q <= 1'b0;
    end else if (redirect_deferred || fetch_flush || pending_target_drained) begin
        pending_first_push_done_q <= 1'b0;
    end else if (pending_target_v_q && fb_push) begin
        pending_first_push_done_q <= 1'b1;
    end
end

wire pending_release_for_straddle = pending_target_v_q
                                 && pending_target_q[1]
                                 && pending_first_push_done_q;

// Stale-pending-override race fix (handle_mm_fault crash root cause).
//
// Scenario:
//   1. A deferred redirect (e.g. beqz mispredict at IE while ITLB miss on
//      its target c0075e34) latches pending_target_q := c0075e34 and
//      pending_target_v_q := 1.
//   2. PTW completes, producer fetches c0075e34, fb_push lands, the c.j
//      at c0075e34 enters the pipeline.
//   3. The c.j is unconditional + unpredicted → mispredict at IE → a NEW
//      non-deferred RDR_BRANCH redirect fires to c007582a. pc_in becomes
//      the new target this cycle.
//   4. pending_target_v_q clears at the NEXT clock edge (existing logic
//      under `else if (arb_redirect_valid)`), but during THIS cycle it's
//      still 1 — so pending_overrides_vaddr would route i_vaddr to the
//      STALE c0075e34 instead of the new c007582a, and the redirect-cycle
//      imem.req (fired by the new redirect's gate) fetches the old word.
//   5. Next cycle, pc_out advances to target+4 = c007582e and the new
//      target's word (c0075828) is never fetched. The buffer ends up with
//      a stale c0075e34 head + post-redirect c007582c next; the aligner
//      stitches the two halves into a bogus instruction at half_index=1
//      (0xc1461537 = lui a0, 0xc1461 instead of the real lui a3, 0xc146f
//      at c007582a) and silently skips the real lui. a3 stays at 0,
//      addi a3,a3,-608 produces 0xfffffda0, lw a2,56(a3) faults at
//      0xfffffdd8 — the handle_mm_fault crash.
//
// Fix: any arb_redirect_valid in the same cycle as an active
// pending_target_v_q must yield the i_vaddr override to the new redirect.
// The new redirect's pc_in becomes i_vaddr; the new target's word gets
// fetched (or, for deferred new redirects with mmu_i_stall=1, the
// imem.req gate suppresses the fetch and pending_target_q gets re-latched
// to the new target via redirect_deferred — same behaviour as before).
//
// Importantly we yield on arb_redirect_valid alone (NOT gated by
// mmu_i_stall): gating by mmu_i_stall would create a combinational loop
// (pending_overrides_vaddr → i_vaddr → mmu_i_stall → yield →
// pending_overrides_vaddr). arb_redirect_valid is independent of the
// current cycle's i_vaddr (its sources — branch_taken_valid at IE,
// bpu_redirect_fire at ID, wb_xret_fire at IWB, registered interrupt —
// all read pre-IE state), so this gate is safe.
wire pending_yield_to_redirect = arb_redirect_valid;
wire pending_holds_pc        = pending_target_v_q && !pending_release_for_straddle
                            && !pending_yield_to_redirect;
wire pending_overrides_vaddr = pending_target_v_q && !pending_release_for_straddle
                            && !pending_yield_to_redirect;

`ifdef BOOT
program_counter #(.DEFAULT(32'h00001000)) program_counter_inst
`else
program_counter #(.DEFAULT(32'h80000000)) program_counter_inst
`endif
(
	.clk_i		(clk_i),
	.reset_i	(reset_i),
	// Phase 3: c_stall replaced by fetch_producer_stall. The bypass
	// includes arb_redirect_valid so that the back-pressure stall
	// does NOT suppress the redirect's PC latch when a branch/xRET/
	// trap/debug fires while the buffer is full.
	//
	// Phase 4.3: csr_ret_hazard is dead — xRET resolves at IWB so the
	// older csrrw mepc/sepc has already committed before the carrier
	// reaches wb_trap_unit. The previous Phase 3.2 guard (`& ~csr_ret_hazard`)
	// is removed.
	//
	// pending_target_v_q stall: while a deferred redirect is pending,
	// pc_out must NOT advance (it's "parked" at the previous fetch's PC,
	// waiting for the override to drive the bus). Without this gate,
	// pc_out would latch pc_in = pc_out + 4 on the cycle the override
	// fires the bus req, and the next sequential fetch would skip
	// target + 4.
	//
	// (An earlier draft also gated the bypass by ~insert_bubble for
	// the load-use bubble case. After moving branch resolution to the
	// IE stage, insert_bubble is permanently 0 — the IE-stage forwarding
	// handles the load-use case for branches without any pipeline
	// bubble. That guard is dead and removed.)
	// Phase 4.8: xret_hold_pc keeps pc_out parked at the xret target
	// while the FSM waits for priv to settle and the fetch to complete.
	.stall_i	((interrupt_valid | ret_pulse | arb_redirect_valid) ? 1'b0 :
	             (fetch_producer_stall | pending_holds_pc | xret_hold_pc | refetch_pending_q)),
	.pc_in_i	(pc_in),
	.pc_out_o	(pc_out)
);

// refetch_after_trap: use pc_out (= handler_addr, held by the stall) so the
// memory request targets the correct handler address instead of handler_addr+4.
//
// pending_target_v_q override: see the long comment on `pending_target_q`
// above. While a deferred redirect is pending, drive i_vaddr from the
// latched target so the MMU sees a stable VA across the entire PTW window
// (otherwise pc_in would advance and the MMU would walk the wrong page
// once the original PTW completes).
// Phase 4.8: xret_drive_va overrides i_vaddr to the saved target so the
// MMU translates the correct VA at the now-settled priv_level.
// Phase 4.14b (Bug 28): extend refetch_after_trap to hold i_vaddr = pc_out
// until the first req actually fires. refetch_after_trap is a 1-cycle pulse,
// but if mmu_i_stall is high (ITLB miss → PTW), the pulse expires before
// the req can fire. Without extending it, i_vaddr falls back to pc_in =
// pc_out+4 and the first fetch after PTW skips the handler's first
// instruction (csrrw tp,sscratch,tp at c0002de4) → tp never swaps →
// _save_context writes to user VA → crash.
logic refetch_pending_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        refetch_pending_q <= 1'b0;
    else if (refetch_after_trap)
        refetch_pending_q <= 1'b1;
    else if (imem_port.req || arb_redirect_valid)
        // Clear once the first req fires (refetch consumed) or a new
        // redirect overrides (trap/branch/xret takes priority).
        refetch_pending_q <= 1'b0;
end
wire refetch_extended = refetch_after_trap | refetch_pending_q;

wire [31:0] i_vaddr = (reset_i | insert_bubble | refetch_extended) ? pc_out :
                      xret_drive_va                                 ? xret_target_q :
                      pending_overrides_vaddr                       ? pending_target_q :
                                                                      pc_in;
assign imem_port.addr  = i_paddr;  // MMU translates i_vaddr → i_paddr
// Force req=1 during refetch even when the producer is otherwise stalled.
// Phase 3: gate by fetch_producer_stall (NOT if_id_stall) so the fetch
// path keeps refilling when ID is dry.
//
// arb_redirect_valid bypass: a redirect (branch/xRET/trap/debug) MUST
// issue its target's fetch on the redirect cycle, regardless of
// fetch_stall back-pressure. Without this, the redirect target gets
// skipped: pc_out latches the target the next cycle, then pc_in
// advances to target+4, and the producer fetches target+4 first —
// the actual redirect target instruction is never fetched.
//
// Phase 4.3: csr_ret_hazard guard removed (xRET resolves at IWB —
// the older csrrw mepc/sepc has already committed before the carrier
// reaches wb_trap_unit, so reading mepc/sepc here is always fresh).
//
// Phase 3.4 ~mmu_i_stall guard kept: when the redirect target lives
// on a virtually-mapped page whose ITLB entry is missing, the MMU's
// i_paddr_o defaults to {PPN=0, offset} until the PTW finishes and
// fills the ITLB. Without this gate the bus would issue a fetch with
// that bogus PA and the aligner would buffer garbage.
// Phase 4.8: xret_suppress holds off the fetch during XRET_WAIT (priv
// settling). XRET_FETCH lets the normal ~fetch_producer_stall path issue
// the req at the correct priv (mmu_i_stall gates naturally if PTW needed).
//
// Phase 4.10: suppress the redirect-cycle fetch for TRAP redirects
// (~interrupt_valid gate). On a trap, priv_level hasn't settled yet
// (csr_unit updates it at posedge), so the PMP check on the handler
// fetch would use the OLD priv — e.g. priv=S instead of M, causing a
// spurious access fault that re-captures inflight_i_fault_q=1 and
// creates a 2nd trap with MPP=M. Deferring the handler fetch to the
// refetch_after_trap cycle (1 cycle later) lets priv_level settle
// first. Branch/xret/debug redirects keep the same-cycle fetch because
// their priv_level is unchanged.
// Phase 4.14 (Bug 27): gate refetch_after_trap by ~mmu_i_stall.
// When a trap redirects to the handler VA but the ITLB has no
// entry for it (evicted by user PTW FIFO fills during dynamic
// linker mmap), the combinational i_paddr_out defaults to the
// low VA bits (from the zero-init itlb_entry). Without the gate,
// the bus req fires with this garbage PA and fetches wrong
// instruction bytes from an unrelated physical address.
// Confirmed by CYC trace: i_pa=0x00000de4 (low bits of VA
// c0002de4) with itlb_hit=0 and imem_req=1 at cycle 127483735.
assign imem_port.req   = (refetch_extended & ~mmu_i_stall) |
                         (arb_redirect_valid & ~mmu_i_stall & ~xret_suppress
                          & ~interrupt_valid) |
                         (~fetch_producer_stall & ~xret_suppress
                          & ~interrupt_valid);
assign imem_port.we    = 1'b0;
assign imem_port.be    = 4'b1111;
assign imem_port.wdata = 32'b0;

// ── Phase 3: fetch_buffer + compressed_aligner are the LIVE fetch path ──
// docs/fetch_revamp_plan.md §4.3 / §4.4 / §9 Phase 3.
//
// The decoder now reads from the compressed_aligner instead of the
// legacy c_controller. The c_controller is kept instantiated for
// reversibility but no functional path consumes its outputs. Phase 4
// will delete it entirely.
//
// Key timing change: a registered fetch buffer adds +1 cycle of latency
// between imem_port.rdata and the IE register wall capture. This
// increases branch misprediction penalty from 1 cycle to 2. The user
// has explicitly accepted this trade ("BPU will amortize") in exchange
// for converging towards a textbook fetch design.
//
// Producer/consumer flow:
//   - Producer: pc_out + imem_port.req fetch one word per cycle, but
//     are HELD when the buffer would overflow (fetch_stall) or when a
//     redirect just fired (the bypass on program_counter.stall_i).
//   - inflight_q tracks the in-flight cycle of the icache 1-cycle
//     latency; clears on arb_redirect_valid so wrong-path rdata is
//     dropped at the push gate.
//   - The buffer is pushed on (rvalid && inflight_q), so a redirect
//     mid-fetch silently drops the wrong-path word.
//   - The aligner consumes from the buffer head/next, advancing
//     half_index according to compressed/straddled layout.
//   - Consumer side: when the aligner has nothing to emit
//     (aligner_valid=0), hazard_unit raises if_id_stall via the new
//     id_no_insn_stall input, and the IE wall capture in core_top
//     additionally gates on aligner_valid (3l) to avoid latching the
//     decoder's NOP-from-zero output.

// Canonical fetch flush: every redirect (trap, xRET, branch, debug,
// reset) flushes the buffer + aligner half_index in lockstep with
// pc_out latching the new target. Sourced from the Phase 1 redirect
// arbiter so there is one arbiter for the new path and one mux for
// the legacy producer (pc_in mux at line 422), kept consistent by the
// SVA cross-check assertions just below the arbiter instantiation.
// Phase 4.9: flush on xret_at_decode (same-cycle as mret pops from
// buffer, clearing the wrong-path entry behind it) and xret_draining
// (continuous flush while mret transits IE→IWB).
// IF-stage BPU redirects do NOT flush the buffer or drop in-flight pushes —
// the branch's own fetch word must still populate the buffer so it can reach
// IE for resolution. Higher-priority redirects (trap/branch/xret/RAS) still
// flush.
wire arb_redirect_flushing = arb_redirect_valid && (arb_redirect_kind != RDR_BPU_IF);
wire fetch_flush = arb_redirect_flushing | xret_at_decode | xret_draining;

// inflight_vaddr_q latches i_vaddr on every cycle imem_port.req is
// high. The vaddr register itself has NO reset (so a request issued in
// the very first non-reset cycle is captured even if we're still
// settling out of reset).
logic [31:0] inflight_vaddr_q;
always_ff @(posedge clk_i) begin
    if (imem_port.req)
        inflight_vaddr_q <= i_vaddr;
end

// ── Phase 4.8: route instruction-side faults through fetch_buffer ────────
// Wrong-path-bug fix for the PMP cluster + vm_A_and_D residual.
//
// Background. `mmu_i_access_fault_o` and `mmu_i_fault_o` both have a
// COMBINATIONAL term that fires the SAME cycle the producer issues
// imem.req (term1: `i_req_i && i_pmp_fault` for access faults;
// `itlb_hit && !i_perm_ok` for page faults from ITLB-hit perm fails,
// e.g. an A-bit-clear PTE). For an unconditional jump (e.g.
// `j 0x8000078c` at PC 0x80000764), the producer issues a sequential
// prefetch for PC+4 = 0x80000768 ONE cycle after the JAL fetch. If
// 0x80000768 lives in a no-perm PMP region (PMP cluster) or on a
// page with cleared A/D bit (vm_A_and_D), the comb fault fires the
// same cycle. Two cycles later, before the JAL has reached IE, the
// legacy path latches the fault into trap_sequencer and interrupt_ctrl
// fires a sync trap with mepc = wrong-path PC. The JAL never commits
// — it gets clobbered by the trap's IE flush. The result is one EXTRA
// trap that spike never sees (spike is non-speculative).
//
// Fix. Latch the comb fault into `inflight_i_fault_q` at imem.req
// time, ride it through the fetch_buffer on the same entry as the rdata
// (using the existing fault/cause fields), and only fire the trap when
// the buffer entry has actually reached the aligner head AND no older
// in-flight redirect (branch / xRET / debug-resume) is firing this cycle.
// Combined with the natural fetch_flush on `arb_redirect_valid`, this
// guarantees the wrong-path entry is squashed before its fault can leak.
//
// PTW-completion versions of i_fault / i_access_fault keep firing
// through the legacy direct-to-trap_sequencer path (the
// `mmu_i_*_fault_ptw` outputs added to mmu_sv32 expose just term2 of
// the legacy outputs). PTW completion has no live imem.req cycle to
// ride the buffer, but it's also naturally delayed by the PTW window
// so it doesn't suffer the wrong-path bug.
//
// Priority on capture: access fault wins over page fault on the same
// cycle (PMP is checked before MMU translation per the RISC-V spec).
logic       inflight_i_fault_q;
logic [4:0] inflight_i_cause_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        inflight_i_fault_q <= 1'b0;
        inflight_i_cause_q <= 5'd0;
    end else if (arb_redirect_valid && !imem_port.req) begin
        // A redirect (trap/branch/xret) invalidates any in-flight fault
        // from the previous fetch direction. Without this clear, a stale
        // fault flag persists when the redirect's handler fetch is blocked
        // by mmu_i_stall (ITLB miss at old priv), and the next fb_push
        // (from refetch_after_trap) inherits the stale fault — creating a
        // spurious 2nd trap at the wrong privilege (pmp_check_on_pa bug).
        // The `!imem_port.req` guard ensures we don't clear when the
        // redirect itself issues a new fetch (which might also fault).
        //
        // For TRAP redirects, the handler fetch is suppressed on the
        // redirect cycle (see the ~interrupt_valid gate on imem_port.req)
        // so imem_port.req=0 and this clear fires. This avoids the
        // stale-priv PMP bug where the handler fetch at PA 0x80000e00
        // would see priv=S instead of M and spuriously re-capture
        // fault=1 into inflight_i_fault_q (confirmed by VCD cycles
        // 1482–1486 before this fix).
        inflight_i_fault_q <= 1'b0;
        inflight_i_cause_q <= 5'd0;
    end else if (imem_port.req) begin
        if (mmu_i_access_fault) begin
            inflight_i_fault_q <= 1'b1;
            inflight_i_cause_q <= 5'd1;   // INSN_ACCESS_FAULT
        end else if (mmu_i_fault) begin
            inflight_i_fault_q <= 1'b1;
            inflight_i_cause_q <= 5'd12;  // INSN_PAGE_FAULT
        end else begin
            inflight_i_fault_q <= 1'b0;
            inflight_i_cause_q <= 5'd0;
        end
    end
end

// inflight_q tracks "a fetch is on the bus, waiting for rvalid".
//
// Priority on the same cycle:
//   1. imem_port.req → inflight_q=1 (a new request is being issued —
//      its rvalid will arrive next cycle and we want to capture it).
//      This wins over arb_redirect_valid because on the redirect cycle
//      the producer issues a req for the *new* target (pc_in already
//      reflects the redirect because the pc_sel mux is combinational).
//   2. arb_redirect_valid && !imem_port.req → inflight_q=0 (a redirect
//      with no new req this cycle drops any prior wrong-path in-flight).
//   3. imem_port.rvalid (and not req) → inflight_q=0 (response landed).
logic inflight_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        inflight_q <= 1'b0;
    else if (imem_port.req)
        inflight_q <= 1'b1;
    else if (arb_redirect_valid)
        inflight_q <= 1'b0;
    else if (imem_port.rvalid)
        inflight_q <= 1'b0;
end

// Push to the buffer when imem returns a valid rdata, gated only by
// `!arb_redirect_valid` to drop wrong-path rdata that arrives on the
// same cycle as a redirect.
//
// Notably we do NOT gate by inflight_q here. inflight_q is reset-
// cleared, but the SRAM may have a valid `pa_rvalid_o` on the very
// first non-reset cycle (because the icache fetched during the last
// reset cycle, and rvalid is registered without reset). Gating the
// push by inflight_q would cause us to DROP the rdata for the very
// first instruction at the reset PC, leading to a "first instruction
// after reset is silently skipped" bug. inflight_q is still used by
// fetch_stall to anticipate the buffer fill 1 cycle early.
// Phase 4.8: xret_drop_push drops the stale rvalid from the wrong-priv
// fetch that was issued on the wb_xret_fire cycle (before the FSM could
// suppress it). The rdata is from PA=VA (untranslated) and is garbage.
wire fb_push_raw = imem_port.rvalid && !arb_redirect_flushing && !xret_drop_push;

fetch_pkg::fetch_buffer_entry_t fb_push_entry;
assign fb_push_entry.word  = imem_port.rdata;
// Store the WORD-ALIGNED vaddr so the aligner's pc_id arithmetic
// (head.vaddr + (half_index ? 2 : 0)) works correctly even when a
// redirect lands on a half-aligned target (e.g. j to a 16-bit
// compressed instruction at vaddr[1]=1). The icache fetches the
// containing word regardless of whether the request was half-aligned;
// the aligner's half_index already tracks which half is "current" via
// redirect_target_i[1].
assign fb_push_entry.vaddr = {inflight_vaddr_q[31:2], 2'b00};
// Phase 4.8: route comb i-side faults through the buffer (see big
// comment above on inflight_i_fault_q). Both access faults (cause 1)
// and page faults (cause 12) take this path; PTW-completion faults
// keep firing through the legacy direct mmu_i_*_fault_ptw path.
assign fb_push_entry.fault = inflight_i_fault_q;
assign fb_push_entry.cause = inflight_i_cause_q;
// IF-stage predictions: per-half, latched at imem.req (see §3d below)
assign fb_push_entry.pred_lo_taken  = inflight_pred_lo_taken_q;
assign fb_push_entry.pred_hi_taken  = inflight_pred_hi_taken_q;
assign fb_push_entry.pred_lo_target = inflight_pred_lo_target_q;
assign fb_push_entry.pred_hi_target = inflight_pred_hi_target_q;

// Phase 4.13: vaddr-based duplicate-push dedup.
//
// The producer's imem_port.req is held high every cycle that
// ~fetch_producer_stall. While pending_target_v_q is held (for a
// deferred redirect whose target needs PTW), pc_out is parked and
// i_vaddr is driven from pending_target_q (a fixed value), so the
// producer issues 2+ identical fetches back-to-back. Both rvalids
// push duplicate entries into the fetch_buffer, the aligner emits the
// same compressed instructions twice, and IE re-runs them with rs1
// FORWARDED from the first commit (so the second commit computes a
// new value, e.g. `c.addi16sp sp,-64` shifts sp by 64 a second time).
// Across hundreds of SBI ecalls during early boot the sp drift
// accumulates and breaks setup_arch's epilogue.
//
// Earlier attempts to fix this in the producer (Phase 4.10/4.11/4.12
// FSM and pending_req_block variants) deadlocked: a 4-byte instruction
// straddled across two icache words (e.g. `lui a0` at half-aligned
// c04046f6, after a sfence.vma flushes the ITLB and forces a deferred
// PTW redirect to the next sequential instruction) needs the producer
// to issue TWO different fetches in a row. Blocking the producer at
// the second fetch leaves the aligner with only one half of the
// instruction; pc_ie never reaches the target; FSM never exits.
//
// The proper fix lives at the buffer push gate, where we can compare
// vaddrs and drop only the truly duplicate ones:
//
//   - Track the previous successful push's vaddr in last_pushed_vaddr_q.
//   - On a new push attempt, drop it if the vaddr matches the last
//     pushed vaddr (i.e. the producer just over-issued).
//   - Clear the history on fetch_flush so a re-push after a
//     branch/xret/trap is not falsely dropped.
//
// Straddled instructions: the two halves come from different
// word-aligned vaddrs (c04046f4 and c04046f8), so the vaddr comparison
// does NOT trip and both pushes go through. ✓
//
// Normal sequential: pc_out advances every cycle, every push has a
// different vaddr. ✓
//
// Duplicate-fetch bug: the second push has the same vaddr as the
// first → dropped. ✓
//
// This fix is downstream of the producer (no req throttling) so it
// cannot deadlock on multi-word fetch sequences.
logic [31:0] last_pushed_vaddr_q;
logic        last_pushed_valid_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i || fetch_flush) begin
        last_pushed_vaddr_q <= 32'b0;
        last_pushed_valid_q <= 1'b0;
    end else if (fb_push_raw) begin
        last_pushed_vaddr_q <= fb_push_entry.vaddr;
        last_pushed_valid_q <= 1'b1;
    end
end

wire fb_push_dup = last_pushed_valid_q
                && (fb_push_entry.vaddr == last_pushed_vaddr_q);
wire fb_push     = fb_push_raw && !fb_push_dup;

// Aligner output wires (forward declared so the producer back-pressure
// computed below can reference fb_full / fb_count from the buffer).
logic        aligner_pop;
logic [31:0] aligner_inst;
logic [31:0] aligner_pc_id;
logic        aligner_valid;
logic        aligner_fault;
logic [4:0]  aligner_cause;
logic        aligner_is_compressed;

logic                              fb_full;
logic                              fb_overflow;
fetch_pkg::fetch_buffer_entry_t    fb_head;
fetch_pkg::fetch_buffer_entry_t    fb_next;
logic                              fb_head_valid;
logic                              fb_next_valid;
logic                              fb_empty;
logic [2:0]                        fb_count;       // DEPTH=4 → 3 bits (0..4)

fetch_buffer #(.DEPTH(4)) fetch_buffer_inst (
    .clk_i        (clk_i),
    .reset_i      (reset_i),
    .flush_i      (fetch_flush),
    .push_i       (fb_push),
    .push_entry_i (fb_push_entry),
    .full_o       (fb_full),
    .overflow_o   (fb_overflow),
    .pop_i        (aligner_pop),
    .head_entry_o (fb_head),
    .next_entry_o (fb_next),
    .head_valid_o (fb_head_valid),
    .next_valid_o (fb_next_valid),
    .empty_o      (fb_empty),
    .count_o      (fb_count)
);

compressed_aligner compressed_aligner_inst (
    .clk_i               (clk_i),
    .reset_i             (reset_i),
    .flush_i             (fetch_flush),
    .consumer_take_i     (~if_id_stall),

    .head_i              (fb_head),
    .next_i              (fb_next),
    .head_valid_i        (fb_head_valid),
    .next_valid_i        (fb_next_valid),
    .pop_o               (aligner_pop),

    // RDR_BPU_IF must NOT reseat the aligner: the buffer isn't flushed
    // (the branch's own word is still in-flight), so reseating half_index
    // to the predicted target's [1] bit would corrupt the current emit
    // position within the un-flushed head entry.
    .redirect_valid_i    (arb_redirect_valid && arb_redirect_kind != RDR_BPU_IF),
    .redirect_target_i   (arb_redirect_target),

    .instruction_o       (aligner_inst),
    .pc_id_o             (aligner_pc_id),
    .instruction_valid_o (aligner_valid),
    .instruction_fault_o (aligner_fault),
    .instruction_cause_o (aligner_cause),
    .is_compressed_o     (aligner_is_compressed),
    .pred_taken_o        (aligner_pred_taken),
    .pred_target_o       (aligner_pred_target)
);
logic        aligner_pred_taken;
logic [31:0] aligner_pred_target;

// Producer back-pressure: hold pc_out and gate imem_port.req when the
// buffer would overflow on the next rvalid.
//
//   fb_full is "the buffer is already full".
//   (fb_count == 1) && inflight_q is "buffer has one entry AND there's
//   one word in flight that will arrive next cycle and fill it" — we
//   need to anticipate this case because the icache cannot back-pressure.
//
// The combined fetch_stall is the source of producer hold throughout
// the rest of this file (replaces the role of c_stall on the fetch path).
// DEPTH=4 wider gate: stall when count==DEPTH-1 + inflight. Max buffer
// throughput. Overflow on BPU IF target handled by refetch-on-overflow.
wire fetch_stall = fb_full | ((fb_count == 3'd3) && inflight_q);

// ── Phase 3: legacy c_controller is disconnected from functional paths ─
// The decoder, IE wall, and predicted_pc_id are now driven by the
// compressed_aligner above. The c_controller is kept INSTANTIATED so
// the diff can be reverted easily if RISCOF regresses, but its outputs
// are renamed to legacy_* and only consumed by SVA / debug helpers.
// Phase 4 will delete c_controller entirely.
wire c_redirect = (pc_sel != PC_plus_4);
onebit_sig_e controller_flush;
assign controller_flush = onebit_sig_e'(resumereq_i | interrupt_valid);

logic [31:0] legacy_pc_id;
logic [31:0] legacy_instruction_pipe;
logic [31:0] legacy_next_instruction_addr;
onebit_sig_e legacy_c_stall;
onebit_sig_e legacy_c_valid;
onebit_sig_e legacy_c_busy;

c_controller c_controller_inst
(
	.clk_i                  (clk_i),
	.reset_i                (reset_i),
	.stall_i                (if_id_stall),
	.flush_i                (controller_flush),
	.redirect_i             (c_redirect),
	.redirect_addr_i        (pc_in),
	.interrupt_i            (interrupt_valid),
	.ret_pulse_i            (ret_pulse),
	.instruction_i          (reset_i ? 32'b0 : imem_port.rdata),

	.instruction_addr_o     (legacy_pc_id),
	.instruction_o          (legacy_instruction_pipe),
	.next_instruction_addr_o(legacy_next_instruction_addr),
	.c_stall_o              (legacy_c_stall),
	.c_valid_o              (legacy_c_valid),
	.busy_o                 (legacy_c_busy)
);

// ── Decoder source: the new compressed_aligner ─────────────────────────
assign pc_id                 = aligner_pc_id;
assign instruction_pipe      = aligner_inst;
assign c_valid               = onebit_sig_e'(aligner_is_compressed);
// next_instruction_addr is the +2 / +4 fall-through PC consumed by
// debug_ctrl. With the new aligner driving pc_id, compute it locally.
assign next_instruction_addr = aligner_pc_id + (aligner_is_compressed ? 32'd2 : 32'd4);

// c_stall and c_busy are no longer driven by c_controller. Synthesize
// drop-in replacements from the aligner/buffer state:
//   - c_stall (consumed by program_counter and imem_port.req gates) is
//     replaced by fetch_stall above; we tie it to 0 here for any stale
//     consumer that still references the wire.
//   - c_busy is consumed by debug_ctrl to defer halt commit until the
//     fetch path is in a quiescent state. The new equivalent is "the
//     aligner has nothing emitted yet OR a fetch is in flight".
assign c_stall = onebit_sig_e'(1'b0);
assign c_busy  = onebit_sig_e'(~aligner_valid | inflight_q);

// ── BPU: predicted fall-through PC ──────────────────────────────
// Static not-taken: predicted_pc is always the sequential address.
// Future BTB will override this with the predicted target when predicted_taken=1.
assign predicted_pc_id = pc_id + (c_valid ? 32'd2 : 32'd4);
// IF-stage prediction (carried in the fetch_buffer entry) wins; fall back
// to ID-stage target for BHT/BTB/RAS redirects that fire at ID.
assign predicted_target_id = aligner_pred_is_branch ? aligner_pred_target
                                                      : bpu_redirect_target;

// ============================================================
// DECODE STAGE (ID)
// ============================================================
decoder decoder_inst
(
  .instruction_i	(instruction_pipe),
	.ctrl_bus_o		    (ctrl_bus_if_id_raw)
);

// BPU override: predicted_taken reflects IF-stage (aligner carries it
// in the fetch_buffer entry) OR ID-stage (bpu_redirect_fire = BHT/BTB
// at ID + RAS). Either path must flag the IE stage so it can validate
// the prediction and redirect on mispredict.
//
// Gate aligner_pred_taken by decoded inst_type: the IF-stage prediction
// is per-fetch-word and may fire for a non-branch instruction if the
// BTB entry trained on a prior branch at the same address still hits
// (the same word is re-fetched in a different execution context, e.g.,
// after a trap/mret redirects back through overlapping code).  Setting
// predicted_taken on a non-branch would cause a spurious mispredict
// redirect at IE (branch_comp returns FALSE for non-branches).
wire aligner_pred_is_branch = aligner_pred_taken
                           && (ctrl_bus_if_id_raw.inst_type == BRANCH
                            || ctrl_bus_if_id_raw.inst_type == JUMP);
always_comb begin
	ctrl_bus_if_id = ctrl_bus_if_id_raw;
	ctrl_bus_if_id.predicted_taken = onebit_sig_e'(aligner_pred_is_branch | bpu_redirect_fire);
end
// ── JAL/JALR rd write on instruction page fault ──────────────
// Per RISC-V spec, JAL/JALR writes rd = PC+4 before the instruction
// fetch at the target can fault. If the target fetch triggers an
// instruction page fault, the JALR never reaches WB, so we force the
// rd write here in the same cycle the trap fires.
wire jalr_fault_wr = interrupt_valid & mmu_i_fault_r & insn_valid_id &
                     (ctrl_bus_if_id.inst_type == JUMP || ctrl_bus_if_id.inst_type == JUMP_R) &
                     (ctrl_bus_if_id.rd_int != NO_REG);

// Track PMP data fault through pipeline to suppress writeback at IWB
logic pmp_d_fault_imem, pmp_d_fault_iwb;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        pmp_d_fault_imem <= 1'b0;
        pmp_d_fault_iwb  <= 1'b0;
    end else begin
        if (imem_flush)       pmp_d_fault_imem <= 1'b0;
        else if (!imem_stall) pmp_d_fault_imem <= mmu_d_access_fault;
        if (iwb_flush)        pmp_d_fault_iwb <= 1'b0;
        else if (!iwb_stall)  pmp_d_fault_iwb <= pmp_d_fault_imem;
    end
end

wire        rf_wr_en   = jalr_fault_wr | (ctrl_bus_iwb.rd_int != NO_REG && !pmp_d_fault_iwb);
wire [4:0]  rf_wr_addr = jalr_fault_wr ? ctrl_bus_if_id.rd_int[4:0] : ctrl_bus_iwb.rd_int[4:0];
wire [31:0] rf_wr_data = jalr_fault_wr ? (pc_id + 32'd4)            : write_back_data;

reg_file regfile_inst
(
	.clk_i		  (clk_i) ,
	.reset_i	  (reset_i),
	.stall_i	  (1'b0),
	.write_i	  (rf_wr_en),
	.wraddr_i	  (rf_wr_addr),
	.wrdata_i	  (rf_wr_data),
	.rdaddra_i	(dbg_rf_override? ar_ad_i[4:0] : ctrl_bus_if_id.rs1_int[4:0]),
	.rddataa_o	(rs1_int),
	.rdaddrb_i	(ctrl_bus_if_id.rs2_int[4:0]),
	.rddatab_o	(rs2_int),
	.rdaddrc_i	(5'd0),
	.rddatac_o	()
);
`ifdef FPU
	reg_file #(.ZERO_REG(0)) regfile_float_inst
	(
		.clk_i		  (clk_i) ,	
		.reset_i	  (reset_i),
		.stall_i	  (1'b0),
		.write_i	  (ctrl_bus_iwb.rd_float != NO_REG),
		.wraddr_i	  (ctrl_bus_iwb.rd_float[4:0]),	
		.wrdata_i	  (write_back_data),
		.rdaddra_i	(dbg_rf_override? ar_ad_i[4:0] : ctrl_bus_if_id.rs1_float[4:0]),
		.rddataa_o	(rs1_float),
		.rdaddrb_i	(ctrl_bus_if_id.rs2_float[4:0]),
		.rddatab_o	(rs2_float),
		.rdaddrc_i	(ctrl_bus_if_id.rs3_float[4:0]),
		.rddatac_o	(rs3_float)
	);

	assign rs1_id = (ctrl_bus_if_id.rs1_float == NO_REG)? rs1_int : rs1_float;
	assign rs2_id = (ctrl_bus_if_id.rs2_float == NO_REG)? rs2_int : rs2_float;
	assign rs3_id = (ctrl_bus_if_id.rs3_float == NO_REG)? 0 : rs3_float;
`else
  assign rs1_float = 0;
  assign rs2_float = 0;
  assign rs3_float = 0;
  
	assign rs1_id = rs1_int;
	assign rs2_id = rs2_int;
	assign rs3_id = 0;
`endif


//forwarding
forwarding_logic forwarding_logic_id_inst
(
	.rs1_i			    (ctrl_bus_if_id.rs1_int),
	.rs2_i			    (ctrl_bus_if_id.rs2_int),
	.rs1_float_i	  (ctrl_bus_if_id.rs1_float),
	.rs2_float_i	  (ctrl_bus_if_id.rs2_float),
	.rs3_float_i	  (ctrl_bus_if_id.rs3_float),
	.rd_mem_i		    (ctrl_bus_imem.rd_int), 
	.rd_wb_i		    (ctrl_bus_iwb.rd_int),
	.rd_float_mem_i	(ctrl_bus_imem.rd_float), 
	.rd_float_wb_i	(ctrl_bus_iwb.rd_float),
	.wb_mem_i	    	(ctrl_bus_imem.wb_sel), 
	.wb_wb_i		    (ctrl_bus_iwb.wb_sel),
	.forwarda_id_o	(forwarda_id),
	.forwardb_id_o	(forwardb_id),
	.forwardc_id_o	(forwardc_id)
);

// Phase 3 (branch-in-IE + load-use cleanup): include the MEMORY case
// so that a load instruction in IMEM stage forwards its load result
// to a consumer in IE/ID. The legacy relied on stall_line's
// `(lu_ie | br_true) & stall_condition_ie` bubble to delay the
// consumer until the load reached IWB (where write_back_data already
// handles MEMORY → readdata_iwb). With Phase 3 the stall_line's
// load-use bubble was removed (along with the branch bubble) to
// match the architecture brief's "MEM/WB merged → no load-use stall".
// That requires the IMEM-stage forwarding to actually return the
// load result. readdata_imem is the dmem rvalid data for the IMEM-stage
// instruction (the load currently in MEM), so it's the correct
// forwarding source for MEMORY wb_sel.
always_comb
begin
	case(ctrl_bus_imem.wb_sel)
		EXEC:   imem_forwarded_data = exec_result_imem;
		PC_WB:  imem_forwarded_data = pc_imem;
		MEMORY: imem_forwarded_data = readdata_imem;
		default:imem_forwarded_data = 0;
	endcase
end

always_comb
begin
	case(forwarda_id)
		NO_FORWARD: rs1_forwarded_id = rs1_id;
		FORWARD_IMEM: rs1_forwarded_id = imem_forwarded_data;
		FORWARD_IWB: rs1_forwarded_id = write_back_data;
		default:rs1_forwarded_id = 0;
	endcase
	case(forwardb_id)
		NO_FORWARD: rs2_forwarded_id = rs2_id;
		FORWARD_IMEM: rs2_forwarded_id = imem_forwarded_data;
		FORWARD_IWB: rs2_forwarded_id = write_back_data;
		default:rs2_forwarded_id = 0;
	endcase
	case(forwardc_id)
		NO_FORWARD: rs3_forwarded_id = rs3_id;
		FORWARD_IMEM: rs3_forwarded_id = imem_forwarded_data;
		FORWARD_IWB: rs3_forwarded_id = write_back_data;
		default:rs3_forwarded_id = 0;
	endcase
end
//stall unit
stall_line stall_line_inst
(
    .ctrl_bus_if_id_i	(ctrl_bus_if_id),
    .ctrl_bus_ie_i		(ctrl_bus_ie),
    .ctrl_bus_imem_i	(ctrl_bus_imem),
    .insert_bubble_o	(insert_bubble)
);

// ── Phase 3 (post branch-in-IE move): branch_comp and branch_target ─
// are now instantiated DOWN at the IE stage (after the IE-stage
// forwarding logic computes opA/opB_forwarded_data). See the comment
// block near branch_comp_inst around line ~1145.
//
// This eliminates the load-use bubble for branches (the legacy
// stall_line generated 1 or 2 stalls because the branch was reading
// rs1_forwarded_id at the ID stage). With branch in IE the regular
// IE-stage forwarding (FORWARD_IMEM / FORWARD_IWB) provides the
// values for free. Branch penalty becomes 2 cycles (was 1) — accepted
// trade for the BPU revamp.
imm_gen imm_gen_inst
(
  .instruction_i	(instruction_pipe),
  .imm_sel_i		  (ctrl_bus_if_id.imm_sel),
  .imm_o			    (imm_id)
);

//interrupt and exception controller
interrupt_ctrl interrupt_ctrl_inst
(
	.clk_i              (clk_i),
  .rst_i              (reset_i),
  // Async interrupt sources
  .ext_itr_i          (ext_itr_i),
  .timer_itr_i        (timer_itr_i),
  .soft_itr_i         (soft_itr_i),
  // CSR state
  .ip_i               (ip_csr),
  .ie_i               (ie_csr),
  .vec_i              (vec_csr),
  .status_i           (status_csr),
  // Program counters
  .pc_id_i            (pc_id),
  .pc_ie_i            (pc_ie),
  .pc_out_i           (pc_out),
  // Privilege and delegation
  .priv_i             (priv_level),
  .medeleg_i          (medeleg),
  .mideleg_i          (mideleg),
  // ID-stage exception sources (raw — gating done inside)
  .ecall_raw_i        (ctrl_bus_if_id.ecall),
  .ebreak_raw_i       (ctrl_bus_if_id.ebreak),
  .illegal_insn_i     (illegal_insn_id),
  .ie_csr_invalid_i   (csr_invalid),
  .insn_valid_id_i    (insn_valid_id),
  .debug_ebreak_i     (dcsr_ebreak),
  .branch_taken_i     (branch_taken_valid),
  // IE-stage signals for misalign detection (done inside)
  .ie_mem_op_i        (ctrl_bus_ie.mem_op),
  .ie_ls_width_i      (ctrl_bus_ie.load_store_width),
  .ie_amo_op_i        (ctrl_bus_ie.amo_op),
  .ie_addr_lsb_i      (alu_result[1:0]),
  .ie_fault_addr_i    (alu_result),
  .amo_in_progress_i  (amo_in_progress),
  // MMU page faults
  .insn_page_fault_i  (mmu_i_fault_r),
  .insn_fault_addr_i  (mmu_i_fault_addr_r),
  // Registered to break combinational loop (d_fault → trap → flush → d_fault).
  // Stale faults during flush are discarded by interrupt_valid priority clear.
  .data_page_fault_i  (mmu_d_fault_r),
  .data_fault_is_store_i(mmu_d_fault_is_store_r),  // Bug 30: use registered flag
  .data_fault_addr_i  (mmu_d_fault_addr_r),
  // PMP access faults
  .insn_access_fault_i       (mmu_i_access_fault_r),
  .insn_access_fault_addr_i  (mmu_i_access_fault_addr_r),
  // Use registered version to break combinational loop:
  // d_pmp_fault → trap_valid → interrupt_valid → flush_i → settles wrong.
  // Registered path — IE stall holds the faulting instruction for 1 cycle
  .data_access_fault_i       (mmu_d_access_fault_r),
  .data_access_fault_is_store_i(mmu_d_fault_is_store_r),  // Bug 30: use registered flag
  .data_access_fault_addr_i  (mmu_d_access_fault_addr_r),
  // Outputs
  .trap_valid_o       (trap_true),
  .async_trap_o       (async_trap),
  .trap_to_s_o        (trap_to_s),
  .handler_addr_o     (handler_addr),
  .ecause_o           (ecause_csr),
  .epc_o              (epc_csr),
  .mtval_o            (mtval_csr),
  .interrupt_src_o    (interrupt_src),
  .exception_from_ie_o(exception_from_ie),
  // Phase 4 trap revamp: level-signal interrupt outputs for wb_trap_unit
  .interrupt_pending_o(interrupt_pending),
  .interrupt_cause_o  (interrupt_cause),
  .interrupt_to_s_o   (interrupt_to_s_lvl)
);

// ============================================================
// EXECUTE STAGE (IE)
// ============================================================
//reg wall ID/IE
always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i) begin
			ctrl_bus_ie <= CTRL_BUS_NOP();
			pc_ie <= 0;
			imm_ie <= 0;
			rs1_forwarded_ie <= 0;
			rs2_forwarded_ie <= 0;
			rs3_forwarded_ie <= 0;
			c_valid_ie <= FALSE;
			stale_ie <= 1'b0;
			predicted_pc_ie <= 0;
			predicted_target_ie <= 0;
		end
		else if(ie_flush || interrupt_valid) begin
			ctrl_bus_ie <= CTRL_BUS_NOP();
			pc_ie <= 0;
			imm_ie <= 0;
			rs1_forwarded_ie <= 0;
			rs2_forwarded_ie <= 0;
			rs3_forwarded_ie <= 0;
			c_valid_ie <= FALSE;
			stale_ie <= 1'b0;
			predicted_pc_ie <= 0;
			predicted_target_ie <= 0;
		end
		else if(!ie_stall && aligner_valid) begin
			// Phase 4.8: a fault marker from the fetch_buffer (an entry
			// whose imem.req faulted on PMP) emerges here as
			// `aligner_fault=1`. The decoder reads the (garbage) word
			// and produces an arbitrary ctrl_bus_if_id; we MUST NOT
			// let that arbitrary instruction execute. Capture NOP
			// instead, and rely on i_buf_access_fault → trap_sequencer
			// (declared near the trap_sequencer instantiation) to fire
			// the actual sync trap one cycle later. pc_ie is left at
			// the faulting PC for trace fidelity; the trap's epc comes
			// from i_access_fault_addr_r (= aligner_pc_id at latch
			// time) so the value of pc_ie doesn't reach the CSR.
			// Phase 4.8: NOP on aligner_fault (buffer-routed PMP/page fault)
			// Phase 4.9+: NOP on xret_draining (wrong-path speculative
			//   instructions after mret/sret, before it commits at IWB)
			ctrl_bus_ie <= (aligner_fault || xret_draining) ? CTRL_BUS_NOP() : ctrl_bus_if_id;
			pc_ie <= pc_id;
			imm_ie <= imm_id;
			rs1_forwarded_ie <= rs1_forwarded_id;
			rs2_forwarded_ie <= rs2_forwarded_id;
			rs3_forwarded_ie <= rs3_forwarded_id;
			predicted_pc_ie <= predicted_pc_id;
			predicted_target_ie <= predicted_target_id;
			c_valid_ie <= c_valid;
			stale_ie <= stale_id;
		end
		else if(!ie_stall && !aligner_valid) begin
			// Phase 3 (branch-in-IE): the aligner has nothing to emit
			// this cycle (buffer empty after a redirect, or waiting for
			// a straddled-32-bit's second word). Inject a NOP into IE
			// instead of holding the previous IE value. Holding would
			// cause the previous instruction to be executed twice when
			// downstream stages advance — particularly bad if it was a
			// branch (the redirect would re-fire) or a CSR write (would
			// double-update).
			ctrl_bus_ie <= CTRL_BUS_NOP();
			pc_ie <= 0;
			imm_ie <= 0;
			rs1_forwarded_ie <= 0;
			rs2_forwarded_ie <= 0;
			rs3_forwarded_ie <= 0;
			c_valid_ie <= FALSE;
			stale_ie <= 1'b0;
			predicted_pc_ie <= 0;
			predicted_target_ie <= 0;
		end
		else begin
			// During a real IE stall (load in flight, AMO, MMU PTW etc.),
			// the IE pipeline registers are frozen but forwarding sources
			// (IMEM/IWB) continue to advance. If the instruction currently
			// in IE has a forwarding dependency on a source that is about
			// to leave the pipeline, capture the forwarded value now so it
			// is not lost. Without this, a store whose rs2 source completes
			// IWB while the store itself is stuck in IE (e.g. DTLB miss)
			// would write stale data.
			if (forwarda_ie == FORWARD_IWB)
				rs1_forwarded_ie <= write_back_data;
			else if (forwarda_ie == FORWARD_IMEM)
				rs1_forwarded_ie <= imem_forwarded_data;
			if (forwardb_ie == FORWARD_IWB)
				rs2_forwarded_ie <= write_back_data;
			else if (forwardb_ie == FORWARD_IMEM)
				rs2_forwarded_ie <= imem_forwarded_data;
			if (forwardc_ie == FORWARD_IWB)
				rs3_forwarded_ie <= write_back_data;
			else if (forwardc_ie == FORWARD_IMEM)
				rs3_forwarded_ie <= imem_forwarded_data;
		end
	end

//execute stage

//forwarding
forwarding_logic forwarding_logic_ie_inst
(
	.rs1_i			    (ctrl_bus_ie.rs1_int),
	.rs2_i			    (ctrl_bus_ie.rs2_int),
	.rs1_float_i	  (ctrl_bus_ie.rs1_float),
	.rs2_float_i	  (ctrl_bus_ie.rs2_float),
	.rs3_float_i	  (ctrl_bus_ie.rs3_float),
	.rd_mem_i		    (ctrl_bus_imem.rd_int), 
	.rd_wb_i		    (ctrl_bus_iwb.rd_int),
	.rd_float_mem_i	(ctrl_bus_imem.rd_float), 
	.rd_float_wb_i	(ctrl_bus_iwb.rd_float),
	.wb_mem_i		    (ctrl_bus_imem.wb_sel), 
	.wb_wb_i		    (ctrl_bus_iwb.wb_sel),
	.forwarda_id_o	(forwarda_ie),
	.forwardb_id_o	(forwardb_ie),
	.forwardc_id_o	(forwardc_ie)
);
always_comb
begin
	case(forwarda_ie)
		NO_FORWARD: opA_forwarded_data = rs1_forwarded_ie;
		FORWARD_IMEM: opA_forwarded_data = imem_forwarded_data;
		FORWARD_IWB: opA_forwarded_data = write_back_data;
		default: opA_forwarded_data = 0;
	endcase

	case(forwardb_ie)
		NO_FORWARD: opB_forwarded_data = rs2_forwarded_ie;
		FORWARD_IMEM: opB_forwarded_data = imem_forwarded_data;
		FORWARD_IWB: opB_forwarded_data = write_back_data;
		default: opB_forwarded_data = 0;
	endcase

	case(forwardc_ie)
		NO_FORWARD: opC_forwarded_data = rs3_forwarded_ie;
		FORWARD_IMEM: opC_forwarded_data = imem_forwarded_data;
		FORWARD_IWB: opC_forwarded_data = write_back_data;
		default: opC_forwarded_data = 0;
	endcase
end

// ── Phase 3 (branch-in-IE): branch_comp + branch_target_address ───────
// MOVED HERE FROM THE ID STAGE.
//
// Why: with the registered fetch buffer (Phase 3) the producer pipe is
// 1 cycle longer, which broke the legacy stall_line interaction with
// the load-use hazard for branches. The legacy needed up to 2 stall
// cycles to wait for a load value to reach a forwarding source readable
// from the ID stage (where branch_comp lived). Phase 3's wait windows
// shifted, leading to incorrect branch_target computation from stale
// forwarded operands AND a chicken-and-egg fight between insert_bubble
// and the arb_redirect_valid PC-stall bypass.
//
// Solution: resolve the branch in IE instead of ID. The IE-stage
// forwarding network (forwarda_ie/forwardb_ie via opA/opB_forwarded_data)
// already handles all hazards correctly because it's the same network
// the ALU uses, which has been correct in legacy for years.
//
// Cost: branch penalty 1 → 2 cycles. Accepted because BPU work in
// project_core_revamp_plan.md will amortize this. The eventual BPU
// makes "branch in ID" pointless anyway since prediction subsumes the
// 1-cycle gain.
//
// Cleanup that follows from this move:
//   - stall_line.br_true cases are dead (removed)
//   - the insert_bubble guard on the arb_redirect_valid PC-stall
//     bypass is dead (removed)
//   - the bpu_mispredict expression now uses ctrl_bus_ie.predicted_taken
//     (was ctrl_bus_if_id.predicted_taken)
branch_comp branch_comp_inst
(
	.a_i			      (opA_forwarded_data),
	.b_i			      (opB_forwarded_data),
	.br_cond_i		  (ctrl_bus_ie.br_cond),
	.opcode_i		    (ctrl_bus_ie.inst_type),
	.branch_taken_o	(branch_taken)
);
branch_target_address branch_target_address_inst
(
	.pc_i		  (pc_ie),
	.rs1_i		(opA_forwarded_data),
	.imm_i		(imm_ie),
	.opcode_i	(ctrl_bus_ie.inst_type),
	.target_o	(branch_target_address)
);

// ── BPU — IF-stage prediction (per-half, registered redirect) + ID fallback + RAS ──
//
// The BPU reads combinationally at i_vaddr and i_vaddr+2 (the fetch
// address being presented to the I-cache this cycle). The redirect
// fires from a REGISTERED output one cycle later to break the
// combinational loop: i_vaddr → BPU → pc_sel → pc_in → i_vaddr.
//
// Timing (non-straddle branch at address P):
//   Cycle N  : i_vaddr=P, imem_req(P), BPU predicts taken→T. Registered.
//   Cycle N+1: bpu_if_redirect_fire_q=1, pc_sel=BPU_IF, pc_in=T.
//              i_vaddr=T (skipping P+4 which would be wrong-path).
//              The branch's own word (P) was already fetched in cycle N
//              and enters the buffer on rvalid — no flush needed.
//
// Straddle (32-bit branch at upper half): needs TWO words before decode.
//   Cycle N  : i_vaddr=P, BPU predicts upper-half straddle→T. Registered.
//   Cycle N+1: HOLD redirect (straddle_pending). i_vaddr=P+4 (normal advance).
//   Cycle N+2: straddle fires. pc_sel=BPU_IF, pc_in=T.
//
// Per-half predictions are latched into inflight_pred_*_q at imem.req
// time and ride into the fetch_buffer entry. The aligner fires prediction
// on the correct half via lo_consumed_q/hi_consumed_q.
wire        bpu_if_pred_taken;          // Port A: ID-stage read at pc_id
wire        bpu_if_pred_valid;
wire [31:0] bpu_if_pred_target;
wire        bpu_if_pred_is_compressed;  // unused at ID stage

// Port B — IF-stage lower half (vaddr+0)
wire        bpu_if_lo_taken;
wire        bpu_if_lo_valid;
wire [31:0] bpu_if_lo_target;
wire        bpu_if_lo_is_comp;

// Port C — IF-stage upper half (vaddr+2)
wire        bpu_if_hi_taken;
wire        bpu_if_hi_valid;
wire [31:0] bpu_if_hi_target;
wire        bpu_if_hi_is_comp;

// BPU IF reads at the TWO HALVES of the WORD being fetched (always
// word-aligned), regardless of i_vaddr[1]. The entry stored in the
// fetch_buffer is word-aligned (fb_push_entry.vaddr = inflight_vaddr_q
// rounded to word), so the per-half predictions (pred_lo at vaddr+0,
// pred_hi at vaddr+2) must match the word's halves.
//
// BUG (2026-04-20, Dhrystone "IInt_Glob" corruption root cause):
//   The old version read at (i_vaddr, i_vaddr+2). When i_vaddr was
//   half-aligned (e.g., i_vaddr=0x...c16 after a redirect to an
//   upper-half target), port B read at 0xc16 (upper half of word
//   0xc14) and port C read at 0xc18 (lower half of NEXT word 0xc18).
//   The entry at 0xc14 then stored pred_hi_taken = port C fire, but
//   port C was predicting a branch in word 0xc18 — not in word 0xc14.
//   The aligner fired pred_taken on the mv at 0xc16, triggering the
//   ID-stage mispredict path spuriously.
wire [31:0] bpu_if_word_aligned = {i_vaddr[31:2], 2'b00};
wire [31:0] bpu_if_pc_lo = bpu_if_word_aligned;                 // vaddr+0
wire [31:0] bpu_if_pc_hi = bpu_if_word_aligned | 32'd2;         // vaddr+2

// Raw fire: BPU hit + predicted taken (combinational, NOT used for redirect)
wire lo_fire_raw = bpu_if_lo_valid && bpu_if_lo_taken;
wire hi_fire_raw = bpu_if_hi_valid && bpu_if_hi_taken;

// When i_vaddr[1]=1 (half-aligned redirect target), the lower half's
// instruction is skipped by the aligner (it starts at half_index=1).
// So no need to predict for the lower half — the prediction would
// never fire at the aligner.
wire lo_fire = lo_fire_raw && (i_vaddr[1] == 1'b0);
wire hi_fire = hi_fire_raw;

// Program order: lo beats hi (lo executes first).
// The post-branch wrong-path emit bug (2026-04-20 Dhrystone corruption)
// is fixed in compressed_aligner.sv via the squash FSM: on a predicted-
// taken branch emit, the aligner drains the fetch_buffer without emitting
// until an entry matching the predicted target vaddr appears.
wire pick_lo = lo_fire;
wire pick_hi = !lo_fire && hi_fire;

// Straddle: 32-bit branch starting at upper half spans into next word.
wire hi_is_straddle = pick_hi && !bpu_if_hi_is_comp;

// Pick a winner for the combinational prediction (for inflight latches).
wire        if_any_fire      = pick_lo || pick_hi;
wire [31:0] if_pick_target   = pick_lo ? bpu_if_lo_target : bpu_if_hi_target;

// ── Registered redirect FSM (one-at-a-time policy) ─────────────────────
// States:
//   IDLE           — no pending IF-stage prediction.
//   FIRE           — prediction registered; fire redirect this cycle.
//   STRADDLE_WAIT  — straddle prediction; wait 1 cycle for tail word.
//
// bpu_if_pending_q: set when FIRE fires (prediction enters pipeline).
// Cleared when a branch resolves at IE (bpu_bht_train_en) or a higher-
// priority redirect overrides. While pending=1, the FSM stays in IDLE —
// no new IF prediction can fire until the pipeline has made forward
// progress. This prevents the infinite redirect loop that caused PMP/
// trap test hangs: the BPU must wait for IE to validate (or invalidate)
// the current prediction before issuing the next one.
localparam [1:0] BPU_IF_IDLE          = 2'd0,
                 BPU_IF_FIRE          = 2'd1,
                 BPU_IF_STRADDLE_WAIT = 2'd2;

logic [1:0]  bpu_if_state_q;
logic [31:0] bpu_if_target_q;
logic        bpu_if_pending_q;

wire hp_redirect = arb_redirect_valid && arb_redirect_kind != RDR_BPU_IF;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        bpu_if_state_q   <= BPU_IF_IDLE;
        bpu_if_target_q  <= 32'b0;
        bpu_if_pending_q <= 1'b0;
    end else begin
        // Pending flag: clear on any CF commit at IE (BRANCH train OR
        // BRANCH-taken/JUMP alloc) or on higher-priority redirect.
        //
        // Using bpu_bht_train_en alone (BRANCH only) was too narrow:
        // after a JAL prediction, pending stayed set until the next
        // BRANCH commit, potentially blocking many subsequent IF-stage
        // predictions. bpu_btb_alloc_en covers JAL (JUMP) commits too,
        // matching the set of instructions the BTB trains on.
        if (hp_redirect)
            bpu_if_pending_q <= 1'b0;
        else if (bpu_bht_train_en || bpu_btb_alloc_en)
            bpu_if_pending_q <= 1'b0;

        // FSM
        if (hp_redirect) begin
            bpu_if_state_q <= BPU_IF_IDLE;
        end else begin
            case (bpu_if_state_q)
                BPU_IF_IDLE: begin
                    // fb_head_valid: don't fire until the pipeline has at
                    // least one buffered instruction from the current path.
                    // After a flush the buffer is empty; this gate prevents
                    // the BPU from redirecting before the first instruction
                    // from the new path has even entered the pipeline.
                    if (if_any_fire && imem_port.req
                        && !arb_redirect_valid && !bpu_if_pending_q
                        && fb_head_valid) begin
                        bpu_if_target_q <= if_pick_target;
                        bpu_if_state_q  <= hi_is_straddle ? BPU_IF_STRADDLE_WAIT
                                                          : BPU_IF_FIRE;
                    end
                end
                BPU_IF_FIRE: begin
                    bpu_if_pending_q <= 1'b1;
                    bpu_if_state_q   <= BPU_IF_IDLE;
                end
                BPU_IF_STRADDLE_WAIT: begin
                    if (imem_port.req)
                        bpu_if_state_q <= BPU_IF_FIRE;
                end
                default: bpu_if_state_q <= BPU_IF_IDLE;
            endcase
        end
    end
end

// BPU IF (per-half IF-stage prediction) disabled: with Svadu HW A/D
// updates active, BPU IF speculative fetches interact with the PTW's
// in-flight PTE writeback in a way that corrupts a kernel data load
// (Linux v6.6 hits BUG at drivers/of/address.c:401 — of_match_bus's
// final beqz on the NULL match for the default bus reads as non-NULL,
// loop falls through to BUG()). Disabling BPU IF lets Linux boot all
// the way through kernel init to userspace. CoreMark loses ~1%,
// Dhrystone loses ~4% from this — branch prediction at ID (BHT/BTB,
// kept enabled below) does most of the work.
//
// Pair with the aligner's pred_taken_o tie-off (see compressed_aligner.sv).
wire        bpu_if_redirect_fire   = 1'b0;
wire [31:0] bpu_if_redirect_target = bpu_if_target_q;

// ID-stage prediction: gated on decoded inst_type (BRANCH only).
// Suppress when the aligner is already firing this instruction's IF-stage
// prediction — avoids double redirect on the same branch.
//
// JAL prediction disabled: when BPU fires on a JAL at ID, RDR_BPU is a
// flushing redirect AND the aligner's pop_o is gated by ~if_id_stall.
// If if_id_stall=1 for any reason that cycle (icache_stall, mmu_i_stall,
// etc.), the JAL is NEVER consumed into IE — its ra writeback never
// commits, the callee saves stale ra, and on return jumps to the wrong
// address. Reproduced as Linux init SIGSEGV at 0x95757e50: a glibc
// __libc_malloc → _int_malloc tail-call chain where the inner JAL's ra
// was lost, causing the called function to ret directly to xmalloc's
// bnez with sp 32 bytes off, reading a stale stack slot.
// JAL targets resolve at EX with a 2-cycle penalty — acceptable cost.
wire        bpu_is_branch_id = (ctrl_bus_if_id_raw.inst_type == BRANCH);
wire        bpu_bht_btb_fire = bpu_if_pred_valid
                              && bpu_is_branch_id && bpu_if_pred_taken
                              && insn_valid_id
                              && aligner_valid
                              && !aligner_pred_is_branch;

// Return detection at ID
wire [4:0]  id_rs1 = ctrl_bus_if_id_raw.rs1_int[4:0];
wire [4:0]  id_rd  = ctrl_bus_if_id_raw.rd_int[4:0];
wire        id_rs1_is_ra = (id_rs1 == 5'd1) || (id_rs1 == 5'd5);
wire        id_rd_is_ra  = (id_rd  == 5'd1) || (id_rd  == 5'd5);
wire        is_return_id = (ctrl_bus_if_id_raw.inst_type == JUMP_R)
                        && id_rs1_is_ra && !id_rd_is_ra
                        && insn_valid_id && aligner_valid;

// Call detection at IE
wire [4:0]  ie_rd = ctrl_bus_ie.rd_int[4:0];
wire        ie_rd_is_ra = (ie_rd == 5'd1) || (ie_rd == 5'd5);
wire        is_call_ie = (ctrl_bus_ie.inst_type == JUMP || ctrl_bus_ie.inst_type == JUMP_R)
                      && ie_rd_is_ra && !stale_ie && !ie_stall;

// RAS
wire [31:0] ras_top;
wire        ras_valid;
wire        id_advancing = !ie_stall && aligner_valid;
wire        ras_pop_fire = is_return_id && ras_valid && id_advancing;
wire [31:0] ras_push_addr = pc_ie + (c_valid_ie == TRUE ? 32'd2 : 32'd4);
ras ras_inst (
	.clk_i(clk_i), .reset_i(reset_i),
	.push_i(is_call_ie), .push_addr_i(ras_push_addr),
	.pop_i(ras_pop_fire), .top_o(ras_top), .valid_o(ras_valid)
);

// ID-stage redirect: BHT/BTB only.
// RAS pop-fire disabled (Linux-boot regression): ras_pop_fire firing the
// redirect somehow pollutes ITLB/PTW state and breaks the kernel's first
// csrw satp transition (instruction page fault at c0001058). RAS push/pop
// logic still runs (no harm), it just doesn't drive the pipeline redirect.
wire        bpu_redirect_fire   = bpu_bht_btb_fire;
wire [31:0] bpu_redirect_target = bpu_if_pred_target;

// Training at IE
wire        bpu_bht_train_en  = (ctrl_bus_ie.inst_type == BRANCH) && !stale_ie && !ie_stall;
wire        bpu_btb_alloc_en  = ((ctrl_bus_ie.inst_type == BRANCH && branch_taken == TRUE)
                              || (ctrl_bus_ie.inst_type == JUMP))
                              && !stale_ie && !ie_stall;
// Per-half inflight latches: capture IF-stage predictions at imem.req so
// they ride the fetch into the buffer entry that arrives on rvalid.
//
// Gated by bpu_if_latch_en: only the ONE fetch whose prediction the FSM
// accepted carries prediction data. All other fetches get pred_*_taken=0
// so phantom predictions never leak into buffer entries.
wire bpu_if_latch_en = (bpu_if_state_q == BPU_IF_IDLE)
                     && if_any_fire && imem_port.req
                     && !arb_redirect_valid && !bpu_if_pending_q
                     && fb_head_valid;

logic        inflight_pred_lo_taken_q, inflight_pred_hi_taken_q;
logic [31:0] inflight_pred_lo_target_q, inflight_pred_hi_target_q;
always_ff @(posedge clk_i) begin
    if (imem_port.req) begin
        inflight_pred_lo_taken_q  <= bpu_if_latch_en ? pick_lo : 1'b0;
        inflight_pred_hi_taken_q  <= bpu_if_latch_en ? pick_hi : 1'b0;
        inflight_pred_lo_target_q <= bpu_if_lo_target;
        inflight_pred_hi_target_q <= bpu_if_hi_target;
    end
end

wire        bpu_btb_is_uncond     = (ctrl_bus_ie.inst_type == JUMP);
wire        bpu_btb_is_compressed = (c_valid_ie == TRUE);
bpu bpu_inst (
	.clk_i(clk_i), .reset_i(reset_i),
	// Port A — ID-stage
	.pc_id_i             (pc_id),
	.pred_taken_o        (bpu_if_pred_taken),
	.pred_valid_o        (bpu_if_pred_valid),
	.pred_target_o       (bpu_if_pred_target),
	.pred_is_compressed_o(bpu_if_pred_is_compressed),
	// Port B — IF-stage lower half
	.if_lo_pc_i                 (bpu_if_pc_lo),
	.if_lo_pred_taken_o         (bpu_if_lo_taken),
	.if_lo_pred_valid_o         (bpu_if_lo_valid),
	.if_lo_pred_target_o        (bpu_if_lo_target),
	.if_lo_pred_is_compressed_o (bpu_if_lo_is_comp),
	// Port C — IF-stage upper half
	.if_hi_pc_i                 (bpu_if_pc_hi),
	.if_hi_pred_taken_o         (bpu_if_hi_taken),
	.if_hi_pred_valid_o         (bpu_if_hi_valid),
	.if_hi_pred_target_o        (bpu_if_hi_target),
	.if_hi_pred_is_compressed_o (bpu_if_hi_is_comp),
	// Update port — IE stage
	.update_en_i(bpu_bht_train_en), .update_pc_i(pc_ie),
	.update_taken_i(branch_taken == TRUE), .update_target_i(branch_target_address),
	.update_btb_alloc_i(bpu_btb_alloc_en),
	.update_is_uncond_i(bpu_btb_is_uncond),
	.update_is_compressed_i(bpu_btb_is_compressed)
);

always_comb
begin
	case(ctrl_bus_ie.operand_a)
		PC: alu_operand_a = pc_ie;
		REGISTER: alu_operand_a = opA_forwarded_data;
		default: alu_operand_a = 0;
	endcase

	case(ctrl_bus_ie.operand_b)
		IMM: alu_operand_b = imm_ie;
		REGISTER: alu_operand_b = opB_forwarded_data;
		default: alu_operand_b = 0;
	endcase

	case(ctrl_bus_ie.operand_c)
		IMM: alu_operand_c = imm_ie;
		REGISTER: alu_operand_c = opC_forwarded_data;
		default: alu_operand_c = 0;
	endcase
end

csr_unit csr_unit_inst
(
	.clk_i					      (clk_i),
  .reset_i				      (reset_i),
	.mtime_i				      (mtime_i),
	.stop_counters_i	  	(onebit_sig_e'(dcsr_stopcount & halted_o)),
	.float_valid_i			  (onebit_sig_e'(ctrl_bus_ie.float_op != NO_FP_OP && alu_stall == FALSE)),
	.roundmode_o			    (frm),
	.float_status_i			  (float_status),
  .csr_instret_trigger_i(onebit_sig_e'(ctrl_bus_ie.inst_type != NO_INS)),
	// Let CSR writes complete — interrupts fire after instruction commits.
	// (Ibex: "interrupts taken as soon as whatever instruction in ID finishes")
	.csr_cmd_i				    (ctrl_bus_ie.csr_op),
	.csr_use_immediate_i	(ctrl_bus_ie.csr_use_immediate),
	.csr_addr_i				    (dbg_rf_override? csr_reg_e'(ar_ad_i[11:0]) : ctrl_bus_ie.csr_addr),
	.imm_i					      (imm_ie),
	.reg_i					      (opA_forwarded_data),
	.csr_value_o			    (csr_result),
	.csr_invalid_o        (csr_invalid),

  //trap signals (interrupts + exceptions)
  .trap_valid_i         (interrupt_valid),
  .trap_to_s_i          (trap_to_s),
  .ecause_i             (ecause_csr),
  .epc_i                (epc_csr),
  .mtval_i              (mtval_csr),
  .interrupt_src_i      (interrupt_src),
  // Phase 4.3: xRET commits at IWB via wb_trap_unit. ret_fire/sret_fire
  // from privilege_unit (ID-stage) are no longer used as commit pulses;
  // they will be deleted in the Phase 4 cleanup pass once nothing else
  // depends on them.
  .ret_i                (wb_xret_fire && (ctrl_bus_iwb.mret == TRUE)),
  .sret_i               (wb_xret_fire && (ctrl_bus_iwb.sret == TRUE)),

  .ip_o                 (ip_csr),
  .ie_o                 (ie_csr),
  .vec_o                (vec_csr),
  .mtvec_o              (mtvec_csr),
  .stvec_o              (stvec_csr),
  .status_o             (status_csr),
  .epc_o                (epc),
  .sepc_o               (sepc),
  .priv_o               (priv_level),
  .medeleg_o            (medeleg),
  .mideleg_o            (mideleg),
  .satp_o               (satp_csr),
  .menvcfg_adue_o       (menvcfg_adue),
  .pmpcfg_o             (pmpcfg_csr),
  .pmpaddr_o            (pmpaddr_csr)
);

// ═══════════════════════════════════════════════════════════════════════════
// Phase 4 trap revamp: wb_trap_unit (parallel/observe-only in Phase 4.2)
// ═══════════════════════════════════════════════════════════════════════════
// Resolves traps, interrupts and mret/sret/dret atomically at the IWB
// stage. In Phase 4.2 the unit is instantiated and its outputs are
// computed but NOT yet driving the redirect_arbiter or csr_unit — those
// stay on the legacy interrupt_ctrl/privilege_unit path. Phase 4.3 cuts
// the trap path over; Phase 4.4 cuts xRET over and deletes csr_ret_hazard.
//
// dpc_i is wired in but Phase 4 hasn't tagged dret yet (it stays on the
// existing debug_ctrl path), so wb_dret_fire is permanently 0 for now.
wb_trap_unit wb_trap_unit_inst (
    .clk_i               (clk_i),
    .reset_i             (reset_i),

    .ctrl_bus_iwb_i      (ctrl_bus_iwb),
    .pc_iwb_i            (pc_iwb),
    .insn_valid_iwb_i    (~stale_iwb),

    .interrupt_pending_i (interrupt_pending),
    .interrupt_cause_i   (interrupt_cause),
    .interrupt_to_s_i    (interrupt_to_s_lvl),

    .mepc_i              (epc),
    .sepc_i              (sepc),
    .dpc_i               (dpc),
    .mtvec_i             (mtvec_csr),
    .stvec_i             (stvec_csr),
    .medeleg_i           (medeleg),
    .priv_i              (priv_level),

    .trap_fire_o         (wb_trap_fire),
    .xret_fire_o         (wb_xret_fire),
    .dret_fire_o         (wb_dret_fire),
    .cause_o             (wb_cause),
    .tval_o              (wb_tval),
    .epc_o               (wb_epc),
    .trap_to_s_o         (wb_trap_to_s),
    .is_async_o          (wb_is_async),
    .redirect_valid_o    (wb_redirect_valid),
    .redirect_target_o   (wb_redirect_target),
    .redirect_kind_o     (wb_redirect_kind),
    .kill_iwb_o          (wb_kill_iwb)
);

// ── Sv32 MMU ─────────────────────────────────────────────────
// mmu_priv (instruction-side privilege with MRET/SRET override) driven by privilege_unit.
mmu_sv32 mmu_inst (
  .clk_i          (clk_i),
  .reset_i        (reset_i),
  .satp_i         (satp_csr),
  .priv_i         (priv_level),   // data-side: always use actual privilege
  .i_priv_i       (mmu_priv),     // instruction-side: overridden on MRET/SRET
  .mstatus_i      (status_csr),
  .menvcfg_adue_i (menvcfg_adue),
  .sfence_i       (ctrl_bus_ie.sfence_vma),
  // MMU PTW abort: traps, branches, and xRET invalidate in-flight PTW
  // (the VA context changes). The xret_fetch_ctrl FSM ensures the
  // flush+flush_prev 2-cycle dead zone passes during XRET_WAIT, so the
  // fresh PTW in XRET_FETCH starts cleanly without a livelock.
  .flush_i        (interrupt_valid | (~if_id_stall & branch_taken_valid) | wb_xret_fire),
  // Instruction translation
  .i_vaddr_i      (i_vaddr),
  .i_req_i        (~reset_i),
  .i_paddr_o      (i_paddr),
  .i_stall_o      (mmu_i_stall),
  .i_fault_o      (mmu_i_fault),
  .i_fault_addr_o (mmu_i_fault_addr),
  // Data translation
  .d_vaddr_i      (d_vaddr_pre),
  .d_req_i        (d_req_for_mmu),
  .d_req_raw_i    (d_req_raw),
  .d_store_i      (d_store_for_mmu),
  .d_paddr_o      (d_paddr),
  .d_stall_o      (mmu_d_stall),
  .d_fault_o      (mmu_d_fault),
  .d_fault_addr_o (mmu_d_fault_addr),
  // PTW memory interface
  .ptw_addr_o     (ptw_addr),
  .ptw_req_o      (ptw_req),
  .ptw_we_o       (ptw_we),
  .ptw_wdata_o    (ptw_wdata),
  .ptw_data_i     (dmem_port.rdata),
  // Read stall: wait for rvalid. Write stall (svadu): wait for ready.
  .ptw_stall_i    (ptw_we ? ~dmem_port.ready :
                   ptw_req ? ~ptw_rvalid : ~dmem_port.ready),
  .ptw_active_o   (ptw_active),
  // PMP
  .pmpcfg_i              (pmpcfg_csr),
  .pmpaddr_i             (pmpaddr_csr),
  .i_access_fault_o      (mmu_i_access_fault),
  .i_access_fault_addr_o (mmu_i_access_fault_addr),
  .d_access_fault_o      (mmu_d_access_fault),
  .d_access_fault_addr_o (mmu_d_access_fault_addr),
  // Phase 4.8: PTW-completion-only fault terms for the buffer-routed
  // i-side fault fix. See big comment near `inflight_i_fault_q`.
  .i_fault_ptw_o            (mmu_i_fault_ptw),
  .i_fault_ptw_addr_o       (mmu_i_fault_ptw_addr),
  .i_access_fault_ptw_o     (mmu_i_access_fault_ptw),
  .i_access_fault_ptw_addr_o(mmu_i_access_fault_ptw_addr)
);

alu alu_inst
(
	.clk_i			    (clk_i),
	.reset_i		    (reset_i),
	.stall_i		    (1'b0),
  .flush_i        (ie_flush),
	.a_i			      (alu_operand_a),
	.b_i			      (alu_operand_b),
	.c_i			      (alu_operand_c),
	.alu_op_i		    (ctrl_bus_ie.alu_op),
	.mul_op_i		    (ctrl_bus_ie.mul_op),
	.bit_op_i		    (ctrl_bus_ie.bit_op),
	.float_op_i		  (ctrl_bus_ie.float_op),
	.roundmode_i	  ((ctrl_bus_ie.roundmode == DYN)? frm : ctrl_bus_ie.roundmode),
	.alu_stall_o	  (alu_stall),
	.result_o		    (alu_result),
	.float_status_o	(float_status)
);
always_comb
begin
	if (ctrl_bus_ie.amo_op != NO_AMO_OP)
		exec_result_ie = amo_result;
	else case(ctrl_bus_ie.exec_result)
		ALU_RES: exec_result_ie = alu_result;
		CSR_RES: exec_result_ie = csr_result;
		default: exec_result_ie = 0;
	endcase
end
//regwall IE/IMEM
always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i) begin
			ctrl_bus_imem <= CTRL_BUS_NOP();
			pc_imem <= 0;
			exec_result_imem <= 0;
			stale_imem <= 1'b0;
		end
		else if(imem_flush) begin
			ctrl_bus_imem <= CTRL_BUS_NOP();
			pc_imem <= 0;
			exec_result_imem <= 0;
			stale_imem <= 1'b0;
		end
		else if(!imem_stall) begin
			ctrl_bus_imem <= ctrl_bus_ie;
			pc_imem <= c_valid_ie? pc_ie + 2 : pc_ie + 4;
			exec_result_imem <= exec_result_ie;
			stale_imem <= stale_ie;
		end
	end

// ============================================================
// MEMORY STAGE (IMEM)
// ============================================================
core2avl core2avl_inst
(
	// core side signals
	.clk_i			    	(clk_i),
	.reset_i		      (reset_i),
	.stall_i			    (FALSE),
	.load_store_width	(dbg_mem_override? load_store_width_e'(am_st_i) :  ctrl_bus_ie.load_store_width),
	.mem_unsigned	  	(dbg_mem_override? FALSE : ctrl_bus_ie.mem_unsigned),
	.mem_op				    (dbg_mem_override? mem_op_e'({1'b0,am_wr_i}) :
	                     exception_from_ie ? NO_MEM_OP : ctrl_bus_ie.mem_op),
	.addr_i			    	(dbg_mem_override? am_ad_i :  alu_result),
	.data2write_i		  (dbg_mem_override? am_di_i :  opB_forwarded_data),
	.data2read_o		  (readdata_imem),
	//avl signals (intermediate, muxed with AMO unit)
	.readdata_i			  (dmem_port.rdata),
	.address_o			  (c2a_address),
	.writedata_o		  (c2a_writedata),
	.byteenable_o		  (c2a_byteenable),
	.read_o				    (c2a_read),
	.write_o			    (c2a_write),
	.misalign_stall_o (misalign_stall)
);

// ── AMO unit ──────────────────────────────────────────────────
amo_unit amo_unit_inst
(
	.clk_i            (clk_i),
	.reset_i          (reset_i),
	.amo_op_i         (ctrl_bus_ie.amo_op),
	.addr_i           (alu_result),
	.rs2_i            (opB_forwarded_data),
	// Only genuine interrupts/traps should abort an AMO start.
	// ie_flush from insert_bubble creates a combinational loop with amo_stall
	// and must NOT suppress the AMO unit's activation.
	.flush_i          (interrupt_valid),
	// DBus
	.dbus_addr_o      (amo_dbus_addr),
	.dbus_byteenable_o(amo_dbus_byteenable),
	.dbus_read_o      (amo_dbus_read),
	.dbus_write_o     (amo_dbus_write),
	.dbus_writedata_o (amo_dbus_writedata),
	.dbus_readdata_i  (dmem_port.rdata),
	.dbus_stall_i     (amo_dbus_read ? ~dmem_port.rvalid : ~dmem_port.ready),
	// Control
	.result_o         (amo_result),
	.stall_o          (amo_stall),
	.active_o         (amo_active),
	.in_progress_o    (amo_in_progress)
);

// D-port mux: PTW > AMO > core data access
// Virtual address before translation (for MMU input)
wire [31:0] d_vaddr_pre = amo_active ? amo_dbus_addr : c2a_address;
assign d_store_for_mmu = amo_active ? amo_dbus_write : c2a_write;
wire d_req_for_mmu = amo_active ? (amo_dbus_read | amo_dbus_write) : (c2a_read | c2a_write);
// Raw data request from pipeline — not gated by exception_from_ie or PMP faults.
// Used by MMU PMP checker to avoid combinational loop through d_req → PMP → trap → suppression → d_req.
wire d_req_raw = amo_active ? (amo_dbus_read | amo_dbus_write) :
                 (ctrl_bus_ie.mem_op != NO_MEM_OP);

// PTW takes over D-port when walking page table; otherwise use translated address
assign dmem_port.addr  = ptw_active ? ptw_addr : d_paddr;
assign dmem_port.be    = ptw_active ? 4'b1111 :
                         amo_active ? amo_dbus_byteenable : c2a_byteenable;
assign dmem_port.req   = ptw_active ? ptw_req :
                         (mmu_d_access_fault || mmu_d_fault) ? 1'b0 :  // PMP/page fault: suppress bus
                         amo_active ? (amo_dbus_read | amo_dbus_write) :
                                      (c2a_read | c2a_write);
assign dmem_port.we    = ptw_active ? ptw_we :
                         (mmu_d_access_fault || mmu_d_fault) ? 1'b0 :  // PMP/page fault: suppress bus
                         amo_active ? amo_dbus_write : c2a_write;
assign dmem_port.wdata = ptw_active ? ptw_wdata :
                         amo_active ? amo_dbus_writedata  : c2a_writedata;

always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i) begin
			ctrl_bus_iwb <= CTRL_BUS_NOP();
			pc_iwb <= 0;
			exec_result_iwb <= 0;
			readdata_iwb <= 0;
			stale_iwb <= 1'b0;
		end
		else if(iwb_flush) begin
			ctrl_bus_iwb <= CTRL_BUS_NOP();
			pc_iwb <= 0;
			exec_result_iwb <= 0;
			readdata_iwb <= 0;
			stale_iwb <= 1'b0;
		end
		else if(!iwb_stall) begin
			ctrl_bus_iwb <= ctrl_bus_imem;
			pc_iwb <= pc_imem;
			exec_result_iwb <= exec_result_imem;
			readdata_iwb <= readdata_imem;
			stale_iwb <= stale_imem;
		end
	end
// ============================================================
// WRITEBACK STAGE (IWB)
// ============================================================
always_comb
begin
	case(ctrl_bus_iwb.wb_sel)
		EXEC: write_back_data = exec_result_iwb;
		MEMORY: write_back_data = readdata_iwb;
		PC_WB: write_back_data = pc_iwb;
		default: write_back_data = 0;
	endcase
end



//tracer
`ifdef DV_DIAG_TRACE
// Minimal pipeline-visible signals for diag tracer (srcB_imem not in DV_TRACER block)
logic [31:0] srcB_imem_diag;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) srcB_imem_diag <= 0;
    else if (!ie_stall) srcB_imem_diag <= opB_forwarded_data;
end
`endif

`ifdef DV_TRACER
logic [31:0] i1,i2,i3;
logic [31:0] pc1;
logic [31:0] pc2;
logic [31:0] pc3;
logic [31:0] srcA_imem,srcA_iwb;
logic [31:0] srcB_imem,srcB_iwb;
logic [31:0] srcC_imem,srcC_iwb;
bit stall_ie_reg;
logic a1;
logic a2;
logic fstat_imem;
logic fstat_iwb;

always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i) begin
		stall_ie_reg <= 0;
		pc1 <= 0; pc2 <= 0; pc3 <= 0;
		i1 <= 0; i2 <= 0; i3 <= 0;
		a1 <= 0; a2 <= 0;
		fstat_imem <= 0; fstat_iwb <= 0;
		srcA_imem <= 0; srcB_imem <= 0; srcC_imem <= 0;
		srcA_iwb <= 0; srcB_iwb <= 0; srcC_iwb <= 0;
	end
	else begin
		stall_ie_reg <= ie_stall;

		if(!ie_stall) begin
			pc1 <= next_instruction_addr;
			i1 <= instruction_pipe;
		end
		if(!imem_stall) begin
			pc2 <= pc1;
			i2 <= i1;
			a1 <= c_valid_ie;
			fstat_imem <= float_status.NV | float_status.DZ | float_status.OF | float_status.UF | float_status.NX;
			if(!stall_ie_reg) begin
				srcA_imem <= opA_forwarded_data;
				srcB_imem <= opB_forwarded_data;
				srcC_imem <= opC_forwarded_data;
			end
		end
		if(!iwb_stall) begin
			pc3 <= pc2;
			i3 <= i2;
			a2 <= a1;
			srcA_iwb <= srcA_imem;
			srcB_iwb <= srcB_imem;
			srcC_iwb <= srcC_imem;
			fstat_iwb <= fstat_imem;
		end
	end
end
tracer tracer_ip (
	.clk_i(clk_i),
	.rst_ni(~reset_i),
	.hart_id_i(1'b0),
	// RVFI as described at https://github.com/SymbioticEDA/riscv-formal/blob/master/docs/rvfi.md
	// The standard interface does not have _i/_o suffixes. For consistency with the standard the
	// signals in this module don't have the suffixes either.
	/*
	input logic [63:0] rvfi_order,                  +
	input logic        rvfi_trap,
	input logic        rvfi_halt,
	input logic        rvfi_intr,
	input logic [ 1:0] rvfi_mode,
	*/
	.rvfi_valid(ctrl_bus_iwb.inst_type != NO_INS),
	.rvfi_insn_t(i3),
	.rvfi_rs1_addr_t(ctrl_bus_iwb.rs1_int == NO_REG? ctrl_bus_iwb.rs1_float : ctrl_bus_iwb.rs1_int),
	.rvfi_rs2_addr_t(ctrl_bus_iwb.rs2_int == NO_REG? ctrl_bus_iwb.rs2_float : ctrl_bus_iwb.rs2_int),
	.rvfi_rs3_addr_t(ctrl_bus_iwb.rs3_int == NO_REG? ctrl_bus_iwb.rs3_float : ctrl_bus_iwb.rs3_int),
	.rvfi_rs1_rdata_t(srcA_iwb),
	.rvfi_rs2_rdata_t(srcB_iwb),
	.rvfi_rs3_rdata_t(srcC_iwb),
	.rvfi_rd_addr_t(ctrl_bus_iwb.rd_int == NO_REG? ctrl_bus_iwb.rd_float : ctrl_bus_iwb.rd_int),
	.rvfi_rd_wdata_t(write_back_data),
	.rvfi_pc_rdata_t(a2? pc_iwb - 2 :pc_iwb - 4 ),
	.rvfi_pc_wdata_t(pc3),
	.rvfi_mem_addr(ctrl_bus_iwb.mem_op != NO_MEM_OP ? exec_result_iwb : 32'h0),
	.rvfi_mem_rmask(ctrl_bus_iwb.mem_op == READ ? 4'hF : 4'h0),
	.rvfi_mem_wmask(ctrl_bus_iwb.mem_op == WRITE ? 4'hF : 4'h0),
	.rvfi_mem_rdata(readdata_iwb),
	.rvfi_mem_wdata(srcB_iwb)
);
`endif

endmodule