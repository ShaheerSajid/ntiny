// ── RISC-V CLINT (Core Local Interruptor) ────────────────────────
// Single-hart CLINT with mtime, mtimecmp, and msip registers.
// Compliant with the RISC-V Privileged specification.
//
// Register map (base 0x0200_0000):
//   0x0000  msip        [0]    RW  Machine software interrupt pending
//   0x4000  mtimecmp_lo [31:0] RW  Timer compare (lower 32)
//   0x4004  mtimecmp_hi [31:0] RW  Timer compare (upper 32)
//   0xBFF8  mtime_lo    [31:0] RW  Free-running counter (lower 32)
//   0xBFFC  mtime_hi    [31:0] RW  Free-running counter (upper 32)
//
// Interrupts (active-high, level-sensitive):
//   timer_irq_o: mtime >= mtimecmp
//   soft_irq_o:  msip[0]

module clint #(
    parameter DATA_WIDTH = 32       // 32 for RV32, 64 for RV64
)(
    input  logic                  clk_i,
    input  logic                  reset_i,

    // Bus interface (matches existing peripheral pattern)
    input  logic                  chipselect_i,
    input  logic                  write_i,
    input  logic                  read_i,
    input  logic [15:0]           address_i,      // byte address within CLINT region
    input  logic [DATA_WIDTH-1:0] writedata_i,
    output logic [DATA_WIDTH-1:0] readdata_o,

    // Interrupt outputs (directly to core)
    output logic                  timer_irq_o,
    output logic                  soft_irq_o,
    output logic [63:0]           mtime_o         // for TIME/TIMEH CSRs
);

// ── Registers ────────────────────────────────────────────────────
logic        msip_reg;
logic [63:0] mtime;
logic [63:0] mtimecmp;

// ── Address decode ───────────────────────────────────────────────
localparam ADDR_MSIP         = 16'h0000;
localparam ADDR_MTIMECMP_LO  = 16'h4000;
localparam ADDR_MTIMECMP_HI  = 16'h4004;
localparam ADDR_MTIME_LO     = 16'hBFF8;
localparam ADDR_MTIME_HI     = 16'hBFFC;

// ── Interrupt generation ─────────────────────────────────────────
assign timer_irq_o = (mtime >= mtimecmp);
assign soft_irq_o  = msip_reg;
assign mtime_o     = mtime;

// ── Write logic ──────────────────────────────────────────────────
always_ff @(posedge clk_i or posedge reset_i) begin
    if (reset_i) begin
        msip_reg <= 1'b0;
        mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;  // max value = no interrupt initially
        mtime    <= 64'd0;
    end else begin
        // mtime: free-running counter, increments every cycle
        mtime <= mtime + 64'd1;

        // Register writes
        if (chipselect_i && write_i) begin
            case (address_i)
                ADDR_MSIP:        msip_reg       <= writedata_i[0];
                ADDR_MTIMECMP_LO: mtimecmp[31:0] <= writedata_i;
                ADDR_MTIMECMP_HI: mtimecmp[63:32]<= writedata_i;
                ADDR_MTIME_LO:    mtime[31:0]    <= writedata_i;
                ADDR_MTIME_HI:    mtime[63:32]   <= writedata_i;
                default: ;
            endcase
        end
    end
end

// ── Read logic (registered) ──────────────────────────────────────
// Register the read data so it's stable when periph_bridge samples it
// 1 cycle after the request (matches periph_bridge sel_r timing).
always_ff @(posedge clk_i) begin
    if (chipselect_i && read_i) begin
        case (address_i)
            ADDR_MSIP:        readdata_o <= {31'd0, msip_reg};
            ADDR_MTIMECMP_LO: readdata_o <= mtimecmp[31:0];
            ADDR_MTIMECMP_HI: readdata_o <= mtimecmp[63:32];
            ADDR_MTIME_LO:    readdata_o <= mtime[31:0];
            ADDR_MTIME_HI:    readdata_o <= mtime[63:32];
            default:          readdata_o <= '0;
        endcase
    end
end

endmodule
