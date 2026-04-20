// Return Address Stack — 8-entry LIFO for JALR-return prediction.
//
// Shift-register style: top is always slot 0. Push shifts everything
// down (drops oldest on full); pop shifts everything up. Circular
// semantics avoid a "full" signal dropping pushes, which would
// desync RAS with the actual call stack.
//
// For Step 3 the pop fires at ID when a JALR-return is detected;
// the push fires at IE when a JAL/JALR call commits. On mispredict
// recovery (rare for real call/return pairs) the RAS state is
// left as-is — a subsequent wrong pop is tolerable, the missed
// prediction just pays the normal IE redirect cost.
module ras #(
    parameter int unsigned DEPTH = 8
) (
    input  logic        clk_i,
    input  logic        reset_i,

    input  logic        push_i,
    input  logic [31:0] push_addr_i,
    input  logic        pop_i,

    output logic [31:0] top_o,
    output logic        valid_o   // RAS has at least one entry
);
    localparam int unsigned CNT_W = $clog2(DEPTH + 1);

    logic [31:0]       stack [0:DEPTH-1];
    logic [CNT_W-1:0]  count_q;

    assign top_o   = stack[0];
    assign valid_o = (count_q != '0);

    always_ff @(posedge clk_i or posedge reset_i) begin
        if (reset_i) begin
            count_q <= '0;
            for (int i = 0; i < DEPTH; i++)
                stack[i] <= 32'b0;
        end else begin
            unique case ({push_i, pop_i})
                2'b10: begin
                    // push: shift down (oldest drops if full), insert at 0
                    for (int i = DEPTH-1; i > 0; i--)
                        stack[i] <= stack[i-1];
                    stack[0] <= push_addr_i;
                    if (count_q < DEPTH[CNT_W-1:0])
                        count_q <= count_q + 1'b1;
                end
                2'b01: begin
                    // pop: shift up
                    for (int i = 0; i < DEPTH-1; i++)
                        stack[i] <= stack[i+1];
                    stack[DEPTH-1] <= 32'b0;
                    if (count_q != '0)
                        count_q <= count_q - 1'b1;
                end
                2'b11: begin
                    // push+pop simultaneous: replace top in-place
                    stack[0] <= push_addr_i;
                end
                default: ;
            endcase
        end
    end

endmodule
