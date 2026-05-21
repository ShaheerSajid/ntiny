// PMP Checker — combinational Physical Memory Protection check
// Given a physical address, privilege level, and access type,
// returns whether the access is denied by PMP configuration.
//
// 16 PMP entries, supporting OFF/TOR/NA4/NAPOT modes.
// First matching entry wins (priority-ordered).
// M-mode: full access if no match (unless locked entry matches).
// S/U-mode: denied if no match.

module pmp_checker (
    input  logic [33:0] addr_i,         // 34-bit Sv32 physical address
    input  logic [1:0]  priv_i,         // effective privilege (11=M, 01=S, 00=U)
    input  logic        is_read_i,      // load / PTW read
    input  logic        is_write_i,     // store
    input  logic        is_exec_i,      // instruction fetch
    input  logic [31:0] pmpcfg_i  [4],  // pmpcfg0-3
    input  logic [31:0] pmpaddr_i [16], // pmpaddr0-15 (each holds addr[33:2])
    output logic        fault_o         // 1 = access denied
);

    // Per-entry config byte extraction
    // pmpcfg[i/4] byte (i%4): [L:7][0:6][0:5][A1:4][A0:3][X:2][W:1][R:0]
    logic [7:0]  cfg     [16];
    logic [1:0]  mode    [16];  // A field
    logic        lock    [16];  // L bit
    logic        perm_r  [16];
    logic        perm_w  [16];
    logic        perm_x  [16];

    // Address matching results
    logic        match   [16];
    logic        perm_ok [16];

    // Extract config bytes
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_cfg
            assign cfg[i]    = pmpcfg_i[i/4][(i%4)*8 +: 8];
            assign mode[i]   = cfg[i][4:3];
            assign lock[i]   = cfg[i][7];
            assign perm_r[i] = cfg[i][0];
            assign perm_w[i] = cfg[i][1];
            assign perm_x[i] = cfg[i][2];
        end
    endgenerate

    // Granule address: addr[33:2] (32 bits for Sv32 34-bit physical address)
    wire [31:0] addr_g = addr_i[33:2];

    // Address matching for each entry
    generate
        for (genvar i = 0; i < 16; i++) begin : gen_match
            // Previous entry's pmpaddr (entry 0 lower bound = 0)
            // pmpaddr holds addr[33:2] — full 32-bit register for Sv32
            wire [31:0] prev_addr = (i == 0) ? 32'd0 : pmpaddr_i[i-1];
            wire [31:0] this_addr = pmpaddr_i[i];

            // TOR: addr_g >= prev_addr && addr_g < this_addr
            wire tor_match = (addr_g >= prev_addr) && (addr_g < this_addr);

            // NA4: exact 4-byte match
            wire na4_match = (addr_g == this_addr);

            // NAPOT: XOR trick to decode region
            // pmpaddr stores: base[33:2] | (size/8 - 1)
            // napot_ones = trailing 1s mask + 1 more bit
            wire [31:0] napot_ones = pmpaddr_i[i] ^ (pmpaddr_i[i] + 32'd1);
            wire napot_match = ((addr_g ^ this_addr) & ~napot_ones) == 32'd0;

            // Select match based on mode
            always_comb begin
                case (mode[i])
                    2'b00:   match[i] = 1'b0;          // OFF
                    2'b01:   match[i] = tor_match;      // TOR
                    2'b10:   match[i] = na4_match;      // NA4
                    2'b11:   match[i] = napot_match;    // NAPOT
                endcase
            end

            // Permission check for this entry
            assign perm_ok[i] = (is_read_i  ? perm_r[i] : 1'b1) &
                                (is_write_i ? perm_w[i] : 1'b1) &
                                (is_exec_i  ? perm_x[i] : 1'b1);
        end
    endgenerate

    // Priority encoder: first matching entry wins
    always_comb begin
        // Default when PMP is implemented (NUM_PMPS > 0 — always true here:
        // 16 entries hardwired): M-mode = full access, S/U-mode = denied
        // when no entry matches. Per RISC-V Priv §3.7.1 the deny is keyed
        // on PMP being IMPLEMENTED, not on any entry being ACTIVE — so a
        // hart with all entries set to OFF still denies S/U accesses
        // (required by rv32i_m/pmp/pmps_none + pmpu_none).
        fault_o = (priv_i != 2'b11);

        // Scan entries 15→0 so entry 0 (highest priority) wins.
        for (int i = 15; i >= 0; i--) begin
            if (match[i]) begin
                if (priv_i == 2'b11 && !lock[i])
                    fault_o = 1'b0;      // M-mode + unlocked = always allowed
                else
                    fault_o = !perm_ok[i]; // Check R/W/X permissions
            end
        end
    end

endmodule
