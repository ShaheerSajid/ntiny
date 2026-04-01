// Sv32 MMU — ITLB, DTLB, shared Page Table Walker
// Sits inside core_top between virtual addresses (PC / ALU) and physical buses

import common_pkg::*;
import core_pkg::*;

module mmu_sv32 (
    input  logic        clk_i,
    input  logic        reset_i,

    // CSR configuration
    input  logic [31:0] satp_i,       // MODE[31], ASID[30:22], PPN[21:0]
    input  logic [1:0]  priv_i,       // current privilege level (for data translation)
    input  logic [1:0]  i_priv_i,     // instruction-side privilege (may differ on MRET/SRET)
    input  logic [31:0] mstatus_i,    // MPRV[17], MPP[12:11], SUM[18], MXR[19]

    // SFENCE.VMA flush
    input  logic        sfence_i,

    // Pipeline flush — abort any in-flight PTW walk (trap/interrupt redirect)
    input  logic        flush_i,

    // Instruction address translation
    input  logic [31:0] i_vaddr_i,    // virtual address from PC
    input  logic        i_req_i,      // fetch active
    output logic [31:0] i_paddr_o,    // translated physical address
    output logic        i_stall_o,    // stall fetch (TLB miss)
    output logic        i_fault_o,    // instruction page fault (cause 12)
    output logic [31:0] i_fault_addr_o, // faulting virtual address (may differ from i_vaddr_i during PTW)

    // Data address translation
    input  logic [31:0] d_vaddr_i,    // virtual address from ALU/AMO
    input  logic        d_req_i,      // load or store active
    input  logic        d_store_i,    // 1=store, 0=load
    output logic [31:0] d_paddr_o,    // translated physical address
    output logic        d_stall_o,    // stall data access (TLB miss)
    output logic        d_fault_o,    // load/store page fault (cause 13/15)
    output logic [31:0] d_fault_addr_o, // faulting virtual address (may differ from d_vaddr_i during PTW)

    // PTW memory interface (directly drives dbus when active)
    output logic [31:0] ptw_addr_o,   // physical address for PTE read
    output logic        ptw_req_o,    // PTE read request active
    input  logic [31:0] ptw_data_i,   // PTE data from memory
    input  logic        ptw_stall_i,  // memory stall for PTW read
    output logic        ptw_active_o  // PTW is using dbus
);

    // ── Translation enable ───────────────────────────────────────
    wire sv32_en = satp_i[31];
    wire [8:0]  satp_asid = satp_i[30:22];
    wire [21:0] satp_ppn  = satp_i[21:0];

    // Effective privilege: for data, MPRV overrides to MPP
    wire [1:0] d_eff_priv = (mstatus_i[17] && mstatus_i[12:11] != 2'b11)
                            ? mstatus_i[12:11] : priv_i;
    wire i_translate = sv32_en && (i_priv_i != 2'b11);
    wire d_translate = sv32_en && (d_eff_priv != 2'b11);

    // Access modifiers from mstatus
    wire sum_bit = mstatus_i[18];  // S-mode can access U pages
    wire mxr_bit = mstatus_i[19];  // loads from executable pages allowed

    // ── TLB entry type ───────────────────────────────────────────
    localparam TLB_ENTRIES = 8;

    typedef struct packed {
        logic        valid;
        logic [8:0]  asid;
        logic [9:0]  vpn1;
        logic [9:0]  vpn0;
        logic [11:0] ppn1;    // PPN[1] (12 bits for Sv32)
        logic [9:0]  ppn0;    // PPN[0] (10 bits)
        logic        mega;    // superpage (4MB)
        logic        d, a, g, u, x, w, r;
    } tlb_entry_t;

    // ── ITLB ─────────────────────────────────────────────────────
    tlb_entry_t itlb [TLB_ENTRIES];
    logic [2:0] itlb_wr_ptr;  // FIFO replacement pointer

    wire [9:0] i_vpn1 = i_vaddr_i[31:22];
    wire [9:0] i_vpn0 = i_vaddr_i[21:12];

    logic itlb_hit;
    logic [TLB_ENTRIES-1:0] itlb_match;
    tlb_entry_t itlb_entry;

    // ITLB parallel lookup
    always_comb begin
        itlb_hit = 1'b0;
        itlb_entry = '0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            itlb_match[i] = itlb[i].valid &&
                            (itlb[i].vpn1 == i_vpn1) &&
                            (itlb[i].mega || itlb[i].vpn0 == i_vpn0) &&
                            (itlb[i].g || itlb[i].asid == satp_asid);
            if (itlb_match[i]) begin
                itlb_hit = 1'b1;
                itlb_entry = itlb[i];
            end
        end
    end

    // ITLB physical address construction
    wire [31:0] i_paddr_tlb = itlb_entry.mega
        ? {itlb_entry.ppn1, i_vpn0, i_vaddr_i[11:0]}          // megapage: PPN[1] + VPN[0] + offset
        : {itlb_entry.ppn1, itlb_entry.ppn0, i_vaddr_i[11:0]}; // 4KB: PPN[1:0] + offset

    // ITLB permission check
    // NOTE: SUM (mstatus[18]) only applies to DATA accesses. Instruction fetches from
    // U-mode pages are ALWAYS forbidden in S-mode, regardless of SUM (spec §3.1.6.3).
    wire i_perm_ok = itlb_entry.x &&          // must be executable
                     itlb_entry.a &&          // accessed bit
                     ((i_priv_i == 2'b00) ? itlb_entry.u :    // U-mode needs U bit
                      (i_priv_i == 2'b01) ? !itlb_entry.u :   // S-mode: U pages always forbidden for insn fetch
                      1'b1);                                   // M-mode: always OK

    // ── DTLB ─────────────────────────────────────────────────────
    tlb_entry_t dtlb [TLB_ENTRIES];
    logic [2:0] dtlb_wr_ptr;

    wire [9:0] d_vpn1 = d_vaddr_i[31:22];
    wire [9:0] d_vpn0 = d_vaddr_i[21:12];

    logic dtlb_hit;
    logic [TLB_ENTRIES-1:0] dtlb_match;
    tlb_entry_t dtlb_entry;

    // DTLB parallel lookup
    always_comb begin
        dtlb_hit = 1'b0;
        dtlb_entry = '0;
        for (int i = 0; i < TLB_ENTRIES; i++) begin
            dtlb_match[i] = dtlb[i].valid &&
                            (dtlb[i].vpn1 == d_vpn1) &&
                            (dtlb[i].mega || dtlb[i].vpn0 == d_vpn0) &&
                            (dtlb[i].g || dtlb[i].asid == satp_asid);
            if (dtlb_match[i]) begin
                dtlb_hit = 1'b1;
                dtlb_entry = dtlb[i];
            end
        end
    end

    // DTLB physical address construction
    wire [31:0] d_paddr_tlb = dtlb_entry.mega
        ? {dtlb_entry.ppn1, d_vpn0, d_vaddr_i[11:0]}
        : {dtlb_entry.ppn1, dtlb_entry.ppn0, d_vaddr_i[11:0]};

    // DTLB permission check
    wire d_read_ok  = dtlb_entry.r || (mxr_bit && dtlb_entry.x);  // MXR allows X as R
    wire d_write_ok = dtlb_entry.w && dtlb_entry.d;               // writable + dirty
    wire d_access_ok = dtlb_entry.a &&
                       ((d_eff_priv == 2'b00) ? dtlb_entry.u :
                        (d_eff_priv == 2'b01) ? (!dtlb_entry.u || sum_bit) :
                        1'b1);
    wire d_perm_ok = d_access_ok && (d_store_i ? d_write_ok : d_read_ok);

    // ── PTW (Page Table Walker) ──────────────────────────────────
    typedef enum logic [2:0] {
        PTW_IDLE,
        PTW_L1,       // reading level-1 PTE
        PTW_L0_WAIT,  // wait 1 cycle for L1 rvalid to clear before L0 read
        PTW_L0,       // reading level-0 PTE
        PTW_FILL,     // write TLB entry
        PTW_FAULT     // page fault detected
    } ptw_state_t;

    ptw_state_t ptw_state, ptw_next;
    logic [31:0] ptw_pte;           // captured PTE
    logic [31:0] ptw_vaddr;         // virtual address being translated
    logic        ptw_for_store;     // translation is for a store
    logic        ptw_for_insn;      // translation is for instruction fetch
    logic        ptw_mega;          // level-1 leaf = megapage

    // PTE fields
    wire pte_v = ptw_pte[0];
    wire pte_r = ptw_pte[1];
    wire pte_w = ptw_pte[2];
    wire pte_x = ptw_pte[3];
    wire pte_u = ptw_pte[4];
    wire pte_g = ptw_pte[5];
    wire pte_a = ptw_pte[6];
    wire pte_d = ptw_pte[7];
    wire [11:0] pte_ppn1 = ptw_pte[31:20];
    wire [9:0]  pte_ppn0 = ptw_pte[19:10];

    wire pte_is_leaf = pte_r || pte_x;  // leaf if R or X set
    // Invalid PTE: not valid, or reserved encoding (W without R)
    wire pte_invalid = !pte_v || (!pte_r && pte_w);

    // Megapage alignment check: PPN[0] must be zero for aligned 4MB page
    wire mega_misaligned = (|pte_ppn0);

    // Permission check for the PTE being walked
    logic ptw_perm_fault;
    always_comb begin
        if (ptw_for_insn) begin
            // Instruction: need X, A
            ptw_perm_fault = !pte_x || !pte_a;
        end else if (ptw_for_store) begin
            // Store: need W, D, A
            ptw_perm_fault = !pte_w || !pte_d || !pte_a;
        end else begin
            // Load: need R (or X if MXR), A
            ptw_perm_fault = !(pte_r || (mxr_bit && pte_x)) || !pte_a;
        end
    end

    // U/S permission check
    logic ptw_priv_fault;
    wire [1:0] ptw_check_priv = ptw_for_insn ? i_priv_i : d_eff_priv;
    always_comb begin
        if (ptw_check_priv == 2'b00)
            ptw_priv_fault = !pte_u;             // U-mode needs U bit
        else if (ptw_check_priv == 2'b01)
            // SUM only applies to data; instruction fetch from U-pages always faults in S-mode
            ptw_priv_fault = ptw_for_insn ? pte_u : (pte_u && !sum_bit);
        else
            ptw_priv_fault = 1'b0;               // M-mode OK
    end

    // PTW address computation
    wire [31:0] ptw_l1_addr = {satp_ppn[19:0], 12'b0} + {20'b0, ptw_vaddr[31:22], 2'b00};
    wire [31:0] ptw_l0_addr = {pte_ppn1, pte_ppn0, 12'b0} + {20'b0, ptw_vaddr[21:12], 2'b00};

    // Latched L1 PTE for address construction during L0
    logic [31:0] ptw_l1_pte_saved;

    // PTW FSM
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            ptw_state <= PTW_IDLE;
            ptw_pte <= '0;
            ptw_vaddr <= '0;
            ptw_for_store <= 1'b0;
            ptw_for_insn <= 1'b0;
            ptw_mega <= 1'b0;
            ptw_l1_pte_saved <= '0;
        end else if (flush_i) begin
            // Pipeline flush (trap/interrupt): abort any in-flight PTW walk.
            // The PTW was walking a stale virtual address that is no longer relevant.
            ptw_state <= PTW_IDLE;
        end else begin
            case (ptw_state)
                PTW_IDLE: begin
                    // Priority: DTLB miss > ITLB miss
                    if (d_translate && d_req_i && !dtlb_hit) begin
                        ptw_state <= PTW_L1;
                        ptw_vaddr <= d_vaddr_i;
                        ptw_for_store <= d_store_i;
                        ptw_for_insn <= 1'b0;
                        ptw_mega <= 1'b0;
                    end else if (i_translate && i_req_i && !itlb_hit) begin
                        ptw_state <= PTW_L1;
                        ptw_vaddr <= i_vaddr_i;
                        ptw_for_store <= 1'b0;
                        ptw_for_insn <= 1'b1;
                        ptw_mega <= 1'b0;
                    end
                end

                PTW_L1: begin
                    if (!ptw_stall_i) begin
                        ptw_pte <= ptw_data_i;
                        ptw_l1_pte_saved <= ptw_data_i;
                        // Check PTE next cycle
                        if (!ptw_data_i[0] || (!ptw_data_i[1] && ptw_data_i[2])) begin
                            // Invalid or reserved encoding
                            ptw_state <= PTW_FAULT;
                        end else if (ptw_data_i[1] || ptw_data_i[3]) begin
                            // Leaf at level 1 = megapage
                            if (|ptw_data_i[19:10]) begin
                                // Misaligned megapage
                                ptw_state <= PTW_FAULT;
                            end else begin
                                ptw_mega <= 1'b1;
                                ptw_state <= PTW_FILL;
                            end
                        end else begin
                            // Pointer: go to level 0 (via wait state to drain stale rvalid)
                            ptw_state <= PTW_L0_WAIT;
                        end
                    end
                end

                PTW_L0_WAIT: begin
                    // One dead cycle: ptw_active=0, no request issued.
                    // This lets the stale rvalid from the L1 read clear
                    // before we start the L0 read.
                    ptw_state <= PTW_L0;
                end

                PTW_L0: begin
                    if (!ptw_stall_i) begin
                        ptw_pte <= ptw_data_i;
                        if (!ptw_data_i[0] || (!ptw_data_i[1] && ptw_data_i[2])) begin
                            ptw_state <= PTW_FAULT;
                        end else if (ptw_data_i[1] || ptw_data_i[3]) begin
                            // Leaf at level 0 = 4KB page
                            ptw_mega <= 1'b0;
                            ptw_state <= PTW_FILL;
                        end else begin
                            // Pointer at level 0 = invalid
                            ptw_state <= PTW_FAULT;
                        end
                    end
                end

                PTW_FILL: begin
                    // Permission check, then fill TLB or fault
                    if (ptw_perm_fault || ptw_priv_fault) begin
                        ptw_state <= PTW_FAULT;
                    end else begin
                        ptw_state <= PTW_IDLE;
                        // TLB fill happens via separate logic below
                    end
                end

                PTW_FAULT: begin
                    // Fault signaled for one cycle, then back to idle
                    ptw_state <= PTW_IDLE;
                end

                default: ptw_state <= PTW_IDLE;
            endcase
        end
    end

    // PTW memory interface
    assign ptw_active_o = (ptw_state == PTW_L1) || (ptw_state == PTW_L0);
    assign ptw_req_o    = ptw_active_o;
    assign ptw_addr_o   = (ptw_state == PTW_L1) ? ptw_l1_addr :
                          (ptw_state == PTW_L0) ? ptw_l0_addr : 32'b0;

    // ── TLB fill logic ───────────────────────────────────────────
    wire tlb_fill = (ptw_state == PTW_FILL) && !ptw_perm_fault && !ptw_priv_fault;

    tlb_entry_t fill_entry;
    always_comb begin
        fill_entry.valid = 1'b1;
        fill_entry.asid  = satp_asid;
        fill_entry.vpn1  = ptw_vaddr[31:22];
        fill_entry.vpn0  = ptw_vaddr[21:12];
        fill_entry.ppn1  = ptw_pte[31:20];
        fill_entry.ppn0  = ptw_pte[19:10];
        fill_entry.mega  = ptw_mega;
        fill_entry.d     = ptw_pte[7];
        fill_entry.a     = ptw_pte[6];
        fill_entry.g     = ptw_pte[5];
        fill_entry.u     = ptw_pte[4];
        fill_entry.x     = ptw_pte[3];
        fill_entry.w     = ptw_pte[2];
        fill_entry.r     = ptw_pte[1];
    end

    // ITLB write (fill on PTW completion for insn, flush on SFENCE)
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < TLB_ENTRIES; i++)
                itlb[i].valid <= 1'b0;
            itlb_wr_ptr <= '0;
        end else if (sfence_i) begin
            for (int i = 0; i < TLB_ENTRIES; i++)
                itlb[i].valid <= 1'b0;
            itlb_wr_ptr <= '0;
        end else if (tlb_fill && ptw_for_insn) begin
            itlb[itlb_wr_ptr] <= fill_entry;
            itlb_wr_ptr <= itlb_wr_ptr + 1;
        end
    end

    // DTLB write
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            for (int i = 0; i < TLB_ENTRIES; i++)
                dtlb[i].valid <= 1'b0;
            dtlb_wr_ptr <= '0;
        end else if (sfence_i) begin
            for (int i = 0; i < TLB_ENTRIES; i++)
                dtlb[i].valid <= 1'b0;
            dtlb_wr_ptr <= '0;
        end else if (tlb_fill && !ptw_for_insn) begin
            dtlb[dtlb_wr_ptr] <= fill_entry;
            dtlb_wr_ptr <= dtlb_wr_ptr + 1;
        end
    end

    // ── Output logic ─────────────────────────────────────────────

    // Instruction side
    assign i_paddr_o = i_translate ? i_paddr_tlb : i_vaddr_i;
    assign i_stall_o = i_translate && i_req_i && (!itlb_hit || ptw_active_o);
    assign i_fault_o = (i_translate && i_req_i && itlb_hit && !i_perm_ok) ||
                       (i_translate && ptw_state == PTW_FAULT && ptw_for_insn);
    // Fault address: PTW fault uses the address that was being walked, not current i_vaddr
    assign i_fault_addr_o = (ptw_state == PTW_FAULT && ptw_for_insn) ? ptw_vaddr : i_vaddr_i;

    // Data side
    assign d_paddr_o = d_translate ? d_paddr_tlb : d_vaddr_i;
    assign d_stall_o = d_translate && d_req_i && (!dtlb_hit || ptw_active_o);
    assign d_fault_o = (d_translate && d_req_i && dtlb_hit && !d_perm_ok) ||
                       (d_translate && ptw_state == PTW_FAULT && !ptw_for_insn);
    // Fault address: PTW fault uses the address that was being walked
    assign d_fault_addr_o = (ptw_state == PTW_FAULT && !ptw_for_insn) ? ptw_vaddr : d_vaddr_i;

endmodule
