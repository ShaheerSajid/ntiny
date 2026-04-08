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
logic [31:0] predicted_pc_ie;      // BPU: fall-through PC flopped into IE
onebit_sig_e interrupt_valid;
onebit_sig_e ret_valid;
onebit_sig_e debug_valid;
ctrl_bus_e ctrl_bus_if_id;
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
logic [31:0] pmpcfg_csr  [4];
logic [31:0] pmpaddr_csr [16];

// MMU signals
logic [31:0] i_paddr, d_paddr;
logic        mmu_i_stall, mmu_d_stall;
logic        mmu_i_fault, mmu_d_fault;
logic [31:0] mmu_i_fault_addr, mmu_d_fault_addr;
logic        mmu_i_access_fault, mmu_d_access_fault;
logic [31:0] mmu_i_access_fault_addr, mmu_d_access_fault_addr;
logic [31:0] ptw_addr;
logic        ptw_req, ptw_active;
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
logic [31:0] mmu_i_fault_addr_r, mmu_d_fault_addr_r;
logic        mmu_i_access_fault_r,      mmu_d_access_fault_r;
logic [31:0] mmu_i_access_fault_addr_r, mmu_d_access_fault_addr_r;

// privilege_unit forward declaration so trap_sequencer can read it
// (privilege_unit_inst is instantiated later in the file)
logic ret_side_effects_done;

trap_sequencer trap_seq_inst (
    .clk_i              (clk_i),
    .reset_i            (reset_i),
    // Pipeline events
    .interrupt_valid_i        (interrupt_valid),
    .ret_valid_i              (ret_valid),
    .sret_i                   (ctrl_bus_if_id.sret == TRUE),
    .ret_side_effects_done_i  (ret_side_effects_done),
    .branch_taken_i           (branch_taken_valid),
    .if_id_stall_i            (if_id_stall),
    .mmu_i_stall_i            (mmu_i_stall),
    // Raw faults from MMU
    .mmu_i_fault_i              (mmu_i_fault),
    .mmu_i_fault_addr_i         (mmu_i_fault_addr),
    .mmu_d_fault_i              (mmu_d_fault),
    .mmu_d_fault_addr_i         (mmu_d_fault_addr),
    .mmu_i_access_fault_i       (mmu_i_access_fault),
    .mmu_i_access_fault_addr_i  (mmu_i_access_fault_addr),
    .mmu_d_access_fault_i       (mmu_d_access_fault),
    .mmu_d_access_fault_addr_i  (mmu_d_access_fault_addr),
    // Registered faults (to interrupt_ctrl)
    .i_fault_r_o                (mmu_i_fault_r),
    .i_fault_addr_r_o           (mmu_i_fault_addr_r),
    .d_fault_r_o                (mmu_d_fault_r),
    .d_fault_addr_r_o           (mmu_d_fault_addr_r),
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
wire csr_ret_hazard;
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
    // Phase 3: aligner-not-ready stall + redirect for branch_squash_q.
    // aligner_valid and arb_redirect_valid are declared later in the
    // file (the fetch_buffer + redirect_arbiter blocks); SystemVerilog
    // forward references inside a single module scope are legal.
    .aligner_valid_i    (aligner_valid),
    .redirect_valid_i   (arb_redirect_valid),
    .exception_from_ie_i(exception_from_ie),
    // Processor state
    .halted_i           (halted_o),
    // CSR ret hazard
    .id_mret_i          (ctrl_bus_if_id.mret),
    .id_sret_i          (ctrl_bus_if_id.sret),
    .illegal_mret_i     (illegal_mret),
    .illegal_sret_i     (illegal_sret),
    .ie_csr_op_i        (ctrl_bus_ie.csr_op),
    .ie_csr_addr_i      (ctrl_bus_ie.csr_addr),
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
    .refetch_after_trap_o(refetch_after_trap),
    // CSR ret hazard
    .csr_ret_hazard_o   (csr_ret_hazard)
);

assign interrupt_valid = onebit_sig_e'(trap_true);
assign debug_valid =  onebit_sig_e'(resumeack_o);

// ── Privilege Unit ──────────────────────────────────────────────────────
// Centralised privilege checks, xRET fire/one-shot, mmu_priv, PLIC protocol.
wire illegal_mret, illegal_sret, illegal_insn_id;
wire csr_invalid;  // unimplemented CSR accessed in IE stage
wire ret_fire, sret_fire;
// `ret_side_effects_done` is forward-declared near the trap_sequencer above.
wire [1:0] mmu_priv;

privilege_unit privilege_unit_inst (
    .clk_i              (clk_i),
    .reset_i            (reset_i),
    // Current privilege state
    .priv_level_i       (priv_level),
    .status_csr_i       (status_csr),
    // Decoded instruction (ID stage)
    .id_mret_i          (ctrl_bus_if_id.mret),
    .id_sret_i          (ctrl_bus_if_id.sret),
    .id_sfence_vma_i    (ctrl_bus_if_id.sfence_vma),
    .id_csr_op_i        (ctrl_bus_if_id.csr_op),
    .id_csr_addr_i      (ctrl_bus_if_id.csr_addr),
    // Pipeline state
    .insn_valid_id_i    (insn_valid_id),
    .csr_ret_hazard_i   (csr_ret_hazard),
    .ie_stall_i         (ie_stall),
    .interrupt_valid_i  (interrupt_valid),
    // Illegal instruction outputs
    .illegal_mret_o     (illegal_mret),
    .illegal_sret_o     (illegal_sret),
    .illegal_insn_id_o  (illegal_insn_id),
    // Return instruction control
    .ret_valid_o        (ret_valid),
    .ret_fire_o         (ret_fire),
    .sret_fire_o        (sret_fire),
    .ret_side_effects_done_o(ret_side_effects_done),
    // MMU privilege
    .mmu_priv_o         (mmu_priv)
);

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
assign bpu_mispredict = onebit_sig_e'(branch_taken != ctrl_bus_ie.predicted_taken);

wire branch_taken_valid = bpu_mispredict;  // redirect on mispredict, not raw branch_taken
wire ret_valid_valid    = ret_valid;

always_comb
begin
	// Priority: debug > interrupt/trap > branch > ret > PC+4
	if (debug_valid)             pc_sel = BRANCH_DPC;
	else if (interrupt_valid)    pc_sel = INTERRUPT;
	else if (branch_taken_valid) pc_sel = BRANCH_PC;
	else if (ret_valid_valid)    pc_sel = RET;
	else                         pc_sel = PC_plus_4;
end
always_comb
begin
	case(pc_sel)
		PC_plus_4: pc_in = pc_out + 4;
		BRANCH_PC: pc_in = branch_target_address;
    INTERRUPT: pc_in = handler_addr;
    RET      : pc_in = (ctrl_bus_if_id.sret == TRUE) ? sepc : epc;
		BRANCH_DPC:pc_in = dpc;
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
    .sret_select_i   (ctrl_bus_if_id.sret == TRUE),

    .handler_addr_i  (handler_addr),
    .branch_target_i (branch_target_address),
    .sepc_i          (sepc),
    .mepc_i          (epc),
    .dpc_i           (dpc),

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
wire ret_pulse = ret_fire | sret_fire;

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
wire fetch_producer_stall = ie_stall | mmu_i_stall | halted_o |
                            csr_ret_hazard | refetch_after_trap |
                            insert_bubble | fetch_stall;

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
	// CRITICAL: the bypass must NOT fire when csr_ret_hazard is
	// asserted. csr_ret_hazard means an mret/sret is in ID while a
	// csrrw mepc/sepc is still in IE — i.e., the RET target value is
	// being WRITTEN this cycle but won't be visible to the redirect
	// path until the next cycle. Without this guard, the program_counter
	// latches pc_in = OLD epc (because mepc reads the pre-write value),
	// causing the mret to jump to the previous trap's epc rather than
	// the freshly-set value.
	//
	// (An earlier draft also gated the bypass by ~insert_bubble for
	// the load-use bubble case. After moving branch resolution to the
	// IE stage, insert_bubble is permanently 0 — the IE-stage forwarding
	// handles the load-use case for branches without any pipeline
	// bubble. That guard is dead and removed.)
	.stall_i	(((interrupt_valid | ret_pulse | arb_redirect_valid) & ~csr_ret_hazard) ? 1'b0 : fetch_producer_stall),
	.pc_in_i	(pc_in),
	.pc_out_o	(pc_out)
);

// refetch_after_trap: use pc_out (= handler_addr, held by the stall) so the
// memory request targets the correct handler address instead of handler_addr+4.
wire [31:0] i_vaddr = (reset_i | insert_bubble | refetch_after_trap) ? pc_out : pc_in;
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
// Same csr_ret_hazard guard as on program_counter.stall_i: don't fire
// the bypass during a csr→ret hazard cycle, because the redirect
// target (mepc/sepc) is being written THIS cycle and reading it
// reads the OLD value.
assign imem_port.req   = refetch_after_trap | (arb_redirect_valid & ~csr_ret_hazard) | ~fetch_producer_stall;
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
wire fetch_flush = arb_redirect_valid;

// inflight_vaddr_q latches i_vaddr on every cycle imem_port.req is
// high. The vaddr register itself has NO reset (so a request issued in
// the very first non-reset cycle is captured even if we're still
// settling out of reset).
logic [31:0] inflight_vaddr_q;
always_ff @(posedge clk_i) begin
    if (imem_port.req)
        inflight_vaddr_q <= i_vaddr;
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
wire fb_push = imem_port.rvalid && !arb_redirect_valid;

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
assign fb_push_entry.fault = 1'b0;  // Phase 3: faults still via legacy mmu_i_fault path
assign fb_push_entry.cause = 5'b0;

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
logic [1:0]                        fb_count;

fetch_buffer #(.DEPTH(2)) fetch_buffer_inst (
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

    .redirect_valid_i    (arb_redirect_valid),
    .redirect_target_i   (arb_redirect_target),

    .instruction_o       (aligner_inst),
    .pc_id_o             (aligner_pc_id),
    .instruction_valid_o (aligner_valid),
    .instruction_fault_o (aligner_fault),
    .instruction_cause_o (aligner_cause),
    .is_compressed_o     (aligner_is_compressed)
);

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
wire fetch_stall = fb_full | ((fb_count == 2'd1) && inflight_q);

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

// ============================================================
// DECODE STAGE (ID)
// ============================================================
decoder decoder_inst
(
  .instruction_i	(instruction_pipe),
	.ctrl_bus_o		    (ctrl_bus_if_id)
);
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
  .data_fault_is_store_i(d_store_for_mmu),
  .data_fault_addr_i  (mmu_d_fault_addr_r),
  // PMP access faults
  .insn_access_fault_i       (mmu_i_access_fault_r),
  .insn_access_fault_addr_i  (mmu_i_access_fault_addr_r),
  // Use registered version to break combinational loop:
  // d_pmp_fault → trap_valid → interrupt_valid → flush_i → settles wrong.
  // Registered path — IE stall holds the faulting instruction for 1 cycle
  .data_access_fault_i       (mmu_d_access_fault_r),
  .data_access_fault_is_store_i(d_store_for_mmu),
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
  .exception_from_ie_o(exception_from_ie)
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
		end
		else if(!ie_stall && aligner_valid) begin
			// Capture a real instruction from the aligner.
			ctrl_bus_ie <= ctrl_bus_if_id;
			pc_ie <= pc_id;
			imm_ie <= imm_id;
			rs1_forwarded_ie <= rs1_forwarded_id;
			rs2_forwarded_ie <= rs2_forwarded_id;
			rs3_forwarded_ie <= rs3_forwarded_id;
			predicted_pc_ie <= predicted_pc_id;
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
  .ret_i                (ret_fire),
  .sret_i               (sret_fire),

  .ip_o                 (ip_csr),
  .ie_o                 (ie_csr),
  .vec_o                (vec_csr),
  .status_o             (status_csr),
  .epc_o                (epc),
  .sepc_o               (sepc),
  .priv_o               (priv_level),
  .medeleg_o            (medeleg),
  .mideleg_o            (mideleg),
  .satp_o               (satp_csr),
  .pmpcfg_o             (pmpcfg_csr),
  .pmpaddr_o            (pmpaddr_csr)
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
  .sfence_i       (ctrl_bus_ie.sfence_vma),
  .flush_i        (interrupt_valid | (~if_id_stall & (branch_taken_valid | ret_valid))),
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
  .ptw_data_i     (dmem_port.rdata),
  .ptw_stall_i    (ptw_req ? ~ptw_rvalid : ~dmem_port.ready),
  .ptw_active_o   (ptw_active),
  // PMP
  .pmpcfg_i              (pmpcfg_csr),
  .pmpaddr_i             (pmpaddr_csr),
  .i_access_fault_o      (mmu_i_access_fault),
  .i_access_fault_addr_o (mmu_i_access_fault_addr),
  .d_access_fault_o      (mmu_d_access_fault),
  .d_access_fault_addr_o (mmu_d_access_fault_addr)
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
assign dmem_port.we    = ptw_active ? 1'b0 :
                         (mmu_d_access_fault || mmu_d_fault) ? 1'b0 :  // PMP/page fault: suppress bus
                         amo_active ? amo_dbus_write : c2a_write;
assign dmem_port.wdata = ptw_active ? 32'b0 :
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