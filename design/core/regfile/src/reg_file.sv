module reg_file
  #(parameter bit ZERO_REG = 1) // 1 = integer (x0 hardwired to 0), 0 = float (no zero reg)
  (
    input logic clk_i,
    input logic reset_i,
    input logic stall_i,
    input logic write_i,
    input logic[4:0] wraddr_i,
    input logic[31:0] wrdata_i,
    input logic[4:0] rdaddra_i,
    input logic[4:0] rdaddrb_i,
    input logic[4:0] rdaddrc_i,
    output logic[31:0] rddataa_o,
    output logic[31:0] rddatab_o,
    output logic[31:0] rddatac_o

  );

   var logic [31:0] 	 regfile [0:31] ;

   generate
     if (ZERO_REG) begin : gen_zero_reg
       assign rddataa_o = (rdaddra_i==0)?0:regfile[rdaddra_i];
       assign rddatab_o = (rdaddrb_i==0)?0:regfile[rdaddrb_i];
       assign rddatac_o = (rdaddrc_i==0)?0:regfile[rdaddrc_i];
     end else begin : gen_no_zero_reg
       assign rddataa_o = regfile[rdaddra_i];
       assign rddatab_o = regfile[rdaddrb_i];
       assign rddatac_o = regfile[rdaddrc_i];
     end
   endgenerate

   always_ff@(posedge clk_i or posedge reset_i) begin
    if(reset_i)
    begin
      for(int i=0;i<32;i=i+1)
        regfile[i]<=0;
    end
	else if (!stall_i && write_i && (!ZERO_REG || wraddr_i != 0)) regfile[wraddr_i] <= wrdata_i;
   end

endmodule
