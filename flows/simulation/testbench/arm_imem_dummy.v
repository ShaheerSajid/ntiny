module arm_imem (Q, CLK, CEN, WEN, A, D, EMA, GWEN, RETN);


  output reg[31:0] Q;
  input  CLK;
  input  CEN;
  input [3:0] WEN;
  input [12:0] A;
  input [31:0] D;
  input [2:0] EMA;
  input  GWEN;
  input  RETN;

reg [31:0] mem[0:8191];
integer i;
initial begin
for(i = 0; i < 8192; i=i+1)
	mem[i] = 0;
$readmemh("imem.text", mem);
end
always@(posedge CLK)
begin
	if(~CEN)
	begin
		Q <= mem[A];
		if(~GWEN) begin
			if(~WEN[0]) mem[A][7:0] <=   D[7:0];
			if(~WEN[1]) mem[A][15:8] <=  D[15:8];
			if(~WEN[2]) mem[A][23:16] <= D[23:16];
			if(~WEN[3]) mem[A][31:24] <= D[31:24];
		end			
	end
end
endmodule