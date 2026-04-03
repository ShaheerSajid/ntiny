import common_pkg::*;
import core_pkg::*;

// ── Load/Store Unit ──────────────────────────────────────────────
// Converts core memory operations to bus transactions.
// Supports misaligned HALF/WORD accesses by splitting into two
// aligned bus transactions (FSM: IDLE → SECOND for misaligned).
//
// Aligned: 1-cycle (same as before)
// Misaligned: 2-cycle (first + second aligned transaction)

module core2avl
#(parameter DATA_WIDTH=32, parameter ADDR_WIDTH=32)
(
    input  logic                  clk_i,
    input  logic                  reset_i,
    input  onebit_sig_e           stall_i,
    input  load_store_width_e     load_store_width,
    input  onebit_sig_e           mem_unsigned,
    input  mem_op_e               mem_op,
    input  logic [ADDR_WIDTH-1:0] addr_i,
    input  logic [DATA_WIDTH-1:0] data2write_i,
    output logic [DATA_WIDTH-1:0] data2read_o,
    // Bus signals
    input  logic [DATA_WIDTH-1:0] readdata_i,
    output logic [ADDR_WIDTH-1:0] address_o,
    output logic [DATA_WIDTH-1:0] writedata_o,
    output logic [3:0]            byteenable_o,
    output onebit_sig_e           read_o,
    output onebit_sig_e           write_o,
    // Stall output: asserted during second transaction of misaligned access
    output logic                  misalign_stall_o
);

// ── Misalignment detection ───────────────────────────────────────
wire [1:0] byt = addr_i[1:0];
wire is_misaligned = (load_store_width == HALF && byt[0]) ||
                     (load_store_width == WORD && |byt);
wire crosses_word  = is_misaligned;  // all misaligned HALF/WORD cross a word boundary

// ── FSM ──────────────────────────────────────────────────────────
typedef enum logic {IDLE, SECOND} state_e;
state_e state;

// Latched signals for second transaction
logic [ADDR_WIDTH-1:0] addr_q;
logic [DATA_WIDTH-1:0] wdata_q;
load_store_width_e     width_q;
mem_op_e               op_q;
logic [DATA_WIDTH-1:0] first_rdata_q;  // captured read data from first txn

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        state <= IDLE;
    end else if (state == IDLE && crosses_word && mem_op != NO_MEM_OP && !stall_i) begin
        state         <= SECOND;
        addr_q        <= addr_i;
        wdata_q       <= data2write_i;
        width_q       <= load_store_width;
        op_q          <= mem_op;
        first_rdata_q <= readdata_i;  // captured next cycle (1-cycle latency)
    end else if (state == SECOND) begin
        state         <= IDLE;
        first_rdata_q <= readdata_i;  // update with actual response
    end
end

// Capture first read data when it arrives (1 cycle after first req)
logic [DATA_WIDTH-1:0] first_rdata_captured;
always_ff @(posedge clk_i) begin
    if (state == SECOND)
        first_rdata_captured <= readdata_i;
end

// ── Address computation ──────────────────────────────────────────
wire [ADDR_WIDTH-1:0] aligned_addr    = {addr_i[ADDR_WIDTH-1:2], 2'b00};
wire [ADDR_WIDTH-1:0] aligned_addr_q  = {addr_q[ADDR_WIDTH-1:2], 2'b00};
wire [ADDR_WIDTH-1:0] next_word_addr  = aligned_addr_q + 4;

// ── Byte enable computation ─────────────────────────────────────
// First transaction: bytes from byt to end of word
// Second transaction: remaining bytes at start of next word
logic [3:0] be_first, be_second, be_aligned;

always_comb begin
    be_aligned = 4'b0000;
    be_first   = 4'b0000;
    be_second  = 4'b0000;

    case (load_store_width)
        BYTE: case (byt)
            0: be_aligned = 4'b0001;
            1: be_aligned = 4'b0010;
            2: be_aligned = 4'b0100;
            3: be_aligned = 4'b1000;
        endcase
        HALF: case (byt)
            0: be_aligned = 4'b0011;
            2: be_aligned = 4'b1100;
            // Misaligned: byt=1 → bytes 1,2 (within word, NOT crossing)
            1: be_aligned = 4'b0110;
            // Misaligned crossing: byt=3 → byte 3 first, byte 0 second
            3: begin be_first = 4'b1000; be_second = 4'b0001; end
        endcase
        WORD: case (byt)
            0: be_aligned = 4'b1111;
            1: begin be_first = 4'b1110; be_second = 4'b0001; end
            2: begin be_first = 4'b1100; be_second = 4'b0011; end
            3: begin be_first = 4'b1000; be_second = 4'b0111; end
        endcase
        default: be_aligned = 4'b0000;
    endcase
end

// Does this access actually cross a word boundary?
wire actually_crosses = (be_second != 4'b0000);

// ── Bus output mux ───────────────────────────────────────────────
always_comb begin
    if (state == SECOND) begin
        // Second transaction of misaligned pair
        address_o    = next_word_addr;
        byteenable_o = be_second;
        read_o       = onebit_sig_e'(op_q == READ);
        write_o      = onebit_sig_e'(op_q == WRITE);
    end else if (actually_crosses && mem_op != NO_MEM_OP) begin
        // First transaction of misaligned pair
        address_o    = aligned_addr;
        byteenable_o = be_first;
        read_o       = onebit_sig_e'(mem_op == READ);
        write_o      = onebit_sig_e'(mem_op == WRITE);
    end else begin
        // Normal aligned access (or non-crossing misaligned like HALF byt=1)
        address_o    = addr_i;
        byteenable_o = be_aligned;
        read_o       = onebit_sig_e'(mem_op == READ);
        write_o      = onebit_sig_e'(mem_op == WRITE);
    end
end

// ── Write data shifting ──────────────────────────────────────────
always_comb begin
    if (state == SECOND) begin
        // Second transaction: shift remaining data to low byte lanes
        case (width_q)
            HALF: writedata_o = wdata_q;  // byte 0 of halfword → byte lane 0
            WORD: case (addr_q[1:0])
                1: writedata_o = {24'b0, wdata_q[31:24]};
                2: writedata_o = {16'b0, wdata_q[31:16]};
                3: writedata_o = { 8'b0, wdata_q[31:8]};
                default: writedata_o = wdata_q;
            endcase
            default: writedata_o = wdata_q;
        endcase
    end else begin
        // First or aligned: shift data to correct byte lanes
        case (byt)
            0: writedata_o = data2write_i;
            1: writedata_o = data2write_i << 8;
            2: writedata_o = data2write_i << 16;
            3: writedata_o = data2write_i << 24;
        endcase
    end
end

// ── Stall output ─────────────────────────────────────────────────
// Stall during first transaction of a crossing misaligned access
// (the second transaction happens next cycle)
assign misalign_stall_o = (state == IDLE) && actually_crosses && (mem_op != NO_MEM_OP);

// ── IWB pipeline register ────────────────────────────────────────
load_store_width_e mode_iwb;
logic [3:0] be_iwb;
onebit_sig_e mem_unsigned_iwb;
logic        was_misaligned_iwb;
logic [1:0]  byt_iwb;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        mode_iwb          <= load_store_width_e'(2'b00);
        be_iwb            <= 4'b0000;
        mem_unsigned_iwb  <= FALSE;
        was_misaligned_iwb <= 1'b0;
        byt_iwb           <= 2'b0;
    end else if (!stall_i && state == IDLE && !actually_crosses) begin
        // Normal aligned: latch for IWB extraction
        mode_iwb          <= load_store_width;
        be_iwb            <= be_aligned;
        mem_unsigned_iwb  <= mem_unsigned;
        was_misaligned_iwb <= 1'b0;
        byt_iwb           <= byt;
    end else if (state == SECOND) begin
        // Misaligned complete: latch for IWB extraction
        mode_iwb          <= width_q;
        be_iwb            <= 4'b0000;  // not used for misaligned
        mem_unsigned_iwb  <= mem_unsigned;
        was_misaligned_iwb <= 1'b1;
        byt_iwb           <= addr_q[1:0];
    end
end

// ── Read data extraction (aligned path) ──────────────────────────
logic [DATA_WIDTH-1:0] q1;
always_comb begin
    case (be_iwb)
        4'b0001: q1 = {{24{1'b0}}, readdata_i[ 7: 0]};
        4'b0010: q1 = {{24{1'b0}}, readdata_i[15: 8]};
        4'b0100: q1 = {{24{1'b0}}, readdata_i[23:16]};
        4'b1000: q1 = {{24{1'b0}}, readdata_i[31:24]};
        4'b0011: q1 = {{16{1'b0}}, readdata_i[15: 0]};
        4'b0110: q1 = {{16{1'b0}}, readdata_i[23: 8]};
        4'b1100: q1 = {{16{1'b0}}, readdata_i[31:16]};
        4'b1111: q1 = readdata_i;
        default: q1 = 32'h0;
    endcase
end

// ── Read data extraction (misaligned path) ───────────────────────
// Combine first_rdata_captured (from first aligned read) with
// readdata_i (from second aligned read, available this cycle)
logic [DATA_WIDTH-1:0] q_misaligned;
always_comb begin
    q_misaligned = 32'h0;
    case (mode_iwb)
        HALF: begin
            // HALF crossing: byt=3 → first has byte[3], second has byte[0]
            q_misaligned = {{16{1'b0}}, readdata_i[7:0], first_rdata_captured[31:24]};
        end
        WORD: case (byt_iwb)
            1: q_misaligned = {readdata_i[ 7:0], first_rdata_captured[31: 8]};
            2: q_misaligned = {readdata_i[15:0], first_rdata_captured[31:16]};
            3: q_misaligned = {readdata_i[23:0], first_rdata_captured[31:24]};
            default: q_misaligned = readdata_i;
        endcase
        default: q_misaligned = readdata_i;
    endcase
end

// ── Sign extension + output select ───────────────────────────────
logic [DATA_WIDTH-1:0] q_raw;
assign q_raw = was_misaligned_iwb ? q_misaligned : q1;

logic [DATA_WIDTH-1:0] q;
always_comb begin
    case ({mem_unsigned_iwb, mode_iwb})
        {FALSE, BYTE}: q = {{24{q_raw[ 7]}}, q_raw[ 7:0]};
        {FALSE, HALF}: q = {{16{q_raw[15]}}, q_raw[15:0]};
        {FALSE, WORD}: q = q_raw;
        {TRUE,  BYTE}: q = {{24{1'b0}}, q_raw[ 7:0]};
        {TRUE,  HALF}: q = {{16{1'b0}}, q_raw[15:0]};
        default:       q = 32'h0;
    endcase
end

assign data2read_o = q;

endmodule
