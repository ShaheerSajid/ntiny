// ─────────────────────────────────────────────────────────────────────
// tb_tracer — testbench-side tracer module.
// Owns the IE→IMEM→IWB pipeline-state register chain that the tracer
// needs, and instantiates the tracer itself. Reaches into the design
// via hierarchical refs (`tb_soc_top.soc_top_inst.core_top_inst.*`)
// so the design carries ZERO tracer/log code.
//
// Compile-gated by DV_TRACER so non-trace builds skip everything.
// ─────────────────────────────────────────────────────────────────────
`ifdef DV_TRACER
import core_pkg::*;

module tb_tracer (
    input logic clk_i,
    input logic reset_i
);

    // Hierarchical taps into core_top
    wire [31:0] cor_next_instruction_addr =
        tb_soc_top.soc_top_inst.core_top_inst.next_instruction_addr;
    wire [31:0] cor_instruction_pipe =
        tb_soc_top.soc_top_inst.core_top_inst.instruction_pipe;
    wire        cor_ie_stall   = tb_soc_top.soc_top_inst.core_top_inst.ie_stall;
    wire        cor_imem_stall = tb_soc_top.soc_top_inst.core_top_inst.imem_stall;
    wire        cor_iwb_stall  = tb_soc_top.soc_top_inst.core_top_inst.iwb_stall;
    wire        cor_c_valid_ie = tb_soc_top.soc_top_inst.core_top_inst.c_valid_ie;
    wire [31:0] cor_opA_fwd    = tb_soc_top.soc_top_inst.core_top_inst.opA_forwarded_data;
    wire [31:0] cor_opB_fwd    = tb_soc_top.soc_top_inst.core_top_inst.opB_forwarded_data;
    wire [31:0] cor_opC_fwd    = tb_soc_top.soc_top_inst.core_top_inst.opC_forwarded_data;

    // float_status is a struct; expand its bits we care about
    wire        cor_fstat_any  =
        tb_soc_top.soc_top_inst.core_top_inst.float_status.NV |
        tb_soc_top.soc_top_inst.core_top_inst.float_status.DZ |
        tb_soc_top.soc_top_inst.core_top_inst.float_status.OF |
        tb_soc_top.soc_top_inst.core_top_inst.float_status.UF |
        tb_soc_top.soc_top_inst.core_top_inst.float_status.NX;

    wire [31:0] cor_pc_iwb       = tb_soc_top.soc_top_inst.core_top_inst.pc_iwb;
    wire [31:0] cor_write_back_data =
        tb_soc_top.soc_top_inst.core_top_inst.write_back_data;
    wire [31:0] cor_exec_result_iwb =
        tb_soc_top.soc_top_inst.core_top_inst.exec_result_iwb;
    wire [31:0] cor_readdata_iwb =
        tb_soc_top.soc_top_inst.core_top_inst.readdata_iwb;
    wire [1:0]  cor_priv         = tb_soc_top.soc_top_inst.core_top_inst.priv_level;
    wire        cor_int_v        = tb_soc_top.soc_top_inst.core_top_inst.interrupt_valid;
    wire [31:0] cor_ecause       = tb_soc_top.soc_top_inst.core_top_inst.ecause_csr;
    wire [31:0] cor_epc          = tb_soc_top.soc_top_inst.core_top_inst.epc_csr;
    wire [31:0] cor_mtval        = tb_soc_top.soc_top_inst.core_top_inst.mtval_csr;
    wire        cor_trap_to_s    = tb_soc_top.soc_top_inst.core_top_inst.trap_to_s;
    wire        cor_wb_xret_fire = tb_soc_top.soc_top_inst.core_top_inst.wb_xret_fire;
    wire [31:0] cor_sepc         = tb_soc_top.soc_top_inst.core_top_inst.sepc;
    wire [31:0] cor_epc_csr_main = tb_soc_top.soc_top_inst.core_top_inst.epc;

    // ctrl_bus_iwb is a packed struct — pull individual fields used by tracer
    wire ctrl_bus_e cor_ctrl_iwb = tb_soc_top.soc_top_inst.core_top_inst.ctrl_bus_iwb;

    // Pipeline-state register chain. These were previously inside
    // core_top under `ifdef DV_TRACER`. Now they live here so the
    // synthesizable design has zero trace footprint.
    logic [31:0] i1, i2, i3;
    logic [31:0] pc1, pc2, pc3;
    logic [31:0] srcA_imem, srcA_iwb;
    logic [31:0] srcB_imem, srcB_iwb;
    logic [31:0] srcC_imem, srcC_iwb;
    bit          stall_ie_reg;
    logic        a1, a2;
    logic        fstat_imem, fstat_iwb;

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            stall_ie_reg <= 0;
            pc1 <= 0; pc2 <= 0; pc3 <= 0;
            i1  <= 0; i2  <= 0; i3  <= 0;
            a1  <= 0; a2  <= 0;
            fstat_imem <= 0; fstat_iwb <= 0;
            srcA_imem <= 0; srcB_imem <= 0; srcC_imem <= 0;
            srcA_iwb  <= 0; srcB_iwb  <= 0; srcC_iwb  <= 0;
        end else begin
            stall_ie_reg <= cor_ie_stall;

            if (!cor_ie_stall) begin
                pc1 <= cor_next_instruction_addr;
                i1  <= cor_instruction_pipe;
            end
            if (!cor_imem_stall) begin
                pc2 <= pc1;
                i2  <= i1;
                a1  <= cor_c_valid_ie;
                fstat_imem <= cor_fstat_any;
                if (!stall_ie_reg) begin
                    srcA_imem <= cor_opA_fwd;
                    srcB_imem <= cor_opB_fwd;
                    srcC_imem <= cor_opC_fwd;
                end
            end
            if (!cor_iwb_stall) begin
                pc3 <= pc2;
                i3  <= i2;
                a2  <= a1;
                srcA_iwb <= srcA_imem;
                srcB_iwb <= srcB_imem;
                srcC_iwb <= srcC_imem;
                fstat_iwb <= fstat_imem;
            end
        end
    end

    tracer tracer_ip (
        .clk_i           (clk_i),
        .rst_ni          (~reset_i),
        .hart_id_i       (1'b0),
        .rvfi_valid      (cor_ctrl_iwb.inst_type != NO_INS),
        .rvfi_insn_t     (i3),
        .rvfi_rs1_addr_t (cor_ctrl_iwb.rs1_int == NO_REG ? cor_ctrl_iwb.rs1_float : cor_ctrl_iwb.rs1_int),
        .rvfi_rs2_addr_t (cor_ctrl_iwb.rs2_int == NO_REG ? cor_ctrl_iwb.rs2_float : cor_ctrl_iwb.rs2_int),
        .rvfi_rs3_addr_t (cor_ctrl_iwb.rs3_int == NO_REG ? cor_ctrl_iwb.rs3_float : cor_ctrl_iwb.rs3_int),
        .rvfi_rs1_rdata_t(srcA_iwb),
        .rvfi_rs2_rdata_t(srcB_iwb),
        .rvfi_rs3_rdata_t(srcC_iwb),
        .rvfi_rd_addr_t  (cor_ctrl_iwb.rd_int == NO_REG ? cor_ctrl_iwb.rd_float : cor_ctrl_iwb.rd_int),
        .rvfi_rd_wdata_t (cor_write_back_data),
        .rvfi_pc_rdata_t (a2 ? cor_pc_iwb - 2 : cor_pc_iwb - 4),
        .rvfi_pc_wdata_t (pc3),
        .rvfi_mem_addr   (cor_ctrl_iwb.mem_op != NO_MEM_OP ? cor_exec_result_iwb : 32'h0),
        .priv_i          (cor_priv),
        .trap_valid_i    (cor_int_v),
        .trap_cause_i    (cor_ecause),
        .trap_epc_i      (cor_epc),
        .trap_tval_i     (cor_mtval),
        .trap_to_s_i     (cor_trap_to_s),
        .xret_fire_i     (cor_wb_xret_fire),
        .xret_is_sret_i  (cor_ctrl_iwb.sret == TRUE),
        .xret_target_i   ((cor_ctrl_iwb.sret == TRUE) ? cor_sepc : cor_epc_csr_main),
        .rvfi_mem_rmask  (cor_ctrl_iwb.mem_op == READ  ? 4'hF : 4'h0),
        .rvfi_mem_wmask  (cor_ctrl_iwb.mem_op == WRITE ? 4'hF : 4'h0),
        .rvfi_mem_rdata  (cor_readdata_iwb),
        .rvfi_mem_wdata  (srcB_iwb)
    );

endmodule
`endif // DV_TRACER
