// SD Card SPI Controller
// Based on MIT 6.111 sd_controller with SDHC improvements from regymm
// https://github.com/regymm/mit_sd_controller_improved
//
// Usage:
//   1. Assert rst_n low, then release
//   2. Wait for `ready` to go high (card initialized)
//   3. Set `rd_block` to desired block number, pulse `rd_start`
//   4. Read bytes as `rd_data_valid` pulses, `rd_data` has byte
//   5. `rd_done` pulses when 512-byte block is complete

module sd_spi (
    input             clk,          // 27MHz system clock
    input             rst_n,

    // SD card SPI pins
    output            sd_clk,
    output            sd_mosi,
    input             sd_miso,
    output reg        sd_cs_n,

    // Status
    output            ready,        // Card initialized and ready
    output reg  [3:0] error_code,   // 0=ok, non-zero=error type

    // Block read interface
    input      [31:0] rd_block,     // Block number to read
    input             rd_start,     // Pulse to start read
    output reg  [7:0] rd_data,      // Read data byte
    output reg        rd_data_valid,// Pulse when rd_data is valid
    output reg        rd_done       // Pulse when block read complete
);

//==============================================================================
// Error codes
//==============================================================================
localparam ERR_NONE    = 4'd0;
localparam ERR_CMD0    = 4'd1;
localparam ERR_CMD8    = 4'd2;
localparam ERR_ACMD41  = 4'd3;
localparam ERR_TIMEOUT = 4'd4;
localparam ERR_READ    = 4'd5;

//==============================================================================
// Slow clock generation (~100kHz from 27MHz)
// Toggle clk_pulse every 128 cycles = 27MHz/256 = ~105kHz
//==============================================================================
reg [7:0] clk_div;
wire clk_pulse = (clk_div == 8'd0);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        clk_div <= 0;
    else
        clk_div <= clk_div + 1;
end

//==============================================================================
// State machine
//==============================================================================
localparam RST              = 5'd0;
localparam INIT             = 5'd1;
localparam CMD0             = 5'd2;
localparam CMD8             = 5'd3;
localparam CMD55            = 5'd4;
localparam CMD41            = 5'd5;
localparam POLL_CMD         = 5'd6;
localparam IDLE             = 5'd7;
localparam READ_BLOCK       = 5'd8;
localparam READ_BLOCK_WAIT  = 5'd9;
localparam READ_BLOCK_DATA  = 5'd10;
localparam READ_BLOCK_CRC   = 5'd11;
localparam SEND_CMD         = 5'd12;
localparam RECEIVE_BYTE_WAIT= 5'd13;
localparam RECEIVE_BYTE     = 5'd14;
localparam ERROR            = 5'd15;

reg [4:0] state;
reg [4:0] return_state;
reg sclk_sig;
reg [55:0] cmd_out;
reg [7:0] recv_data;
reg [2:0] response_type;

reg [9:0] byte_counter;
reg [9:0] bit_counter;
reg [19:0] boot_counter;
reg [15:0] timeout_counter;

assign sd_clk = sclk_sig;
assign sd_mosi = cmd_out[55];
assign ready = (state == IDLE);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= RST;
        sclk_sig <= 0;
        boot_counter <= 20'd100_000;  // ~4ms at 27MHz
        sd_cs_n <= 1;
        cmd_out <= {56{1'b1}};
        recv_data <= 8'hFF;
        error_code <= ERR_NONE;
        rd_data_valid <= 0;
        rd_done <= 0;
        timeout_counter <= 0;
    end
    else begin
        rd_data_valid <= 0;
        rd_done <= 0;

        if (clk_pulse) begin
            case (state)
                RST: begin
                    if (boot_counter == 0) begin
                        sclk_sig <= 0;
                        cmd_out <= {56{1'b1}};
                        byte_counter <= 0;
                        bit_counter <= 160;  // 160 init clocks (>74 required)
                        sd_cs_n <= 1;
                        state <= INIT;
                    end
                    else begin
                        boot_counter <= boot_counter - 1;
                        // Generate slow clock during boot
                        if (boot_counter[2])
                            sclk_sig <= ~sclk_sig;
                    end
                end

                INIT: begin
                    if (bit_counter == 0) begin
                        sd_cs_n <= 0;
                        state <= CMD0;
                        timeout_counter <= 16'hFFFF;
                    end
                    else begin
                        bit_counter <= bit_counter - 1;
                        sclk_sig <= ~sclk_sig;
                    end
                end

                CMD0: begin
                    // CMD0: GO_IDLE_STATE
                    cmd_out <= 56'hFF_40_00_00_00_00_95;
                    bit_counter <= 55;
                    response_type <= 3'd1;
                    return_state <= CMD8;
                    state <= SEND_CMD;
                end

                CMD8: begin
                    // CMD8: SEND_IF_COND (voltage check)
                    // Response is R7 (5 bytes)
                    cmd_out <= 56'hFF_48_00_00_01_AA_87;
                    bit_counter <= 55;
                    response_type <= 3'd7;  // R7 response
                    return_state <= CMD55;
                    state <= SEND_CMD;
                end

                CMD55: begin
                    // CMD55: APP_CMD prefix
                    cmd_out <= 56'hFF_77_00_00_00_00_01;
                    bit_counter <= 55;
                    response_type <= 3'd1;
                    return_state <= CMD41;
                    state <= SEND_CMD;
                end

                CMD41: begin
                    // ACMD41: SD_SEND_OP_COND (with HCS bit set for SDHC)
                    cmd_out <= 56'hFF_69_40_00_00_00_01;
                    bit_counter <= 55;
                    response_type <= 3'd1;
                    return_state <= POLL_CMD;
                    state <= SEND_CMD;
                end

                POLL_CMD: begin
                    if (recv_data[0] == 0) begin
                        // Card ready (response 0x00)
                        state <= IDLE;
                    end
                    else if (timeout_counter == 0) begin
                        // Timeout waiting for card
                        error_code <= ERR_ACMD41;
                        state <= ERROR;
                    end
                    else begin
                        // Not ready yet, retry CMD55+ACMD41
                        timeout_counter <= timeout_counter - 1;
                        state <= CMD55;
                    end
                end

                IDLE: begin
                    sd_cs_n <= 1;
                    if (rd_start) begin
                        sd_cs_n <= 0;
                        state <= READ_BLOCK;
                    end
                end

                READ_BLOCK: begin
                    // CMD17: READ_SINGLE_BLOCK
                    // SDHC uses block addressing (not byte)
                    cmd_out <= {16'hFF_51, rd_block, 8'hFF};
                    bit_counter <= 55;
                    response_type <= 3'd1;
                    return_state <= READ_BLOCK_WAIT;
                    state <= SEND_CMD;
                end

                READ_BLOCK_WAIT: begin
                    // Wait for data token (0xFE)
                    if (sclk_sig == 1 && sd_miso == 0) begin
                        byte_counter <= 511;
                        bit_counter <= 7;
                        return_state <= READ_BLOCK_DATA;
                        state <= RECEIVE_BYTE;
                    end
                    sclk_sig <= ~sclk_sig;
                end

                READ_BLOCK_DATA: begin
                    rd_data <= recv_data;
                    rd_data_valid <= 1;
                    if (byte_counter == 0) begin
                        bit_counter <= 7;
                        return_state <= READ_BLOCK_CRC;
                        state <= RECEIVE_BYTE;
                    end
                    else begin
                        byte_counter <= byte_counter - 1;
                        bit_counter <= 7;
                        return_state <= READ_BLOCK_DATA;
                        state <= RECEIVE_BYTE;
                    end
                end

                READ_BLOCK_CRC: begin
                    // Read and discard 2 CRC bytes
                    if (byte_counter == 0) begin
                        byte_counter <= 1;
                        bit_counter <= 7;
                        return_state <= READ_BLOCK_CRC;
                        state <= RECEIVE_BYTE;
                    end
                    else begin
                        rd_done <= 1;
                        sd_cs_n <= 1;
                        state <= IDLE;
                    end
                end

                SEND_CMD: begin
                    if (sclk_sig == 1) begin
                        if (bit_counter == 0) begin
                            state <= RECEIVE_BYTE_WAIT;
                        end
                        else begin
                            bit_counter <= bit_counter - 1;
                            cmd_out <= {cmd_out[54:0], 1'b1};
                        end
                    end
                    sclk_sig <= ~sclk_sig;
                end

                RECEIVE_BYTE_WAIT: begin
                    if (sclk_sig == 1) begin
                        if (sd_miso == 0) begin
                            // Start bit received
                            recv_data <= 0;
                            case (response_type)
                                3'd1: bit_counter <= 6;   // R1: 7 more bits
                                3'd7: bit_counter <= 38;  // R7: 39 more bits (we only keep last 8)
                                default: bit_counter <= 6;
                            endcase
                            state <= RECEIVE_BYTE;
                        end
                        else if (timeout_counter == 0) begin
                            // No response - error
                            if (return_state == CMD8) begin
                                // CMD8 timeout is OK (older SD cards)
                                state <= CMD55;
                            end
                            else begin
                                error_code <= ERR_CMD0;
                                state <= ERROR;
                            end
                        end
                        else begin
                            timeout_counter <= timeout_counter - 1;
                        end
                    end
                    sclk_sig <= ~sclk_sig;
                end

                RECEIVE_BYTE: begin
                    if (sclk_sig == 1) begin
                        recv_data <= {recv_data[6:0], sd_miso};
                        if (bit_counter == 0) begin
                            state <= return_state;
                        end
                        else begin
                            bit_counter <= bit_counter - 1;
                        end
                    end
                    sclk_sig <= ~sclk_sig;
                end

                ERROR: begin
                    sd_cs_n <= 1;
                    // Stay in error state
                end

                default: state <= RST;
            endcase
        end
    end
end

endmodule
