
///////////////////////////////////////////////////////////

`include "uart_defs.sv"

////////////////////////////////////////////////////////
///////////////// uart module decleration //////////////
////////////////////////////////////////////////////////

module uart_top  
                            (
                    input logic               clk_i,
                    input logic               rst_i,
                    // avalon interface
                    input logic               write_i,        // input logic  write signal
                    input logic               read_i,         // input logic  read signal
                    input logic               chipselect_i,   // input logic  chipselect signal
                    input logic       [31:0]  writedata_i,    // input logic  write data
                    input logic       [4:0]   address_i,       // input logic  address signal
                    output logic      [31:0]  readdata_o,      // output logic  read data

                    input logic               rx_i,
                    output logic              tx_o,
                    output logic              tx_intr_o,
                    output logic              rx_intr_o
                   
   
                );
//

//-----------------------------------------------------------------
// Register baudrate
//-----------------------------------------------------------------
var logic [31:0] Baudrate_reg;


always_ff @( posedge clk_i or posedge rst_i ) begin
    if (rst_i)
        Baudrate_reg    <=  32'd5279;       // defult baud rate 9600 = (50M/9600)
    else if(write_i && (address_i==`U_BAUDRATE))
        Baudrate_reg    <=  writedata_i;
end



//-----------------------------------------------------------------
// Register u_tx data 
//-----------------------------------------------------------------
wire logic  u_tx_wr_q;
assign u_tx_wr_q = (write_i && (address_i == `U_TX));
// u_tx_data [external]
wire logic  [7:0]  u_tx_data_out_w = writedata_i[`U_TX_DATA_R];




// u_control_ie [internal]
var logic        u_control_ie_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    u_control_ie_q <= 1'd`U_CONTROL_IE_DEFAULT;
else if (write_i && (address_i == `U_CONTROL))
    u_control_ie_q <= writedata_i[`U_CONTROL_IE_R];

wire logic         u_control_ie_out_w = u_control_ie_q;


// u_control_rst_rx [auto_clr]
var logic        u_control_rst_rx_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    u_control_rst_rx_q <= 1'd`U_CONTROL_RST_RX_DEFAULT;
else if (write_i && (address_i == `U_CONTROL))
    u_control_rst_rx_q <= writedata_i[`U_CONTROL_RST_RX_R];
else
    u_control_rst_rx_q <= 1'd`U_CONTROL_RST_RX_DEFAULT;

wire logic         u_control_rst_rx_out_w = u_control_rst_rx_q;





wire logic  [7:0]  u_rx_data_in_w;
wire logic         u_status_ie_in_w;
wire logic         u_status_txfull_in_w;
wire logic         u_status_txempty_in_w;
wire logic         u_status_rxfull_in_w;
wire logic         u_status_rxvalid_in_w;


//-----------------------------------------------------------------
// Read mux
//-----------------------------------------------------------------
var logic [31:0] data_r;

always_comb
begin
    data_r = 32'b0;

    case (address_i)

    `U_RX:
    begin
        data_r[`U_RX_DATA_R] = u_rx_data_in_w;
    end
    `U_STATUS:
    begin
        data_r[`U_STATUS_IE_R] = u_status_ie_in_w;
        data_r[`U_STATUS_TXFULL_R] = u_status_txfull_in_w;
        data_r[`U_STATUS_TXEMPTY_R] = u_status_txempty_in_w;
        data_r[`U_STATUS_RXFULL_R] = u_status_rxfull_in_w;
        data_r[`U_STATUS_RXVALID_R] = u_status_rxvalid_in_w;
    end
    `U_CONTROL:
    begin
        data_r[`U_CONTROL_IE_R] = u_control_ie_q;
    end
    `U_BAUDRATE:
    begin
        data_r = Baudrate_reg;
    end
    default :
        data_r = 32'b0;
    endcase
end

always_ff @( posedge clk_i ) begin : read_register_block
    if (rst_i)
        readdata_o <= 0;
    else
        readdata_o <= data_r;
end

wire logic  u_tx_wr_req_w = u_tx_wr_q;

//-----------------------------------------------------------------
// Registers
//-----------------------------------------------------------------

// Configuration
localparam   STOP_BITS = 1'b0; // 0 = 1, 1 = 2
wire logic  [31:0]   BIT_DIV   =   Baudrate_reg ;

localparam   START_BIT = 4'd0;
localparam   STOP_BIT0 = 4'd9;
localparam   STOP_BIT1 = 4'd10;


// TX Signals
var logic          tx_busy_q;
var logic [3:0]    tx_bits_q;
var logic [31:0]   tx_count_q;
var logic [7:0]    tx_shift_reg_q;
var logic          txd_q;

// RX Signals
var logic          rxd_q;
var logic [7:0]    rx_data_q;
var logic [3:0]    rx_bits_q;
var logic [31:0]   rx_count_q;
var logic [7:0]    rx_shift_reg_q;
var logic          rx_ready_q;
var logic          rx_busy_q;

var logic          rx_err_q;

//-----------------------------------------------------------------
// Re-sync RXD
//-----------------------------------------------------------------
var logic rxd_ms_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
   rxd_ms_q <= 1'b1;
   rxd_q    <= 1'b1;
end
else
begin
   rxd_ms_q <= rx_i;
   rxd_q    <= rxd_ms_q;
end

//-----------------------------------------------------------------
// RX Clock Divider
//-----------------------------------------------------------------
wire logic  rx_sample_w = (rx_count_q == 32'b0);

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    rx_count_q        <= 32'b0;
else
begin
    // Inactive
    if (!rx_busy_q)
        rx_count_q    <= {1'b0, BIT_DIV[31:1]};
    // Rx bit timer
    else if (rx_count_q != 0)
        rx_count_q    <= (rx_count_q - 1);
    // Active
    else if (rx_sample_w)
    begin
        // Last bit?
        if ((rx_bits_q == STOP_BIT0 && !STOP_BITS) || (rx_bits_q == STOP_BIT1 && STOP_BITS))
            rx_count_q    <= 32'b0;
        else
            rx_count_q    <= BIT_DIV;
    end
end

//-----------------------------------------------------------------
// RX Shift Register
//-----------------------------------------------------------------
always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
    rx_shift_reg_q <= 8'h00;
    rx_busy_q      <= 1'b0;
end
// Rx busy
else if (rx_busy_q && rx_sample_w)
begin
    // Last bit?
    if (rx_bits_q == STOP_BIT0 && !STOP_BITS)
        rx_busy_q <= 1'b0;
    else if (rx_bits_q == STOP_BIT1 && STOP_BITS)
        rx_busy_q <= 1'b0;
    else if (rx_bits_q == START_BIT)
    begin
        // Start bit should still be low as sampling mid
        // way through start bit, so if high, error!
        if (rxd_q)
            rx_busy_q <= 1'b0;
    end
    // Rx shift register
    else
        rx_shift_reg_q <= {rxd_q, rx_shift_reg_q[7:1]};
end
// Start bit?
else if (!rx_busy_q && rxd_q == 1'b0)
begin
    rx_shift_reg_q <= 8'h00;
    rx_busy_q      <= 1'b1;
end

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    rx_bits_q  <= START_BIT;
else if (rx_sample_w && rx_busy_q)
begin
    if ((rx_bits_q == STOP_BIT1 && STOP_BITS) || (rx_bits_q == STOP_BIT0 && !STOP_BITS))
        rx_bits_q <= START_BIT;
    else
        rx_bits_q <= rx_bits_q + 4'd1;
end
else if (!rx_busy_q && (BIT_DIV == 32'b0))
    rx_bits_q  <= START_BIT + 4'd1;
else if (!rx_busy_q)
    rx_bits_q  <= START_BIT;





wire logic  u_rx_rd_req_w = read_i & (address_i == `U_RX);
//-----------------------------------------------------------------
// RX Data
//-----------------------------------------------------------------
always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
   rx_ready_q      <= 1'b0;
   rx_data_q       <= 8'h00;
   rx_err_q        <= 1'b0;
end
else
begin
   // If reading data, reset data state
   if (u_rx_rd_req_w || u_control_rst_rx_out_w)
   begin
       rx_ready_q <= 1'b0;
       rx_err_q   <= 1'b0;
   end

   if (rx_busy_q && rx_sample_w)
   begin
       // Stop bit
       if ((rx_bits_q == STOP_BIT1 && STOP_BITS) || (rx_bits_q == STOP_BIT0 && !STOP_BITS))
       begin
           // RXD should be still high
           if (rxd_q)
           begin
               rx_data_q      <= rx_shift_reg_q;
               rx_ready_q     <= 1'b1;
           end
           // Bad Stop bit - wait for a full bit period
           // before allowing start bit detection again
           else
           begin
               rx_ready_q      <= 1'b0;
               rx_data_q       <= 8'h00;
               rx_err_q        <= 1'b1;
           end
       end
       // Mid start bit sample - if high then error
       else if (rx_bits_q == START_BIT && rxd_q)
           rx_err_q        <= 1'b1;
   end
end

assign u_rx_data_in_w        = rx_data_q;
assign u_status_rxvalid_in_w = rx_ready_q;
assign u_status_rxfull_in_w  = rx_ready_q;

//-----------------------------------------------------------------
// TX Clock Divider
//-----------------------------------------------------------------
wire logic  tx_sample_w = (tx_count_q == 32'b0);

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    tx_count_q      <= 32'b0;
else
begin
    // Idle
    if (!tx_busy_q)
        tx_count_q  <= BIT_DIV;
    // Tx bit timer
    else if (tx_count_q != 0)
        tx_count_q  <= (tx_count_q - 1);
    else if (tx_sample_w)
        tx_count_q  <= BIT_DIV;
end

//-----------------------------------------------------------------
// TX Shift Register
//-----------------------------------------------------------------
var logic tx_complete_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
    tx_shift_reg_q <= 8'h00;
    tx_busy_q      <= 1'b0;
    tx_complete_q  <= 1'b0;
end
// Tx busy
else if (tx_busy_q)
begin
    // Shift tx data
    if (tx_bits_q != START_BIT && tx_sample_w)
        tx_shift_reg_q <= {1'b0, tx_shift_reg_q[7:1]};

    // Last bit?
    if (tx_bits_q == STOP_BIT0 && tx_sample_w && !STOP_BITS)
    begin
        tx_busy_q      <= 1'b0;
        tx_complete_q  <= 1'b1;
    end
    else if (tx_bits_q == STOP_BIT1 && tx_sample_w && STOP_BITS)
    begin
        tx_busy_q      <= 1'b0;
        tx_complete_q  <= 1'b1;
    end
end
// Buffer data to transmit
else if (u_tx_wr_req_w)
begin
    tx_shift_reg_q <= u_tx_data_out_w;
    tx_busy_q      <= 1'b1;
    tx_complete_q  <= 1'b0;
end
else
    tx_complete_q  <= 1'b0;

assign u_status_txfull_in_w  = tx_busy_q;
assign u_status_txempty_in_w = ~tx_busy_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    tx_bits_q  <= 4'd0;
else if (tx_sample_w && tx_busy_q)
begin
    if ((tx_bits_q == STOP_BIT1 && STOP_BITS) || (tx_bits_q == STOP_BIT0 && !STOP_BITS))
        tx_bits_q <= START_BIT;
    else
        tx_bits_q <= tx_bits_q + 4'd1;
end

//-----------------------------------------------------------------
// UART Tx Pin
//-----------------------------------------------------------------
var logic txd_r;

always_comb
begin
    txd_r = 1'b1;

    if (tx_busy_q)
    begin
        // Start bit (TXD = L)
        if (tx_bits_q == START_BIT)
            txd_r = 1'b0;
        // Stop bits (TXD = H)
        else if (tx_bits_q == STOP_BIT0 || tx_bits_q == STOP_BIT1)
            txd_r = 1'b1;
        // Data bits
        else
            txd_r = tx_shift_reg_q[0];
    end
end

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    txd_q <= 1'b1;
else
    txd_q <= txd_r;

assign tx_o = txd_q;

//-----------------------------------------------------------------
// Interrupt
//-----------------------------------------------------------------
var logic tx_intr_q;
var logic rx_intr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
   tx_intr_q <= 1'b0;
else if (tx_complete_q)
   tx_intr_q <= 1'b1;
else
   tx_intr_q <= 1'b0;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
   rx_intr_q <= 1'b0;
else if (u_status_rxvalid_in_w)
   rx_intr_q <= 1'b1;
else
   rx_intr_q <= 1'b0;

assign u_status_ie_in_w = u_control_ie_out_w;

//-----------------------------------------------------------------
// Assignments
//-----------------------------------------------------------------
assign tx_intr_o = tx_intr_q;
assign rx_intr_o = rx_intr_q;

endmodule
