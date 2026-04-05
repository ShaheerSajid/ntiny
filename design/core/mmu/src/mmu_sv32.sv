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
    input  logic        d_req_i,      // load or store active (from core2avl, post-suppression)
    input  logic        d_req_raw_i,  // raw pipeline data request (pre-suppression, for PMP)
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
    output logic        ptw_active_o, // PTW is using dbus

    // PMP configuration from CSR unit
    input  logic [31:0] pmpcfg_i  [4],
    input  logic [31:0] pmpaddr_i [16],

    // PMP access fault outputs (cause 1/5/7)
    output logic        i_access_fault_o,
    output logic [31:0] i_access_fault_addr_o,
    output logic        d_access_fault_o,
    output logic [31:0] d_access_fault_addr_o
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

    // ITLB physical address construction — 34-bit Sv32
    wire [33:0] i_paddr_tlb_34 = itlb_entry.mega
        ? {itlb_entry.ppn1, i_vpn0, i_vaddr_i[11:0]}          // megapage: PPN[1] + VPN[0] + offset
        : {itlb_entry.ppn1, itlb_entry.ppn0, i_vaddr_i[11:0]}; // 4KB: PPN[1:0] + offset
    wire [31:0] i_paddr_tlb = i_paddr_tlb_34[31:0];  // bus address (32-bit)

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

    // DTLB physical address construction — 34-bit Sv32
    wire [33:0] d_paddr_tlb_34 = dtlb_entry.mega
        ? {dtlb_entry.ppn1, d_vpn0, d_vaddr_i[11:0]}
        : {dtlb_entry.ppn1, dtlb_entry.ppn0, d_vaddr_i[11:0]};
    wire [31:0] d_paddr_tlb = d_paddr_tlb_34[31:0];  // bus address (32-bit)

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
    logic [1:0]  ptw_priv;          // latched privilege at PTW start
    logic        ptw_sum;           // latched SUM bit at PTW start
    logic        flush_prev;        // 1-cycle delay after flush to suppress stale requests
    always_ff @(posedge clk_i or posedge reset_i)
        if (reset_i) flush_prev <= 1'b0;
        else         flush_prev <= flush_i;

    // Suppress stale TLB-hit i_faults after flush until the ITLB resolves.
    // After a redirect (SRET/branch/trap), the old ITLB entry may still match
    // the old address. Suppress TLB-hit faults while the fetch is stalled
    // (PTW walking for the new target). Once the stall clears, the ITLB has
    // the correct entry and TLB-hit faults are real.
    logic flush_ifault_suppress;
    always_ff @(posedge clk_i or posedge reset_i)
        if (reset_i)                          flush_ifault_suppress <= 1'b0;
        else if (flush_i)                     flush_ifault_suppress <= 1'b1;   // start suppression
        else if (!i_stall_o && !flush_prev)   flush_ifault_suppress <= 1'b0;   // stall resolved

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
    // Use LATCHED privilege and SUM from when the PTW started, not the
    // current values — a trap can change priv/SUM mid-walk, causing the
    // PTW to incorrectly fault on U-pages when checking with S-mode priv.
    wire [1:0] ptw_check_priv = ptw_priv;
    wire       ptw_check_sum  = ptw_sum;
    always_comb begin
        if (ptw_check_priv == 2'b00)
            ptw_priv_fault = !pte_u;
        else if (ptw_check_priv == 2'b01)
            ptw_priv_fault = ptw_for_insn ? pte_u : (pte_u && !ptw_check_sum);
        else
            ptw_priv_fault = 1'b0;
    end

    // PTW address computation — full 34-bit Sv32 physical addresses
    // satp_ppn is 22 bits → addr[33:12], plus VPN index gives 34-bit PTE address
    wire [33:0] ptw_l1_addr_34 = {satp_ppn, 12'b0} + {22'b0, ptw_vaddr[31:22], 2'b00};
    wire [33:0] ptw_l0_addr_34 = {pte_ppn1, pte_ppn0, 12'b0} + {22'b0, ptw_vaddr[21:12], 2'b00};
    // Bus address is 32-bit (RAM is below 4GB); PMP uses full 34-bit
    wire [31:0] ptw_l1_addr = ptw_l1_addr_34[31:0];
    wire [31:0] ptw_l0_addr = ptw_l0_addr_34[31:0];

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
            ptw_priv <= 2'b11;
            ptw_sum <= 1'b0;
            ptw_l1_pte_saved <= '0;
        end else if (flush_i || flush_prev) begin
            // Pipeline flush (trap/interrupt): abort any in-flight PTW walk.
            // Also suppress for 1 cycle after flush to prevent stale d_req_i
            // from starting a new walk with wrong privilege (trap changed priv).
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
                        ptw_priv <= d_eff_priv;  // latch priv at walk start
                        ptw_sum <= sum_bit;      // latch SUM at walk start
                    end else if (i_translate && i_req_i && !itlb_hit) begin
                        ptw_state <= PTW_L1;
                        ptw_vaddr <= i_vaddr_i;
                        ptw_for_store <= 1'b0;
                        ptw_for_insn <= 1'b1;
                        ptw_mega <= 1'b0;
                        ptw_priv <= i_priv_i;    // latch insn priv at walk start
                        ptw_sum <= sum_bit;
                    end
                end

                PTW_L1: begin
                    if (ptw_pmp_denied) begin
                        ptw_state <= PTW_FAULT;
                    end else if (!ptw_stall_i) begin
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
                    if (ptw_pmp_denied) begin
                        ptw_state <= PTW_FAULT;
                    end else if (!ptw_stall_i) begin
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

    // PTW memory interface — suppress request on PMP denial
    wire ptw_in_read = (ptw_state == PTW_L1) || (ptw_state == PTW_L0);
    assign ptw_active_o = ptw_in_read && !ptw_pmp_denied;
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

    // ── PMP checkers ───────────────────────────────────────────────

    // Instruction-side PMP check (always on physical address, even when MMU off)
    // Instruction physical address is 32-bit; zero-extend to 34-bit for PMP
    logic i_pmp_fault;
    wire [31:0] i_paddr_out = i_translate ? i_paddr_tlb : i_vaddr_i;

    pmp_checker pmp_i_check (
        .addr_i     (i_translate ? i_paddr_tlb_34 : {2'b0, i_vaddr_i}),  // 34-bit
        .priv_i     (i_priv_i),
        .is_read_i  (1'b0),
        .is_write_i (1'b0),
        .is_exec_i  (1'b1),
        .pmpcfg_i   (pmpcfg_i),
        .pmpaddr_i  (pmpaddr_i),
        .fault_o    (i_pmp_fault)
    );

    // Data/PTW PMP check (shared — PTW and data are mutually exclusive)
    // PTW uses full 34-bit address from Sv32 page table walk;
    // normal data uses 32-bit zero-extended to 34-bit.
    wire [31:0] d_paddr_out = d_translate ? d_paddr_tlb : d_vaddr_i;
    wire [33:0] ptw_pmp_addr_34 = (ptw_state == PTW_L1) ? ptw_l1_addr_34 :
                                  (ptw_state == PTW_L0) ? ptw_l0_addr_34 : 34'd0;
    wire [33:0] d_pmp_addr  = ptw_in_read ? ptw_pmp_addr_34 :
                              d_translate ? d_paddr_tlb_34 : {2'b0, d_vaddr_i};
    // PTW implicit reads use the privilege that initiated the walk (S or U mode),
    // NOT M-mode. Per RISC-V spec §3.7.1, PMP checks on page table accesses use
    // the effective privilege of the access that triggered the translation.
    wire [1:0]  d_pmp_priv  = ptw_in_read ? ptw_priv   : d_eff_priv;
    wire        d_pmp_read  = ptw_in_read ? 1'b1        : (d_req_i && !d_store_i);
    wire        d_pmp_write = ptw_in_read ? 1'b0        : (d_req_i && d_store_i);

    logic d_pmp_fault_comb;
    pmp_checker pmp_d_check (
        .addr_i     (d_pmp_addr),
        .priv_i     (d_pmp_priv),
        .is_read_i  (d_pmp_read),
        .is_write_i (d_pmp_write),
        .is_exec_i  (1'b0),
        .pmpcfg_i   (pmpcfg_i),
        .pmpaddr_i  (pmpaddr_i),
        .fault_o    (d_pmp_fault_comb)
    );

    // Register d_pmp_fault to break combinational loop through Verilator's
    // UNOPTFLAT resolution (d_pmp_fault → ptw_active → flush_i → settles wrong).
    // 1-cycle latency: PTW PMP denial fires next cycle, acceptable because
    // PTW L1/L0 states wait for !ptw_stall_i anyway.
    logic d_pmp_fault;
    always_ff @(posedge clk_i or posedge reset_i)
        if (reset_i) d_pmp_fault <= 1'b0;
        else         d_pmp_fault <= d_pmp_fault_comb;

    // PTW PMP denial — use COMBINATIONAL d_pmp_fault_comb for immediate blocking.
    // This doesn't create a loop: ptw_pmp_denied → ptw_active_o → d_stall_o/bus_mux
    // are all downstream and don't feed back to PMP checker inputs.
    wire ptw_pmp_denied = d_pmp_fault_comb && ptw_in_read;

    // Track if PTW fault was caused by PMP (for access fault vs page fault distinction)
    // Track if PTW fault was caused by PMP (uses combinational ptw_pmp_denied)
    logic ptw_pmp_fault_r;
    always_ff @(posedge clk_i or posedge reset_i)
        if (reset_i)                                      ptw_pmp_fault_r <= 1'b0;
        else if (ptw_state == PTW_IDLE)                   ptw_pmp_fault_r <= 1'b0;
        else if (d_pmp_fault_comb && ptw_in_read)         ptw_pmp_fault_r <= 1'b1;

    // ── Output logic ─────────────────────────────────────────────

    // Instruction side
    assign i_paddr_o = i_paddr_out;
    assign i_stall_o = i_translate && i_req_i && (!itlb_hit || ptw_active_o);
    // Page faults (cause 12): TLB permission fail or PTW fault (not PMP-caused)
    // Suppress TLB-hit faults for 2 cycles after flush (flush_i || flush_prev)
    // to prevent stale faults from the old fetch path after redirects.
    assign i_fault_o = (!flush_i && !flush_ifault_suppress && i_translate && i_req_i && itlb_hit && !i_perm_ok) ||
                       (i_translate && ptw_state == PTW_FAULT && ptw_for_insn && !ptw_pmp_fault_r);
    assign i_fault_addr_o = (ptw_state == PTW_FAULT && ptw_for_insn) ? ptw_vaddr : i_vaddr_i;
    // Access faults (cause 1): PMP denial on fetch or PTW PMP fault for insn
    // Instruction PMP fault is registered (mmu_i_access_fault_r in core_top), no comb loop risk
    assign i_access_fault_o = (i_req_i && i_pmp_fault) ||
                              (ptw_state == PTW_FAULT && ptw_for_insn && ptw_pmp_fault_r);
    assign i_access_fault_addr_o = (ptw_state == PTW_FAULT && ptw_for_insn) ? ptw_vaddr : i_vaddr_i;

    // Data side
    assign d_paddr_o = d_paddr_out;
    assign d_stall_o = d_translate && d_req_i && (!dtlb_hit || ptw_active_o);
    // Page faults (cause 13/15)
    // NO !flush_i gate — d_fault_o is fully registered in core_top (mmu_d_fault_r)
    // and the registered path has `if (interrupt_valid) clear` priority, so stale
    // faults during flush are discarded (interrupt_valid is already high from the
    // real trap that caused the flush). IE stall holds the faulting instruction.
    assign d_fault_o = (d_translate && d_req_i && dtlb_hit && !d_perm_ok) ||
                       (d_translate && ptw_state == PTW_FAULT && !ptw_for_insn && !ptw_pmp_fault_r);
    assign d_fault_addr_o = (ptw_state == PTW_FAULT && !ptw_for_insn) ? ptw_vaddr : d_vaddr_i;
    // Access faults (cause 5/7): PMP denial on data access or PTW PMP fault for data
    // Data PMP fault: uses d_req_raw_i (pipeline's raw request) to avoid
    // combinational loop: d_req_i comes from core2avl which is downstream
    // of the bus suppression that this fault triggers.
    // Use combinational d_pmp_fault_comb for immediate fault detection.
    // The registered d_pmp_fault is used only for interrupt_ctrl (via core_top).
    assign d_access_fault_o = (d_req_raw_i && !ptw_in_read && d_pmp_fault_comb) ||
                              (ptw_state == PTW_FAULT && !ptw_for_insn && ptw_pmp_fault_r);
    assign d_access_fault_addr_o = (ptw_state == PTW_FAULT && !ptw_for_insn) ? ptw_vaddr : d_vaddr_i;

endmodule
