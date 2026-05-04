// ── ntiny GPIO ────────────────────────────────────────────────
// Phase 2a of peripheral standardisation: register layout matches
// SiFive GPIO0 (drivers/gpio/gpio-sifive.c, compatible "sifive,gpio0").
//
// address_i is a WORD INDEX (sliced from bus addr[6:2] in soc_top),
// not a byte offset — same convention as the other ntiny peripherals.
//
// Register map (byte / word indices):
//   0x00 / 0   input_val   (RO)  per-pin input values
//   0x04 / 1   input_en    (RW)  input buffer enable (RAZ/WI here)
//   0x08 / 2   output_en   (RW)  direction: 1 = drive pin
//   0x0C / 3   output_val  (RW)  output values
//   0x10 / 4   pue         (RAZ/WI)
//   0x14 / 5   ds          (RAZ/WI)
//   0x18 / 6   rise_ie     (RW)  rising-edge IRQ enable
//   0x1C / 7   rise_ip     (W1C) rising-edge IRQ pending
//   0x20 / 8   fall_ie     (RW)
//   0x24 / 9   fall_ip     (W1C)
//   0x28 / 10  high_ie     (RW)
//   0x2C / 11  high_ip     (W1C)
//   0x30 / 12  low_ie      (RW)
//   0x34 / 13  low_ip      (W1C)
//   0x38 / 14  iof_en      (RAZ/WI)
//   0x3C / 15  iof_sel     (RAZ/WI)
//   0x40 / 16  out_xor     (RW)
//
// Per-pin IRQ:
//   interrupt_reg[i] = (rise_ip[i] & rise_ie[i]) | (fall_ip[i] & fall_ie[i])
//                    | (high_ip[i] & high_ie[i]) | (low_ip[i] & low_ie[i])
// soc_top forwards bits [1:0] to PLIC (2 IRQ-capable pins exposed today).

module gpio_top (
    input  logic        clk_i,
    input  logic        resetn_i,        // active-high reset (legacy name)
    input  logic [4:0]  address_i,       // word index, 0..16
    input  logic [31:0] writedata_i,
    input  logic        write_i,
    output logic [31:0] readdata_o,
    input  logic        read_i,
    input  logic        chipselect_i,

    output logic [31:0] gpio_oen,
    input  logic [31:0] gpio_i,
    output logic [31:0] gpio_o,

    output logic [31:0] interrupt_reg
);

    // ── Registers ──────────────────────────────────────────────
    logic [31:0] input_en_q;
    logic [31:0] output_en_q;
    logic [31:0] output_val_q;
    logic [31:0] rise_ie_q, rise_ip_q;
    logic [31:0] fall_ie_q, fall_ip_q;
    logic [31:0] high_ie_q, high_ip_q;
    logic [31:0] low_ie_q,  low_ip_q;
    logic [31:0] out_xor_q;

    logic [31:0] gpio_prev_q;

    // ── Word index constants ───────────────────────────────────
    localparam WORD_INPUT_VAL  = 5'd0;
    localparam WORD_INPUT_EN   = 5'd1;
    localparam WORD_OUTPUT_EN  = 5'd2;
    localparam WORD_OUTPUT_VAL = 5'd3;
    localparam WORD_PUE        = 5'd4;
    localparam WORD_DS         = 5'd5;
    localparam WORD_RISE_IE    = 5'd6;
    localparam WORD_RISE_IP    = 5'd7;
    localparam WORD_FALL_IE    = 5'd8;
    localparam WORD_FALL_IP    = 5'd9;
    localparam WORD_HIGH_IE    = 5'd10;
    localparam WORD_HIGH_IP    = 5'd11;
    localparam WORD_LOW_IE     = 5'd12;
    localparam WORD_LOW_IP     = 5'd13;
    localparam WORD_IOF_EN     = 5'd14;
    localparam WORD_IOF_SEL    = 5'd15;
    localparam WORD_OUT_XOR    = 5'd16;

    assign gpio_o   = output_val_q ^ out_xor_q;
    assign gpio_oen = output_en_q;

    // ── Edge detection ─────────────────────────────────────────
    wire [31:0] pin_rise = gpio_i & ~gpio_prev_q;
    wire [31:0] pin_fall = ~gpio_i & gpio_prev_q;

    // ── Register writes + IP set/W1C ───────────────────────────
    always_ff @(posedge clk_i or posedge resetn_i) begin
        if (resetn_i) begin
            input_en_q   <= 32'h0;
            output_en_q  <= 32'h0;
            output_val_q <= 32'h0;
            rise_ie_q    <= 32'h0;
            rise_ip_q    <= 32'h0;
            fall_ie_q    <= 32'h0;
            fall_ip_q    <= 32'h0;
            high_ie_q    <= 32'h0;
            high_ip_q    <= 32'h0;
            low_ie_q     <= 32'h0;
            low_ip_q     <= 32'h0;
            out_xor_q    <= 32'h0;
            gpio_prev_q  <= 32'h0;
        end else begin
            gpio_prev_q <= gpio_i;

            // Default IP set (event accumulates).
            rise_ip_q <= rise_ip_q | pin_rise;
            fall_ip_q <= fall_ip_q | pin_fall;
            high_ip_q <= high_ip_q | gpio_i;
            low_ip_q  <= low_ip_q  | ~gpio_i;

            if (write_i && chipselect_i) begin
                case (address_i)
                    WORD_INPUT_EN:   input_en_q   <= writedata_i;
                    WORD_OUTPUT_EN:  output_en_q  <= writedata_i;
                    WORD_OUTPUT_VAL: output_val_q <= writedata_i;
                    WORD_RISE_IE:    rise_ie_q    <= writedata_i;
                    WORD_RISE_IP:    rise_ip_q    <= (rise_ip_q | pin_rise) & ~writedata_i;
                    WORD_FALL_IE:    fall_ie_q    <= writedata_i;
                    WORD_FALL_IP:    fall_ip_q    <= (fall_ip_q | pin_fall) & ~writedata_i;
                    WORD_HIGH_IE:    high_ie_q    <= writedata_i;
                    WORD_HIGH_IP:    high_ip_q    <= (high_ip_q | gpio_i) & ~writedata_i;
                    WORD_LOW_IE:     low_ie_q     <= writedata_i;
                    WORD_LOW_IP:     low_ip_q     <= (low_ip_q | ~gpio_i) & ~writedata_i;
                    WORD_OUT_XOR:    out_xor_q    <= writedata_i;
                    // PUE / DS / IOF_EN / IOF_SEL: RAZ/WI
                    default: ;
                endcase
            end
        end
    end

    // ── Reads ──────────────────────────────────────────────────
    always_ff @(posedge clk_i) begin
        if (read_i && chipselect_i) begin
            case (address_i)
                WORD_INPUT_VAL:  readdata_o <= gpio_i;
                WORD_INPUT_EN:   readdata_o <= input_en_q;
                WORD_OUTPUT_EN:  readdata_o <= output_en_q;
                WORD_OUTPUT_VAL: readdata_o <= output_val_q;
                WORD_RISE_IE:    readdata_o <= rise_ie_q;
                WORD_RISE_IP:    readdata_o <= rise_ip_q;
                WORD_FALL_IE:    readdata_o <= fall_ie_q;
                WORD_FALL_IP:    readdata_o <= fall_ip_q;
                WORD_HIGH_IE:    readdata_o <= high_ie_q;
                WORD_HIGH_IP:    readdata_o <= high_ip_q;
                WORD_LOW_IE:     readdata_o <= low_ie_q;
                WORD_LOW_IP:     readdata_o <= low_ip_q;
                WORD_OUT_XOR:    readdata_o <= out_xor_q;
                // RAZ regs
                WORD_PUE,
                WORD_DS,
                WORD_IOF_EN,
                WORD_IOF_SEL:    readdata_o <= 32'h0;
                default:         readdata_o <= 32'h0;
            endcase
        end
    end

    assign interrupt_reg = (rise_ip_q & rise_ie_q)
                         | (fall_ip_q & fall_ie_q)
                         | (high_ip_q & high_ie_q)
                         | (low_ip_q  & low_ie_q);

endmodule
