module sim_uart
(
		input clk_i,
		input write,
		input [7:0]data
);


always @ (posedge clk_i) begin
	if (write )
	begin
		$write("%c", data);
		if(data == 35)
		$finish;
	end
end
endmodule
