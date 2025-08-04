module qspi (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       sclk,
    input  logic       ss_n,
    input  logic       mosi,
    output logic       miso
);

    logic [7:0]  spi_rx_data;
    logic [7:0]  spi_tx_data;
    logic        spi_done;

    // Instantiate the core SPI slave
    spi_slave u_spi_slave (
        .clk      (clk),
        .rst_n    (rst_n),
        .sclk     (sclk),
        .ss_n     (ss_n),
        .mosi     (mosi),
        .miso     (miso),
        .data_rx  (spi_rx_data),
        .data_tx  (spi_tx_data),
        .done     (spi_done)
    );

    // ROM: 32-bit wide, 128KB = 32K words
    logic [31:0] rom [0:32767];
    initial $readmemh("/home/shaheer/Documents/GitHub/ntiny/software/mem_init/tests/mem.text", rom);  // 32-bit values per line

    // State machine
    typedef enum logic [2:0] {
        IDLE,
        ADDR0, ADDR1, ADDR2,
        READ
    } state_t;

    state_t state;
    logic [7:0] cmd, addr0, addr1, addr2;
    logic [23:0] address;
    logic [31:0] word_out;
    logic [1:0] byte_index;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            cmd         <= 8'h00;
            address     <= 24'h000000;
            word_out    <= 32'h00000000;
            spi_tx_data <= 8'h00;
            byte_index  <= 2'd0;
        end else begin
            if (spi_done) begin
                case (state)
                    IDLE: begin
                        cmd <= spi_rx_data;
                        if (spi_rx_data == 8'h0B) begin
                            //$display("[QSPI] Command 0x0B (FAST READ) received");
                            state <= ADDR0;
                        end
                    end

                    ADDR0: begin
                        addr0 <= spi_rx_data;
                        state <= ADDR1;
                    end

                    ADDR1: begin
                        addr1 <= spi_rx_data;
                        state <= ADDR2;
                    end

                    ADDR2: begin
                        addr2 <= spi_rx_data;
                        address <= {addr0, addr1, spi_rx_data};  // Big endian
                        $display("[QSPI] Address received: 0x%06X", {addr0, addr1, spi_rx_data});
                        state <= READ;

                        byte_index <= 2'd1;
                        spi_tx_data <= rom[{addr0, addr1, spi_rx_data}[23:2]][7:0];
                        word_out <= rom[{addr0, addr1, spi_rx_data}[23:2]];
                        //$display("[QSPI] Sending byte[0]: 0x%02X", rom[{addr0, addr1, spi_rx_data}[23:2]][7:0]);
                    end

                    READ: begin
                        case (byte_index)
                            2'd0: begin
                                spi_tx_data <= word_out[7:0];
                                //$display("[QSPI] Sending byte[0]: 0x%02X", word_out[7:0]);
                            end
                            2'd1: begin
                                spi_tx_data <= word_out[15:8];
                                //$display("[QSPI] Sending byte[1]: 0x%02X", word_out[15:8]);
                            end
                            2'd2: begin
                                spi_tx_data <= word_out[23:16];
                                //$display("[QSPI] Sending byte[2]: 0x%02X", word_out[23:16]);
                            end
                            2'd3: begin
                                spi_tx_data <= word_out[31:24];
                                //$display("[QSPI] Sending byte[3]: 0x%02X", word_out[31:24]);
                            end
                        endcase

                        byte_index <= byte_index + 1;

                        if (byte_index == 2'd3) begin
                            address <= address + 3'd4;
                            word_out <= rom[address[23:2] + 1];
                            // $display("[QSPI] Next word @ ROM[%0d] = 0x%08X", address[23:2] + 1, rom[address[23:2] + 1]);
                            byte_index <= 0;
                            // spi_tx_data <= rom[address[23:2] + 1][7:0];
                            // //$display("[QSPI] Sending byte[0]: 0x%02X", rom[address[23:2] + 1][7:0]);
                        end
                    end
                endcase
            end

            if (ss_n)
                state <= IDLE;
        end
    end
endmodule
