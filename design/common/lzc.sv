module lzc
#(
    parameter WIDTH = 32
)
(
    input [WIDTH-1:0] a_i,
    output logic [$clog2(WIDTH)-1:0] cnt_o,
    output logic zero_o
);

//a recursive function that takes WIDTH as input 
//generates lzc4 until only 2 are left
//then create select logic 

localparam LZC_WIDTH = 2**$clog2(WIDTH);
localparam LSB_PAD = LZC_WIDTH-WIDTH;

logic zero;
logic [$clog2(WIDTH)-1:0] cnt;

gen_lzc #(.WIDTH(LZC_WIDTH)) gen_lzc_inst
(
    .a_i({a_i, {LSB_PAD{1'b1}}}),
    .cnt_o(cnt),
    .zero_o(zero)
);
assign zero_o = (a_i == {WIDTH{1'b0}});
assign cnt_o = zero_o? 0 : cnt;

endmodule


module gen_lzc
#(
    parameter WIDTH = 32
)
(
    input [WIDTH-1:0] a_i,
    output logic [$clog2(WIDTH)-1:0] cnt_o,
    output logic zero_o
);

//a recursive function that takes WIDTH as input 
//generates lzc4 until only 2 are left
//then create select logic 

generate
    if(WIDTH == 4)
    begin
        lzc_4 leaf(.a_i(a_i), .cnt_o(cnt_o), .zero_o(zero_o));
    end
    else
    begin
        logic [$clog2(WIDTH/2)-1:0] c[1:0];
        logic [1:0] z;
        gen_lzc #(.WIDTH(WIDTH/2)) h(.a_i(a_i[WIDTH-1:(WIDTH/2)]), .cnt_o(c[1]), .zero_o(z[1]));
        gen_lzc #(.WIDTH(WIDTH/2)) l(.a_i(a_i[(WIDTH/2) - 1:0]  ), .cnt_o(c[0]), .zero_o(z[0]));
        assign cnt_o = {z[1], z[1]? c[0]:c[1]};
        assign zero_o = &z;
    end
endgenerate

endmodule




//unit block
module lzc_4
(
    input [3:0] a_i,
    output [1:0] cnt_o,
    output zero_o
);

assign zero_o = ~(|a_i);
assign cnt_o[0] = (~a_i[3] & a_i[2]) | (~a_i[3] & ~a_i[1]);
assign cnt_o[1] = (~a_i[3] & ~a_i[2]);
endmodule



