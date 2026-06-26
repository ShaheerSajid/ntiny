// ── Program counter register ─────────────────────────────────────────
// The architectural PC. On reset it loads the parameterised reset vector
// (DEFAULT = boot ROM 0x1000 or RAM 0x80000000, set at instantiation).
// Otherwise it captures pc_in_i (the next PC chosen by the redirect
// arbiter) every cycle the fetch stage is not stalled. Holding on stall_i
// keeps the front-end pinned while a fetch or downstream stall resolves.
// See microarch doc: "Fetch front-end" -> program_counter.
import common_pkg::*;
import core_pkg::*;

module program_counter
#(parameter DEFAULT = 0)            // reset vector
(
	input logic clk_i,
	input logic reset_i,
	input logic stall_i,            // freeze the PC (front-end stalled)
	input logic [31:0]pc_in_i,      // next PC (from redirect arbiter)
	output var logic [31:0]pc_out_o // current PC
);

always_ff@(posedge clk_i or  posedge reset_i)
begin
	if (reset_i)
		begin
			pc_out_o <= DEFAULT;
		end
	else if(!stall_i)
		begin
			pc_out_o <= pc_in_i;
		end		
end
endmodule
