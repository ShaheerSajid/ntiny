////////////////////////////////////////////////////////
////////////////	 SPI Module		////////////////////
////////////////////////////////////////////////////////


`include "spi_defs.sv"

module spi_top 

//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------

     (
                    input logic              clk_i,
                    input logic              rst_i,
                    // avalon interface
                    input logic              write_i,        // input logic write signal
                    input logic              read_i,         // input logic read signal
                    input logic              chipselect_i,   // input logic chipselect signal
                    input logic      [31:0]  writedata_i,    // input logic write data
                    input logic      [31:0]   address_i,       // input logic address signal
                    output logic     [31:0]  readdata_o,      // output logic read data
                    output logic     [7:0]   spi_cs_o,
                    input logic              spi_miso_i,
                    output logic             spi_mosi_o,      
                    output logic             intr_o,
					output logic			   spi_clk_o
                   
   
                );


//-----------------------------------------------------------------
// Request Logic
//-----------------------------------------------------------------
wire logic  read_en_w  = read_i;
wire logic  write_en_w = write_i;

var logic     [7:0]      SPI_SCK_RATIO_reg;

// spi_dgier_gie [internal]
var logic        spi_dgier_gie_q;

always_ff @ (posedge clk_i or posedge rst_i)
if (rst_i)
    spi_dgier_gie_q <= 1'd`SPI_DGIER_GIE_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_DGIER))
    spi_dgier_gie_q <= writedata_i[`SPI_DGIER_GIE_R];

wire  logic      spi_dgier_gie_out_w = spi_dgier_gie_q;


//-----------------------------------------------------------------
// Register spi_ipisr
//-----------------------------------------------------------------
var logic spi_ipisr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i)
if (rst_i)
    spi_ipisr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_IPISR))
    spi_ipisr_wr_q <= 1'b1;
else
    spi_ipisr_wr_q <= 1'b0;

// spi_ipisr_tx_empty [external]
wire logic        spi_ipisr_tx_empty_out_w = writedata_i[`SPI_IPISR_TX_EMPTY_R];


//-----------------------------------------------------------------
// Register spi_ipier
//-----------------------------------------------------------------
var logic spi_ipier_wr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_ipier_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_IPIER))
    spi_ipier_wr_q <= 1'b1;
else
    spi_ipier_wr_q <= 1'b0;

// spi_ipier_tx_empty [internal]
var logic        spi_ipier_tx_empty_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_ipier_tx_empty_q <= 1'd`SPI_IPIER_TX_EMPTY_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_IPIER))
    spi_ipier_tx_empty_q <= writedata_i[`SPI_IPIER_TX_EMPTY_R];

wire  logic       spi_ipier_tx_empty_out_w = spi_ipier_tx_empty_q;


//-----------------------------------------------------------------
// Register spi_srr
//-----------------------------------------------------------------
var logic spi_srr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_srr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_SRR))
    spi_srr_wr_q <= 1'b1;
else
    spi_srr_wr_q <= 1'b0;

// spi_srr_reset [auto_clr]
var logic [31:0]  spi_srr_reset_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_srr_reset_q <= 32'd`SPI_SRR_RESET_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_SRR))
    spi_srr_reset_q <= writedata_i[`SPI_SRR_RESET_R];
else
    spi_srr_reset_q <= 32'd`SPI_SRR_RESET_DEFAULT;

wire  logic [31:0]  spi_srr_reset_out_w = spi_srr_reset_q;


//-----------------------------------------------------------------
// Register spi_cr
//-----------------------------------------------------------------
var logic spi_cr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i  )
if (rst_i)
    spi_cr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_wr_q <= 1'b1;
else
    spi_cr_wr_q <= 1'b0;

// spi_cr_loop [internal]
var logic        spi_cr_loop_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_loop_q <= 1'd`SPI_CR_LOOP_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_loop_q <= writedata_i[`SPI_CR_LOOP_R];

wire logic      spi_cr_loop_out_w = spi_cr_loop_q;


// spi_cr_spe [internal]
var logic        spi_cr_spe_q;

always_ff @ (posedge clk_i  or posedge rst_i)
if (rst_i)
    spi_cr_spe_q <= 1'd`SPI_CR_SPE_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_spe_q <= writedata_i[`SPI_CR_SPE_R];

wire   logic      spi_cr_spe_out_w = spi_cr_spe_q;


// spi_cr_master [internal]
var logic        spi_cr_master_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_master_q <= 1'd`SPI_CR_MASTER_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_master_q <= writedata_i[`SPI_CR_MASTER_R];

wire   logic      spi_cr_master_out_w = spi_cr_master_q;


// spi_cr_cpol [internal]
var logic        spi_cr_cpol_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_cpol_q <= 1'd`SPI_CR_CPOL_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_cpol_q <= writedata_i[`SPI_CR_CPOL_R];

wire  logic       spi_cr_cpol_out_w = spi_cr_cpol_q;


// spi_cr_cpha [internal]
var logic        spi_cr_cpha_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_cpha_q <= 1'd`SPI_CR_CPHA_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_cpha_q <= writedata_i[`SPI_CR_CPHA_R];

wire   logic      spi_cr_cpha_out_w = spi_cr_cpha_q;


// spi_cr_txfifo_rst [auto_clr]
var logic        spi_cr_txfifo_rst_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_txfifo_rst_q <= 1'd`SPI_CR_TXFIFO_RST_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_txfifo_rst_q <= writedata_i[`SPI_CR_TXFIFO_RST_R];
else
    spi_cr_txfifo_rst_q <= 1'd`SPI_CR_TXFIFO_RST_DEFAULT;

wire  logic       spi_cr_txfifo_rst_out_w = spi_cr_txfifo_rst_q;


// spi_cr_rxfifo_rst [auto_clr]
var logic        spi_cr_rxfifo_rst_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_rxfifo_rst_q <= 1'd`SPI_CR_RXFIFO_RST_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_rxfifo_rst_q <= writedata_i[`SPI_CR_RXFIFO_RST_R];
else
    spi_cr_rxfifo_rst_q <= 1'd`SPI_CR_RXFIFO_RST_DEFAULT;

wire  logic       spi_cr_rxfifo_rst_out_w = spi_cr_rxfifo_rst_q;


// spi_cr_manual_ss [internal]
var logic        spi_cr_manual_ss_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_manual_ss_q <= 1'd`SPI_CR_MANUAL_SS_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_manual_ss_q <= writedata_i[`SPI_CR_MANUAL_SS_R];

wire  logic       spi_cr_manual_ss_out_w = spi_cr_manual_ss_q;


// spi_cr_trans_inhibit [internal]
var logic        spi_cr_trans_inhibit_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_trans_inhibit_q <= 1'd`SPI_CR_TRANS_INHIBIT_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_trans_inhibit_q <= writedata_i[`SPI_CR_TRANS_INHIBIT_R];

wire  logic       spi_cr_trans_inhibit_out_w = spi_cr_trans_inhibit_q;


// spi_cr_lsb_first [internal]
var logic        spi_cr_lsb_first_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_cr_lsb_first_q <= 1'd`SPI_CR_LSB_FIRST_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_CR))
    spi_cr_lsb_first_q <= writedata_i[`SPI_CR_LSB_FIRST_R];

wire   logic      spi_cr_lsb_first_out_w = spi_cr_lsb_first_q;


//-----------------------------------------------------------------
// Register spi_sr
//-----------------------------------------------------------------
var logic spi_sr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_sr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_SR))
    spi_sr_wr_q <= 1'b1;
else
    spi_sr_wr_q <= 1'b0;





//-----------------------------------------------------------------
// Register spi_dtr
//-----------------------------------------------------------------
var logic spi_dtr_wr_q;
var logic [7:0]spi_dtr;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_dtr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_DTR))
    spi_dtr_wr_q <= 1'b1;
else
    spi_dtr_wr_q <= 1'b0;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_dtr <= 8'b0;
else if (write_en_w && (address_i[7:0] == `SPI_DTR))
    spi_dtr <= writedata_i[`SPI_DTR_DATA_R];


// spi_dtr_data [external]
wire [7:0]  spi_dtr_data_out_w = spi_dtr;


//-----------------------------------------------------------------
// Register spi_drr
//-----------------------------------------------------------------
var logic spi_drr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_drr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_DRR))
    spi_drr_wr_q <= 1'b1;
else
    spi_drr_wr_q <= 1'b0;


//-----------------------------------------------------------------
// Register spi_ssr
//-----------------------------------------------------------------
var logic spi_ssr_wr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_ssr_wr_q <= 1'b0;
else if (write_en_w && (address_i[7:0] == `SPI_SSR))
    spi_ssr_wr_q <= 1'b1;
else
    spi_ssr_wr_q <= 1'b0;

// spi_ssr_value [internal]
var logic [7:0]  spi_ssr_value_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    spi_ssr_value_q <= 8'd`SPI_SSR_VALUE_DEFAULT;
else if (write_en_w && (address_i[7:0] == `SPI_SSR))
    spi_ssr_value_q <= writedata_i[`SPI_SSR_VALUE_R];

wire [7:0]  spi_ssr_value_out_w = spi_ssr_value_q;


wire        spi_ipisr_tx_empty_in_w;
wire        spi_sr_rx_empty_in_w;
wire        spi_sr_rx_full_in_w;
wire        spi_sr_tx_empty_in_w;
wire        spi_sr_tx_full_in_w;
wire [7:0]  spi_drr_data_in_w;


//-----------------------------------------------------------------
// Read mux
//-----------------------------------------------------------------
var logic [31:0] data_r;

always_comb
begin
    data_r = 32'b0;

    case (address_i[7:0])

    `SPI_DGIER:
    begin
        data_r[`SPI_DGIER_GIE_R] = spi_dgier_gie_q;
    end
    `SPI_IPISR:
    begin
        data_r[`SPI_IPISR_TX_EMPTY_R] = spi_ipisr_tx_empty_in_w;
    end
    `SPI_IPIER:
    begin
        data_r[`SPI_IPIER_TX_EMPTY_R] = spi_ipier_tx_empty_q;
    end
    `SPI_SRR:
    begin
    end
    `SPI_CR:
    begin
        data_r[`SPI_CR_LOOP_R] = spi_cr_loop_q;
        data_r[`SPI_CR_SPE_R] = spi_cr_spe_q;
        data_r[`SPI_CR_MASTER_R] = spi_cr_master_q;
        data_r[`SPI_CR_CPOL_R] = spi_cr_cpol_q;
        data_r[`SPI_CR_CPHA_R] = spi_cr_cpha_q;
        data_r[`SPI_CR_MANUAL_SS_R] = spi_cr_manual_ss_q;
        data_r[`SPI_CR_TRANS_INHIBIT_R] = spi_cr_trans_inhibit_q;
        data_r[`SPI_CR_LSB_FIRST_R] = spi_cr_lsb_first_q;
    end
    `SPI_SR:
    begin
        data_r[`SPI_SR_RX_EMPTY_R] = spi_sr_rx_empty_in_w;
        data_r[`SPI_SR_RX_FULL_R] = spi_sr_rx_full_in_w;
        data_r[`SPI_SR_TX_EMPTY_R] = spi_sr_tx_empty_in_w;
        data_r[`SPI_SR_TX_FULL_R] = spi_sr_tx_full_in_w;
    end
    `SPI_DRR:
    begin
        data_r[`SPI_DRR_DATA_R] = spi_drr_data_in_w;
    end
    `SPI_SSR:
    begin
        data_r[`SPI_SSR_VALUE_R] = spi_ssr_value_q;
    end
    `SPI_CLK_RATIO:
    begin
        data_r  = SPI_SCK_RATIO_reg;
    end
    default :
        data_r = 32'b0;
    endcase
end


//-----------------------------------------------------------------
// Retime read response
//-----------------------------------------------------------------
var logic [31:0] rd_data_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    rd_data_q <= 32'b0;
else if (read_en_w)
    rd_data_q <= data_r;

assign readdata_o = rd_data_q;



wire logic  spi_cr_rd_req_w = read_en_w & (address_i[7:0] == `SPI_CR);
wire logic  spi_drr_rd_req_w = read_en_w & (address_i[7:0] == `SPI_DRR);

wire logic  spi_ipisr_wr_req_w = spi_ipisr_wr_q;
wire logic  spi_cr_wr_req_w = spi_cr_wr_q;
wire logic  spi_dtr_wr_req_w = spi_dtr_wr_q;
wire logic  spi_drr_wr_req_w = spi_drr_wr_q;


//-----------------------------------------------------------------
// TX FIFO
//-----------------------------------------------------------------
wire   logic     sw_reset_w      = spi_srr_reset_out_w == 32'h0000000A;
wire   logic     tx_fifo_flush_w = sw_reset_w | spi_cr_txfifo_rst_out_w;
wire   logic    rx_fifo_flush_w = sw_reset_w | spi_cr_rxfifo_rst_out_w;

wire    logic    tx_accept_w;
wire     logic   tx_ready_w;
wire   logic [7:0] tx_data_raw_w;
wire   logic     tx_pop_w;

spi_fifo
#(
    .WIDTH(8),
    .DEPTH(4),
    .ADDR_W(2)
)
u_tx_fifo
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    .flush_i(tx_fifo_flush_w),

    .data_in_i(spi_dtr_data_out_w),
    .push_i(spi_dtr_wr_req_w),
    .accept_o(tx_accept_w),

    .pop_i(tx_pop_w),
    .data_out_o(tx_data_raw_w),
    .valid_o(tx_ready_w)
);

assign spi_sr_tx_empty_in_w = ~tx_ready_w;
assign spi_sr_tx_full_in_w  = ~tx_accept_w;

// Reverse order if LSB first
wire  logic [7:0] tx_data_w = spi_cr_lsb_first_out_w ? 
    {
      tx_data_raw_w[0]
    , tx_data_raw_w[1]
    , tx_data_raw_w[2]
    , tx_data_raw_w[3]
    , tx_data_raw_w[4]
    , tx_data_raw_w[5]
    , tx_data_raw_w[6]
    , tx_data_raw_w[7]
    } : tx_data_raw_w;

//-----------------------------------------------------------------
// RX FIFO
//-----------------------------------------------------------------
wire   logic     rx_accept_w;
wire   logic     rx_ready_w;
wire  logic [7:0] rx_data_w;
wire   logic     rx_push_w;

spi_fifo
#(
    .WIDTH(8),
    .DEPTH(4),
    .ADDR_W(2)
)
u_rx_fifo
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    .flush_i(rx_fifo_flush_w),

    .data_in_i(rx_data_w),
    .push_i(rx_push_w),
    .accept_o(rx_accept_w),

    .pop_i(spi_drr_rd_req_w),
    .data_out_o(spi_drr_data_in_w),
    .valid_o(rx_ready_w)
);


assign spi_sr_rx_empty_in_w = ~rx_ready_w;
assign spi_sr_rx_full_in_w  = ~rx_accept_w;

//-----------------------------------------------------------------
// Configuration
//-----------------------------------------------------------------


always_ff @(posedge clk_i or posedge rst_i )
begin
     if (rst_i)
        SPI_SCK_RATIO_reg <= `SPI_CLK_RATIO_VALUE_DEFAULT;
     else if (write_en_w && address_i==`SPI_CLK_RATIO)
        SPI_SCK_RATIO_reg <= writedata_i [7:0];
end

wire   logic  [7:0]      clk_div_w;
assign clk_div_w = SPI_SCK_RATIO_reg;

//-----------------------------------------------------------------
// Registers
//-----------------------------------------------------------------
var logic   active_q;
var logic [5:0] bit_count_q;
var logic [7:0]   shift_reg_q;
var logic [31:0]    clk_div_q;
var logic   done_q;


var logic   spi_clk_q;
var logic   spi_mosi_q;

//-----------------------------------------------------------------
// Implementation
//-----------------------------------------------------------------
wire logic  enable_w = spi_cr_spe_out_w & spi_cr_master_out_w & ~spi_cr_trans_inhibit_out_w;

// Something to do, SPI enabled...
wire logic  start_w = enable_w & ~active_q & ~done_q & tx_ready_w;

// Loopback more or normal
wire logic  miso_w = spi_cr_loop_out_w ? spi_mosi_o : spi_miso_i;

// SPI Clock Generator
always_ff @ (posedge clk_i or posedge rst_i  )
if (rst_i)
    clk_div_q <= 32'd0;
else if (start_w || sw_reset_w || clk_div_q == 32'd0)
    clk_div_q <= clk_div_w;
else
    clk_div_q <= clk_div_q - 32'd1;

wire logic  clk_en_w = (clk_div_q == 32'd0);

//-----------------------------------------------------------------
// Sample, Drive pulse generation
//-----------------------------------------------------------------
var logic sample_r;
var logic drive_r;

always_comb
begin
    sample_r = 1'b0;
    drive_r  = 1'b0;

    // SPI = IDLE
    if (start_w)    
        drive_r  = ~spi_cr_cpha_out_w; // Drive initial data (CPHA=0)
    // SPI = ACTIVE
    else if (active_q && clk_en_w)
    begin
        // Sample
        // CPHA=0, sample on the first edge
        // CPHA=1, sample on the second edge
        if (bit_count_q[0] == spi_cr_cpha_out_w)
            sample_r = 1'b1;
        // Drive (CPHA = 1)
        else if (spi_cr_cpha_out_w)
            drive_r = 1'b1;
        // Drive (CPHA = 0)
        else 
            drive_r = (bit_count_q != 6'b0) && (bit_count_q != 6'd15);
    end
end

//-----------------------------------------------------------------
// Shift register
//-----------------------------------------------------------------
always_ff @ (posedge clk_i  or posedge rst_i )
if (rst_i)
begin
    shift_reg_q    <= 8'b0;
    spi_clk_q      <= 1'b0;
    spi_mosi_q     <= 1'b0;
end
else
begin
    // SPI = RESET (or potentially update CPOL)
    if (sw_reset_w || (spi_cr_wr_req_w & !start_w))
    begin
        shift_reg_q    <= 8'b0;
        spi_clk_q      <= spi_cr_cpol_out_w;
    end
    // SPI = IDLE
    else if (start_w)
    begin
        spi_clk_q      <= spi_cr_cpol_out_w;

        // CPHA = 0
        if (drive_r)
        begin
            spi_mosi_q    <= tx_data_w[7];
            shift_reg_q   <= {tx_data_w[6:0], 1'b0};
        end
        // CPHA = 1
        else
            shift_reg_q   <= tx_data_w;
    end
    // SPI = ACTIVE
    else if (active_q && clk_en_w)
    begin
        // Toggle SPI clock output
        if (!spi_cr_loop_out_w)
            spi_clk_q <= ~spi_clk_q;

        // Drive MOSI
        if (drive_r)
        begin
            spi_mosi_q  <= shift_reg_q[7];
            shift_reg_q <= {shift_reg_q[6:0],1'b0};
        end
        // Sample MISO
        else if (sample_r)
            shift_reg_q[0] <= miso_w;
    end
end

//-----------------------------------------------------------------
// Bit counter
//-----------------------------------------------------------------
always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
    bit_count_q    <= 6'b0;
    active_q       <= 1'b0;
    done_q         <= 1'b0;
end
else if (sw_reset_w)
begin
    bit_count_q    <= 6'b0;
    active_q       <= 1'b0;
    done_q         <= 1'b0;
end
else if (start_w)
begin
    bit_count_q    <= 6'b0;
    active_q       <= 1'b1;
    done_q         <= 1'b0;
end
else if (active_q && clk_en_w)
begin
    // End of SPI transfer reached
    if (bit_count_q == 6'd15)
    begin
        // Go back to IDLE active_q
        active_q  <= 1'b0;

        // Set transfer complete flags
        done_q   <= 1'b1;
    end
    // Increment cycle counter
    else 
        bit_count_q <= bit_count_q + 6'd1;
end
else
    done_q         <= 1'b0;

// Delayed done_q for FIFO level check
var logic check_tx_level_q;
always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    check_tx_level_q <= 1'b0;
else
    check_tx_level_q <= done_q;

// Interrupt
var logic intr_q;

always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
    intr_q <= 1'b0;
else if (check_tx_level_q && spi_ipier_tx_empty_out_w && spi_ipisr_tx_empty_in_w)
    intr_q <= 1'b1;
else if (spi_ipisr_wr_req_w && spi_ipisr_tx_empty_out_w)
    intr_q <= 1'b0;

assign spi_ipisr_tx_empty_in_w = spi_sr_tx_empty_in_w;

//-----------------------------------------------------------------
// Assignments
//-----------------------------------------------------------------
assign spi_clk_o            = spi_clk_q;
assign spi_mosi_o           = spi_mosi_q;

// Reverse order if LSB first
assign rx_data_w = spi_cr_lsb_first_out_w ? 
    {
      shift_reg_q[0]
    , shift_reg_q[1]
    , shift_reg_q[2]
    , shift_reg_q[3]
    , shift_reg_q[4]
    , shift_reg_q[5]
    , shift_reg_q[6]
    , shift_reg_q[7]
    } : shift_reg_q;


assign rx_push_w            = done_q;
assign tx_pop_w             = done_q;

assign spi_cs_o             = spi_ssr_value_out_w;
assign intr_o               = spi_dgier_gie_out_w & intr_q;

endmodule

//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------

module spi_fifo
//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
    parameter WIDTH   = 8,
    parameter DEPTH   = 4,
    parameter ADDR_W  = 2
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Inputs
     input logic               clk_i
    ,input logic               rst_i
    ,input logic  [WIDTH-1:0]  data_in_i
    ,input logic               push_i
    ,input logic               pop_i
    ,input logic               flush_i

    // Outputs
    ,output logic [WIDTH-1:0]  data_out_o
    ,output logic              accept_o
    ,output logic              valid_o
);

//-----------------------------------------------------------------
// Local Params
//-----------------------------------------------------------------
localparam COUNT_W = ADDR_W + 1;

//-----------------------------------------------------------------
// Registers
//-----------------------------------------------------------------
var logic [WIDTH-1:0]   ram_q[DEPTH-1:0];
var logic [ADDR_W-1:0]  rd_ptr_q;
var logic [ADDR_W-1:0]  wr_ptr_q;
var logic [COUNT_W-1:0] count_q;

integer i;
//-----------------------------------------------------------------
// Sequential
//-----------------------------------------------------------------
always_ff @ (posedge clk_i or posedge rst_i )
if (rst_i)
begin
    for ( i =0; i<DEPTH-1; i = i+1)
    begin
        ram_q[i] <= {(WIDTH){1'b0}}; 
    end
    count_q   <= {(COUNT_W) {1'b0}};
    rd_ptr_q  <= {(ADDR_W) {1'b0}};
    wr_ptr_q  <= {(ADDR_W) {1'b0}};
end
else if (flush_i)
begin
    count_q   <= {(COUNT_W) {1'b0}};
    rd_ptr_q  <= {(ADDR_W) {1'b0}};
    wr_ptr_q  <= {(ADDR_W) {1'b0}};
end
else
begin
    // Push
    if (push_i & accept_o)
    begin
        ram_q[wr_ptr_q] <= data_in_i;
        wr_ptr_q        <= wr_ptr_q + 1;
    end

    // Pop
    if (pop_i & valid_o)
        rd_ptr_q      <= rd_ptr_q + 1;

    // Count up
    if ((push_i & accept_o) & ~(pop_i & valid_o))
        count_q <= count_q + 1;
    // Count down
    else if (~(push_i & accept_o) & (pop_i & valid_o))
        count_q <= count_q - 1;
end

//-------------------------------------------------------------------
// Combinatorial
//-------------------------------------------------------------------
assign valid_o       = (count_q != 0);
assign accept_o      = (count_q != DEPTH);

assign data_out_o    = ram_q[rd_ptr_q];



endmodule


