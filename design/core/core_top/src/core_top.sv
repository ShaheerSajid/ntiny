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


  output plic_claim_o,
  output plic_complete_o
);


//reset
ctrl_bus_e ctrl_bus_reset;
assign ctrl_bus_reset.inst_type = NO_INS;
assign ctrl_bus_reset.br_cond = NO_CONDITION;
assign ctrl_bus_reset.load_store_width = NO_WIDTH;
assign ctrl_bus_reset.mem_unsigned = FALSE;
assign ctrl_bus_reset.imm_sel = NO_IMM;
assign ctrl_bus_reset.mem_op = NO_MEM_OP;
assign ctrl_bus_reset.operand_a = NO_OPERAND;
assign ctrl_bus_reset.operand_b = NO_OPERAND;
assign ctrl_bus_reset.operand_c = NO_OPERAND;
assign ctrl_bus_reset.alu_op = NO_ALU_OP;
assign ctrl_bus_reset.csr_op = NO_CSR_OP;
assign ctrl_bus_reset.csr_use_immediate = FALSE;
assign ctrl_bus_reset.csr_addr = NO_CSR_REG;
assign ctrl_bus_reset.mul_op = NO_MUL_OP;
assign ctrl_bus_reset.amo_op = NO_AMO_OP;
assign ctrl_bus_reset.bit_op = NO_BIT_OP;
assign ctrl_bus_reset.float_op = NO_FP_OP;
assign ctrl_bus_reset.roundmode = RNE;
assign ctrl_bus_reset.exec_result = NO_EX_RES;
assign ctrl_bus_reset.rs1_int = NO_REG;
assign ctrl_bus_reset.rs2_int = NO_REG;
assign ctrl_bus_reset.rs3_int = NO_REG;
assign ctrl_bus_reset.rd_int = NO_REG;
assign ctrl_bus_reset.rs1_float = NO_REG;
assign ctrl_bus_reset.rs2_float = NO_REG;
assign ctrl_bus_reset.rs3_float = NO_REG;
assign ctrl_bus_reset.rd_float = NO_REG;
assign ctrl_bus_reset.wb_sel = NO_WB;
assign ctrl_bus_reset.ebreak = FALSE;
assign ctrl_bus_reset.ecall = FALSE;
assign ctrl_bus_reset.mret = FALSE;
assign ctrl_bus_reset.sret = FALSE;
assign ctrl_bus_reset.sfence_vma = FALSE;

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

// MMU signals
logic [31:0] i_paddr, d_paddr;
logic        mmu_i_stall, mmu_d_stall;
logic        mmu_i_fault, mmu_d_fault;
logic [31:0] mmu_i_fault_addr, mmu_d_fault_addr;
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
// Also naturally gives correct priority: data faults from IE (combinational) are processed
// before instruction faults from IF (delayed 1 cycle by register).
logic        mmu_i_fault_r;
logic [31:0] mmu_i_fault_addr_r;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        mmu_i_fault_r      <= 1'b0;
        mmu_i_fault_addr_r <= 32'b0;
    end else if (interrupt_valid) begin
        // Clear when a trap fires (pipeline redirects to handler).
        // Do NOT clear on branch/ret: if the branch/ret TARGET itself faults
        // (e.g., page without A bit), the fault is real and must propagate.
        // Speculative faults (pc+4 past page boundary) are prevented by
        // flush_i aborting the PTW before it reaches FAULT state.
        mmu_i_fault_r      <= 1'b0;
        mmu_i_fault_addr_r <= 32'b0;
    end else begin
        mmu_i_fault_r      <= mmu_i_fault;
        mmu_i_fault_addr_r <= mmu_i_fault_addr;
    end
end

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
logic misalign_load_ie;
logic misalign_store_ie;
logic misalign_amo_ie;
logic exception_from_ie;
////////////////////////////////debug logic//////////////////////////
logic [31:0] dpc;
logic [31:0] dcsr;
dcause_e debug_cause;
onebit_sig_e debug_step;
onebit_sig_e ar_done_r;
onebit_sig_e am_done_r;
onebit_sig_e c_busy;
logic [31:0]next_instruction_addr;
enum logic [1:0] {RUNNING, HALTED, RESUME} pstate, nstate;
always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i)
		pstate <= RUNNING;
	else
		pstate <= nstate;
end
always_comb
begin
	case(pstate)
		RUNNING: nstate = (haltreq_i || (ctrl_bus_if_id.ebreak == TRUE && dcsr[15]) || (debug_step && !c_busy))? HALTED : RUNNING;
		HALTED:	nstate = resumereq_i? RESUME : HALTED;
		RESUME: nstate = resumereq_i? RESUME : RUNNING;
		default: nstate = RUNNING;
	endcase
end
assign resumeack_o = onebit_sig_e'(pstate == RESUME);
assign running_o = onebit_sig_e'(pstate == RUNNING);
assign halted_o = onebit_sig_e'((pstate == HALTED) || (pstate == RESUME));

//dcsr
always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i)
		debug_cause <= NO_DBG_CAUSE;
	else if(pstate == RUNNING && ctrl_bus_if_id.ebreak == TRUE && dcsr[15])
		debug_cause <= DBG_EBREAK;
	else if(pstate == RUNNING && haltreq_i)
		debug_cause <= DBG_HALTREQ;
	else if(pstate == RUNNING && debug_step)
		debug_cause <= DBG_STEP;
end
assign debug_step = onebit_sig_e'(dcsr[2]);
always_ff@(posedge clk_i or posedge reset_i)
begin
		if(reset_i)
			dcsr <= 0;
		else if(ar_en_i && ar_wr_i && (ar_ad_i == 16'h07b0))
			dcsr <= ar_di_i;//add dcsr
end
//dpc
always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i)
		dpc <= 0;
	else if(ar_en_i && ar_wr_i && (ar_ad_i == 16'h07b1)) 
		dpc <= ar_di_i;
	else if(pstate == RUNNING && ctrl_bus_if_id.ebreak == TRUE && dcsr[15])
		dpc <= pc_id;
	else if(pstate == RUNNING && (haltreq_i || debug_step))
		dpc <= next_instruction_addr;
end
//abstract register read logic
always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i) begin
		ar_do_o <= 0;
		ar_done_r <= FALSE;
		am_done_r <= FALSE;
	end
	else begin
		if(ar_ad_i < 32'h1000)
			case(ar_ad_i)
				16'h07b0: ar_do_o <= {4'd4, 12'd0, dcsr[15], 1'b0, dcsr[13:9], debug_cause, 1'b0, dcsr[4], 1'b0, dcsr[2], 2'd3};
				16'h07b1: ar_do_o <= dpc;
				default:  ar_do_o <= csr_result;
			endcase
		else if(ar_ad_i >= 32'h1000 && ar_ad_i <= 32'h101f)
			ar_do_o <= rs1_int;
		else if(ar_ad_i >= 32'h1020 && ar_ad_i <= 32'h103f)
			ar_do_o <= rs1_float;

		ar_done_r <= ar_en_i;
		am_done_r <= onebit_sig_e'(am_en_i & dmem_port.ready);
	end
end
assign am_do_o = readdata_imem;
assign ar_done_o = ar_done_r;
assign am_done_o = am_done_r;
////////////////////////////////////////////

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
    .mmu_i_stall_i      (mmu_i_stall),
    .mmu_d_stall_i      (mmu_d_stall),
    .dmem_req_i         (dmem_port.req),
    .dmem_ready_i       (dmem_port.ready),
    .insert_bubble_i    (insert_bubble),
    // Control flow
    .interrupt_valid_i  (interrupt_valid),
    .resumeack_i        (resumeack_o),
    .exception_from_ie_i(exception_from_ie),
    // Processor state
    .halted_i           (pstate == HALTED),
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
assign ret_valid = onebit_sig_e'(((ctrl_bus_if_id.mret && !illegal_mret) ||
                                  (ctrl_bus_if_id.sret && !illegal_sret)) && insn_valid_id);
assign debug_valid =  onebit_sig_e'(resumeack_o);

// ── Early MRET/SRET commit from ID ──────────────────────────────
// Per RISC-V spec, xRET atomically updates priv + xSTATUS + PC. If the
// instruction fetch at the return target triggers a page fault BEFORE xRET
// reaches IE, the trap must be taken from the post-xRET state (new privilege,
// updated mstatus). We commit the CSR side effects on the first cycle of
// ret_valid using a one-shot flag to prevent re-firing while stalled.
logic ret_side_effects_done;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        ret_side_effects_done <= 1'b0;
    else if (interrupt_valid)
        ret_side_effects_done <= 1'b0;
    else if (ret_valid && !csr_ret_hazard && !ret_side_effects_done)
        ret_side_effects_done <= 1'b1;
    else if (!ret_valid)
        ret_side_effects_done <= 1'b0;
end

wire ret_fire  = ctrl_bus_if_id.mret && insn_valid_id && !illegal_mret &&
                 !ret_side_effects_done && !csr_ret_hazard && !interrupt_valid;
wire sret_fire = ctrl_bus_if_id.sret && insn_valid_id && !illegal_sret &&
                 !ret_side_effects_done && !csr_ret_hazard && !interrupt_valid;

// Misaligned access detection in IE stage
wire [1:0] mem_addr_lsb = alu_result[1:0];
assign misalign_load_ie = (ctrl_bus_ie.mem_op == READ) && (
    (ctrl_bus_ie.load_store_width == HALF && mem_addr_lsb[0]) ||
    (ctrl_bus_ie.load_store_width == WORD && |mem_addr_lsb)
);
assign misalign_store_ie = (ctrl_bus_ie.mem_op == WRITE) && (
    (ctrl_bus_ie.load_store_width == HALF && mem_addr_lsb[0]) ||
    (ctrl_bus_ie.load_store_width == WORD && |mem_addr_lsb)
);
// AMO instructions require word-aligned addresses (cause 6: store/AMO misaligned)
// Only check on the entry cycle (AMO unit in IDLE): once the FSM is running, the
// address is latched inside the AMO unit and alu_result becomes unreliable because
// pipeline flush logic destroys the forwarding sources.
assign misalign_amo_ie = (ctrl_bus_ie.amo_op != NO_AMO_OP) && |mem_addr_lsb && !amo_in_progress;

// Privilege violation detection (ID stage, like ecall/ebreak)
// CSR address[9:8] = minimum privilege level required
logic [11:0] csr_addr_raw_id;
assign csr_addr_raw_id = ctrl_bus_if_id.csr_addr;
wire csr_access = (ctrl_bus_if_id.csr_op == WRITE_CSR) ||
                   (ctrl_bus_if_id.csr_op == SET_CSR) ||
                   (ctrl_bus_if_id.csr_op == CLEAR_CSR);
wire illegal_csr_priv = csr_access && (priv_level < csr_addr_raw_id[9:8]);
// MRET requires M-mode; SRET requires at least S-mode
// Once ret_side_effects_done, the xRET has already committed its CSR side effects
// from ID. Don't flag it as illegal due to the (now-updated) privilege level.
wire illegal_mret = (ctrl_bus_if_id.mret == TRUE) && (priv_level != 2'b11) && !ret_side_effects_done;
wire illegal_sret = (ctrl_bus_if_id.sret == TRUE) && (priv_level < 2'b01) && !ret_side_effects_done;
// TVM enforcement: SATP access or SFENCE.VMA from S-mode when mstatus.TVM=1 → illegal insn
wire tvm_active        = status_csr[20] && (priv_level == 2'b01);
wire illegal_satp_tvm  = tvm_active && csr_access && (csr_addr_raw_id == 12'h180);
wire illegal_sfence_tvm = tvm_active && (ctrl_bus_if_id.sfence_vma == TRUE);
wire illegal_insn_id = illegal_csr_priv | illegal_mret | illegal_sret
                     | illegal_satp_tvm | illegal_sfence_tvm;
assign exception_from_ie = misalign_load_ie | misalign_store_ie | misalign_amo_ie;

//plic drive logic
logic from_plic;
always_ff@(posedge clk_i or posedge reset_i)
begin
	if(reset_i)
		from_plic <= 1'b0;
	else if(plic_claim_o)
		from_plic <= 1'b1;
  else if(plic_complete_o)
    from_plic <= 1'b0;
end

assign plic_complete_o = from_plic & ctrl_bus_if_id.mret & ~illegal_mret;
assign plic_claim_o = ext_itr_i & trap_true;

// Do NOT gate branch_taken with insn_valid_id: after a trap, c_controller delivers
// the first mtvec instruction into ID on the very next cycle (N+1), but insn_valid_id
// is still 0 that cycle (cleared on cycle N). Gating would suppress the JAL redirect,
// causing the CPU to execute handler entry[1] instead of entry[0].
// The IE register flush on interrupt_valid already prevents stale pre-trap effects.
wire branch_taken_valid = branch_taken;
wire ret_valid_valid    = ret_valid;  // already gated with insn_valid_id in assignment

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
// ============================================================
// FETCH STAGE
// ============================================================
`ifdef BOOT
program_counter #(.DEFAULT(32'h00001000)) program_counter_inst
`else
program_counter #(.DEFAULT(32'h80000000)) program_counter_inst
`endif
(
	.clk_i		(clk_i),
	.reset_i	(reset_i),
	.stall_i	(interrupt_valid? 1'b0 : if_id_stall | c_stall),
	.pc_in_i	(pc_in),
	.pc_out_o	(pc_out)
);
// refetch_after_trap: use pc_out (= handler_addr, held by the stall) so the
// memory request targets the correct handler address instead of handler_addr+4.
wire [31:0] i_vaddr = (reset_i | insert_bubble | refetch_after_trap) ? pc_out : pc_in;
assign imem_port.addr  = i_paddr;  // MMU translates i_vaddr → i_paddr
// Force req=1 during refetch: if_id_stall=1 on that cycle (from refetch_after_trap)
// so ~if_id_stall would be 0, but we still need to issue the fetch.
assign imem_port.req   = refetch_after_trap | (~if_id_stall & ~c_stall);
assign imem_port.we    = 1'b0;
assign imem_port.be    = 4'b1111;
assign imem_port.wdata = 32'b0;


//c_extension

//address select logic

logic controller_branch_taken;
logic [31:0] controller_branch_addr;
onebit_sig_e controller_flush;

assign controller_branch_taken = branch_taken_valid | resumeack_o | ret_valid;
assign controller_flush = onebit_sig_e'(resumereq_i | interrupt_valid);
always_comb begin
  casez({branch_taken_valid, ret_valid, resumeack_o})
		3'b100: controller_branch_addr = branch_target_address;
		3'b?10: controller_branch_addr = epc;
		3'b??1: controller_branch_addr = dpc;
		default: controller_branch_addr = 0;
	endcase
end

c_controller c_controller_inst
(
	.clk_i					        (clk_i),
	.reset_i				        (reset_i),
	.stall_i				        (if_id_stall),
  .interrupt_true_i       (interrupt_valid),
	.flush_i				        (controller_flush),
	.pc_sel_i				        (pc_sel),
	.instruction_i			    (reset_i? 0:imem_port.rdata),
	.branch_taken_i			    (onebit_sig_e'(controller_branch_taken)),
	.branch_target_address_i(controller_branch_addr),
  .branch_addr_i          (branch_target_address),
	.dpc_i					        (dpc),
  .handler_addr_i         (handler_addr),
  .epc_i                  (epc),

	.instruction_addr_o		  (pc_id),
	.instruction_o			    (instruction_pipe),
	.next_instruction_addr_o(next_instruction_addr),
	.c_stall_o				      (c_stall),
	.c_valid_o				      (c_valid),
	.busy_o					        (c_busy)
);

//instruction decode stage
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

wire        rf_wr_en   = jalr_fault_wr | (ctrl_bus_iwb.rd_int != NO_REG);
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
	.rdaddra_i	(((pstate==HALTED) & ar_en_i)? ar_ad_i[4:0] : ctrl_bus_if_id.rs1_int[4:0]),
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
		.rdaddra_i	(((pstate==HALTED) & ar_en_i)? ar_ad_i[4:0] : ctrl_bus_if_id.rs1_float[4:0]),
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

always_comb
begin
	case(ctrl_bus_imem.wb_sel)
		EXEC:imem_forwarded_data = exec_result_imem;
		PC_WB:imem_forwarded_data = pc_imem;
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

branch_comp branch_comp_inst
(
	.a_i			      (rs1_forwarded_id),
	.b_i			      (rs2_forwarded_id),
	.br_cond_i		  (ctrl_bus_if_id.br_cond),
	.opcode_i		    (ctrl_bus_if_id.inst_type),
	.branch_taken_o	(branch_taken)
);
branch_target_address branch_target_address_inst
(
	.pc_i		  (pc_id),
	.rs1_i		(rs1_forwarded_id),
	.imm_i		(imm_id),
	.opcode_i	(ctrl_bus_if_id.inst_type),
	.target_o	(branch_target_address)
);
imm_gen imm_gen_inst
(
  .instruction_i	(instruction_pipe),
  .imm_sel_i		  (ctrl_bus_if_id.imm_sel),
  .imm_o			    (imm_id)
);

//interrupt and exception controller
interrupt_ctrl interrupt_ctrl_inst
(
	.clk_i            (clk_i),
  .rst_i            (reset_i),
  //interrupt sources
  .ext_itr_i        (ext_itr_i),
  .timer_itr_i      (timer_itr_i),
  .soft_itr_i       (soft_itr_i),
  //from csr
  .ip_i             (ip_csr),
  .ie_i             (ie_csr),
  .vec_i            (vec_csr),
  .status_i         (status_csr),
  .pc_i             (mmu_i_fault_r ? mmu_i_fault_addr_r : pc_id),
  // privilege and delegation
  .priv_i           (priv_level),
  .medeleg_i        (medeleg),
  .mideleg_i        (mideleg),
  // synchronous exceptions
  .ecall_i          (ctrl_bus_if_id.ecall & ~illegal_insn_id & insn_valid_id),
  .ebreak_i         (ctrl_bus_if_id.ebreak & ~dcsr[15] & ~illegal_insn_id & insn_valid_id),
  .illegal_insn_i   (illegal_insn_id & insn_valid_id),
  .misalign_load_i  (misalign_load_ie),
  .misalign_store_i (misalign_store_ie),
  .misalign_amo_i   (misalign_amo_ie),
  // page faults from MMU (insn fault registered to break combinational loop)
  .insn_page_fault_i  (mmu_i_fault_r),
  .load_page_fault_i  (mmu_d_fault & ~d_store_for_mmu),
  .store_page_fault_i (mmu_d_fault & d_store_for_mmu),
  .page_fault_addr_i  (mmu_d_fault ? mmu_d_fault_addr : mmu_i_fault_addr_r),
  .pc_ie_i          (pc_ie),
  .fault_addr_i     (alu_result),
  //to csr and core
  .trap_valid_o     (trap_true),
  .trap_to_s_o      (trap_to_s),
  .handler_addr_o   (handler_addr),
  .ecause_o         (ecause_csr),
  .epc_o            (epc_csr),
  .mtval_o          (mtval_csr),
  .interrupt_src_o  (interrupt_src)
);

// ============================================================
// EXECUTE STAGE (IE)
// ============================================================
//reg wall ID/IE
always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i) begin
			ctrl_bus_ie <= ctrl_bus_reset;
			pc_ie <= 0;
			imm_ie <= 0;
			rs1_forwarded_ie <= 0;
			rs2_forwarded_ie <= 0;
			rs3_forwarded_ie <= 0;
			c_valid_ie <= FALSE;
			stale_ie <= 1'b0;
		end
		else if(ie_flush || interrupt_valid) begin
			ctrl_bus_ie <= ctrl_bus_reset;
			pc_ie <= 0;
			imm_ie <= 0;
			rs1_forwarded_ie <= 0;
			rs2_forwarded_ie <= 0;
			rs3_forwarded_ie <= 0;
			c_valid_ie <= FALSE;
			stale_ie <= 1'b0;
		end
		else if(!ie_stall) begin
			// When stale_id is set (1 cycle after trap), the instruction in ID is
			// leftover from before the trap redirect. Inject NOP to prevent any
			// side effects (register writes, memory ops, CSR ops) as it flows through.
			ctrl_bus_ie <= stale_id ? ctrl_bus_reset : ctrl_bus_if_id;
			pc_ie <= pc_id;
			imm_ie <= imm_id;
			rs1_forwarded_ie <= rs1_forwarded_id;
			rs2_forwarded_ie <= rs2_forwarded_id;
			rs3_forwarded_ie <= rs3_forwarded_id;
			c_valid_ie <= c_valid;
			stale_ie <= stale_id;
		end
		else begin
			// During a stall the IE pipeline registers are frozen, but forwarding
			// sources (IMEM/IWB) continue to advance.  If the instruction currently
			// in IE has a forwarding dependency on a source that is about to leave
			// the pipeline, capture the forwarded value now so it is not lost.
			// Without this, a store whose rs2 source completes IWB while the store
			// itself is stuck in IE (e.g. DTLB miss) would write stale data.
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
	.stop_counters_i	  	(onebit_sig_e'(dcsr[10] & (pstate==HALTED))),
	.float_valid_i			  (onebit_sig_e'(ctrl_bus_ie.float_op != NO_FP_OP && alu_stall == FALSE)),
	.roundmode_o			    (frm),
	.float_status_i			  (float_status),
  .csr_instret_trigger_i(onebit_sig_e'(ctrl_bus_ie.inst_type != NO_INS)),
	.csr_cmd_i				    (ctrl_bus_ie.csr_op),
	.csr_use_immediate_i	(ctrl_bus_ie.csr_use_immediate),
	.csr_addr_i				    (((pstate==HALTED) & ar_en_i)? csr_reg_e'(ar_ad_i[11:0]) : ctrl_bus_ie.csr_addr),
	.imm_i					      (imm_ie),
	.reg_i					      (opA_forwarded_data),
	.csr_value_o			    (csr_result),

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
  .satp_o               (satp_csr)
);

// ── Sv32 MMU ─────────────────────────────────────────────────
// Use registered priv_level, with a combinational override for MRET/SRET.
// On trap cycles (interrupt_valid), priv is still the old value but the handler
// code is identity-mapped (VA==PA), so M-mode non-translation is correct.
// On MRET/SRET cycles, the fetch address is the return target (mepc/sepc) which
// is in the target privilege's address space. We must use the target privilege
// for translation so the MMU resolves the correct physical address.
// status_csr.MPP[12:11] gives the MRET target; status_csr.SPP[8] gives SRET target.
wire [1:0] ret_target_priv = ctrl_bus_if_id.mret ? status_csr[12:11] :  // MRET: MPP
                                                    {1'b0, status_csr[8]}; // SRET: SPP
// Don't override during csr_ret_hazard: epc is stale, using S-mode privilege
// would cause the MMU to translate a stale address and start a spurious PTW walk.
// After ret_side_effects_done, priv_level is already the target privilege (the
// MRET/SRET CSR side effects committed from ID), so use priv_level directly.
wire [1:0] mmu_priv = (ret_valid && !csr_ret_hazard && !ret_side_effects_done) ? ret_target_priv : priv_level;

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
  .ptw_active_o   (ptw_active)
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
			ctrl_bus_imem <= ctrl_bus_reset;
			pc_imem <= 0;
			exec_result_imem <= 0;
			stale_imem <= 1'b0;
		end
		else if(imem_flush) begin
			ctrl_bus_imem <= ctrl_bus_reset;
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
	.load_store_width	(((pstate==HALTED) & am_en_i)? load_store_width_e'(am_st_i) :  ctrl_bus_ie.load_store_width),
	.mem_unsigned	  	(((pstate==HALTED) & am_en_i)? FALSE : ctrl_bus_ie.mem_unsigned),
	.mem_op				    (((pstate==HALTED) & am_en_i)? mem_op_e'({1'b0,am_wr_i}) :
	                     exception_from_ie ? NO_MEM_OP : ctrl_bus_ie.mem_op),
	.addr_i			    	(((pstate==HALTED) & am_en_i)? am_ad_i :  alu_result),
	.data2write_i		  (((pstate==HALTED) & am_en_i)? am_di_i :  opB_forwarded_data),
	.data2read_o		  (readdata_imem),
	//avl signals (intermediate, muxed with AMO unit)
	.readdata_i			  (dmem_port.rdata),
	.address_o			  (c2a_address),
	.writedata_o		  (c2a_writedata),
	.byteenable_o		  (c2a_byteenable),
	.read_o				    (c2a_read),
	.write_o			    (c2a_write)
);

// ── AMO unit ──────────────────────────────────────────────────
amo_unit amo_unit_inst
(
	.clk_i            (clk_i),
	.reset_i          (reset_i),
	.amo_op_i         (ctrl_bus_ie.amo_op),
	.addr_i           (alu_result),
	.rs2_i            (opB_forwarded_data),
	.flush_i          (ie_flush | interrupt_valid),
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

// PTW takes over D-port when walking page table; otherwise use translated address
assign dmem_port.addr  = ptw_active ? ptw_addr : d_paddr;
assign dmem_port.be    = ptw_active ? 4'b1111 :
                         amo_active ? amo_dbus_byteenable : c2a_byteenable;
assign dmem_port.req   = ptw_active ? ptw_req :
                         amo_active ? (amo_dbus_read | amo_dbus_write) :
                                      (c2a_read | c2a_write);
assign dmem_port.we    = ptw_active ? 1'b0 :
                         amo_active ? amo_dbus_write : c2a_write;
assign dmem_port.wdata = ptw_active ? 32'b0 :
                         amo_active ? amo_dbus_writedata  : c2a_writedata;

always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i) begin
			ctrl_bus_iwb <= ctrl_bus_reset;
			pc_iwb <= 0;
			exec_result_iwb <= 0;
			readdata_iwb <= 0;
			stale_iwb <= 1'b0;
		end
		else if(iwb_flush) begin
			ctrl_bus_iwb <= ctrl_bus_reset;
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