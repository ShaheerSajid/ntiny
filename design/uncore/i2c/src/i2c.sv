


`include "i2c_master_defines.sv"


`define REG_CLK_PRESCALER 3'b000 //BASEADDR+0x00
`define REG_CTRL          3'b001 //BASEADDR+0x04
`define REG_RX            3'b010 //BASEADDR+0x08
`define REG_STATUS        3'b011 //BASEADDR+0x0C
`define REG_TX            3'b100 //BASEADDR+0x10
`define REG_CMD           3'b101 //BASEADDR+0x14

module i2c_top
 
(
    input  logic                      clk_i,
    input  logic                      rstn_i,
    input  logic                [7:0] avl_addr,
    input  logic               [31:0] avl_wdata,
    input  logic                      avl_write,
    input  logic                      avl_chipsel,
    output logic               [31:0] avl_rdata,
    output logic                      interrupt_o,
    input  logic                      scl_pad_i,
    output logic                      scl_pad_o,
    output logic                      scl_padoen_o,
    input  logic                      sda_pad_i,
    output logic                      sda_pad_o,
    output logic                      sda_padoen_o,
	output	logic					  test
);

    //
    // variable declarations
    //
	//wire scl_pad_i,scl_pad_o,scl_padoen_o,sda_pad_i,sda_pad_o,sda_padoen_o;
	
	
    logic  [3:0] i2c_addr_map;

    // registers
    reg  [15:0] r_pre; // clock prescale register
    reg  [ 7:0] r_ctrl;  // control register
    reg  [ 7:0] r_tx;  // transmit register
    wire [ 7:0] s_rx;  // receive register
    reg  [ 7:0] r_cmd;   // command register
    wire [ 7:0] s_status;   // status register
	assign test = r_ctrl[7];
    // done signal: command completed, clear command register
    wire s_done;

    // core enable signal
    wire s_core_en;
    wire s_ien;

    // status register signals
    wire s_irxack;
    reg  rxack;       // received aknowledge from slave
    reg  tip;         // transfer in progress
    reg  irq_flag;    // interrupt pending flag
    wire i2c_busy;    // bus busy (start signal detected)
    wire i2c_al;      // i2c bus arbitration lost
    reg  al;          // status register arbitration lost bit
	
    //
    // module body
    //

    assign i2c_addr_map = avl_addr[5:2];

    always_ff @ (posedge clk_i or posedge rstn_i )
    begin
        if( rstn_i)
        begin
            r_pre  <= 'h0;
            r_ctrl <= 'h0;
            r_tx   <= 'h0;
            r_cmd  <= 'h0;
        end
        else if ( avl_chipsel && avl_write)
             begin
                if (s_done | i2c_al)
                      r_cmd[7:4] <= 4'h0;          // clear command bits when done
                                                   // or when aribitration lost
                r_cmd[2:1] <= 2'b0;                 // reserved bits
                r_cmd[0]   <= 1'b0;                 // clear IRQ_ACK bit
                case (i2c_addr_map)
                    `REG_CLK_PRESCALER:
                        r_pre <= avl_wdata[15:0];
                    `REG_CTRL:
                        r_ctrl <= avl_wdata[7:0];
                    `REG_TX:
                        r_tx <= avl_wdata[7:0];
                    `REG_CMD:
                    begin
                        if(s_core_en)
                            r_cmd <= avl_wdata[7:0];
                    end
                endcase
            end
            else
            begin
                if (s_done | i2c_al)
                    r_cmd[7:4] <= 4'h0;           // clear command bits when done
                                                  // or when aribitration lost
                r_cmd[2:1] <= 2'b0;               // reserved bits
                r_cmd[0]   <= 1'b0;               // clear IRQ_ACK bit
            end
    end //always

    always_ff@(posedge clk_i or posedge rstn_i)
    begin
        if (rstn_i)
            avl_rdata <= 32'h0;
        else if (avl_chipsel) begin
            case (i2c_addr_map)
                `REG_CLK_PRESCALER:
                    avl_rdata <= {16'h0,r_pre};
                `REG_CTRL:
                    avl_rdata <= {24'h0,r_ctrl};
                `REG_RX:
                    avl_rdata <= {24'h0,s_rx};
                `REG_STATUS: 
                    avl_rdata <= {24'h0,s_status};
                `REG_TX:    
                    avl_rdata <= {24'h0,r_tx};
                `REG_CMD:
                    avl_rdata <= {24'h0,r_cmd};
                default:
                    avl_rdata <= 32'h0;
            endcase
         end
    end

    // decode command register
    wire sta  = r_cmd[7];
    wire sto  = r_cmd[6];
    wire rd   = r_cmd[5];
    wire wr   = r_cmd[4];
    wire ack  = r_cmd[3];
    wire iack = r_cmd[0];

    // decode control register
    assign s_core_en = r_ctrl[7];
    assign s_ien     = r_ctrl[6];

    // hookup byte controller block
    i2c_master_byte_ctrl byte_controller 
    (
            .clk      ( clk_i         ),
            .nReset   ( rstn_i      ),
            .ena      ( s_core_en    ),
            .clk_cnt  ( r_pre        ),
            .start    ( sta          ),
            .stop     ( sto          ),
            .read     ( rd           ),
            .write    ( wr           ),
            .ack_in   ( ack          ),
            .din      ( r_tx         ),
            .cmd_ack  ( s_done       ),
            .ack_out  ( s_irxack     ),
            .dout     ( s_rx         ),
            .i2c_busy ( i2c_busy     ),
            .i2c_al   ( i2c_al       ),
            .scl_i    ( scl_pad_i    ),
            .scl_o    ( scl_pad_o    ),
            .scl_oen  ( scl_padoen_o ),
            .sda_i    ( sda_pad_i    ),
            .sda_o    ( sda_pad_o    ),
            .sda_oen  ( sda_padoen_o )
    );

    // status register block + interrupt request signal
    always_ff @(posedge clk_i or posedge rstn_i )
    begin
        if ( rstn_i)
        begin
            al       <= 1'b0;
            rxack    <= 1'b0;
            tip      <= 1'b0;
            irq_flag <= 1'b0;
        end
        else
        begin
            al       <= i2c_al | (al & ~sta);
            rxack    <= s_irxack;
            tip      <= (rd | wr);
            irq_flag <= (s_done | i2c_al | irq_flag) & ~iack; // interrupt request flag is always generated
        end
    end

    // generate interrupt request signals
    always_ff @(posedge clk_i or posedge rstn_i )
    begin
        if ( rstn_i)
            interrupt_o <= 1'b0;
        else
            interrupt_o <= irq_flag && s_ien; // interrupt signal is only generated when IEN (interrupt enable bit is set)
    end
 
    // assign status register bits
    assign s_status[7]   = rxack;
    assign s_status[6]   = i2c_busy;
    assign s_status[5]   = al;
    assign s_status[4:2] = 3'h0; // reserved
    assign s_status[1]   = tip;
    assign s_status[0]   = irq_flag;
	
	
	
	//assign SCL = scl_padoen_o?1'bz:scl_pad_o;
	//assign scl_pad_i = SCL;
	
	//assign SDA = sda_padoen_o?1'bz:scl_pad_o;
	//assign sda_pad_i = SDA;



endmodule
