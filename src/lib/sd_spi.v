// SD Card SPI Controller
// Handles initialization and block reads in SPI mode
//
// Usage:
//   1. Assert rst_n low, then release
//   2. Wait for `ready` to go high (card initialized)
//   3. Set `rd_block` to desired block number, pulse `rd_start`
//   4. Read bytes as `rd_data_valid` pulses, `rd_data` has byte
//   5. `rd_done` pulses when 512-byte block is complete
//
// Clock: expects 27MHz system clock (divides internally for SPI)
// Init SPI clock: ~211kHz (27MHz / 128)
// Data SPI clock: ~13.5MHz (27MHz / 2)

module sd_spi (
    input             clk,          // 27MHz system clock
    input             rst_n,

    // SD card SPI pins
    output reg        sd_clk,
    output reg        sd_mosi,
    input             sd_miso,
    output reg        sd_cs_n,

    // Status
    output reg        ready,        // Card initialized and ready
    output reg  [3:0] error_code,   // 0=ok, non-zero=error type

    // Block read interface
    input      [31:0] rd_block,     // Block number to read
    input             rd_start,     // Pulse to start read
    output reg  [7:0] rd_data,      // Read data byte
    output reg        rd_data_valid,// Pulse when rd_data is valid
    output reg        rd_done       // Pulse when block read complete
);

//==============================================================================
// Clock Divider
//==============================================================================
// Slow clock for init: 27MHz / 128 = ~211kHz
// Fast clock for data: 27MHz / 2 = 13.5MHz
reg        use_fast_clk;
reg  [6:0] clk_div;
wire       spi_tick_slow = (clk_div == 7'd63);   // half-period at /128
wire       spi_tick_fast = 1'b1;                  // every cycle for /2
wire       spi_tick = use_fast_clk ? spi_tick_fast : spi_tick_slow;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        clk_div <= 0;
    else
        clk_div <= clk_div + 1;
end

//==============================================================================
// SPI Bit Engine
//==============================================================================
reg  [7:0] spi_tx_data;
reg  [7:0] spi_rx_data;
reg  [3:0] spi_bit_cnt;
reg        spi_active;
reg        spi_byte_done;
reg        spi_clk_phase;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sd_clk <= 0;
        sd_mosi <= 1;
        spi_rx_data <= 8'hFF;
        spi_bit_cnt <= 0;
        spi_byte_done <= 0;
        spi_clk_phase <= 0;
    end else if (spi_active && spi_tick) begin
        spi_byte_done <= 0;
        if (!spi_clk_phase) begin
            // Falling edge: drive MOSI
            sd_clk <= 0;
            if (spi_bit_cnt < 8)
                sd_mosi <= spi_tx_data[7 - spi_bit_cnt];
            else
                sd_mosi <= 1;
            spi_clk_phase <= 1;
        end else begin
            // Rising edge: sample MISO
            sd_clk <= 1;
            if (spi_bit_cnt < 8) begin
                spi_rx_data <= {spi_rx_data[6:0], sd_miso};
                spi_bit_cnt <= spi_bit_cnt + 1;
                if (spi_bit_cnt == 7)
                    spi_byte_done <= 1;
            end
            spi_clk_phase <= 0;
        end
    end else begin
        spi_byte_done <= 0;
    end
end

//==============================================================================
// Main State Machine
//==============================================================================
localparam S_POWER_UP       = 4'd0;
localparam S_SEND_CLOCKS    = 4'd1;
localparam S_CMD0           = 4'd2;
localparam S_CMD8           = 4'd3;
localparam S_CMD55          = 4'd4;
localparam S_ACMD41         = 4'd5;
localparam S_CMD58          = 4'd6;
localparam S_READY          = 4'd7;
localparam S_READ_CMD       = 4'd8;
localparam S_READ_WAIT      = 4'd9;
localparam S_READ_DATA      = 4'd10;
localparam S_READ_CRC       = 4'd11;
localparam S_ERROR          = 4'd12;

localparam ERR_NONE         = 4'd0;
localparam ERR_CMD0         = 4'd1;
localparam ERR_CMD8         = 4'd2;
localparam ERR_ACMD41       = 4'd3;
localparam ERR_TIMEOUT      = 4'd4;
localparam ERR_READ         = 4'd5;
localparam ERR_TOKEN        = 4'd6;

reg  [3:0]  state;
reg  [15:0] wait_cnt;
reg  [15:0] retry_cnt;
reg  [9:0]  byte_cnt;
reg  [3:0]  cmd_idx;
reg  [47:0] cmd_buf;
reg  [7:0]  resp_byte;
reg         sdhc;
reg  [3:0]  resp_wait;

wire [47:0] CMD0_W  = {8'h40, 32'h00000000, 8'h95};
wire [47:0] CMD8_W  = {8'h48, 32'h000001AA, 8'h87};
wire [47:0] CMD55_W = {8'h77, 32'h00000000, 8'h01};
wire [47:0] ACMD41_W= {8'h69, 32'h40000000, 8'h01};
wire [47:0] CMD58_W = {8'h7A, 32'h00000000, 8'h01};

wire [31:0] rd_addr = sdhc ? rd_block : (rd_block << 9);
wire [47:0] CMD17_W = {8'h51, rd_addr, 8'h01};

reg  [2:0]  sub_state;
localparam SUB_SEND      = 3'd0;
localparam SUB_WAIT_RESP = 3'd1;
localparam SUB_GOT_RESP  = 3'd2;
localparam SUB_EXTRA     = 3'd3;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_POWER_UP;
        ready <= 0;
        error_code <= ERR_NONE;
        sd_cs_n <= 1;
        spi_active <= 0;
        use_fast_clk <= 0;
        wait_cnt <= 0;
        retry_cnt <= 0;
        byte_cnt <= 0;
        cmd_idx <= 0;
        sub_state <= SUB_SEND;
        sdhc <= 0;
        rd_data_valid <= 0;
        rd_done <= 0;
        spi_tx_data <= 8'hFF;
        spi_bit_cnt <= 0;
        resp_wait <= 0;
    end else begin
        rd_data_valid <= 0;
        rd_done <= 0;

        case (state)

            S_POWER_UP: begin
                sd_cs_n <= 1;
                sd_mosi <= 1;
                if (wait_cnt < 16'hFFFF)
                    wait_cnt <= wait_cnt + 1;
                else begin
                    wait_cnt <= 0;
                    byte_cnt <= 0;
                    spi_active <= 1;
                    spi_tx_data <= 8'hFF;
                    spi_bit_cnt <= 0;
                    spi_clk_phase <= 0;
                    state <= S_SEND_CLOCKS;
                end
            end

            S_SEND_CLOCKS: begin
                sd_cs_n <= 1;
                spi_tx_data <= 8'hFF;
                if (spi_byte_done) begin
                    byte_cnt <= byte_cnt + 1;
                    spi_bit_cnt <= 0;
                    if (byte_cnt >= 10) begin
                        sd_cs_n <= 0;
                        state <= S_CMD0;
                        sub_state <= SUB_SEND;
                        cmd_buf <= CMD0_W;
                        cmd_idx <= 0;
                        spi_bit_cnt <= 0;
                    end
                end
            end

            S_CMD0: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data != 8'hFF) begin
                                resp_byte <= spi_rx_data;
                                sub_state <= SUB_GOT_RESP;
                            end else if (resp_wait == 0) begin
                                state <= S_ERROR;
                                error_code <= ERR_CMD0;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                    SUB_GOT_RESP: begin
                        if (resp_byte == 8'h01) begin
                            state <= S_CMD8;
                            sub_state <= SUB_SEND;
                            cmd_buf <= CMD8_W;
                            cmd_idx <= 0;
                            spi_bit_cnt <= 0;
                        end else begin
                            state <= S_ERROR;
                            error_code <= ERR_CMD0;
                        end
                    end
                endcase
            end

            S_CMD8: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data != 8'hFF) begin
                                resp_byte <= spi_rx_data;
                                byte_cnt <= 0;
                                sub_state <= SUB_EXTRA;
                            end else if (resp_wait == 0) begin
                                // No CMD8 response = SD v1, skip to ACMD41
                                state <= S_CMD55;
                                sub_state <= SUB_SEND;
                                cmd_buf <= CMD55_W;
                                cmd_idx <= 0;
                                retry_cnt <= 0;
                                spi_bit_cnt <= 0;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                    SUB_EXTRA: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            byte_cnt <= byte_cnt + 1;
                            spi_bit_cnt <= 0;
                            if (byte_cnt == 3) begin
                                state <= S_CMD55;
                                sub_state <= SUB_SEND;
                                cmd_buf <= CMD55_W;
                                cmd_idx <= 0;
                                retry_cnt <= 0;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                endcase
            end

            S_CMD55: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data != 8'hFF) begin
                                state <= S_ACMD41;
                                sub_state <= SUB_SEND;
                                cmd_buf <= ACMD41_W;
                                cmd_idx <= 0;
                                spi_bit_cnt <= 0;
                            end else if (resp_wait == 0) begin
                                state <= S_ERROR;
                                error_code <= ERR_ACMD41;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                endcase
            end

            S_ACMD41: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data != 8'hFF) begin
                                resp_byte <= spi_rx_data;
                                sub_state <= SUB_GOT_RESP;
                            end else if (resp_wait == 0) begin
                                state <= S_ERROR;
                                error_code <= ERR_ACMD41;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                    SUB_GOT_RESP: begin
                        if (resp_byte == 8'h00) begin
                            state <= S_CMD58;
                            sub_state <= SUB_SEND;
                            cmd_buf <= CMD58_W;
                            cmd_idx <= 0;
                            spi_bit_cnt <= 0;
                        end else if (retry_cnt < 16'hFFFF) begin
                            retry_cnt <= retry_cnt + 1;
                            state <= S_CMD55;
                            sub_state <= SUB_SEND;
                            cmd_buf <= CMD55_W;
                            cmd_idx <= 0;
                            spi_bit_cnt <= 0;
                        end else begin
                            state <= S_ERROR;
                            error_code <= ERR_ACMD41;
                        end
                    end
                endcase
            end

            S_CMD58: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data != 8'hFF) begin
                                resp_byte <= spi_rx_data;
                                byte_cnt <= 0;
                                sub_state <= SUB_EXTRA;
                            end else if (resp_wait == 0) begin
                                sdhc <= 1;
                                use_fast_clk <= 1;
                                ready <= 1;
                                sd_cs_n <= 1;
                                state <= S_READY;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                    SUB_EXTRA: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (byte_cnt == 0)
                                sdhc <= spi_rx_data[6];
                            byte_cnt <= byte_cnt + 1;
                            if (byte_cnt == 3) begin
                                use_fast_clk <= 1;
                                ready <= 1;
                                sd_cs_n <= 1;
                                state <= S_READY;
                            end
                        end
                    end
                endcase
            end

            S_READY: begin
                sd_cs_n <= 1;
                spi_active <= 1;
                if (rd_start) begin
                    state <= S_READ_CMD;
                    sub_state <= SUB_SEND;
                    cmd_buf <= CMD17_W;
                    cmd_idx <= 0;
                    sd_cs_n <= 0;
                    spi_bit_cnt <= 0;
                end
            end

            S_READ_CMD: begin
                sd_cs_n <= 0;
                case (sub_state)
                    SUB_SEND: begin
                        spi_tx_data <= cmd_buf[47 - cmd_idx*8 -: 8];
                        if (spi_byte_done) begin
                            cmd_idx <= cmd_idx + 1;
                            spi_bit_cnt <= 0;
                            if (cmd_idx == 5) begin
                                sub_state <= SUB_WAIT_RESP;
                                resp_wait <= 8;
                                spi_tx_data <= 8'hFF;
                                spi_bit_cnt <= 0;
                            end
                        end
                    end
                    SUB_WAIT_RESP: begin
                        spi_tx_data <= 8'hFF;
                        if (spi_byte_done) begin
                            spi_bit_cnt <= 0;
                            if (spi_rx_data == 8'h00) begin
                                state <= S_READ_WAIT;
                                wait_cnt <= 0;
                            end else if (spi_rx_data != 8'hFF) begin
                                state <= S_ERROR;
                                error_code <= ERR_READ;
                            end else if (resp_wait == 0) begin
                                state <= S_ERROR;
                                error_code <= ERR_READ;
                            end else
                                resp_wait <= resp_wait - 1;
                        end
                    end
                endcase
            end

            S_READ_WAIT: begin
                sd_cs_n <= 0;
                spi_tx_data <= 8'hFF;
                if (spi_byte_done) begin
                    spi_bit_cnt <= 0;
                    if (spi_rx_data == 8'hFE) begin
                        state <= S_READ_DATA;
                        byte_cnt <= 0;
                    end else if (wait_cnt > 16'hFFFF) begin
                        state <= S_ERROR;
                        error_code <= ERR_TOKEN;
                    end else
                        wait_cnt <= wait_cnt + 1;
                end
            end

            S_READ_DATA: begin
                sd_cs_n <= 0;
                spi_tx_data <= 8'hFF;
                if (spi_byte_done) begin
                    spi_bit_cnt <= 0;
                    rd_data <= spi_rx_data;
                    rd_data_valid <= 1;
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 511) begin
                        state <= S_READ_CRC;
                        byte_cnt <= 0;
                    end
                end
            end

            S_READ_CRC: begin
                sd_cs_n <= 0;
                spi_tx_data <= 8'hFF;
                if (spi_byte_done) begin
                    spi_bit_cnt <= 0;
                    byte_cnt <= byte_cnt + 1;
                    if (byte_cnt == 1) begin
                        sd_cs_n <= 1;
                        rd_done <= 1;
                        state <= S_READY;
                    end
                end
            end

            S_ERROR: begin
                sd_cs_n <= 1;
                ready <= 0;
            end
        endcase
    end
end

endmodule
