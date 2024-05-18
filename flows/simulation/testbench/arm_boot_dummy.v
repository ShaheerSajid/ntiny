module arm_boot (Q, CLK, CEN, A, EMA);

output reg[31:0] Q;
input  CLK;
input  CEN;
input [7:0] A;
input [2:0] EMA;


reg [31:0] mem [0:255];

integer i;
initial begin
for(i = 0; i < 256; i=i+1)
	mem[i] = 0;
$readmemh("boot.text", mem);
end
always@(posedge CLK)
begin
	if(~CEN)
		Q <= mem[A];	
end

endmodule