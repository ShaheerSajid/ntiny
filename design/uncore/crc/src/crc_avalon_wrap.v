module crc_avalon_wrap
(
  // signals for connecting to the Avalon fabric
  input  						clk_i,
  input 						reset_i,
  input  						write_i,
  input  						read_i,
  input  						chipselect_i,
  input  			[31:0]writedata_i,
  input  			[2:0]	address_i,
  output  reg  [31:0]readdata_o

);

///// memory mapped registers

`define   CONTROL     3'h0
`define   CRC_INIT    3'h1
`define   CRC_16_IBM  3'h2
`define   CRC_16_CCIT 3'h3
`define   CRC_32      3'h4
`define   XOR_OUT     3'h5

reg       [3:0]      control;
reg       [31:0]     crc_init;
reg       [31:0]     xor_out;
reg       [31:0]     crc_32;
reg       [31:0]     crc_16_ibm;
reg       [31:0]     crc_16_ccit;


reg       [31:0]     crc_16_ibm_out;
reg       [31:0]     crc_16_ccit_out;
reg       [31:0]     crc_32_out;

always@(posedge clk_i or posedge reset_i)
begin    
  if (reset_i)
  begin
    control     <= 0;
    crc_16_ibm  <= 0;
    crc_16_ccit <= 0;
    crc_32      <= 0;
    crc_init    <= 0;
    xor_out     <= 0;
  end
  else if (write_i & chipselect_i)
  begin 
    case (address_i)
      `CONTROL:	    control     <= writedata_i;		
      `CRC_INIT:	  crc_init    <= writedata_i;	
      `CRC_16_IBM:  crc_16_ibm  <= writedata_i;		
      `CRC_16_CCIT:	crc_16_ccit <= writedata_i;
      `CRC_32:      crc_32      <= writedata_i;
      `XOR_OUT:     xor_out     <= writedata_i;
    endcase
  end
end

always@(posedge clk_i or posedge reset_i)
begin    
  if (reset_i)
    readdata_o <=	0;		
  else if (read_i & chipselect_i)
  begin
    case (address_i)
      `CONTROL:	    readdata_o <=	control;	
      `CRC_INIT:	  readdata_o <=	crc_init;	
      `CRC_16_IBM:  readdata_o <=	crc_16_ibm_out ^ xor_out;		
      `CRC_16_CCIT:	readdata_o <= crc_16_ccit_out ^ xor_out;
      `CRC_32:      readdata_o <=	crc_32_out ^ xor_out;
      `XOR_OUT:     readdata_o <= xor_out;
      default: 		  readdata_o <=  32'd0;	
    endcase
  end
end

/*
Settings for common LFSR/CRC implementations:

Name        Configuration           Length  Polynomial      Initial value
CRC16-IBM   Galois, bit-reverse     16      16'h8005        16'hffff
CRC16-CCITT Galois                  16      16'h1021        16'h1d0f
CRC32       Galois, bit-reverse     32      32'h04c11db7    32'hffffffff 
*/

lfsr_crc #(
  .LFSR_WIDTH   (16      ),
  .LFSR_POLY    (16'h8005),
  .LFSR_INIT    (16'hffff),
  .LFSR_CONFIG  ("GALOIS"),
  .REVERSE      (1       ),
  .INVERT       (0       ),
  .DATA_WIDTH   (32      ),
  .STYLE        ("AUTO"  )
)
lfsr_crc_16_ibm_true
(
  .clk            (clk_i),
  .rst            (reset_i),
  .set_state      (control[0]),
  .init_state_val (crc_init),
  .data_in        (crc_16_ibm),
  .data_in_valid  (control[1]),
  .crc_out        (crc_16_ibm_out)
);

lfsr_crc #(
  .LFSR_WIDTH   (16      ),
  .LFSR_POLY    (16'h1021),
  .LFSR_INIT    (16'h1d0f),
  .LFSR_CONFIG  ("GALOIS"),
  .REVERSE      (0       ),
  .INVERT       (0       ),
  .DATA_WIDTH   (32      ),
  .STYLE        ("AUTO"  )
)
lfsr_crc_16_ccit_false
(
  .clk            (clk_i),
  .rst            (reset_i),
  .set_state      (control[0]),
  .init_state_val (crc_init),
  .data_in        (crc_16_ccit),
  .data_in_valid  (control[2]),
  .crc_out        (crc_16_ccit_out)
);

lfsr_crc #(
  .LFSR_WIDTH   (32      ),
  .LFSR_POLY    (32'h04c11db7),
  .LFSR_INIT    (32'hffffffff),
  .LFSR_CONFIG  ("GALOIS"),
  .REVERSE      (1       ),
  .INVERT       (0       ),
  .DATA_WIDTH   (32      ),
  .STYLE        ("AUTO"  )
)
lfsr_crc_32_true
(
  .clk            (clk_i),
  .rst            (reset_i),
  .set_state      (control[0]),
  .init_state_val (crc_init),
  .data_in        (crc_32),
  .data_in_valid  (control[3]),
  .crc_out        (crc_32_out)
);


endmodule
