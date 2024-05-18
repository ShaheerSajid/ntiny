module bootmem (
	address,
	clken,
	clock,
	q);

	input	[6:0]  address;
	input	  clken;
	input	  clock;
	output	reg [31:0]  q;

  reg [31:0] mem[0:127];
  integer i;

  initial begin
  for(i = 0; i < 128; i=i+1)
  mem[i] = 0;
  $readmemh("boot.text", mem);
  end

  always@(posedge clock)
  begin
  if(clken)
    q <= mem[address];
  end

endmodule