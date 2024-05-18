import common_pkg::*;
import core_pkg::*;

module stall_line
(
    input ctrl_bus_e ctrl_bus_if_id_i,
    input ctrl_bus_e ctrl_bus_ie_i,
    input ctrl_bus_e ctrl_bus_imem_i,
    output onebit_sig_e insert_bubble_o
);


logic stall_condition_ie, stall_condition_imem;
logic c1_ie;
logic c2_ie;
logic c3_ie;
logic c4_ie;
logic c1_imem;
logic c2_imem;
logic c3_imem;
logic c4_imem;

logic f2_ie;
logic f3_ie;
logic f4_ie;
logic f5_ie;
logic f2_imem;
logic f3_imem;
logic f4_imem;
logic f5_imem;

logic br_true;
logic lu_ie;
logic lu_imem;

assign c1_ie = ctrl_bus_ie_i.wb_sel != NO_WB;
assign c2_ie = ctrl_bus_ie_i.rd_int != 0;
assign c3_ie = (ctrl_bus_ie_i.rd_int == ctrl_bus_if_id_i.rs1_int) && ctrl_bus_if_id_i.rs1_int != NO_REG;
assign c4_ie = (ctrl_bus_ie_i.rd_int == ctrl_bus_if_id_i.rs2_int) && ctrl_bus_if_id_i.rs2_int != NO_REG;
//assign f2_ie = ctrl_bus_ie_i.rd_float != 0;
`ifdef FPU
assign f3_ie = (ctrl_bus_ie_i.rd_float == ctrl_bus_if_id_i.rs1_float) && ctrl_bus_if_id_i.rs1_float != NO_REG;
assign f4_ie = (ctrl_bus_ie_i.rd_float == ctrl_bus_if_id_i.rs2_float) && ctrl_bus_if_id_i.rs2_float != NO_REG;
assign f5_ie = (ctrl_bus_ie_i.rd_float == ctrl_bus_if_id_i.rs3_float) && ctrl_bus_if_id_i.rs3_float != NO_REG;
`else
assign f3_ie = 1'b0;
assign f4_ie = 1'b0;
assign f5_ie = 1'b0;
`endif

assign c1_imem = ctrl_bus_imem_i.wb_sel != NO_WB;
assign c2_imem = ctrl_bus_imem_i.rd_int != 0;
assign c3_imem = (ctrl_bus_imem_i.rd_int == ctrl_bus_if_id_i.rs1_int) && ctrl_bus_if_id_i.rs1_int != NO_REG;
assign c4_imem = (ctrl_bus_imem_i.rd_int == ctrl_bus_if_id_i.rs2_int) && ctrl_bus_if_id_i.rs2_int != NO_REG;
//assign f2_imem = ctrl_bus_imem_i.rd_float != 0;
`ifdef FPU
assign f3_imem = (ctrl_bus_imem_i.rd_float == ctrl_bus_if_id_i.rs1_float) && ctrl_bus_if_id_i.rs1_float != NO_REG;
assign f4_imem = (ctrl_bus_imem_i.rd_float == ctrl_bus_if_id_i.rs2_float) && ctrl_bus_if_id_i.rs2_float != NO_REG;
assign f5_imem = (ctrl_bus_imem_i.rd_float == ctrl_bus_if_id_i.rs3_float) && ctrl_bus_if_id_i.rs3_float != NO_REG;
`else
assign f3_imem = 1'b0;
assign f4_imem = 1'b0;
assign f5_imem = 1'b0;
`endif

assign stall_condition_ie = c1_ie && ((c2_ie && (c3_ie || c4_ie)) || (/*f2_ie && */(f3_ie || f4_ie || f5_ie)));
assign stall_condition_imem = c1_imem && ((c2_imem && (c3_imem || c4_imem)) || (/*f2_imem && */(f3_imem || f4_imem || f5_imem)));

assign br_true = ctrl_bus_if_id_i.inst_type == JUMP_R || ctrl_bus_if_id_i.inst_type == BRANCH;
assign lu_ie = ctrl_bus_ie_i.mem_op == READ;
assign lu_imem = ctrl_bus_imem_i.mem_op == READ;

assign insert_bubble_o = onebit_sig_e'(( ((br_true | lu_ie ) & stall_condition_ie) | ((br_true & lu_imem) & stall_condition_imem) ) );

endmodule
