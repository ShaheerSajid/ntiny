`include "mem_map.svh"

// ── Dual-Port RAM with random ready + rvalid latency (sim-only) ──────
// Drop-in wrapper around `ram_dp` that injects pseudo-random
// back-pressure on `ready` and pseudo-random extra latency on `rvalid`.
//
// Purpose: today's `ram_dp` keeps `ready` hard-high and emits `rvalid`
// exactly 1 cycle after acceptance, so the whole memory path is never
// exercised under stall conditions. That masks two bug classes:
//
//   1. Masters that don't actually hold (req, addr) stable when the
//      slave drops ready (e.g. the icache-stalling-slave attempt that
//      shipped instruction 0 as a wrong-PC fetch — would have failed
//      against this model the first time it was tried).
//   2. Arbiters and inflight-tracking FFs that assume a fixed 1-cycle
//      response window.
//
// Behaviour per port:
//   - At reset, draw an initial random stall budget from the LFSR. As
//     soon as the master asserts req, count it down with ready=0 until
//     the budget hits zero, at which point ready=1 and the request is
//     accepted (forwarded to the backing ram_dp).
//   - On a read accept, enter PEND and count down a random response
//     budget. When the budget hits zero, drive cpu_rvalid_o=1 for one
//     cycle with the backing's latched read data.
//   - Writes complete on accept (no PEND, no rvalid — matches
//     ram_dp's write semantics).
//   - One outstanding transaction per port at a time. ready stays 0
//     during PEND so the master can't queue a second request.
//
// Notes:
//   - Minimum read latency is 2 cycles (1 for the backing SRAM + 1 to
//     route through the wrapper's pending register). That alone
//     differs from `ram_dp` (1 cycle) and is enough to catch most
//     "assumes exactly 1-cycle latency" bugs.
//   - The LFSR mask is `% (MAX_+1)` so MAX_STALL=0 / MAX_RESP=0
//     disable the corresponding source of randomness without
//     special-casing.
//   - LFSR is seeded per port so the two ports don't move in lockstep.
//
module ram_dp_delayed #(
    parameter DEPTH    = `RAM_DEPTH,
    parameter AW       = `RAM_ADDR_WIDTH,
    parameter HEX_FILE = "ram.hex",
    // Max random ready=0 cycles before each accept (0 = no stalls).
    parameter int MAX_STALL = 4,
    // Max additional rvalid latency cycles on top of the 1-cycle
    // backing-SRAM delay (0 = baseline backing latency only).
    parameter int MAX_RESP  = 4,
    parameter [31:0] SEED_A = 32'hACE1_1234,
    parameter [31:0] SEED_B = 32'h5A5A_BEEF
)(
    input  logic        clk_i,
    input  logic        reset_i,

    // Port A (instruction fetch — read-only)
    input  logic        pa_req_i,
    input  logic [31:0] pa_addr_i,
    output logic [31:0] pa_rdata_o,
    output logic        pa_rvalid_o,
    output logic        pa_ready_o,

    // Port B (data — read/write)
    input  logic        pb_req_i,
    input  logic        pb_we_i,
    input  logic [31:0] pb_addr_i,
    input  logic [3:0]  pb_be_i,
    input  logic [31:0] pb_wdata_i,
    output logic [31:0] pb_rdata_o,
    output logic        pb_rvalid_o,
    output logic        pb_ready_o
);

localparam int CNT_MAX = (MAX_STALL > MAX_RESP) ? MAX_STALL : MAX_RESP;
localparam int CNT_W   = (CNT_MAX <= 1) ? 1 : $clog2(CNT_MAX + 1);

// ── Pseudo-random source (Galois LFSR, max-length 32-bit taps) ───────
logic [31:0] lfsr_a_q, lfsr_b_q;
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        lfsr_a_q <= SEED_A;
        lfsr_b_q <= SEED_B;
    end else begin
        lfsr_a_q <= {lfsr_a_q[30:0], lfsr_a_q[31] ^ lfsr_a_q[21] ^ lfsr_a_q[1] ^ lfsr_a_q[0]};
        lfsr_b_q <= {lfsr_b_q[30:0], lfsr_b_q[31] ^ lfsr_b_q[21] ^ lfsr_b_q[1] ^ lfsr_b_q[0]};
    end
end

function automatic logic [CNT_W-1:0] rand_stall(input logic [31:0] s);
    rand_stall = (MAX_STALL == 0) ? '0
               : CNT_W'(s[15:8] % (MAX_STALL + 1));
endfunction
function automatic logic [CNT_W-1:0] rand_resp(input logic [31:0] s);
    rand_resp = (MAX_RESP == 0) ? '0
              : CNT_W'(s[7:0] % (MAX_RESP + 1));
endfunction

// ── Backing real RAM (always-ready, 1-cycle latency) ─────────────────
logic        bk_pa_req;
logic [31:0] bk_pa_addr;
logic [31:0] bk_pa_rdata;
logic        bk_pa_rvalid;
logic        bk_pa_ready;

logic        bk_pb_req;
logic        bk_pb_we;
logic [31:0] bk_pb_addr;
logic [3:0]  bk_pb_be;
logic [31:0] bk_pb_wdata;
logic [31:0] bk_pb_rdata;
logic        bk_pb_rvalid;
logic        bk_pb_ready;

ram_dp #(
    .DEPTH    (DEPTH),
    .AW       (AW),
    .HEX_FILE (HEX_FILE)
) backing (
    .clk_i       (clk_i),
    .pa_req_i    (bk_pa_req),
    .pa_addr_i   (bk_pa_addr),
    .pa_rdata_o  (bk_pa_rdata),
    .pa_rvalid_o (bk_pa_rvalid),
    .pa_ready_o  (bk_pa_ready),
    .pb_req_i    (bk_pb_req),
    .pb_we_i     (bk_pb_we),
    .pb_addr_i   (bk_pb_addr),
    .pb_be_i     (bk_pb_be),
    .pb_wdata_i  (bk_pb_wdata),
    .pb_rdata_o  (bk_pb_rdata),
    .pb_rvalid_o (bk_pb_rvalid),
    .pb_ready_o  (bk_pb_ready)
);

typedef enum logic [0:0] { P_IDLE = 1'b0, P_PEND = 1'b1 } pstate_e;

// ── Port A FSM ───────────────────────────────────────────────────────
pstate_e          pa_state_q;
logic [CNT_W-1:0] pa_stall_cnt_q;
logic [CNT_W-1:0] pa_resp_cnt_q;
logic [31:0]      pa_rdata_q;
logic             pa_rvalid_q;
// Tracks whether the backing rdata for the current PEND session has
// landed. Set on bk_pa_rvalid, cleared on accept (start of new session).
logic             pa_rdata_valid_a;

// Ready when in IDLE with no stall budget left.
wire pa_can_accept = (pa_state_q == P_IDLE) && (pa_stall_cnt_q == 0);
wire pa_accept     = pa_can_accept && pa_req_i;

assign pa_ready_o  = pa_can_accept;
assign pa_rvalid_o = pa_rvalid_q;
assign pa_rdata_o  = pa_rdata_q;

// Forward to backing on accept.
assign bk_pa_req  = pa_accept;
assign bk_pa_addr = pa_addr_i;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        pa_state_q     <= P_IDLE;
        pa_stall_cnt_q <= rand_stall(SEED_A);
        pa_resp_cnt_q  <= '0;
        pa_rdata_q     <= '0;
        pa_rvalid_q    <= 1'b0;
    end else begin
        pa_rvalid_q <= 1'b0;  // one-cycle pulse default
        case (pa_state_q)
            P_IDLE: begin
                if (pa_accept) begin
                    pa_state_q    <= P_PEND;
                    pa_resp_cnt_q <= rand_resp(lfsr_a_q);
                end else if (pa_stall_cnt_q != 0) begin
                    pa_stall_cnt_q <= pa_stall_cnt_q - 1;
                end else if (!pa_req_i) begin
                    // Re-arm the stall budget while truly idle so the
                    // next req sees a fresh random delay.
                    pa_stall_cnt_q <= rand_stall(lfsr_a_q);
                end
            end
            P_PEND: begin
                // Latch the backing response whenever it arrives — it
                // shows up exactly 1 cycle after the bk_pa_req pulse.
                if (bk_pa_rvalid) pa_rdata_q <= bk_pa_rdata;
                if (pa_resp_cnt_q == 0 && pa_rdata_valid_a) begin
                    pa_rvalid_q    <= 1'b1;
                    pa_state_q     <= P_IDLE;
                    pa_stall_cnt_q <= rand_stall(lfsr_a_q);
                end else if (pa_resp_cnt_q != 0) begin
                    pa_resp_cnt_q <= pa_resp_cnt_q - 1;
                end
                // If pa_resp_cnt_q == 0 but backing hasn't delivered yet
                // (this can't happen in practice since backing is fixed
                // 1-cycle, but be defensive), stay in PEND.
            end
            default: pa_state_q <= P_IDLE;
        endcase
    end
end

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)        pa_rdata_valid_a <= 1'b0;
    else if (pa_accept) pa_rdata_valid_a <= 1'b0;
    else if (bk_pa_rvalid) pa_rdata_valid_a <= 1'b1;
end

// ── Port B FSM (mirror of A; writes go straight through) ─────────────
pstate_e          pb_state_q;
logic [CNT_W-1:0] pb_stall_cnt_q;
logic [CNT_W-1:0] pb_resp_cnt_q;
logic [31:0]      pb_rdata_q;
logic             pb_rvalid_q;
logic             pb_rdata_valid_b;

wire pb_can_accept = (pb_state_q == P_IDLE) && (pb_stall_cnt_q == 0);
wire pb_accept     = pb_can_accept && pb_req_i;

assign pb_ready_o  = pb_can_accept;
assign pb_rvalid_o = pb_rvalid_q;
assign pb_rdata_o  = pb_rdata_q;

assign bk_pb_req   = pb_accept;
assign bk_pb_we    = pb_we_i;
assign bk_pb_addr  = pb_addr_i;
assign bk_pb_be    = pb_be_i;
assign bk_pb_wdata = pb_wdata_i;

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        pb_state_q     <= P_IDLE;
        pb_stall_cnt_q <= rand_stall(SEED_B);
        pb_resp_cnt_q  <= '0;
        pb_rdata_q     <= '0;
        pb_rvalid_q    <= 1'b0;
    end else begin
        pb_rvalid_q <= 1'b0;
        case (pb_state_q)
            P_IDLE: begin
                if (pb_accept) begin
                    if (pb_we_i) begin
                        // Write: no rvalid expected, stays in IDLE,
                        // just refresh the stall budget.
                        pb_stall_cnt_q <= rand_stall(lfsr_b_q);
                    end else begin
                        pb_state_q    <= P_PEND;
                        pb_resp_cnt_q <= rand_resp(lfsr_b_q);
                    end
                end else if (pb_stall_cnt_q != 0) begin
                    pb_stall_cnt_q <= pb_stall_cnt_q - 1;
                end else if (!pb_req_i) begin
                    pb_stall_cnt_q <= rand_stall(lfsr_b_q);
                end
            end
            P_PEND: begin
                if (bk_pb_rvalid) pb_rdata_q <= bk_pb_rdata;
                if (pb_resp_cnt_q == 0 && pb_rdata_valid_b) begin
                    pb_rvalid_q    <= 1'b1;
                    pb_state_q     <= P_IDLE;
                    pb_stall_cnt_q <= rand_stall(lfsr_b_q);
                end else if (pb_resp_cnt_q != 0) begin
                    pb_resp_cnt_q <= pb_resp_cnt_q - 1;
                end
            end
            default: pb_state_q <= P_IDLE;
        endcase
    end
end

always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)        pb_rdata_valid_b <= 1'b0;
    else if (pb_accept) pb_rdata_valid_b <= 1'b0;
    else if (bk_pb_rvalid) pb_rdata_valid_b <= 1'b1;
end

endmodule
