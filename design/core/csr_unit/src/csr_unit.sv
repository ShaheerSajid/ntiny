

import common_pkg::*;
import core_pkg::*;

module csr_unit (
	input clk_i,
  input reset_i,

	input csr_op_e csr_cmd_i,
	input csr_reg_e csr_addr_i,
	input onebit_sig_e csr_use_immediate_i,
	input [31:0] imm_i,
	input [31:0] reg_i,

	input onebit_sig_e csr_instret_trigger_i,
	input onebit_sig_e stop_counters_i,
	input onebit_sig_e float_valid_i,
	output roundmode_e roundmode_o,
	input float_status_e float_status_i,

///////Trap Signals (interrupts + exceptions)
  input trap_valid_i,
  input trap_to_s_i,              // trap delegated to S-mode
  input [31:0]ecause_i,
  input [31:0]epc_i,
  input [31:0]mtval_i,
  input [31:0]interrupt_src_i,
  input ret_i,                    // MRET
  input sret_i,                   // SRET

  output [31:0]ip_o,
  output [31:0]ie_o,
  output [31:0]vec_o,             // mtvec or stvec (selected by trap_to_s_i)
  output [31:0]status_o,
  output [31:0]epc_o,             // mepc (for MRET)
  output [31:0]sepc_o,            // sepc (for SRET)
  output [1:0] priv_o,            // current privilege level
  output [31:0]medeleg_o,
  output [31:0]mideleg_o,
  output [31:0]satp_o,

	output logic [31:0]csr_value_o,
	output logic       csr_invalid_o  // 1 when accessed CSR address is unimplemented
	);

	// ── Privilege masks ──────────────────────────────────────────
	// SSTATUS: writable bits visible through sstatus view of mstatus
`ifdef FPU
	localparam SSTATUS_WMASK = 32'h000C_6122;  // SIE[1], SPIE[5], SPP[8], FS[14:13], SUM[18], MXR[19]
	localparam SSTATUS_RMASK = 32'h800C_6122;  // + SD[31] for reads
	localparam MSTATUS_WMASK = 32'h007E_79AA;  // all writable mstatus bits
`else
	localparam SSTATUS_WMASK = 32'h000C_0122;
	localparam SSTATUS_RMASK = 32'h000C_0122;
	localparam MSTATUS_WMASK = 32'h007E_19AA;
`endif
	// S-mode interrupt bits: SSIE[1], STIE[5], SEIE[9]
	localparam S_INT_MASK = 32'h0000_0222;

	// ── Registers ────────────────────────────────────────────────
	logic [31:0] _MSTATUS;
	logic [31:0] _MIE;
	logic [31:0] _MTVEC;
	logic [31:0] _MEPC;
	logic [31:0] _MCAUSE;
	logic [31:0] _MTVAL;
	logic [31:0] _MSCRATCH;
	logic [31:0] _MIP;
	logic [31:0] _MCYCLE;
	logic [31:0] _MINSTRET;
	logic [31:0] _MCYCLEH;
	logic [31:0] _MINSTRETH;
	logic [31:0] _MCOUNTINHIBIT;
	logic [31:0] _FFLAGS;
	logic [31:0] _FRM;
	// S-mode registers
	logic [31:0] _STVEC;
	logic [31:0] _SSCRATCH;
	logic [31:0] _SEPC;
	logic [31:0] _SCAUSE;
	logic [31:0] _STVAL;
	logic [31:0] _SATP;
	logic [31:0] _MEDELEG;
	logic [31:0] _MIDELEG;
	logic [31:0] _MCOUNTEREN;
	logic [31:0] _SCOUNTEREN;
	// Privilege level (2'b11=M, 2'b01=S, 2'b00=U)
	logic [1:0]  priv_level;

	// ── CSR select logic ─────────────────────────────────────────
	logic MSTATUS_sel, SSTATUS_sel;
	logic MIE_sel, SIE_sel;
	logic MTVEC_sel, STVEC_sel;
	logic MEPC_sel, SEPC_sel;
	logic MCAUSE_sel, SCAUSE_sel;
	logic MTVAL_sel, STVAL_sel;
	logic MSCRATCH_sel, SSCRATCH_sel;
	logic MIP_sel, SIP_sel;
	logic MCYCLE_sel, MINSTRET_sel, MCYCLEH_sel, MINSTRETH_sel;
	logic MCOUNTINHIBIT_sel;
	logic FFLAGS_sel, FRM_sel, FCSR_sel;
	logic SATP_sel;
	logic MEDELEG_sel, MIDELEG_sel;
	logic MCOUNTEREN_sel, SCOUNTEREN_sel;

	assign MSTATUS_sel      = csr_addr_i == MSTATUS;
	assign SSTATUS_sel      = csr_addr_i == SSTATUS;
	assign MIE_sel          = csr_addr_i == MIE;
	assign SIE_sel          = csr_addr_i == SIE;
	assign MTVEC_sel        = csr_addr_i == MTVEC;
	assign STVEC_sel        = csr_addr_i == STVEC;
	assign MEPC_sel         = csr_addr_i == MEPC;
	assign SEPC_sel         = csr_addr_i == SEPC;
	assign MCAUSE_sel       = csr_addr_i == MCAUSE;
	assign SCAUSE_sel       = csr_addr_i == SCAUSE;
	assign MTVAL_sel        = csr_addr_i == MTVAL;
	assign STVAL_sel        = csr_addr_i == SBADADDR;
	assign MSCRATCH_sel     = csr_addr_i == MSCRATCH;
	assign SSCRATCH_sel     = csr_addr_i == SSCRATCH;
	assign MIP_sel          = csr_addr_i == MIP;
	assign SIP_sel          = csr_addr_i == SIP;
	assign MCYCLE_sel       = csr_addr_i == MCYCLE;
	assign MINSTRET_sel     = csr_addr_i == MINSTRET;
	assign MCYCLEH_sel      = csr_addr_i == MCYCLEH;
	assign MINSTRETH_sel    = csr_addr_i == MINSTRETH;
	assign MCOUNTINHIBIT_sel= csr_addr_i == MCOUNTINHIBIT;
	assign FFLAGS_sel       = csr_addr_i == FFLAGS;
	assign FRM_sel          = csr_addr_i == FRM;
	assign FCSR_sel         = csr_addr_i == FCSR;
	assign SATP_sel         = csr_addr_i == SATP;
	assign MEDELEG_sel      = csr_addr_i == MEDELEG;
	assign MIDELEG_sel      = csr_addr_i == MIDELEG;
	assign MCOUNTEREN_sel   = csr_addr_i == MCOUNTEREN;
	assign SCOUNTEREN_sel   = csr_addr_i == SCOUNTEREN;

	// ── CSR write data ───────────────────────────────────────────
	logic [31:0] csr_data;
	assign csr_data = (csr_use_immediate_i == TRUE) ? imm_i : reg_i;

	// ── Counters ─────────────────────────────────────────────────
	logic [63:0] csr_cycle_update;
	logic [63:0] csr_instret_update;
	assign csr_cycle_update   = (!_MCOUNTINHIBIT[0] && !stop_counters_i) ? {_MCYCLEH,_MCYCLE} + 1 : {_MCYCLEH,_MCYCLE};
	assign csr_instret_update = (!_MCOUNTINHIBIT[2] && csr_instret_trigger_i && !stop_counters_i) ? {_MINSTRETH,_MINSTRET} + 1 : {_MINSTRETH,_MINSTRET};

	// ── Privilege level register ─────────────────────────────────
	always_ff @(posedge clk_i or posedge reset_i) begin
		if (reset_i)
			priv_level <= 2'b11;  // M-mode
		else if (trap_valid_i) begin
			priv_level <= trap_to_s_i ? 2'b01 : 2'b11;
		end else if (ret_i)
			priv_level <= _MSTATUS[12:11];  // MPP
		else if (sret_i)
			priv_level <= {1'b0, _MSTATUS[8]};  // {0, SPP}
	end

	// ── MSTATUS (manual — handles sstatus view + trap/ret) ──────
	always_ff @(posedge clk_i or posedge reset_i) begin
		if (reset_i) begin
			_MSTATUS <= 32'h0;
		end else if (trap_valid_i) begin
			if (trap_to_s_i) begin
				// S-mode trap entry: SPP=priv[0], SPIE=SIE, SIE=0
				_MSTATUS[8]  <= priv_level[0];
				_MSTATUS[5]  <= _MSTATUS[1];
				_MSTATUS[1]  <= 1'b0;
			end else begin
				// M-mode trap entry: MPP=priv, MPIE=MIE, MIE=0
				_MSTATUS[12:11] <= priv_level;
				_MSTATUS[7]     <= _MSTATUS[3];
				_MSTATUS[3]     <= 1'b0;
			end
		end else if (ret_i) begin
			// MRET: MIE=MPIE, MPIE=1, MPP=U(00)
			// If MPP != M, also clear MPRV (spec §3.1.6.1)
			_MSTATUS[3]     <= _MSTATUS[7];
			_MSTATUS[7]     <= 1'b1;
			_MSTATUS[12:11] <= 2'b00;
			_MSTATUS[17]    <= (_MSTATUS[12:11] == 2'b11) ? _MSTATUS[17] : 1'b0;
		end else if (sret_i) begin
			// SRET: SIE=SPIE, SPIE=1, SPP=0
			_MSTATUS[1]  <= _MSTATUS[5];
			_MSTATUS[5]  <= 1'b1;
			_MSTATUS[8]  <= 1'b0;
		end else if (csr_cmd_i == WRITE_CSR && MSTATUS_sel) begin
			_MSTATUS <= (_MSTATUS & ~MSTATUS_WMASK) | (csr_data & MSTATUS_WMASK);
		end else if (csr_cmd_i == SET_CSR && MSTATUS_sel) begin
			_MSTATUS <= _MSTATUS | (csr_data & MSTATUS_WMASK);
		end else if (csr_cmd_i == CLEAR_CSR && MSTATUS_sel) begin
			_MSTATUS <= _MSTATUS & ~(csr_data & MSTATUS_WMASK);
		end else if (csr_cmd_i == WRITE_CSR && SSTATUS_sel) begin
			_MSTATUS <= (_MSTATUS & ~SSTATUS_WMASK) | (csr_data & SSTATUS_WMASK);
		end else if (csr_cmd_i == SET_CSR && SSTATUS_sel) begin
			_MSTATUS <= _MSTATUS | (csr_data & SSTATUS_WMASK);
		end else if (csr_cmd_i == CLEAR_CSR && SSTATUS_sel) begin
			_MSTATUS <= _MSTATUS & ~(csr_data & SSTATUS_WMASK);
		end
	end

	// ── MIE (manual — handles sie view) ──────────────────────────
	always_ff @(posedge clk_i or posedge reset_i) begin
		if (reset_i) begin
			_MIE <= 32'h0;
		end else if (csr_cmd_i == WRITE_CSR && MIE_sel) begin
			_MIE <= csr_data;
		end else if (csr_cmd_i == SET_CSR && MIE_sel) begin
			_MIE <= _MIE | csr_data;
		end else if (csr_cmd_i == CLEAR_CSR && MIE_sel) begin
			_MIE <= _MIE & ~csr_data;
		end else if (csr_cmd_i == WRITE_CSR && SIE_sel) begin
			_MIE <= (_MIE & ~S_INT_MASK) | (csr_data & S_INT_MASK);
		end else if (csr_cmd_i == SET_CSR && SIE_sel) begin
			_MIE <= _MIE | (csr_data & S_INT_MASK);
		end else if (csr_cmd_i == CLEAR_CSR && SIE_sel) begin
			_MIE <= _MIE & ~(csr_data & S_INT_MASK);
		end
	end

	// ── MIP (manual — handles sip view + external source update) ─
	always_ff @(posedge clk_i or posedge reset_i) begin
		if (reset_i) begin
			_MIP <= 32'h0;
		end else if (csr_cmd_i == WRITE_CSR && MIP_sel) begin
			_MIP <= csr_data;
		end else if (csr_cmd_i == SET_CSR && MIP_sel) begin
			_MIP <= _MIP | csr_data;
		end else if (csr_cmd_i == CLEAR_CSR && MIP_sel) begin
			_MIP <= _MIP & ~csr_data;
		end else if (csr_cmd_i == WRITE_CSR && SIP_sel) begin
			// Only SSIP (bit 1) is writable through sip
			_MIP <= (_MIP & ~32'h2) | (csr_data & 32'h2);
		end else if (csr_cmd_i == SET_CSR && SIP_sel) begin
			_MIP <= _MIP | (csr_data & 32'h2);
		end else if (csr_cmd_i == CLEAR_CSR && SIP_sel) begin
			_MIP <= _MIP & ~(csr_data & 32'h2);
		end else begin
			// Hardware update from external sources
			_MIP <= interrupt_src_i;
		end
	end

	// ── Counter registers (unchanged) ────────────────────────────
	csr_register_32 #(32'h0) csr_mcycle     (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLE_sel),
	                                          .wdata(csr_data),.update(csr_cycle_update[31:0]), .csr(_MCYCLE));
	csr_register_32 #(32'h0) csr_minstret   (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRET_sel),
	                                          .wdata(csr_data),.update(csr_instret_update[31:0]), .csr(_MINSTRET));
	csr_register_32 #(32'h0) csr_mcycleh    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCYCLEH_sel),
	                                          .wdata(csr_data),.update(csr_cycle_update[63:32]), .csr(_MCYCLEH));
	csr_register_32 #(32'h0) csr_minstreth  (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MINSTRETH_sel),
	                                          .wdata(csr_data),.update(csr_instret_update[63:32]), .csr(_MINSTRETH));
	csr_register_32 #(32'h0) csr_mcounterinhibit (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCOUNTINHIBIT_sel),
	                                          .wdata(csr_data),.update(_MCOUNTINHIBIT), .csr(_MCOUNTINHIBIT));

	// ── M-mode trap registers ────────────────────────────────────
	csr_register_32 #(32'h0) csr_mtvec    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVEC_sel),
	                                        .wdata(csr_data),.update(_MTVEC), .csr(_MTVEC));
	csr_register_32 #(32'h0) csr_mepc     (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MEPC_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && !trap_to_s_i) ? epc_i : _MEPC), .csr(_MEPC));
	csr_register_32 #(32'h0) csr_mcause   (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCAUSE_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && !trap_to_s_i) ? ecause_i : _MCAUSE), .csr(_MCAUSE));
	csr_register_32 #(32'h0) csr_mtval    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MTVAL_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && !trap_to_s_i) ? mtval_i : _MTVAL), .csr(_MTVAL));
	csr_register_32 #(32'h0) csr_mscratch (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MSCRATCH_sel),
	                                        .wdata(csr_data),.update(_MSCRATCH), .csr(_MSCRATCH));

	// ── S-mode trap registers ────────────────────────────────────
	csr_register_32 #(32'h0) csr_stvec    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(STVEC_sel),
	                                        .wdata(csr_data),.update(_STVEC), .csr(_STVEC));
	csr_register_32 #(32'h0) csr_sepc     (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(SEPC_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && trap_to_s_i) ? epc_i : _SEPC), .csr(_SEPC));
	csr_register_32 #(32'h0) csr_scause   (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(SCAUSE_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && trap_to_s_i) ? ecause_i : _SCAUSE), .csr(_SCAUSE));
	csr_register_32 #(32'h0) csr_stval    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(STVAL_sel),
	                                        .wdata(csr_data),.update((trap_valid_i && trap_to_s_i) ? mtval_i : _STVAL), .csr(_STVAL));
	csr_register_32 #(32'h0) csr_sscratch (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(SSCRATCH_sel),
	                                        .wdata(csr_data),.update(_SSCRATCH), .csr(_SSCRATCH));

	// ── Delegation & counter enable ──────────────────────────────
	csr_register_32 #(32'h0) csr_medeleg    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MEDELEG_sel),
	                                          .wdata(csr_data),.update(_MEDELEG), .csr(_MEDELEG));
	csr_register_32 #(32'h0) csr_mideleg    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MIDELEG_sel),
	                                          .wdata(csr_data),.update(_MIDELEG), .csr(_MIDELEG));
	csr_register_32 #(32'h0) csr_mcounteren (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(MCOUNTEREN_sel),
	                                          .wdata(csr_data),.update(_MCOUNTEREN), .csr(_MCOUNTEREN));
	csr_register_32 #(32'h0) csr_scounteren (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(SCOUNTEREN_sel),
	                                          .wdata(csr_data),.update(_SCOUNTEREN), .csr(_SCOUNTEREN));

	// ── SATP (placeholder for Sv32 MMU, Phase 3) ─────────────────
	csr_register_32 #(32'h0) csr_satp       (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(SATP_sel),
	                                          .wdata(csr_data),.update(_SATP), .csr(_SATP));

	// ── FPU CSRs (unchanged) ─────────────────────────────────────
	wire [4:0] new_fflags = {float_status_i.NV, float_status_i.DZ, float_status_i.OF, float_status_i.UF, float_status_i.NX};
	wire [31:0] fflags_accumulate = (float_valid_i == TRUE) ? (_FFLAGS | {27'b0, new_fflags}) : _FFLAGS;
	wire [31:0] fflags_wdata = FCSR_sel ? {27'b0, csr_data[4:0]} : csr_data;
	wire [31:0] frm_wdata   = FCSR_sel ? {29'b0, csr_data[7:5]} : csr_data;

	csr_register_32 #(32'h0) csr_fflags (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(FFLAGS_sel | FCSR_sel),
	                                      .wdata(fflags_wdata),.update(fflags_accumulate), .csr(_FFLAGS));
	csr_register_32 #(32'h0) csr_frm    (.clk_i(clk_i),.reset_i(reset_i),.csr_cmd_i(csr_cmd_i),.enable(FRM_sel | FCSR_sel),
	                                      .wdata(frm_wdata),.update(_FRM), .csr(_FRM));

	assign roundmode_o = roundmode_e'(_FRM[2:0]);

	// ── SD bit (read-only, computed) ─────────────────────────────
`ifdef FPU
	wire mstatus_sd = (_MSTATUS[14:13] == 2'b11);
`else
	wire mstatus_sd = 1'b0;
`endif

	// ── CSR read mux ─────────────────────────────────────────────
	wire csr_active = (csr_cmd_i != NO_CSR_OP);

	always_comb begin
		csr_invalid_o = 1'b0;
		case (csr_addr_i)
			FFLAGS:         csr_value_o = {27'b0, _FFLAGS[4:0]};
			FRM:            csr_value_o = {29'b0, _FRM[2:0]};
			FCSR:           csr_value_o = {24'b0, _FRM[2:0], _FFLAGS[4:0]};
			CYCLE:          csr_value_o = _MCYCLE;
			TIME:           csr_value_o = 0;
			INSTRET:        csr_value_o = _MINSTRET;
			CYCLEH:         csr_value_o = _MCYCLEH;
			TIMEH:          csr_value_o = 0;
			INSTRETH:       csr_value_o = _MINSTRETH;
			MSTATUS:        csr_value_o = {mstatus_sd, _MSTATUS[30:0]};
`ifdef FPU
			MISA:           csr_value_o = 32'h40141127; // RV32IMAFCSU
`else
			MISA:           csr_value_o = 32'h40141107; // RV32IMACSU
`endif
			MIE:            csr_value_o = _MIE;
			MTVEC:          csr_value_o = _MTVEC;
			MSCRATCH:       csr_value_o = _MSCRATCH;
			MEPC:           csr_value_o = _MEPC;
			MCAUSE:         csr_value_o = _MCAUSE;
			MTVAL:          csr_value_o = _MTVAL;
			MIP:            csr_value_o = _MIP;
			MCYCLE:         csr_value_o = _MCYCLE;
			MINSTRET:       csr_value_o = _MINSTRET;
			MCYCLEH:        csr_value_o = _MCYCLEH;
			MINSTRETH:      csr_value_o = _MINSTRETH;
			MCOUNTINHIBIT:  csr_value_o = _MCOUNTINHIBIT;
			MSTATUSH:       csr_value_o = 32'h0;  // RV32 little-endian: MBE=SBE=0, read-only zero
			MHARTID:        csr_value_o = 32'h0;  // Hart 0 (single-hart)
			MVENDORID:      csr_value_o = 32'h0;  // Non-commercial
			MARCHID:        csr_value_o = 32'h0;  // Not assigned
			MIMPID:         csr_value_o = 32'h0;  // Implementation-specific
			MEDELEG:        csr_value_o = _MEDELEG;
			MIDELEG:        csr_value_o = _MIDELEG;
			MCOUNTEREN:     csr_value_o = _MCOUNTEREN;
			// S-mode CSRs
			SSTATUS:        csr_value_o = {mstatus_sd, _MSTATUS[30:0]} & SSTATUS_RMASK;
			SIE:            csr_value_o = _MIE & S_INT_MASK;
			STVEC:          csr_value_o = _STVEC;
			SCOUNTEREN:     csr_value_o = _SCOUNTEREN;
			SSCRATCH:       csr_value_o = _SSCRATCH;
			SEPC:           csr_value_o = _SEPC;
			SCAUSE:         csr_value_o = _SCAUSE;
			SBADADDR:       csr_value_o = _STVAL;
			SIP:            csr_value_o = _MIP & S_INT_MASK;
			SATP:           csr_value_o = _SATP;
			default: begin
				csr_value_o = 0;
				csr_invalid_o = csr_active;  // only flag invalid if a CSR op is active
			end
		endcase
	end

	// ── Outputs ──────────────────────────────────────────────────
	assign ip_o      = _MIP;
	assign ie_o      = _MIE;
	assign vec_o     = trap_to_s_i ? _STVEC : _MTVEC;
	assign status_o  = _MSTATUS;
	assign epc_o     = _MEPC;
	assign sepc_o    = _SEPC;
	assign priv_o    = priv_level;
	assign medeleg_o = _MEDELEG;
	assign mideleg_o = _MIDELEG;
	assign satp_o    = _SATP;

endmodule

module csr_register_32
 #(
		parameter DEFAULT = 32'b0
	)
	(
		input   clk_i,
        input   reset_i,
        input 	csr_op_e csr_cmd_i,
		input 	bit	enable,
		input	[31:0] 	wdata,
		input	[31:0]  update,
		output	logic[31:0]  csr
	);
	always_ff @ (posedge clk_i or posedge reset_i) begin: CSR
				if (reset_i) begin
					csr <= DEFAULT;
		end else if ((csr_cmd_i == WRITE_CSR) && enable) begin
					csr <= wdata;
		end else if ((csr_cmd_i == SET_CSR) && enable) begin
					csr <= csr | wdata;
		end else if ((csr_cmd_i == CLEAR_CSR) && enable) begin
					csr <= csr & ~wdata;
		end else begin
					csr <= update;
		end
	end
endmodule
