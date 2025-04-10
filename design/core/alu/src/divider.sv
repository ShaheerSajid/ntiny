module divider
            (
                input logic clk_i,
                            reset_i,
                            stall_i,
                            flush_i,
                            sign_i,
                            start_i,
                input logic [31:0]  dividend_i, 
                                    divider_i,
                
                output logic [31:0] quotient_o, 
                                    remainder_o,
                output  logic valid_o
            );
	
	var logic [31:0] N,D;
	var logic [31:0] Q,R;
	var logic [31:0] N_r,D_r;
	
	var logic [5:0] n;
	var logic [5:0] bits;
	var logic loaded;
	var logic N_bit;
	
  wire logic ready;
	wire logic neg_out;
	wire logic n_sign;
	wire logic d_sign;
	wire logic [31:0] abs_dividend;
	wire logic divide_by_zero;
	wire logic signed_ovf;

  assign ready = !n;
	assign n_sign = dividend_i[31];
	assign d_sign = divider_i[31];
	assign neg_out = sign_i & ((D_r[31] & ~N_r[31]) | (~D_r[31] & N_r[31]));
	assign abs_dividend = (~(sign_i & n_sign)) ? {dividend_i} : ~{dividend_i} + 1'b1;

	assign divide_by_zero = loaded && (D_r == 0);
	assign signed_ovf = loaded && sign_i && (N_r == -32'h80000000) && (D_r == -1);
	
	
	always_comb
	begin
		N_bit = N[n-1'b1];
		if(divide_by_zero || signed_ovf)
			bits = 6'd3;
		else
			casez (abs_dividend)
					32'b00000000000000000000000000000001: bits = 6'd3;
					32'b0000000000000000000000000000001?: bits = 6'd3;
					32'b000000000000000000000000000001??: bits = 6'd3;
					32'b00000000000000000000000000001???: bits = 6'd4;
					32'b0000000000000000000000000001????: bits = 6'd5;
					32'b000000000000000000000000001?????: bits = 6'd6;
					32'b00000000000000000000000001??????: bits = 6'd7;
					32'b0000000000000000000000001???????: bits = 6'd8;
					32'b000000000000000000000001????????: bits = 6'd9;
					32'b00000000000000000000001?????????: bits = 6'd10;
					32'b0000000000000000000001??????????: bits = 6'd11;
					32'b000000000000000000001???????????: bits = 6'd12;
					32'b00000000000000000001????????????: bits = 6'd13;
					32'b0000000000000000001?????????????: bits = 6'd14;
					32'b000000000000000001??????????????: bits = 6'd15;
					32'b00000000000000001???????????????: bits = 6'd16;
					32'b0000000000000001????????????????: bits = 6'd17;
					32'b000000000000001?????????????????: bits = 6'd18;
					32'b00000000000001??????????????????: bits = 6'd19;
					32'b0000000000001???????????????????: bits = 6'd20;
					32'b000000000001????????????????????: bits = 6'd21;
					32'b00000000001?????????????????????: bits = 6'd22;
					32'b0000000001??????????????????????: bits = 6'd23;
					32'b000000001???????????????????????: bits = 6'd24;
					32'b00000001????????????????????????: bits = 6'd25;
					32'b0000001?????????????????????????: bits = 6'd26;
					32'b000001??????????????????????????: bits = 6'd27;
					32'b00001???????????????????????????: bits = 6'd28;
					32'b0001????????????????????????????: bits = 6'd29;
					32'b001?????????????????????????????: bits = 6'd30;
					32'b01??????????????????????????????: bits = 6'd31;
					32'b1???????????????????????????????: bits = 6'd32;
					default: bits = 6'd3;
			endcase
	end
	
	wire logic [31:0]r_shift;
	wire logic [31:0]r_diff;
	wire logic [31:0]q;
	assign r_shift = {R[30:0], N_bit};
	assign r_diff = (r_shift >= D)? r_shift - D: r_shift;
	assign q  = (r_shift >= D)? 1 << (n-1'b1):0;
	
	
	always_ff@(posedge clk_i or posedge reset_i)
	begin
		if(reset_i)
		begin
			n <= 0;
			Q <= 0;
			R <= 0;
			N <= 0;
			D <= 0;
			N_r <= 0;
			D_r <= 0;
			loaded <= 1'b0;
		end
    else if(flush_i)
		begin
			n <= 0;
			Q <= 0;
			R <= 0;
			N <= 0;
			D <= 0;
			N_r <= 0;
			D_r <= 0;
			loaded <= 1'b0;
		end
		else if(~stall_i)
		begin
			if(!start_i || ready)
			begin
				n <= bits;
				Q <= 0;
				R <= 0;
				N <= 0;
				D <= 0;
				N_r <= 0;
				D_r <= 0;
				loaded <= 1'b0;
			end
			else if(!loaded)
			begin
				n <= bits;
				Q <= 0;
				R <= 0;
				N <= (~(sign_i & n_sign)) ? {dividend_i} : ~{dividend_i} + 1'b1;
				D <= (~(sign_i & d_sign)) ? {divider_i} : ~{divider_i} + 1'b1;
				N_r <= dividend_i;
				D_r <= divider_i;
				loaded <= 1'b1;
			end
			else if(n > 0 && loaded)
			begin
				n <= n - 1'b1;
				R <= r_diff;
				N <=N;
				D <=D;
				N_r <= N_r;
				D_r <= D_r;
				Q <= Q | q;
				loaded <= 1'b1;
			end
		end
	end
	
	always_comb begin
		if(divide_by_zero)
		begin
			quotient_o =  sign_i? -1 : 32'hFFFFFFFF;
			remainder_o = N_r;
		end
		else if(signed_ovf)
		begin
			quotient_o =  -32'h80000000;
			remainder_o = 0;
		end
		else
		begin
			quotient_o =  (~neg_out)?Q:~Q+1'b1;
		 	remainder_o = (~(sign_i & N_r[31]))?R:~R+1'b1;
		end
	end
	assign valid_o = ready;

endmodule