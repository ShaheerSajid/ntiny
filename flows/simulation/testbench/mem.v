module mem (
	address_a,
	address_b,
	byteena_a,
	byteena_b,
	clock_a,
	clock_b,
	data_a,
	data_b,
	enable_a,
	enable_b,
	wren_a,
	wren_b,
	q_a,
	q_b);

	input	[13:0]  address_a;
	input	[11:0]  address_b;
	input	[3:0]  byteena_a;
	input	[3:0]  byteena_b;
	input	  clock_a;
	input	  clock_b;
	input	[31:0]  data_a;
	input	[31:0]  data_b;
	input	  enable_a;
	input	  enable_b;
	input	  wren_a;
	input	  wren_b;
	output [31:0]  q_a;
	output [31:0]  q_b;

arm_imem m1(.Q(q_a), .CLK(clock_a), .CEN(~enable_a), .WEN(~byteena_a), .A(address_a),.D(data_a), .EMA(0), .GWEN(~wren_a), .RETN(1));
arm_dmem m2(.Q(q_b), .CLK(clock_b), .CEN(~enable_b), .WEN(~byteena_b), .A(address_b),.D(data_b), .EMA(0), .GWEN(~wren_b), .RETN(1));

endmodule
