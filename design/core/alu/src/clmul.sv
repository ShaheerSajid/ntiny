// Carry-less multiply (Zbc) — single-cycle XOR-tree implementation.
//
// Computes the full 64-bit product over GF(2):
//   for i in 0..31: if rs2[i]: result ^= (rs1 << i)
// Caller picks slice via the bit_op enum:
//   CLMUL  : result_o[31:0]
//   CLMULH : result_o[63:32]
//   CLMULR : result_o[62:31]
//
// Synthesizes to a 32-deep XOR tree. If the critical path proves too
// long for the SoC clock target, swap for a multi-cycle FSM (32-cycle).
module clmul (
    input  logic [31:0] in1_i,    // rs1
    input  logic [31:0] in2_i,    // rs2
    output logic [63:0] result_o
);

    logic [63:0] partial [32];

    always_comb begin
        for (int i = 0; i < 32; i++)
            partial[i] = in2_i[i] ? ({32'd0, in1_i} << i) : 64'd0;
    end

    always_comb begin
        result_o = 64'd0;
        for (int i = 0; i < 32; i++)
            result_o ^= partial[i];
    end

endmodule
