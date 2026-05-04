// ── ntiny UART (sifive,uart0 register layout) ────────────────────
//
// Phase 2b peripheral standardisation: register layout matches the
// upstream Linux SiFive UART0 driver (drivers/tty/serial/sifive.c).
// See uart_defs.sv for the full register map.
//
// The bit-level TX/RX FSMs are preserved from the prior implementation
// (proven across many bare-metal tests + Linux boot at 250 kbaud).
// What changed is the software-facing register interface.

`include "uart_defs.sv"

module uart_top (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic        write_i,
    input  logic        read_i,
    input  logic        chipselect_i,
    input  logic [31:0] writedata_i,
    input  logic [4:0]  address_i,        // byte offset, 0..0x1F
    output logic [31:0] readdata_o,

    input  logic        rx_i,
    output logic        tx_o,
    output logic        tx_intr_o,
    output logic        rx_intr_o
);

    // ── Configuration registers ──────────────────────────────
    logic [31:0] div_q;     // baud divisor
    logic        txen_q;
    logic        nstop_q;   // 0 = 1 stop bit, 1 = 2 stop bits
    logic        rxen_q;
    logic        ie_txwm_q;
    logic        ie_rxwm_q;

    // ── TX FSM state (preserved from legacy ntiny UART) ──────
    logic        tx_busy_q;
    logic [3:0]  tx_bits_q;
    logic [31:0] tx_count_q;
    logic [7:0]  tx_shift_reg_q;
    logic        txd_q;
    logic        tx_complete_q;

    // ── RX FSM state ─────────────────────────────────────────
    logic        rxd_ms_q, rxd_q;
    logic [7:0]  rx_data_q;
    logic [3:0]  rx_bits_q;
    logic [31:0] rx_count_q;
    logic [7:0]  rx_shift_reg_q;
    logic        rx_ready_q;
    logic        rx_busy_q;

    // ── Bit-period constants ─────────────────────────────────
    localparam logic [3:0] START_BIT = 4'd0;
    localparam logic [3:0] STOP_BIT0 = 4'd9;
    localparam logic [3:0] STOP_BIT1 = 4'd10;

    // ── Read port (combinational mux + 1-cycle register) ────
    logic [31:0] data_r;
    always_comb begin
        data_r = 32'h0;
        case (address_i)
            `U_TXDATA: begin
                data_r[`U_TXDATA_FULL_B] = tx_busy_q;
            end
            `U_RXDATA: begin
                data_r[`U_RXDATA_DATA_R]  = rx_data_q;
                data_r[`U_RXDATA_EMPTY_B] = ~rx_ready_q;
            end
            `U_TXCTRL: begin
                data_r[`U_TXCTRL_TXEN_B]  = txen_q;
                data_r[`U_TXCTRL_NSTOP_B] = nstop_q;
            end
            `U_RXCTRL: begin
                data_r[`U_RXCTRL_RXEN_B]  = rxen_q;
            end
            `U_IE: begin
                data_r[`U_IE_TXWM_B] = ie_txwm_q;
                data_r[`U_IE_RXWM_B] = ie_rxwm_q;
            end
            `U_IP: begin
                data_r[`U_IP_TXWM_B] = ~tx_busy_q;        // tx watermark = TX free
                data_r[`U_IP_RXWM_B] = rx_ready_q;        // rx watermark = byte available
            end
            `U_DIV: begin
                data_r = div_q;
            end
            default: data_r = 32'h0;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (rst_i)
            readdata_o <= 32'h0;
        else
            readdata_o <= data_r;
    end

    // ── Register writes ──────────────────────────────────────
    wire u_txdata_wr = write_i && chipselect_i && (address_i == `U_TXDATA);
    wire u_rxdata_rd = read_i  && chipselect_i && (address_i == `U_RXDATA);

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            div_q     <= 32'd5279;          // 50 MHz / 9600 baud default
            txen_q    <= 1'b0;
            nstop_q   <= 1'b0;
            rxen_q    <= 1'b0;
            ie_txwm_q <= 1'b0;
            ie_rxwm_q <= 1'b0;
        end else if (write_i && chipselect_i) begin
            case (address_i)
                `U_TXCTRL: begin
                    txen_q  <= writedata_i[`U_TXCTRL_TXEN_B];
                    nstop_q <= writedata_i[`U_TXCTRL_NSTOP_B];
                end
                `U_RXCTRL: begin
                    rxen_q  <= writedata_i[`U_RXCTRL_RXEN_B];
                end
                `U_IE: begin
                    ie_txwm_q <= writedata_i[`U_IE_TXWM_B];
                    ie_rxwm_q <= writedata_i[`U_IE_RXWM_B];
                end
                `U_DIV: begin
                    div_q <= writedata_i;
                end
                default: ;
            endcase
        end
    end

    // ── RX double-flop synchroniser ──────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            rxd_ms_q <= 1'b1;
            rxd_q    <= 1'b1;
        end else begin
            rxd_ms_q <= rx_i;
            rxd_q    <= rxd_ms_q;
        end
    end

    // ── RX clock divider ─────────────────────────────────────
    wire rx_sample_w = (rx_count_q == 32'b0);
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            rx_count_q <= 32'b0;
        else if (!rxen_q)
            rx_count_q <= 32'b0;
        else if (!rx_busy_q)
            rx_count_q <= {1'b0, div_q[31:1]};
        else if (rx_count_q != 0)
            rx_count_q <= rx_count_q - 1;
        else if (rx_sample_w) begin
            if ((rx_bits_q == STOP_BIT0 && !nstop_q) ||
                (rx_bits_q == STOP_BIT1 &&  nstop_q))
                rx_count_q <= 32'b0;
            else
                rx_count_q <= div_q;
        end
    end

    // ── RX shift register ────────────────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            rx_shift_reg_q <= 8'h00;
            rx_busy_q      <= 1'b0;
        end else if (!rxen_q) begin
            rx_busy_q <= 1'b0;
        end else if (rx_busy_q && rx_sample_w) begin
            if ((rx_bits_q == STOP_BIT0 && !nstop_q) ||
                (rx_bits_q == STOP_BIT1 &&  nstop_q))
                rx_busy_q <= 1'b0;
            else if (rx_bits_q == START_BIT) begin
                if (rxd_q) rx_busy_q <= 1'b0;       // false start, abort
            end else
                rx_shift_reg_q <= {rxd_q, rx_shift_reg_q[7:1]};
        end else if (!rx_busy_q && (rxd_q == 1'b0)) begin
            rx_shift_reg_q <= 8'h00;
            rx_busy_q      <= 1'b1;
        end
    end

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            rx_bits_q <= START_BIT;
        else if (!rxen_q)
            rx_bits_q <= START_BIT;
        else if (rx_sample_w && rx_busy_q) begin
            if ((rx_bits_q == STOP_BIT1 &&  nstop_q) ||
                (rx_bits_q == STOP_BIT0 && !nstop_q))
                rx_bits_q <= START_BIT;
            else
                rx_bits_q <= rx_bits_q + 4'd1;
        end else if (!rx_busy_q && (div_q == 32'b0))
            rx_bits_q <= START_BIT + 4'd1;
        else if (!rx_busy_q)
            rx_bits_q <= START_BIT;
    end

    // ── RX data hold + ready flag (cleared on rxdata read) ──
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            rx_ready_q <= 1'b0;
            rx_data_q  <= 8'h00;
        end else begin
            // Reading rxdata dequeues the byte (clears ready).
            if (u_rxdata_rd)
                rx_ready_q <= 1'b0;
            // Stop-bit sample with rxd high → byte committed.
            if (rx_busy_q && rx_sample_w &&
                ((rx_bits_q == STOP_BIT1 &&  nstop_q) ||
                 (rx_bits_q == STOP_BIT0 && !nstop_q)) &&
                rxd_q) begin
                rx_data_q  <= rx_shift_reg_q;
                rx_ready_q <= 1'b1;
            end
        end
    end

    // ── TX clock divider ─────────────────────────────────────
    wire tx_sample_w = (tx_count_q == 32'b0);
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            tx_count_q <= 32'b0;
        else if (!tx_busy_q)
            tx_count_q <= div_q;
        else if (tx_count_q != 0)
            tx_count_q <= tx_count_q - 1;
        else if (tx_sample_w)
            tx_count_q <= div_q;
    end

    // ── TX shift register ────────────────────────────────────
    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i) begin
            tx_shift_reg_q <= 8'h00;
            tx_busy_q      <= 1'b0;
            tx_complete_q  <= 1'b0;
        end else if (tx_busy_q) begin
            if (tx_bits_q != START_BIT && tx_sample_w)
                tx_shift_reg_q <= {1'b0, tx_shift_reg_q[7:1]};
            if (tx_bits_q == STOP_BIT0 && tx_sample_w && !nstop_q) begin
                tx_busy_q     <= 1'b0;
                tx_complete_q <= 1'b1;
            end else if (tx_bits_q == STOP_BIT1 && tx_sample_w && nstop_q) begin
                tx_busy_q     <= 1'b0;
                tx_complete_q <= 1'b1;
            end
        end else if (txen_q && u_txdata_wr) begin
            tx_shift_reg_q <= writedata_i[`U_TXDATA_DATA_R];
            tx_busy_q      <= 1'b1;
            tx_complete_q  <= 1'b0;
        end else
            tx_complete_q <= 1'b0;
    end

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            tx_bits_q <= 4'd0;
        else if (tx_sample_w && tx_busy_q) begin
            if ((tx_bits_q == STOP_BIT1 &&  nstop_q) ||
                (tx_bits_q == STOP_BIT0 && !nstop_q))
                tx_bits_q <= START_BIT;
            else
                tx_bits_q <= tx_bits_q + 4'd1;
        end
    end

    // ── TX pin ───────────────────────────────────────────────
    logic txd_r;
    always_comb begin
        txd_r = 1'b1;
        if (tx_busy_q) begin
            if (tx_bits_q == START_BIT)
                txd_r = 1'b0;
            else if (tx_bits_q == STOP_BIT0 || tx_bits_q == STOP_BIT1)
                txd_r = 1'b1;
            else
                txd_r = tx_shift_reg_q[0];
        end
    end

    always_ff @(posedge clk_i or posedge rst_i) begin
        if (rst_i)
            txd_q <= 1'b1;
        else
            txd_q <= txd_r;
    end

    assign tx_o = txd_q;

    // ── PLIC interrupts (qualified by ie register) ──────────
    assign tx_intr_o = ie_txwm_q & ~tx_busy_q;
    assign rx_intr_o = ie_rxwm_q &  rx_ready_q;

endmodule
