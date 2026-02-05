// BMP File Loader (Byte-Stream Interface)
// Accepts a stream of bytes (from FAT32 reader or any source),
// parses BMP header, converts BGR888 to RGB565,
// flips rows (bottom-up to top-down), and writes to framebuffer.
//
// Interface:
//   - Input: byte stream (file_data + file_data_valid + file_done)
//   - Output: framebuffer write port (fb_addr + fb_data + fb_we)
//
// Expects 24-bit uncompressed BMP, target size defined by IMG_W x IMG_H.

module bmp_loader #(
    parameter IMG_W = 1280,
    parameter IMG_H = 720
)(
    input             clk,
    input             rst_n,
    input             start,         // Pulse to begin accepting data

    // Byte stream input (from FAT32 reader)
    input       [7:0] file_data,
    input             file_data_valid,
    input             file_done,     // End of file

    // Framebuffer write interface
    output reg [20:0] fb_addr,       // Pixel index (0 to IMG_W*IMG_H-1)
    output reg [15:0] fb_data,       // RGB565 pixel data
    output reg        fb_we,         // Write enable

    // Status
    output reg        done,          // Image loaded successfully
    output reg        error          // Error occurred
);

//==============================================================================
// States
//==============================================================================
localparam S_IDLE         = 3'd0;
localparam S_READ_HEADER  = 3'd1;
localparam S_SKIP_TO_DATA = 3'd2;
localparam S_READ_PIXELS  = 3'd3;
localparam S_DONE         = 3'd4;
localparam S_ERROR        = 3'd5;

reg  [2:0]  state;

// BMP header fields
reg  [31:0] pixel_offset;
reg  [31:0] bmp_width;
reg  [31:0] bmp_height;
reg  [15:0] bmp_bpp;

// Byte counting
reg  [31:0] byte_cnt;       // Total bytes received
reg  [5:0]  hdr_idx;        // Header buffer write index

// Header buffer (54 bytes)
reg  [7:0]  hdr_buf [0:53];

// Pixel assembly
reg  [7:0]  pix_b, pix_g;
reg  [1:0]  pix_byte_idx;   // 0=B, 1=G, 2=R

// Position tracking
reg  [15:0] pix_x;
reg  [15:0] pix_y;
reg  [15:0] row_bytes_read;

// Row padding
wire [15:0] raw_row_bytes    = IMG_W * 3;
wire [15:0] row_padding      = (4 - (raw_row_bytes & 2'b11)) & 2'b11;
wire [15:0] padded_row_bytes = raw_row_bytes + row_padding;

//==============================================================================
// Main Logic
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE;
        done <= 0;
        error <= 0;
        fb_we <= 0;
        byte_cnt <= 0;
        hdr_idx <= 0;
        pix_byte_idx <= 0;
        pix_x <= 0;
        pix_y <= 0;
        row_bytes_read <= 0;
        pixel_offset <= 0;
        bmp_width <= 0;
        bmp_height <= 0;
        bmp_bpp <= 0;
    end else begin
        fb_we <= 0;

        case (state)

            S_IDLE: begin
                done <= 0;
                error <= 0;
                if (start) begin
                    byte_cnt <= 0;
                    hdr_idx <= 0;
                    pix_byte_idx <= 0;
                    pix_x <= 0;
                    pix_y <= 0;
                    row_bytes_read <= 0;
                    pixel_offset <= 0;
                    state <= S_READ_HEADER;
                end
            end

            //----------------------------------------------------------
            // Collect first 54 bytes into header buffer
            //----------------------------------------------------------
            S_READ_HEADER: begin
                if (file_data_valid) begin
                    byte_cnt <= byte_cnt + 1;

                    if (hdr_idx < 54) begin
                        hdr_buf[hdr_idx] <= file_data;
                        hdr_idx <= hdr_idx + 1;
                    end

                    // After 54 bytes, parse header
                    if (hdr_idx == 53) begin
                        // Validate signature
                        if (hdr_buf[0] != 8'h42 || hdr_buf[1] != 8'h4D) begin
                            state <= S_ERROR;
                        end else begin
                            // Parse fields
                            pixel_offset <= {hdr_buf[13], hdr_buf[12], hdr_buf[11], hdr_buf[10]};
                            bmp_width    <= {hdr_buf[21], hdr_buf[20], hdr_buf[19], hdr_buf[18]};
                            bmp_height   <= {hdr_buf[25], hdr_buf[24], hdr_buf[23], hdr_buf[22]};
                            bmp_bpp      <= {hdr_buf[29], hdr_buf[28]};

                            // Validate: 24-bit uncompressed
                            if ({hdr_buf[29], hdr_buf[28]} != 16'd24) begin
                                state <= S_ERROR;
                            end else if (hdr_buf[30] != 8'h00) begin
                                state <= S_ERROR;
                            end else begin
                                state <= S_SKIP_TO_DATA;
                            end
                        end
                    end
                end

                if (file_done && state == S_READ_HEADER)
                    state <= S_ERROR;  // File too short
            end

            //----------------------------------------------------------
            // Skip bytes until we reach pixel_offset
            //----------------------------------------------------------
            S_SKIP_TO_DATA: begin
                if (file_data_valid) begin
                    byte_cnt <= byte_cnt + 1;
                    // byte_cnt is the count BEFORE this byte, so +1 is current position
                    if (byte_cnt + 1 >= pixel_offset) begin
                        state <= S_READ_PIXELS;
                    end
                end

                // Check if we already passed the offset (header was > pixel offset)
                if (byte_cnt >= pixel_offset && pixel_offset != 0)
                    state <= S_READ_PIXELS;

                if (file_done && state == S_SKIP_TO_DATA)
                    state <= S_ERROR;
            end

            //----------------------------------------------------------
            // Assemble BGR pixels, convert to RGB565, write to FB
            //----------------------------------------------------------
            S_READ_PIXELS: begin
                if (file_data_valid) begin
                    byte_cnt <= byte_cnt + 1;

                    if (row_bytes_read < raw_row_bytes) begin
                        // Actual pixel data
                        case (pix_byte_idx)
                            2'd0: begin
                                pix_b <= file_data;
                                pix_byte_idx <= 1;
                            end
                            2'd1: begin
                                pix_g <= file_data;
                                pix_byte_idx <= 2;
                            end
                            2'd2: begin
                                pix_byte_idx <= 0;

                                // Convert BGR888 to RGB565
                                // R = file_data (current byte), G = pix_g, B = pix_b
                                fb_data <= {file_data[7:3], pix_g[7:2], pix_b[7:3]};

                                // Flip rows: BMP row 0 = bottom of image
                                fb_addr <= ((IMG_H - 1 - pix_y) * IMG_W) + pix_x;
                                fb_we <= 1;

                                pix_x <= pix_x + 1;
                            end
                        endcase
                        row_bytes_read <= row_bytes_read + 1;
                    end else begin
                        // Padding byte - just count it
                        row_bytes_read <= row_bytes_read + 1;
                    end

                    // End of padded row?
                    if (row_bytes_read + 1 >= padded_row_bytes) begin
                        row_bytes_read <= 0;
                        pix_x <= 0;
                        pix_byte_idx <= 0;
                        pix_y <= pix_y + 1;

                        if (pix_y + 1 >= IMG_H)
                            state <= S_DONE;
                    end
                end

                if (file_done && state == S_READ_PIXELS) begin
                    // File ended - if we got enough pixels, call it done
                    if (pix_y >= IMG_H)
                        state <= S_DONE;
                    else
                        state <= S_ERROR;
                end
            end

            S_DONE: begin
                done <= 1;
            end

            S_ERROR: begin
                error <= 1;
            end
        endcase
    end
end

endmodule
