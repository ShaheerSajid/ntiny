module spi_slave (
    input  logic       clk,       // System clock
    input  logic       rst_n,     // Active low reset

    input  logic       sclk,      // SPI clock
    input  logic       ss_n,      // Active low slave select
    input  logic       mosi,      // Master Out Slave In
    output logic       miso,      // Master In Slave Out

    output logic [7:0] data_rx,   // Received data from master
    input  logic [7:0] data_tx,   // Data to send to master
    output logic       done       // High for 1 clk when byte received
);

    logic [2:0] bit_cnt;          // Bit counter
    logic [7:0] shift_reg_rx;     // Receive shift register
    logic [7:0] shift_reg_tx;     // Transmit shift register
    logic       sclk_prev;        // For edge detection

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt      <= 3'd0;
            shift_reg_rx <= 8'd0;
            shift_reg_tx <= 8'd0;
            data_rx      <= 8'd0;
            miso         <= 1'b0;
            sclk_prev    <= 1'b0;
            done         <= 1'b0;
        end else begin
            sclk_prev <= sclk;
            done <= 1'b0;

            if (!ss_n) begin
                // Falling edge: shift out
                if (sclk_prev && !sclk) begin
                    miso <= shift_reg_tx[7];
                    shift_reg_tx <= {shift_reg_tx[6:0], 1'b0};
                end

                // Rising edge: sample in
                if (!sclk_prev && sclk) begin
                    shift_reg_rx <= {shift_reg_rx[6:0], mosi};
                    bit_cnt <= bit_cnt + 1;

                    if (bit_cnt == 3'd7) begin
                        data_rx <= {shift_reg_rx[6:0], mosi};  // Final byte
                        shift_reg_tx <= data_tx;               // Reload TX
                        done <= 1'b1;

                        // ✅ Focused Debug Output Here
                        // $display("[%0t] SPI Byte RX Done:  0x%02h", $time, {shift_reg_rx[6:0], mosi});


                        bit_cnt <= 3'd0;
                    end
                end
            end else begin
                bit_cnt <= 3'd0;
                shift_reg_tx <= data_tx;
                miso <= 1'b0;
            end
        end
    end

endmodule
