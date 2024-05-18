


package soc_top_defs;
    localparam [31:0] MEM_ADDR_START    = 32'h00000000;
    localparam [31:0] MEM_ADDR_END      = 32'h00028000;
    localparam [31:0] MEM_SIZE          = $clog2(MEM_ADDR_END - MEM_ADDR_START);

    localparam [31:0] UART_ADDR_START   = 32'h00100000;
    localparam [31:0] UART_ADDR_END     = 32'h0000000f;
    localparam [31:0] UART_SIZE         = $clog2(UART_ADDR_END - UART_ADDR_START);

    localparam [31:0] TIMER_ADDR_START  = 32'h00200000;
    localparam [31:0] TIMER_ADD_END     = 32'h00000010;
    localparam [31:0] TIMER_SIZE        = $clog2(TIMER_ADD_END - TIMER_ADDR_START);

    localparam [31:0] GPIO_ADDR_START   = 32'h00400000;
    localparam [31:0] GPIO_ADDR_END     = 32'h0000000f;
    localparam [31:0] GPIO_SIZE         = $clog2(GPIO_ADDR_END - GPIO_ADDR_START);


endpackage : soc_top_defs







