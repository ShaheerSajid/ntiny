import common_pkg::*;
import core_pkg::*;

// ── Compressed Instruction Alignment Controller ─────────────────────────────
// Handles RV32C 16-bit / 32-bit instruction alignment.  Maintains a 16-bit
// buffer for instructions that straddle word boundaries.
//
// States:
//   ALIGN    — PC is word-aligned; fetch word maps directly to one instruction
//   MISALIGN — PC is half-word-aligned; lower 16 bits came from previous fetch,
//              upper 16 bits arrive in the current fetch word
//   BRANCH   — redirect landed on a half-word boundary (bit[1]=1); need to
//              pick up the upper half of the fetch word
//
// Architecture:
//   One internal "alignment PC" (apc) tracks the logical instruction address.
//   On redirects (branch/trap/ret/debug), core_top supplies the target address
//   via redirect_i/redirect_addr_i — NO duplicated PC source mux here.
//   On sequential advance, apc increments by +2 (compressed) or +4 (32-bit).
//
// BPU extension point: when a future BTB predicts taken at IF time, core_top
// will assert redirect_i with the BTB target on redirect_addr_i.  The existing
// redirect/apc mechanism handles this without any c_controller changes.
//
module c_controller (
	input              clk_i,
	input              reset_i,
	input  onebit_sig_e stall_i,
	input  onebit_sig_e flush_i,
	input              redirect_i,          // non-sequential redirect this cycle
	input  [31:0]      redirect_addr_i,     // target address for redirect
	input              interrupt_i,         // trap firing (only this bypasses internal PC stall)
	input  [31:0]      instruction_i,       // 32-bit fetch word from memory

	output [31:0]      instruction_addr_o,  // logical PC of current instruction
	output logic [31:0] instruction_o,      // expanded 32-bit instruction
	output [31:0]      next_instruction_addr_o, // next logical PC (for debugger)
	output onebit_sig_e c_stall_o,          // stall main PC for alignment
	output onebit_sig_e c_valid_o,          // current instruction is 16-bit
	output onebit_sig_e busy_o              // in BRANCH state, need another fetch
);

// ── Internal signals ────────────────────────────────────────────────────────
logic [15:0] c_dec_in;       // input to compressed decoder
logic [15:0] ins_buffer;     // buffered upper 16 bits from previous fetch
logic [31:0] ins_extended;   // 32-bit expansion of 16-bit compressed insn
logic [31:0] apc_in;         // next alignment-PC value
logic [31:0] apc_out;        // current alignment-PC
bit          apc_sel;        // 0 = advance by 4, 1 = advance by 2
bit          ins_buffer_en;  // latch upper 16 bits into buffer

// ── Derived conditions ──────────────────────────────────────────────────────
wire insn_is_32bit      = (instruction_i[1:0] == 2'b11);
wire buf_is_32bit       = (ins_buffer[1:0] == 2'b11);
wire redirect_to_half   = redirect_i && redirect_addr_i[1];
wire redirect_to_word   = redirect_i && !redirect_addr_i[1];
wire branch_upper_32bit = (instruction_i[17:16] == 2'b11);

// ── Alignment PC ────────────────────────────────────────────────────────────
// Single source of next address: redirect overrides sequential advance.
always_comb begin
	if (redirect_i)
		apc_in = redirect_addr_i;
	else
		apc_in = apc_sel ? apc_out + 2 : apc_out + 4;
end

`ifdef BOOT
program_counter #(.DEFAULT(32'h00001000)) c_program_counter_inst
`else
program_counter #(.DEFAULT(32'h80000000)) c_program_counter_inst
`endif
(
	.clk_i    (clk_i),
	.reset_i  (reset_i),
	.stall_i  (interrupt_i ? 1'b0 : stall_i || (p_state == BRANCH && branch_upper_32bit)),
	.pc_in_i  (apc_in),
	.pc_out_o (apc_out)
);

// ── Compressed decoder ──────────────────────────────────────────────────────
c_dec c_dec_inst (
	.ins_16 (c_dec_in),
	.ins_32 (ins_extended)
);

// ── Alignment FSM ───────────────────────────────────────────────────────────
enum int unsigned {ALIGN = 0, MISALIGN = 1, BRANCH = 2} p_state, n_state;

always_ff @(posedge clk_i or posedge reset_i) begin
	if (reset_i)
		p_state <= ALIGN;
	else if (flush_i)
		p_state <= ALIGN;
	else if (!stall_i)
		p_state <= n_state;
end

always_comb begin
	// Defaults (NOP-safe)
	c_dec_in      = 16'd0;
	instruction_o = instruction_i;
	apc_sel       = 1'b0;
	ins_buffer_en = 1'b0;
	c_stall_o     = FALSE;
	c_valid_o     = FALSE;
	n_state       = ALIGN;

	case (p_state)
		// ── ALIGN: fetch word starts at word boundary ────────────────────
		ALIGN: begin
			if (insn_is_32bit || instruction_i == 0) begin
				// 32-bit instruction or NOP: pass through directly
				instruction_o = instruction_i;
				n_state       = redirect_to_half ? BRANCH : ALIGN;
			end else begin
				// 16-bit compressed: decode lower half, buffer upper half
				c_dec_in      = instruction_i[15:0];
				instruction_o = ins_extended;
				apc_sel       = 1'b1;
				ins_buffer_en = 1'b1;
				c_valid_o     = TRUE;
				n_state       = redirect_to_half ? BRANCH :
				                redirect_to_word ? ALIGN  : MISALIGN;
			end
		end

		// ── MISALIGN: upper half from prev fetch is in ins_buffer ────────
		MISALIGN: begin
			if (buf_is_32bit) begin
				// Buffered half starts a 32-bit insn: combine with lower fetch
				instruction_o = {instruction_i[15:0], ins_buffer};
				ins_buffer_en = 1'b1;
				n_state       = redirect_to_half ? BRANCH :
				                redirect_to_word ? ALIGN  : MISALIGN;
			end else begin
				// Buffered half is a 16-bit compressed insn
				c_dec_in      = ins_buffer;
				instruction_o = ins_extended;
				apc_sel       = 1'b1;
				c_stall_o     = redirect_i ? FALSE : TRUE;
				c_valid_o     = TRUE;
				n_state       = redirect_to_half ? BRANCH : ALIGN;
			end
		end

		// ── BRANCH: redirect landed on half-word; use upper half of fetch
		BRANCH: begin
			if (branch_upper_32bit) begin
				// Upper half starts a 32-bit insn: buffer it, wait for next fetch
				instruction_o = 0;
				ins_buffer_en = 1'b1;
				n_state       = MISALIGN;
			end else begin
				// Upper half is a 16-bit compressed insn
				c_dec_in      = instruction_i[31:16];
				instruction_o = ins_extended;
				apc_sel       = 1'b1;
				c_valid_o     = TRUE;
				n_state       = redirect_to_half ? BRANCH : ALIGN;
			end
		end

		default: begin
			// Reset-safe defaults already set above
		end
	endcase
end

// ── Outputs ─────────────────────────────────────────────────────────────────
assign instruction_addr_o      = apc_out;
assign next_instruction_addr_o = apc_in;
assign busy_o                  = onebit_sig_e'(p_state == BRANCH);

// ── Instruction buffer (upper 16 bits of previous fetch) ────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
	if (reset_i)
		ins_buffer <= 0;
	else if (flush_i)
		ins_buffer <= 0;
	else if (!stall_i && ins_buffer_en)
		ins_buffer <= instruction_i[31:16];
end

endmodule
