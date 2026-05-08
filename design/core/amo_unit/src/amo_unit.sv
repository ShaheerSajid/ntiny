import common_pkg::*;
import core_pkg::*;

// Atomic Memory Operations unit for RV32A (Zalrsc + Zaamo)
//
// Handles LR.W, SC.W, and 9 AMO.W read-modify-write operations.
// Single-hart: aq/rl ordering bits are decoded but have no effect.
//
// FSM: IDLE → AMO_READ → AMO_WRITE → DONE
//   LR.W:       IDLE → AMO_READ → DONE           (1 bus read)
//   SC.W ok:    IDLE → AMO_WRITE → DONE           (1 bus write)
//   SC.W fail:  IDLE → DONE                       (0 bus ops)
//   AMO*.W:     IDLE → AMO_READ → AMO_WRITE → DONE (1 read + 1 write)

module amo_unit (
    input  logic        clk_i,
    input  logic        reset_i,

    // From IE stage
    input  amo_op_e     amo_op_i,
    input  logic [31:0] addr_i,         // ALU result = rs1 (word-aligned address)
    input  logic [31:0] rs2_i,          // forwarded rs2 value
    input  logic        flush_i,        // pipeline flush (trap taken)

    // DBus signals (active when this unit drives bus)
    output logic [31:0] dbus_addr_o,
    output logic [3:0]  dbus_byteenable_o,
    output logic        dbus_read_o,
    output logic        dbus_write_o,
    output logic [31:0] dbus_writedata_o,
    input  logic [31:0] dbus_readdata_i,
    input  logic        dbus_stall_i,

    // Result and control
    output logic [31:0] result_o,       // value written back to rd
    output logic        stall_o,        // stall IE stage
    output logic        active_o,       // this unit controls bus
    output logic        in_progress_o,  // FSM has left IDLE (address latched)
    // High when an AMO is at IE waiting to start but hasn't activated.
    // Distinguishes "pre-start" (uncommitted, must re-execute on async
    // trap) from "DONE" (memory committed, must skip on async trap).
    // True iff amo_op_i != NO_AMO_OP and state == IDLE.
    output logic        pending_o
);

// ── Reservation register (LR/SC) ──────────────────────────────
logic        resv_valid;
logic [31:0] resv_addr;

// ── FSM ───────────────────────────────────────────────────────
typedef enum logic [1:0] {
    IDLE,
    AMO_READ,
    AMO_WRITE,
    DONE
} amo_state_e;

amo_state_e state, nstate;

// Latched operands (captured at IDLE → first active state)
logic [31:0] addr_q;
logic [31:0] rs2_q;
amo_op_e     op_q;

// Captured read data (from bus read phase)
logic [31:0] read_data_q;

// Latched result (set when operation logically completes)
logic [31:0] result_q;

// ── AMO ALU: old_value OP rs2 ─────────────────────────────────
logic [31:0] amo_writeback;
always_comb begin
    case (op_q)
        AMOSWAP: amo_writeback = rs2_q;
        AMOADD:  amo_writeback = read_data_q + rs2_q;
        AMOXOR:  amo_writeback = read_data_q ^ rs2_q;
        AMOAND:  amo_writeback = read_data_q & rs2_q;
        AMOOR:   amo_writeback = read_data_q | rs2_q;
        AMOMIN:  amo_writeback = ($signed(read_data_q) < $signed(rs2_q)) ? read_data_q : rs2_q;
        AMOMAX:  amo_writeback = ($signed(read_data_q) > $signed(rs2_q)) ? read_data_q : rs2_q;
        AMOMINU: amo_writeback = (read_data_q < rs2_q) ? read_data_q : rs2_q;
        AMOMAXU: amo_writeback = (read_data_q > rs2_q) ? read_data_q : rs2_q;
        default: amo_writeback = rs2_q;
    endcase
end

// SC success: reservation valid and address matches
logic sc_success;
assign sc_success = resv_valid && (resv_addr == addr_i);

// ── Next-state logic ──────────────────────────────────────────
always_comb begin
    nstate = state;
    case (state)
        IDLE: begin
            if (amo_op_i != NO_AMO_OP && !flush_i) begin
                case (amo_op_i)
                    LR_W:    nstate = AMO_READ;
                    SC_W:    nstate = sc_success ? AMO_WRITE : DONE;
                    default: nstate = AMO_READ;   // all AMO RMW ops
                endcase
            end
        end
        AMO_READ: begin
            if (!dbus_stall_i)
                nstate = (op_q == LR_W) ? DONE : AMO_WRITE;
        end
        AMO_WRITE: begin
            if (!dbus_stall_i)
                nstate = DONE;
        end
        DONE: nstate = IDLE;
        default: nstate = IDLE;
    endcase

    if (flush_i && state != IDLE)
        nstate = IDLE;
end

// ── State register ────────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        state <= IDLE;
    else
        state <= nstate;
end

// ── Latch inputs on IDLE → active transition ──────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        addr_q <= '0;
        rs2_q  <= '0;
        op_q   <= NO_AMO_OP;
    end else if (state == IDLE && nstate != IDLE && nstate != DONE) begin
        addr_q <= addr_i;
        rs2_q  <= rs2_i;
        op_q   <= amo_op_i;
    end
end

// ── Capture read data ─────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        read_data_q <= '0;
    else if (state == AMO_READ && !dbus_stall_i)
        read_data_q <= dbus_readdata_i;
end

// ── Result register ───────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i)
        result_q <= '0;
    else case (state)
        IDLE: begin
            // SC fail: result = 1 (nonzero)
            if (amo_op_i == SC_W && !sc_success && !flush_i)
                result_q <= 32'd1;
        end
        AMO_READ: begin
            if (!dbus_stall_i)
                // LR: result = loaded value; AMO: result = old value (captured now)
                result_q <= dbus_readdata_i;
        end
        AMO_WRITE: begin
            if (!dbus_stall_i && op_q == SC_W)
                // SC success: result = 0
                result_q <= 32'd0;
            // AMO: result_q already holds old value from AMO_READ
        end
        default: ;
    endcase
end

// ── Reservation register ──────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        resv_valid <= 1'b0;
        resv_addr  <= '0;
    end else if (flush_i) begin
        // Trap/interrupt invalidates reservation
        resv_valid <= 1'b0;
    end else if (state == AMO_READ && !dbus_stall_i && op_q == LR_W) begin
        // LR.W sets reservation
        resv_valid <= 1'b1;
        resv_addr  <= addr_q;
    end else if (state == IDLE && amo_op_i == SC_W && !flush_i) begin
        // SC.W always clears reservation (success or fail)
        resv_valid <= 1'b0;
    end
end

// ── Bus drive ─────────────────────────────────────────────────
// Defensive: suppress bus on flush_i so an interrupt can't cause
// partial AMO commit (memory updated AND AMO aborted internally
// AND re-executed → double-apply). Empirically this race did not
// fire during Linux boot (counter showed 0 events), but the gate
// is correct per AMO atomicity semantics and costs nothing.
always_comb begin
    dbus_addr_o       = addr_q;
    dbus_byteenable_o = 4'b1111;  // always word-width
    dbus_read_o       = 1'b0;
    dbus_write_o      = 1'b0;
    dbus_writedata_o  = '0;

    if (!flush_i) begin
        case (state)
            AMO_READ: begin
                dbus_read_o = 1'b1;
            end
            AMO_WRITE: begin
                dbus_write_o     = 1'b1;
                dbus_writedata_o = (op_q == SC_W) ? rs2_q : amo_writeback;
            end
            default: ;
        endcase
    end
end

// ── Output: result ────────────────────────────────────────────
assign result_o = result_q;

// ── Output: stall (high during operation, low in DONE) ────────
assign stall_o = (state != IDLE && state != DONE) ||
                 (state == IDLE && amo_op_i != NO_AMO_OP && !flush_i);

// ── Output: active (this unit controls bus) ───────────────────
assign active_o = (state == AMO_READ) || (state == AMO_WRITE);

// ── Output: in-progress (FSM left IDLE, address already latched) ──
// Used to gate combinational checks (e.g. misalignment) that depend
// on alu_result, which becomes unreliable after forwarding data is
// flushed by pipeline stall logic.
assign in_progress_o = (state != IDLE);

// ── Output: pending (AMO at IE waiting to start, hasn't activated) ──
// True iff amo_op_i is a real AMO and FSM is in IDLE. Used by
// interrupt_ctrl to set sepc=pc_ie when an async trap fires the same
// cycle as an IE-stage AMO that flush_i prevents from activating —
// without this gate, async_use_ie misses the case (amo_active stays
// 0 across the squash) and sepc captures pc_id (= insn AFTER the
// AMO), so sret skips the AMO. The AMO's spurious result_q (= 0 or
// stale from a prior AMO) is what causes the
// project_v7_layer3_fix_event_create_dir_regression refcount=0 WARN.
// pending_o stays 0 in DONE state so already-committed AMOs still
// take the pc_id (skip) path.
assign pending_o = (amo_op_i != NO_AMO_OP) && (state == IDLE);

endmodule
