// ── Register file ────────────────────────────────────────────────────
// 32 entries, three combinational read ports (a/b for rs1/rs2, c for the
// rs3 of FP fused multiply-add) and one synchronous write port. The same
// module is used twice: ZERO_REG=1 for the integer file (x0 reads as 0 and
// is never written) and ZERO_REG=0 for the FP file (f0 is a normal register).
// See microarch doc: "Decode and execute datapath" -> reg_file.
module reg_file
  #(parameter bit ZERO_REG = 1) // 1 = integer (x0 hardwired to 0), 0 = float (no zero reg)
  (
    input logic clk_i,
    input logic reset_i,
    input logic stall_i,          // hold the write when the pipe is stalled
    input logic write_i,          // write-enable for this cycle
    input logic[4:0] wraddr_i,    // destination register (rd)
    input logic[31:0] wrdata_i,   // write data (the WB result)
    input logic[4:0] rdaddra_i,   // read port a address (rs1)
    input logic[4:0] rdaddrb_i,   // read port b address (rs2)
    input logic[4:0] rdaddrc_i,   // read port c address (rs3, FP only)
    output logic[31:0] rddataa_o,
    output logic[31:0] rddatab_o,
    output logic[31:0] rddatac_o

  );

   var logic [31:0] 	 regfile [0:31] ; // the 32 architectural registers

   // Combinational reads. In the integer file, address 0 forces a 0 result
   // so x0 always reads as zero regardless of what was last written.
   generate
     if (ZERO_REG) begin : gen_zero_reg
       assign rddataa_o = (rdaddra_i==0)?0:regfile[rdaddra_i];
       assign rddatab_o = (rdaddrb_i==0)?0:regfile[rdaddrb_i];
       assign rddatac_o = (rdaddrc_i==0)?0:regfile[rdaddrc_i];
     end else begin : gen_no_zero_reg
       // FP file: f0 is a real register, no special case.
       assign rddataa_o = regfile[rdaddra_i];
       assign rddatab_o = regfile[rdaddrb_i];
       assign rddatac_o = regfile[rdaddrc_i];
     end
   endgenerate

   // Synchronous write. Suppressed while stalled (so a held instruction does
   // not write twice) and, for the integer file, suppressed for x0 writes.
   always_ff@(posedge clk_i or posedge reset_i) begin
    if(reset_i)
    begin
      for(int i=0;i<32;i=i+1)
        regfile[i]<=0;
    end
	else if (!stall_i && write_i && (!ZERO_REG || wraddr_i != 0)) regfile[wraddr_i] <= wrdata_i;
   end

endmodule
