// Zkr Seed CSR entropy source — xoshiro128** PRNG
//
// Implements the RISC-V Zkr `seed` CSR (0x015).
// Returns 16 bits of entropy per read with OPST = ES16 (0b10).
// Format: {OPST[1:0], 14'b0, entropy[15:0]}
//
// Uses xoshiro128** algorithm (Blackman & Vigna, 2018):
//   - 128-bit state (4 × 32-bit words)
//   - Period 2^128 - 1
//   - Passes BigCrush, PractRand
//   - 4 XOR + 3 shift + 1 rotate per step (~200 gates)
//
// The PRNG advances on every read of the seed CSR.
// Can be reseeded by writing to the seed CSR (optional, non-standard).
// For true randomness on silicon, replace with ring oscillator + this as mixer.

module rng_seed (
    input  logic        clk_i,
    input  logic        reset_i,
    input  logic        read_i,      // seed CSR was read (advance state)
    input  logic        write_i,     // seed CSR was written (reseed, optional)
    input  logic [31:0] wdata_i,     // seed value for reseed
    output logic [31:0] seed_o       // {OPST=ES16, 14'b0, entropy[15:0]}
);

    // Zkr OPST field values
    localparam [1:0] OPST_ES16 = 2'b10;  // 16 bits of entropy available

    // xoshiro128** state (4 × 32-bit)
    logic [31:0] s [4];

    // Default seed (non-zero, spread across state)
    localparam [31:0] SEED0 = 32'hDEAD_BEEF;
    localparam [31:0] SEED1 = 32'hCAFE_BABE;
    localparam [31:0] SEED2 = 32'h1234_5678;
    localparam [31:0] SEED3 = 32'h8765_4321;

    // xoshiro128** output: rotl(s[1] * 5, 7) * 9
    function automatic logic [31:0] rotl(input logic [31:0] x, input int k);
        return (x << k) | (x >> (32 - k));
    endfunction

    wire [31:0] result = rotl(s[1] * 32'd5, 7) * 32'd9;

    // Output: OPST=ES16 + lower 16 bits of result
    assign seed_o = {OPST_ES16, 14'b0, result[15:0]};

    // State update
    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            s[0] <= SEED0;
            s[1] <= SEED1;
            s[2] <= SEED2;
            s[3] <= SEED3;
        end else if (write_i) begin
            // Reseed: XOR written value into each state word (spread entropy)
            s[0] <= s[0] ^ wdata_i;
            s[1] <= s[1] ^ {wdata_i[15:0], wdata_i[31:16]};
            s[2] <= s[2] ^ ~wdata_i;
            s[3] <= s[3] ^ {wdata_i[7:0], wdata_i[31:8]};
        end else if (read_i) begin
            // Advance xoshiro128** state
            logic [31:0] t;
            t = s[1] << 9;
            s[2] <= s[2] ^ s[0];
            s[3] <= s[3] ^ s[1];
            s[1] <= s[1] ^ s[2];
            s[0] <= s[0] ^ s[3];
            s[2] <= s[2] ^ t;
            s[3] <= rotl(s[3], 11);
        end
    end

endmodule
