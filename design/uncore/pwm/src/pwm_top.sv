// ── ntiny PWM (sifive,pwm0 register layout) ────────────────────────
//
// Phase 2e peripheral standardisation: register layout matches the
// upstream Linux SiFive PWM driver (drivers/pwm/pwm-sifive.c). See
// pwm_defs.sv for the register map.
//
// Single 31-bit free-running counter, 4 independent 16-bit compare
// channels. SCALE shifts the counter right before feeding it to the
// comparators. ZERO_CMP resets the counter when channel-0 fires (gives
// variable period). Output i is HIGH while pwms < cmp[i], LOW
// otherwise; pwmcmp_ip[i] is the sticky form of the same comparison
// (cleared by writing 0 to the corresponding bit of PWMCFG).
//
// The previous ntiny PWM offered dual-channel + deadtime + complementary
// modes; those are dropped in this transition. They can be re-added
// later as a custom extension if motor-control workloads need them.

`include "pwm_defs.sv"

module pwm_top (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic [7:0]  address_i,
    input  logic [31:0] writedata_i,
    input  logic        write_i,
    output logic [31:0] readdata_o,
    input  logic        read_i,
    input  logic        chipselect_i,
    output logic        pwm1_h_o,        // cmp0 output
    output logic        pwm1_l_o,        // cmp1 output
    output logic        pwm2_h_o,        // cmp2 output
    output logic        pwm2_l_o         // cmp3 output
);

    wire write_en_w = write_i & chipselect_i;
    wire read_en_w  = read_i  & chipselect_i;

    // ── Configuration registers ────────────────────────────
    logic [3:0]  cfg_scale_q;
    logic        cfg_sticky_q;
    logic        cfg_zerocmp_q;
    logic        cfg_deglitch_q;
    logic        cfg_enalways_q;
    logic        cfg_enonce_q;
    logic        cfg_center_q;
    logic        cfg_gang_q;

    logic [30:0] count_q;
    logic [15:0] cmp_q [0:3];
    logic [3:0]  cmp_ip_q;

    // ── Counter run gate ───────────────────────────────────
    wire run_w = cfg_enalways_q | cfg_enonce_q;

    // PWMS: scaled count, low 16 bits of (count >> scale)
    wire [30:0] count_shifted_w = count_q >> cfg_scale_q;
    wire [15:0] pwms_w = count_shifted_w[15:0];

    // Per-channel compare match (combinational)
    logic [3:0] cmp_match_w;
    always_comb begin
        for (int i = 0; i < 4; i++)
            cmp_match_w[i] = (pwms_w >= cmp_q[i]);
    end

    // ── Writes ─────────────────────────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            cfg_scale_q    <= 4'd0;
            cfg_sticky_q   <= 1'b0;
            cfg_zerocmp_q  <= 1'b0;
            cfg_deglitch_q <= 1'b0;
            cfg_enalways_q <= 1'b0;
            cfg_enonce_q   <= 1'b0;
            cfg_center_q   <= 1'b0;
            cfg_gang_q     <= 1'b0;
            for (int i = 0; i < 4; i++)
                cmp_q[i] <= 16'h0;
        end else if (write_en_w) begin
            case (address_i)
                `PWM_PWMCFG: begin
                    cfg_scale_q    <= writedata_i[`PWM_PWMCFG_SCALE_R];
                    cfg_sticky_q   <= writedata_i[`PWM_PWMCFG_STICKY_B];
                    cfg_zerocmp_q  <= writedata_i[`PWM_PWMCFG_ZEROCMP_B];
                    cfg_deglitch_q <= writedata_i[`PWM_PWMCFG_DEGLITCH_B];
                    cfg_enalways_q <= writedata_i[`PWM_PWMCFG_ENALWAYS_B];
                    cfg_enonce_q   <= writedata_i[`PWM_PWMCFG_ENONCE_B];
                    cfg_center_q   <= writedata_i[`PWM_PWMCFG_CENTER_B];
                    cfg_gang_q     <= writedata_i[`PWM_PWMCFG_GANG_B];
                    // ip bits: write-0-to-clear (only when sticky=0 the
                    // bits also clear automatically next cycle below)
                end
                `PWM_PWMCMP0: cmp_q[0] <= writedata_i[15:0];
                `PWM_PWMCMP1: cmp_q[1] <= writedata_i[15:0];
                `PWM_PWMCMP2: cmp_q[2] <= writedata_i[15:0];
                `PWM_PWMCMP3: cmp_q[3] <= writedata_i[15:0];
                default: ;
            endcase
        end
    end

    // ── Counter ────────────────────────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            count_q <= 31'd0;
        end else if (run_w) begin
            // ZERO_CMP: when cmp[0] fires, reset count.
            if (cfg_zerocmp_q && cmp_match_w[0])
                count_q <= 31'd0;
            else
                count_q <= count_q + 31'd1;
        end
    end

    // ── Sticky IP bits ─────────────────────────────────────
    // pwmcmpXip is set when pwms>=cmp[X]. Sticky bit is cleared by
    // writing 0 to the corresponding bit of PWMCFG. When sticky=0 the
    // bit follows cmp_match_w[i] non-stickily.
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            cmp_ip_q <= 4'h0;
        end else begin
            for (int i = 0; i < 4; i++) begin
                if (write_en_w && address_i == `PWM_PWMCFG &&
                    !writedata_i[28+i]) begin
                    cmp_ip_q[i] <= 1'b0;
                end else if (cfg_sticky_q) begin
                    if (cmp_match_w[i])
                        cmp_ip_q[i] <= 1'b1;
                end else begin
                    cmp_ip_q[i] <= cmp_match_w[i];
                end
            end
        end
    end

    // ── Read mux ───────────────────────────────────────────
    logic [31:0] data_r;
    always_comb begin
        data_r = 32'h0;
        case (address_i)
            `PWM_PWMCFG: begin
                data_r[`PWM_PWMCFG_SCALE_R]    = cfg_scale_q;
                data_r[`PWM_PWMCFG_STICKY_B]   = cfg_sticky_q;
                data_r[`PWM_PWMCFG_ZEROCMP_B]  = cfg_zerocmp_q;
                data_r[`PWM_PWMCFG_DEGLITCH_B] = cfg_deglitch_q;
                data_r[`PWM_PWMCFG_ENALWAYS_B] = cfg_enalways_q;
                data_r[`PWM_PWMCFG_ENONCE_B]   = cfg_enonce_q;
                data_r[`PWM_PWMCFG_CENTER_B]   = cfg_center_q;
                data_r[`PWM_PWMCFG_GANG_B]     = cfg_gang_q;
                data_r[`PWM_PWMCFG_IP0_B]      = cmp_ip_q[0];
                data_r[`PWM_PWMCFG_IP1_B]      = cmp_ip_q[1];
                data_r[`PWM_PWMCFG_IP2_B]      = cmp_ip_q[2];
                data_r[`PWM_PWMCFG_IP3_B]      = cmp_ip_q[3];
            end
            `PWM_PWMCOUNT: data_r = {1'b0, count_q};
            `PWM_PWMS:     data_r = {16'h0, pwms_w};
            `PWM_PWMCMP0:  data_r = {16'h0, cmp_q[0]};
            `PWM_PWMCMP1:  data_r = {16'h0, cmp_q[1]};
            `PWM_PWMCMP2:  data_r = {16'h0, cmp_q[2]};
            `PWM_PWMCMP3:  data_r = {16'h0, cmp_q[3]};
            default: ;
        endcase
    end

    // 1-cycle registered read response to match other peripherals
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            readdata_o <= 32'h0;
        else if (read_en_w)
            readdata_o <= data_r;
    end

    // ── PWM outputs ────────────────────────────────────────
    // HIGH while pwms < cmp[i] (i.e., compare hasn't fired yet).
    // cmp[i] = 0 → output stays LOW (pwm disabled).
    assign pwm1_h_o = ~cmp_match_w[0];
    assign pwm1_l_o = ~cmp_match_w[1];
    assign pwm2_h_o = ~cmp_match_w[2];
    assign pwm2_l_o = ~cmp_match_w[3];

endmodule
