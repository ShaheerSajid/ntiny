// =============================================================================
// Diagnostic Pipeline Tracer for ntiny RISC-V SoC
// =============================================================================
// Enable with +define+DV_DIAG_TRACE in Verilator/simulator command line.
// Produces diag_trace.log with per-cycle pipeline state, event markers for
// traps/returns/regfile writes/CSR writes/memory ops, and infinite loop detection.
//
// Include from tb_soc_top.v inside the module body.
// Hierarchy assumed: soc_top_inst.core_top_inst.*
// =============================================================================

`ifdef DV_DIAG_TRACE

// --- Convenience aliases (shorter names for deeply nested signals) ----------
`define CORE  soc_top_inst.core_top_inst
`define CSR   soc_top_inst.core_top_inst.csr_unit_inst
`define MMU   soc_top_inst.core_top_inst.mmu_inst
`define ITRAP soc_top_inst.core_top_inst.interrupt_ctrl_inst

integer diag_fd;
integer diag_cyc;
reg [31:0] diag_last_pc;
integer diag_pc_repeat;

initial begin
    diag_fd = $fopen("diag_trace.log", "w");
    diag_cyc = 0;
    diag_last_pc = 32'hFFFFFFFF;
    diag_pc_repeat = 0;

    // Header with field descriptions
    $fwrite(diag_fd, "# ntiny diagnostic trace\n");
    $fwrite(diag_fd, "# EVENT lines: TRAP, MRET, SRET, RF_WR, CSR_WR, MEM_WR, MEM_RD\n");
    $fwrite(diag_fd, "# CYC lines: per-cycle pipeline snapshot\n");
    $fwrite(diag_fd, "# priv: 0=U, 1=S, 3=M\n");
    $fwrite(diag_fd, "# ptw_state: 0=IDLE, 1=L1, 2=L0_WAIT, 3=L0, 4=FILL, 5=FAULT\n");
    $fwrite(diag_fd, "# csr_cmd: 0=SYSTEM, 1=WRITE, 2=SET, 3=CLEAR, 4=NOP\n");
    $fwrite(diag_fd, "# pc_sel: 0=PC+4, 1=BRANCH, 2=INT, 3=RET, 4=DPC\n");
    $fwrite(diag_fd, "#\n");
end

always @(posedge clk) begin
    if (!reset) diag_cyc = diag_cyc + 1;
end

always @(posedge clk) begin
    if (!reset) begin

        // =====================================================================
        // EVENT: Trap taken (interrupts + synchronous exceptions)
        // =====================================================================
        if (`CORE.interrupt_valid) begin
            $fwrite(diag_fd, "TRAP[%0d] cause=%08h epc=%08h mtval=%08h handler=%08h priv=%0d->%0d trap_to_s=%0b | i_fault_r=%0b d_fault=%0b d_store=%0b | mmu_priv=%0d i_xlate=%0b d_xlate=%0b | ie_insn_type=%0d ie_mret=%0b ie_sret=%0b ie_csr_op=%0d ie_csr_addr=%03h stale_ie=%0b | ret_valid=%0b csr_ret_haz=%0b\n",
                diag_cyc,
                `CORE.ecause_csr,
                `CORE.epc_csr,
                `CORE.mtval_csr,
                `CORE.handler_addr,
                `CORE.priv_level,
                `CORE.trap_to_s ? 2'd1 : 2'd3,
                `CORE.trap_to_s,
                `CORE.mmu_i_fault_r,
                `CORE.mmu_d_fault,
                `MMU.d_store_i,
                `CORE.mmu_priv,
                `MMU.i_translate,
                `MMU.d_translate,
                `CORE.ctrl_bus_ie.inst_type,
                `CORE.ctrl_bus_ie.mret,
                `CORE.ctrl_bus_ie.sret,
                `CORE.ctrl_bus_ie.csr_op,
                `CORE.ctrl_bus_ie.csr_addr,
                `CORE.stale_ie,
                `CORE.ret_valid,
                `CORE.csr_ret_hazard);
            $display("TRAP[%0d] cause=%08h epc=%08h mtval=%08h handler=%08h priv=%0d->%0d",
                diag_cyc, `CORE.ecause_csr,
                `CORE.epc_csr,
                `CORE.mtval_csr,
                `CORE.handler_addr,
                `CORE.priv_level,
                `CORE.trap_to_s ? 2'd1 : 2'd3);
        end

        // =====================================================================
        // EVENT: MRET (M-mode return)
        // =====================================================================
        if (`CSR.ret_i) begin
            $fwrite(diag_fd, "MRET[%0d] mepc=%08h priv=%0d->%0d mstatus=%08h mpp=%0d mpie=%0b mie=%0b\n",
                diag_cyc,
                `CSR._MEPC,
                `CORE.priv_level,
                `CSR._MSTATUS[12:11],
                `CSR._MSTATUS,
                `CSR._MSTATUS[12:11],
                `CSR._MSTATUS[7],
                `CSR._MSTATUS[3]);
            $display("MRET[%0d] mepc=%08h priv=%0d->%0d",
                diag_cyc, `CSR._MEPC,
                `CORE.priv_level,
                `CSR._MSTATUS[12:11]);
        end

        // =====================================================================
        // EVENT: SRET (S-mode return)
        // =====================================================================
        if (`CSR.sret_i) begin
            $fwrite(diag_fd, "SRET[%0d] sepc=%08h priv=%0d->%0d mstatus=%08h spp=%0b spie=%0b sie=%0b\n",
                diag_cyc,
                `CSR._SEPC,
                `CORE.priv_level,
                {1'b0, `CSR._MSTATUS[8]},
                `CSR._MSTATUS,
                `CSR._MSTATUS[8],
                `CSR._MSTATUS[5],
                `CSR._MSTATUS[1]);
            $display("SRET[%0d] sepc=%08h priv=%0d->%0d",
                diag_cyc, `CSR._SEPC,
                `CORE.priv_level,
                {1'b0, `CSR._MSTATUS[8]});
        end

        // =====================================================================
        // EVENT: Register file write (integer)
        // =====================================================================
        if (`CORE.rf_wr_en && `CORE.rf_wr_addr != 5'd0) begin
            $fwrite(diag_fd, "RF_WR[%0d] x%0d <- %08h pc_iwb=%08h wb_sel=%0d jfw=%0b stale_iwb=%0b\n",
                diag_cyc,
                `CORE.rf_wr_addr,
                `CORE.rf_wr_data,
                `CORE.pc_iwb,
                `CORE.ctrl_bus_iwb.wb_sel,
                `CORE.jalr_fault_wr,
                `CORE.stale_iwb);
        end

        // =====================================================================
        // EVENT: CSR write (any WRITE/SET/CLEAR that actually fires)
        // =====================================================================
        if (`CORE.ctrl_bus_ie.csr_op != 4 && `CORE.ctrl_bus_ie.csr_op != 0 && !`CORE.stale_ie) begin
            $fwrite(diag_fd, "CSR_OP[%0d] cmd=%0d addr=%03h rd_val=%08h wr_val=%08h rs1=%0d rd=%0d pc_ie=%08h\n",
                diag_cyc,
                `CORE.ctrl_bus_ie.csr_op,
                `CORE.ctrl_bus_ie.csr_addr,
                `CORE.csr_result,
                `CSR.csr_data,
                `CORE.ctrl_bus_ie.rs1_int,
                `CORE.ctrl_bus_ie.rd_int,
                `CORE.pc_ie);
        end

        // =====================================================================
        // EVENT: Memory write (store commits — dtlb_hit, no fault, not stale, not stalled)
        // =====================================================================
        if (`MMU.d_store_i && `MMU.dtlb_hit && !`CORE.mmu_d_fault && !`CORE.stale_imem && !`CORE.mmu_d_stall) begin
            $fwrite(diag_fd, "MEM_WR[%0d] vaddr=%08h paddr=%08h data=%08h pc_imem=%08h\n",
                diag_cyc,
                `MMU.d_vaddr_i,
                `MMU.d_paddr_o,
                `CORE.srcB_imem_diag,
                `CORE.pc_imem);
        end

        // =====================================================================
        // PER-CYCLE: Pipeline state — all 4 stages + control
        // =====================================================================
        // Line 1: Pipeline PCs, instruction word, pc_sel
        $fwrite(diag_fd, "CYC[%0d] pc_id=%08h pc_ie=%08h pc_imem=%08h pc_iwb=%08h insn=%08h pc_sel=%0d\n",
            diag_cyc,
            `CORE.pc_id,
            `CORE.pc_ie,
            `CORE.pc_imem,
            `CORE.pc_iwb,
            `CORE.instruction_pipe,
            `CORE.pc_sel);

        // Line 2: Stall/flush/bubble/valid/stale signals
        $fwrite(diag_fd, "  CTRL: stall=%0b ie_stall=%0b i_stall=%0b d_stall=%0b alu_stall=%0b bubble=%0b | ie_flush=%0b imem_flush=%0b iwb_flush=%0b | insn_valid=%0b post_trap=%0b stale=[%0b%0b%0b%0b] | ret=%0b br=%0b trap=%0b trap_to_s=%0b\n",
            `CORE.if_id_stall,
            `CORE.ie_stall,
            `CORE.mmu_i_stall,
            `CORE.mmu_d_stall,
            `CORE.alu_stall,
            `CORE.insert_bubble,
            `CORE.ie_flush,
            `CORE.imem_flush,
            `CORE.iwb_flush,
            `CORE.insn_valid_id,
            `CORE.post_trap,
            `CORE.stale_id,
            `CORE.stale_ie,
            `CORE.stale_imem,
            `CORE.stale_iwb,
            `CORE.ret_valid,
            `CORE.branch_taken,
            `CORE.interrupt_valid,
            `CORE.trap_to_s);

        // Line 3: Privilege, MMU, CSR state
        $fwrite(diag_fd, "  PRIV: priv=%0d mmu_priv=%0d ret_tgt_priv=%0d csr_ret_haz=%0b | mstatus=%08h satp=%08h medeleg=%08h mideleg=%08h\n",
            `CORE.priv_level,
            `CORE.mmu_priv,
            `CORE.ret_target_priv,
            `CORE.csr_ret_hazard,
            `CSR._MSTATUS,
            `CSR._SATP,
            `CSR._MEDELEG,
            `CSR._MIDELEG);

        // Line 4: Trap CSRs (mepc, sepc, mcause, scause, mtvec, stvec)
        $fwrite(diag_fd, "  TCSR: mepc=%08h sepc=%08h mcause=%08h scause=%08h mtval=%08h stval=%08h | mscratch=%08h sscratch=%08h\n",
            `CSR._MEPC,
            `CSR._SEPC,
            `CSR._MCAUSE,
            `CSR._SCAUSE,
            `CSR._MTVAL,
            `CSR._STVAL,
            `CSR._MSCRATCH,
            `CSR._SSCRATCH);

        // Line 5: IE stage decoded instruction info
        $fwrite(diag_fd, "  IE: type=%0d csr_op=%0d csr_addr=%03h mret=%0b sret=%0b ecall=%0b ebreak=%0b sfence=%0b | rs1=%0d rs2=%0d rd=%0d wb_sel=%0d amo=%0d | exec_res=%08h alu_res=%08h csr_res=%08h\n",
            `CORE.ctrl_bus_ie.inst_type,
            `CORE.ctrl_bus_ie.csr_op,
            `CORE.ctrl_bus_ie.csr_addr,
            `CORE.ctrl_bus_ie.mret,
            `CORE.ctrl_bus_ie.sret,
            `CORE.ctrl_bus_ie.ecall,
            `CORE.ctrl_bus_ie.ebreak,
            `CORE.ctrl_bus_ie.sfence_vma,
            `CORE.ctrl_bus_ie.rs1_int,
            `CORE.ctrl_bus_ie.rs2_int,
            `CORE.ctrl_bus_ie.rd_int,
            `CORE.ctrl_bus_ie.wb_sel,
            `CORE.ctrl_bus_ie.amo_op,
            `CORE.exec_result_ie,
            `CORE.alu_result,
            `CORE.csr_result);

        // Line 6: IE operand values (forwarded)
        // fwdb: 0=NO_FORWARD, 1=FORWARD_IMEM, 2=FORWARD_IWB
        $fwrite(diag_fd, "  OPRS: rs1_ie=%08h rs2_ie=%08h opA=%08h opB=%08h | fwdb=%0d opB_fwd=%08h | csr_data=%08h mem_op=%0d\n",
            `CORE.rs1_forwarded_ie,
            `CORE.rs2_forwarded_ie,
            `CORE.alu_operand_a,
            `CORE.alu_operand_b,
            `CORE.forwardb_ie,
            `CORE.opB_forwarded_data,
            `CSR.csr_data,
            `CORE.ctrl_bus_ie.mem_op);

        // Line 7: MMU instruction side
        $fwrite(diag_fd, "  IMMU: i_vaddr=%08h i_paddr=%08h i_xlate=%0b i_fault=%0b i_fault_r=%0b fault_addr_r=%08h | itlb_hit=%0b\n",
            `MMU.i_vaddr_i,
            `CORE.i_paddr,
            `MMU.i_translate,
            `CORE.mmu_i_fault,
            `CORE.mmu_i_fault_r,
            `CORE.mmu_i_fault_addr_r,
            `MMU.itlb_hit);

        // Line 8: MMU data side
        $fwrite(diag_fd, "  DMMU: d_vaddr=%08h d_paddr=%08h d_xlate=%0b d_fault=%0b d_store=%0b | dtlb_hit=%0b\n",
            `MMU.d_vaddr_i,
            `MMU.d_paddr_o,
            `MMU.d_translate,
            `CORE.mmu_d_fault,
            `MMU.d_store_i,
            `MMU.dtlb_hit);

        // Line 9: PTW state
        $fwrite(diag_fd, "  PTW: state=%0d vaddr=%08h pte=%08h for_insn=%0b for_store=%0b mega=%0b | perm_fault=%0b priv_fault=%0b pte_v=%0b pte_r=%0b pte_w=%0b pte_x=%0b pte_a=%0b pte_d=%0b pte_u=%0b\n",
            `MMU.ptw_state,
            `MMU.ptw_vaddr,
            `MMU.ptw_pte,
            `MMU.ptw_for_insn,
            `MMU.ptw_for_store,
            `MMU.ptw_mega,
            `MMU.ptw_perm_fault,
            `MMU.ptw_priv_fault,
            `MMU.pte_v,
            `MMU.pte_r,
            `MMU.pte_w,
            `MMU.pte_x,
            `MMU.pte_a,
            `MMU.pte_d,
            `MMU.pte_u);

        // Line 10: Writeback stage + memory
        $fwrite(diag_fd, "  WB: exec_iwb=%08h rd_iwb=%08h wb_data=%08h rd=%0d wb_sel=%0d stale=%0b | imem_type=%0d imem_rd=%0d srcB_imem_diag=%08h\n",
            `CORE.exec_result_iwb,
            `CORE.readdata_iwb,
            `CORE.write_back_data,
            `CORE.ctrl_bus_iwb.rd_int,
            `CORE.ctrl_bus_iwb.wb_sel,
            `CORE.stale_iwb,
            `CORE.ctrl_bus_imem.inst_type,
            `CORE.ctrl_bus_imem.rd_int,
            `CORE.srcB_imem_diag);

        // =====================================================================
        // Infinite loop detection
        // =====================================================================
        if (`CORE.pc_id == diag_last_pc)
            diag_pc_repeat = diag_pc_repeat + 1;
        else begin
            diag_pc_repeat = 0;
            diag_last_pc = `CORE.pc_id;
        end
        if (diag_pc_repeat == 500) begin
            $fwrite(diag_fd, "STUCK[%0d] pc_id=%08h repeated 500 times! ie_stall=%0b mmu_i_stall=%0b mmu_d_stall=%0b insert_bubble=%0b ptw_state=%0d amo_stall=%0b\n",
                diag_cyc, `CORE.pc_id,
                `CORE.ie_stall,
                `CORE.mmu_i_stall,
                `CORE.mmu_d_stall,
                `CORE.insert_bubble,
                `MMU.ptw_state,
                `CORE.amo_stall);
            $display("STUCK[%0d] pc_id=%08h repeated 500 times!", diag_cyc, `CORE.pc_id);
            $fclose(diag_fd);
            $finish;
        end

    end // !reset
end

`undef CORE
`undef CSR
`undef MMU
`undef ITRAP

`endif // DV_DIAG_TRACE
