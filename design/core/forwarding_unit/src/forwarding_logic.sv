// ── Forwarding (bypass) logic ────────────────────────────────────────
// Detects read-after-write hazards at the ID stage and tells the operand
// muxes where to get the freshest value instead of the stale register-file
// read. For each source register it checks the two younger in-flight
// instructions — one in IMEM (the older, closer) and one in IWB (newer)
// — and prefers IMEM when both match (the more recent result). Integer
// uses ports a/b (rs1/rs2); FP adds port c (rs3) for fused multiply-add.
// Pure combinational. See microarch doc: "Forwarding & load-use hazard".
import common_pkg::*;
import core_pkg::*;

module forwarding_logic
(
	input reg_add_e rs1_i,           // integer source registers this ID instruction reads
	input reg_add_e rs2_i,
	input reg_add_e rs1_float_i,     // FP source registers (rs1/rs2/rs3)
	input reg_add_e rs2_float_i,
	input reg_add_e rs3_float_i,
	input reg_add_e rd_mem_i,        // dest of the instruction now in IMEM
	input reg_add_e rd_wb_i,         // dest of the instruction now in IWB
	input reg_add_e rd_float_mem_i,  // FP dest in IMEM
	input reg_add_e rd_float_wb_i,   // FP dest in IWB
	input wb_sel_e wb_mem_i,         // does the IMEM instruction write back?
	input wb_sel_e wb_wb_i,          // does the IWB instruction write back?
	output forward_sel_e forwarda_id_o, // bypass select for rs1
	output forward_sel_e forwardb_id_o, // bypass select for rs2
	output forward_sel_e forwardc_id_o  // bypass select for rs3 (FP)
);

// Per-source match flags: i=integer, f=float; suffix _mem/_wb = which stage.
// A match needs the producer to actually write back (wb != NO_WB), to have a
// real destination (not x0, not NO_REG), and to equal this source register.
logic i1_mem, i1_wb, i2_mem, i2_wb;
logic f1_mem, f1_wb, f2_mem, f2_wb, f3_mem, f3_wb;

assign i1_mem = wb_mem_i != NO_WB && rd_mem_i != 0 && rd_mem_i != NO_REG && rd_mem_i == rs1_i;
assign i1_wb  = wb_wb_i  != NO_WB && rd_wb_i  != 0 && rd_wb_i  != NO_REG && rd_wb_i  == rs1_i;
assign i2_mem = wb_mem_i != NO_WB && rd_mem_i != 0 && rd_mem_i != NO_REG && rd_mem_i == rs2_i;
assign i2_wb  = wb_wb_i  != NO_WB && rd_wb_i  != 0 && rd_wb_i  != NO_REG && rd_wb_i  == rs2_i;

`ifdef FPU
	assign f1_mem = wb_mem_i != NO_WB  && rd_float_mem_i != NO_REG && rd_float_mem_i == rs1_float_i;
	assign f1_wb  = wb_wb_i  != NO_WB  && rd_float_wb_i  != NO_REG && rd_float_wb_i  == rs1_float_i;
	assign f2_mem = wb_mem_i != NO_WB  && rd_float_mem_i != NO_REG && rd_float_mem_i == rs2_float_i;
	assign f2_wb  = wb_wb_i  != NO_WB  && rd_float_wb_i  != NO_REG && rd_float_wb_i  == rs2_float_i;
	assign f3_mem = wb_mem_i != NO_WB  && rd_float_mem_i != NO_REG && rd_float_mem_i == rs3_float_i;
	assign f3_wb  = wb_wb_i  != NO_WB  && rd_float_wb_i  != NO_REG && rd_float_wb_i  == rs3_float_i;
`else
	assign f1_mem = 1'b0;
	assign f1_wb  = 1'b0;
	assign f2_mem = 1'b0;
	assign f2_wb  = 1'b0;
	assign f3_mem = 1'b0;
	assign f3_wb  = 1'b0;
`endif


// Per source: prefer the IMEM producer (most recent) over IWB; else no bypass.
always_comb
begin
	if(i1_mem || f1_mem)
		forwarda_id_o = FORWARD_IMEM;
	else if(i1_wb || f1_wb)
		forwarda_id_o = FORWARD_IWB;
	else
		forwarda_id_o = NO_FORWARD;

	if(i2_mem || f2_mem)
		forwardb_id_o = FORWARD_IMEM;
	else if(i2_wb || f2_wb)
		forwardb_id_o = FORWARD_IWB;
	else
		forwardb_id_o = NO_FORWARD;

	if(f3_mem)
		forwardc_id_o = FORWARD_IMEM;
	else if(f3_wb)
		forwardc_id_o = FORWARD_IWB;
	else
		forwardc_id_o = NO_FORWARD;
end

endmodule
