// Zbs — single-bit operations for the bit-manipulation extension.
//
// Pure combinational. Four outputs share one barrel-shifter to build
// the bit-mask. Caller provides shamt as either rs2[4:0] (reg form)
// or imm[4:0] (immediate form) — the math is identical.
module zbs (
    input  logic [31:0] in1_i,    // rs1
    input  logic [4:0]  shamt_i,  // bit position

    output logic [31:0] bclr_o,   // rs1 & ~(1 << shamt)
    output logic [31:0] bext_o,   // (rs1 >> shamt) & 1
    output logic [31:0] binv_o,   // rs1 ^  (1 << shamt)
    output logic [31:0] bset_o    // rs1 |  (1 << shamt)
);

    wire [31:0] mask = 32'd1 << shamt_i;

    assign bclr_o = in1_i & ~mask;
    assign bext_o = {31'd0, in1_i[shamt_i]};
    assign binv_o = in1_i ^  mask;
    assign bset_o = in1_i |  mask;

endmodule
