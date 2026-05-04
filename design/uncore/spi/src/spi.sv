// ── ntiny SPI (sifive,spi0 register layout) ────────────────────────
//
// Phase 2d peripheral standardisation: register layout matches the
// upstream Linux SiFive SPI0 driver (drivers/spi/spi-sifive.c). See
// spi_defs.sv for the full register map.
//
// Single CS line. Single-protocol shift only (proto=00). 8-bit frames
// only (FMT.len writable but ignored). FCTRL/FFMT (memory-mapped flash
// mode) RAZ/WI. Inter-frame delays (DELAY0/DELAY1) writable but not
// enforced — bare-metal tests + Linux spidev workloads tolerate this.
//
// The bit-level shift FSM is preserved from the prior implementation
// (proven across loopback + register R/W coverage). What changed is
// the software-facing register interface.

`include "spi_defs.sv"

module spi_top (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        write_i,
    input  logic        read_i,
    input  logic        chipselect_i,
    input  logic [31:0] writedata_i,
    input  logic [31:0] address_i,
    output logic [31:0] readdata_o,
    output logic [7:0]  spi_cs_o,
    input  logic        spi_miso_i,
    output logic        spi_mosi_o,
    output logic        intr_o,
    output logic        spi_clk_o
);

    wire [7:0] addr_w     = address_i[7:0];
    wire       write_en_w = write_i & chipselect_i;
    wire       read_en_w  = read_i  & chipselect_i;

    // ── Configuration registers ────────────────────────────
    logic [11:0] sckdiv_q;
    logic        sckmode_cpha_q;
    logic        sckmode_cpol_q;
    logic        csid_q;             // 1-bit (single CS implemented)
    logic        csdef_q;            // 1-bit, default level for CS0
    logic [1:0]  csmode_q;
    logic [31:0] delay0_q;
    logic [31:0] delay1_q;
    logic [1:0]  fmt_proto_q;
    logic        fmt_endian_q;
    logic        fmt_dir_q;
    logic [3:0]  fmt_len_q;
    logic [2:0]  txmark_q;
    logic [2:0]  rxmark_q;
    logic        ie_txwm_q;
    logic        ie_rxwm_q;

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            sckdiv_q       <= 12'd24;
            sckmode_cpha_q <= 1'b0;
            sckmode_cpol_q <= 1'b0;
            csid_q         <= 1'b0;
            csdef_q        <= 1'b1;        // default high (active-low CS)
            csmode_q       <= `SPI_CSMODE_OFF;
            delay0_q       <= 32'h0001_0001;
            delay1_q       <= 32'h0000_0000;
            fmt_proto_q    <= 2'b00;
            fmt_endian_q   <= 1'b0;
            fmt_dir_q      <= 1'b0;
            fmt_len_q      <= 4'd8;
            txmark_q       <= 3'd0;
            rxmark_q       <= 3'd0;
            ie_txwm_q      <= 1'b0;
            ie_rxwm_q      <= 1'b0;
        end else if (write_en_w) begin
            case (addr_w)
                `SPI_SCKDIV:  sckdiv_q <= writedata_i[`SPI_SCKDIV_DIV_R];
                `SPI_SCKMODE: begin
                    sckmode_cpha_q <= writedata_i[`SPI_SCKMODE_CPHA_B];
                    sckmode_cpol_q <= writedata_i[`SPI_SCKMODE_CPOL_B];
                end
                `SPI_CSID:    csid_q   <= writedata_i[0];
                `SPI_CSDEF:   csdef_q  <= writedata_i[0];
                `SPI_CSMODE:  csmode_q <= writedata_i[`SPI_CSMODE_MODE_R];
                `SPI_DELAY0:  delay0_q <= writedata_i;
                `SPI_DELAY1:  delay1_q <= writedata_i;
                `SPI_FMT: begin
                    fmt_proto_q  <= writedata_i[`SPI_FMT_PROTO_R];
                    fmt_endian_q <= writedata_i[`SPI_FMT_ENDIAN_B];
                    fmt_dir_q    <= writedata_i[`SPI_FMT_DIR_B];
                    fmt_len_q    <= writedata_i[`SPI_FMT_LEN_R];
                end
                `SPI_TXMARK:  txmark_q <= writedata_i[2:0];
                `SPI_RXMARK:  rxmark_q <= writedata_i[2:0];
                `SPI_IE: begin
                    ie_txwm_q <= writedata_i[`SPI_IE_TXWM_B];
                    ie_rxwm_q <= writedata_i[`SPI_IE_RXWM_B];
                end
                default: ;
            endcase
        end
    end

    // ── TX/RX FIFO push/pop strobes ────────────────────────
    wire txdata_wr_w = write_en_w & (addr_w == `SPI_TXDATA);
    wire rxdata_rd_w = read_en_w  & (addr_w == `SPI_RXDATA);

    // ── TX FIFO ────────────────────────────────────────────
    wire        tx_accept_w;
    wire        tx_valid_w;
    wire [7:0]  tx_data_w;
    wire        tx_pop_w;

    spi_fifo #(.WIDTH(8), .DEPTH(4), .ADDR_W(2)) u_tx_fifo (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .flush_i    (1'b0),
        .data_in_i  (writedata_i[7:0]),
        .push_i     (txdata_wr_w),
        .accept_o   (tx_accept_w),
        .pop_i      (tx_pop_w),
        .data_out_o (tx_data_w),
        .valid_o    (tx_valid_w)
    );

    // ── RX FIFO ────────────────────────────────────────────
    wire        rx_accept_w;
    wire        rx_valid_w;
    wire [7:0]  rx_data_out_w;
    wire        rx_push_w;
    logic [7:0] rx_data_in_w;

    spi_fifo #(.WIDTH(8), .DEPTH(4), .ADDR_W(2)) u_rx_fifo (
        .clk_i      (clk_i),
        .rst_i      (rst_i),
        .flush_i    (1'b0),
        .data_in_i  (rx_data_in_w),
        .push_i     (rx_push_w),
        .accept_o   (rx_accept_w),
        .pop_i      (rxdata_rd_w),
        .data_out_o (rx_data_out_w),
        .valid_o    (rx_valid_w)
    );

    // Interrupt-pending approximation. The SiFive driver only checks
    // ip.txwm (TX FIFO has space below mark) and ip.rxwm (RX FIFO has
    // data above mark). FIFO depth=4 makes this near-binary; we treat
    // any-space-available / any-data-available as the trigger when
    // the corresponding mark is non-zero.
    wire ip_txwm_w = (txmark_q != 3'd0) ? tx_accept_w : 1'b0;
    wire ip_rxwm_w = (rxmark_q == 3'd0) ? rx_valid_w  : 1'b0;

    // ── Read mux ───────────────────────────────────────────
    logic [31:0] data_r;
    always_comb begin
        data_r = 32'h0;
        case (addr_w)
            `SPI_SCKDIV:  data_r[`SPI_SCKDIV_DIV_R] = sckdiv_q;
            `SPI_SCKMODE: begin
                data_r[`SPI_SCKMODE_CPHA_B] = sckmode_cpha_q;
                data_r[`SPI_SCKMODE_CPOL_B] = sckmode_cpol_q;
            end
            `SPI_CSID:    data_r[0] = csid_q;
            `SPI_CSDEF:   data_r[0] = csdef_q;
            `SPI_CSMODE:  data_r[`SPI_CSMODE_MODE_R] = csmode_q;
            `SPI_DELAY0:  data_r = delay0_q;
            `SPI_DELAY1:  data_r = delay1_q;
            `SPI_FMT: begin
                data_r[`SPI_FMT_PROTO_R]  = fmt_proto_q;
                data_r[`SPI_FMT_ENDIAN_B] = fmt_endian_q;
                data_r[`SPI_FMT_DIR_B]    = fmt_dir_q;
                data_r[`SPI_FMT_LEN_R]    = fmt_len_q;
            end
            `SPI_TXDATA:  data_r[`SPI_TXDATA_FULL_B] = ~tx_accept_w;
            `SPI_RXDATA: begin
                data_r[`SPI_RXDATA_DATA_R]  = rx_data_out_w;
                data_r[`SPI_RXDATA_EMPTY_B] = ~rx_valid_w;
            end
            `SPI_TXMARK:  data_r[2:0] = txmark_q;
            `SPI_RXMARK:  data_r[2:0] = rxmark_q;
            `SPI_FCTRL:   data_r = 32'h0;
            `SPI_FFMT:    data_r = 32'h0;
            `SPI_IE: begin
                data_r[`SPI_IE_TXWM_B] = ie_txwm_q;
                data_r[`SPI_IE_RXWM_B] = ie_rxwm_q;
            end
            `SPI_IP: begin
                data_r[`SPI_IP_TXWM_B] = ip_txwm_w;
                data_r[`SPI_IP_RXWM_B] = ip_rxwm_w;
            end
            default: ;
        endcase
    end

    logic [31:0] readdata_q;
    always_ff @(posedge clk_i or posedge rst_i)
        if (rst_i)         readdata_q <= 32'h0;
        else if (read_en_w) readdata_q <= data_r;
    assign readdata_o = readdata_q;

    // ── Bit-shift state machine (preserved from legacy) ────
    logic        active_q;
    logic [4:0]  bit_count_q;       // 0..15 = 8-bit transfer (16 SCK edges)
    logic [7:0]  shift_reg_q;
    logic [11:0] clk_div_q;
    logic        done_q;
    logic        spi_clk_q;
    logic        spi_mosi_q;

    wire enable_w = (csmode_q != `SPI_CSMODE_OFF);
    wire start_w  = enable_w & ~active_q & ~done_q & tx_valid_w;
    wire miso_w   = spi_miso_i;

    // SCK divider
    always_ff @(posedge clk_i or posedge rst_i)
        if (rst_i)                                 clk_div_q <= 12'd0;
        else if (start_w || clk_div_q == 12'd0)    clk_div_q <= sckdiv_q;
        else                                       clk_div_q <= clk_div_q - 12'd1;

    wire clk_en_w = (clk_div_q == 12'd0);

    // Sample/drive pulses
    logic sample_r, drive_r;
    always_comb begin
        sample_r = 1'b0;
        drive_r  = 1'b0;
        if (start_w) begin
            drive_r = ~sckmode_cpha_q;          // CPHA=0: pre-drive MOSI
        end else if (active_q && clk_en_w) begin
            if (bit_count_q[0] == sckmode_cpha_q)
                sample_r = 1'b1;
            else if (sckmode_cpha_q)
                drive_r = 1'b1;
            else
                drive_r = (bit_count_q != 5'd0) && (bit_count_q != 5'd15);
        end
    end

    // Shift register + SCK
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            shift_reg_q <= 8'h0;
            spi_clk_q   <= 1'b0;
            spi_mosi_q  <= 1'b0;
        end else if (start_w) begin
            spi_clk_q <= sckmode_cpol_q;
            if (drive_r) begin
                spi_mosi_q  <= tx_data_w[7];
                shift_reg_q <= {tx_data_w[6:0], 1'b0};
            end else begin
                shift_reg_q <= tx_data_w;
            end
        end else if (active_q && clk_en_w) begin
            spi_clk_q <= ~spi_clk_q;
            if (drive_r) begin
                spi_mosi_q  <= shift_reg_q[7];
                shift_reg_q <= {shift_reg_q[6:0], 1'b0};
            end else if (sample_r) begin
                shift_reg_q[0] <= miso_w;
            end
        end
    end

    // Bit counter
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            bit_count_q <= 5'd0;
            active_q    <= 1'b0;
            done_q      <= 1'b0;
        end else if (start_w) begin
            bit_count_q <= 5'd0;
            active_q    <= 1'b1;
            done_q      <= 1'b0;
        end else if (active_q && clk_en_w) begin
            if (bit_count_q == 5'd15) begin
                active_q <= 1'b0;
                done_q   <= 1'b1;
            end else begin
                bit_count_q <= bit_count_q + 5'd1;
            end
        end else begin
            done_q <= 1'b0;
        end
    end

    assign rx_data_in_w = shift_reg_q;
    assign rx_push_w    = done_q & rx_accept_w;
    assign tx_pop_w     = done_q;

    // ── CS line control ────────────────────────────────────
    // CS0 follows csmode (AUTO/HOLD/OFF). Other 7 CS bits stay at the
    // csdef level — ntiny exposes a single CS line; the wider bus is a
    // legacy carry-over.
    logic cs_active_q;
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            cs_active_q <= 1'b0;
        end else if (csmode_q == `SPI_CSMODE_OFF) begin
            cs_active_q <= 1'b0;
        end else if (txdata_wr_w & tx_accept_w) begin
            cs_active_q <= 1'b1;
        end else if (csmode_q == `SPI_CSMODE_AUTO &&
                     ~tx_valid_w & ~active_q & ~done_q) begin
            cs_active_q <= 1'b0;
        end
    end

    wire cs0_w = cs_active_q ? ~csdef_q : csdef_q;
    assign spi_cs_o   = {{7{csdef_q}}, cs0_w};
    assign spi_mosi_o = spi_mosi_q;
    assign spi_clk_o  = spi_clk_q;

    // ── Interrupt ──────────────────────────────────────────
    assign intr_o = (ie_txwm_q & ip_txwm_w) | (ie_rxwm_q & ip_rxwm_w);

endmodule

// ────────────────────────────────────────────────────────────
// Simple synchronous FIFO used for TX and RX. Preserved from the
// legacy SPI implementation.
// ────────────────────────────────────────────────────────────
module spi_fifo
#(
    parameter WIDTH  = 8,
    parameter DEPTH  = 4,
    parameter ADDR_W = 2
)
(
    input  logic               clk_i,
    input  logic               rst_i,
    input  logic [WIDTH-1:0]   data_in_i,
    input  logic               push_i,
    input  logic               pop_i,
    input  logic               flush_i,

    output logic [WIDTH-1:0]   data_out_o,
    output logic               accept_o,
    output logic               valid_o
);

    localparam COUNT_W = ADDR_W + 1;

    logic [WIDTH-1:0]   ram_q [DEPTH-1:0];
    logic [ADDR_W-1:0]  rd_ptr_q;
    logic [ADDR_W-1:0]  wr_ptr_q;
    logic [COUNT_W-1:0] count_q;

    integer i;
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            for (i = 0; i < DEPTH; i = i + 1)
                ram_q[i] <= {WIDTH{1'b0}};
            count_q  <= {COUNT_W{1'b0}};
            rd_ptr_q <= {ADDR_W{1'b0}};
            wr_ptr_q <= {ADDR_W{1'b0}};
        end else if (flush_i) begin
            count_q  <= {COUNT_W{1'b0}};
            rd_ptr_q <= {ADDR_W{1'b0}};
            wr_ptr_q <= {ADDR_W{1'b0}};
        end else begin
            if (push_i & accept_o) begin
                ram_q[wr_ptr_q] <= data_in_i;
                wr_ptr_q        <= wr_ptr_q + 1;
            end
            if (pop_i & valid_o)
                rd_ptr_q <= rd_ptr_q + 1;
            if      ((push_i & accept_o) & ~(pop_i & valid_o)) count_q <= count_q + 1;
            else if (~(push_i & accept_o) & (pop_i & valid_o)) count_q <= count_q - 1;
        end
    end

    assign valid_o    = (count_q != 0);
    assign accept_o   = (count_q != DEPTH);
    assign data_out_o = ram_q[rd_ptr_q];

endmodule
