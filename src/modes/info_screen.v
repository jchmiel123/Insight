// Info Screen / Boot Screen with Debug Display
// Shows boot progress, debug info, and test patterns

module info_screen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] px,
    input  wire [11:0] py,
    input  wire        de,
    input  wire [2:0]  mode,

    // Debug inputs for boot screen
    input  wire [4:0]  fat_state,
    input  wire [3:0]  fat_error,
    input  wire [3:0]  sd_error,
    input  wire        sd_ready,
    input  wire        fat_ready,
    input  wire        image_loaded,
    input  wire [7:0]  dbg_byte0,
    input  wire [7:0]  dbg_byte1,      // Now shows attribute byte (0x0F=LFN, 0x08=vol label)
    input  wire [7:0]  dbg_byte510,
    input  wire [7:0]  dbg_byte511,
    input  wire [9:0]  dbg_blk_wr_idx,
    input  wire [9:0]  dbg_dir_idx,    // Directory entry index

    // FAT32 parameters for debugging
    input  wire [31:0] dbg_part_lba,
    input  wire [31:0] dbg_data_start,
    input  wire [31:0] dbg_root_cluster,
    input  wire [31:0] dbg_dir_lba,

    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

// Screen dimensions
localparam SCREEN_W = 1280;
localparam SCREEN_H = 720;

// Colors
localparam [23:0] COL_BG       = 24'h1A0A2E;
localparam [23:0] COL_DARK     = 24'h0D0518;
localparam [23:0] COL_PURPLE   = 24'h9B4DCA;  // Brighter purple
localparam [23:0] COL_BLUE     = 24'h4D8DC7;  // Brighter blue
localparam [23:0] COL_CYAN     = 24'h4DCACA;  // Brighter cyan
localparam [23:0] COL_GREEN    = 24'h4DCA60;  // Brighter green
localparam [23:0] COL_YELLOW   = 24'hCACA4D;  // Brighter yellow
localparam [23:0] COL_ORANGE   = 24'hCA7D4D;  // Brighter orange
localparam [23:0] COL_RED      = 24'hCA4D4D;  // Brighter red
localparam [23:0] COL_WHITE    = 24'hFFFFFF;
localparam [23:0] COL_GRAY     = 24'h404040;

//==============================================================================
// 4x6 Hex digit font (simple bitmap)
//==============================================================================
// Each digit is 4 pixels wide, 6 pixels tall
// Stored as 6 rows of 4 bits = 24 bits per character
function [23:0] hex_char;
    input [3:0] digit;
    case (digit)
        4'h0: hex_char = 24'b0110_1001_1001_1001_1001_0110;
        4'h1: hex_char = 24'b0010_0110_0010_0010_0010_0111;
        4'h2: hex_char = 24'b0110_1001_0010_0100_1000_1111;
        4'h3: hex_char = 24'b0110_1001_0010_0001_1001_0110;
        4'h4: hex_char = 24'b1001_1001_1111_0001_0001_0001;
        4'h5: hex_char = 24'b1111_1000_1110_0001_1001_0110;
        4'h6: hex_char = 24'b0110_1000_1110_1001_1001_0110;
        4'h7: hex_char = 24'b1111_0001_0010_0100_0100_0100;
        4'h8: hex_char = 24'b0110_1001_0110_1001_1001_0110;
        4'h9: hex_char = 24'b0110_1001_0111_0001_0001_0110;
        4'hA: hex_char = 24'b0110_1001_1111_1001_1001_1001;
        4'hB: hex_char = 24'b1110_1001_1110_1001_1001_1110;
        4'hC: hex_char = 24'b0110_1001_1000_1000_1001_0110;
        4'hD: hex_char = 24'b1110_1001_1001_1001_1001_1110;
        4'hE: hex_char = 24'b1111_1000_1110_1000_1000_1111;
        4'hF: hex_char = 24'b1111_1000_1110_1000_1000_1000;
    endcase
endfunction

// Check if pixel is part of a hex digit at position (char_x, char_y) scaled by 4
function is_hex_pixel;
    input [3:0] digit;
    input [11:0] base_x, base_y;  // Top-left corner of digit on screen
    input [11:0] pixel_x, pixel_y;
    reg [23:0] char_data;
    reg [2:0] local_x, local_y;
    reg [4:0] bit_idx;
    begin
        char_data = hex_char(digit);
        // Scale factor of 4
        if (pixel_x >= base_x && pixel_x < base_x + 16 &&
            pixel_y >= base_y && pixel_y < base_y + 24) begin
            local_x = (pixel_x - base_x) >> 2;  // Divide by 4
            local_y = (pixel_y - base_y) >> 2;  // Divide by 4
            bit_idx = (5 - local_y) * 4 + (3 - local_x);
            is_hex_pixel = char_data[bit_idx];
        end else begin
            is_hex_pixel = 0;
        end
    end
endfunction

//==============================================================================
// Main Display Logic
//==============================================================================
reg [23:0] pixel;

// Progress bar position based on state
// States progress: 0->1->16->17->3->16->17->5->6->16->17->7->...
// Simplified: use fat_state as rough progress, max around state 11 for streaming
wire [6:0] progress = image_loaded ? 7'd100 :
                      fat_state >= 5'd11 ? 7'd90 :
                      fat_state >= 5'd7  ? 7'd60 :
                      fat_state >= 5'd5  ? 7'd40 :
                      fat_state >= 5'd3  ? 7'd20 :
                      fat_state >= 5'd1  ? 7'd10 : 7'd5;

wire [11:0] bar_fill = (12'd800 * {5'd0, progress}) / 12'd100;

always @(posedge clk) begin
    if (!de) begin
        pixel <= 24'h000000;
    end else begin
        case (mode)
            // MODE_PASSTHROUGH (0) - Boot/debug screen
            3'd0: begin
                // Dark background
                pixel <= COL_DARK;

                // Title area: "INSIGHT" using hex chars (I=1, N=hex pattern, S=5, etc)
                // Draw a nice title banner
                if (py >= 60 && py < 120) begin
                    // Background gradient bar
                    if (px >= 440 && px < 840)
                        pixel <= COL_PURPLE;
                    // Simple "SD BOOT" text using available hex: 5D 8007
                    // Actually let's just show status with indicators
                end

                // SD Card status indicator
                if (py >= 140 && py < 180) begin
                    if (px >= 540 && px < 740) begin
                        pixel <= sd_ready ? COL_GREEN : (sd_error ? COL_RED : COL_ORANGE);
                    end
                end

                // Loading message area
                if (py >= 200 && py < 260) begin
                    if (px >= 440 && px < 840) begin
                        if (fat_error != 0)
                            pixel <= COL_RED;
                        else if (image_loaded)
                            pixel <= COL_GREEN;
                        else
                            pixel <= COL_BLUE;
                    end
                end

                // Progress bar background (center)
                if (py >= 300 && py < 340 && px >= 240 && px < 1040) begin
                    pixel <= COL_GRAY;
                    // Progress bar fill
                    if (px < 240 + bar_fill) begin
                        if (fat_error != 0 || sd_error != 0)
                            pixel <= COL_RED;
                        else if (image_loaded)
                            pixel <= COL_GREEN;
                        else
                            pixel <= COL_BLUE;
                    end
                    // Border
                    if (py == 300 || py == 339 || px == 240 || px == 1039)
                        pixel <= COL_WHITE;
                end

                // Status text area
                if (py >= 360 && py < 400) begin
                    // Show state indicators
                    if (px >= 540 && px < 740) begin
                        // SD status box
                        pixel <= sd_ready ? COL_GREEN : COL_RED;
                    end
                end

                // Debug hex display area (bottom)
                if (py >= 450 && py < 700) begin
                    // Row 1: SD_ERR, FAT_STATE, FAT_ERR
                    // "SD:" at x=100
                    if (is_hex_pixel(sd_error, 200, 460, px, py)) pixel <= COL_CYAN;

                    // "ST:" at x=300
                    if (is_hex_pixel(fat_state[3:0], 350, 460, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel({3'b0, fat_state[4]}, 330, 460, px, py)) pixel <= COL_YELLOW;

                    // "ER:" at x=500
                    if (is_hex_pixel(fat_error, 500, 460, px, py)) pixel <= COL_RED;

                    // Row 2: Buffer bytes
                    // Byte0
                    if (is_hex_pixel(dbg_byte0[7:4], 200, 500, px, py)) pixel <= COL_WHITE;
                    if (is_hex_pixel(dbg_byte0[3:0], 220, 500, px, py)) pixel <= COL_WHITE;
                    // Byte1 (attr)
                    if (is_hex_pixel(dbg_byte1[7:4], 260, 500, px, py)) pixel <= COL_WHITE;
                    if (is_hex_pixel(dbg_byte1[3:0], 280, 500, px, py)) pixel <= COL_WHITE;
                    // Byte510
                    if (is_hex_pixel(dbg_byte510[7:4], 400, 500, px, py)) pixel <= COL_CYAN;
                    if (is_hex_pixel(dbg_byte510[3:0], 420, 500, px, py)) pixel <= COL_CYAN;
                    // Byte511
                    if (is_hex_pixel(dbg_byte511[7:4], 460, 500, px, py)) pixel <= COL_CYAN;
                    if (is_hex_pixel(dbg_byte511[3:0], 480, 500, px, py)) pixel <= COL_CYAN;

                    // Buffer write index
                    if (is_hex_pixel(dbg_blk_wr_idx[9:8], 600, 500, px, py)) pixel <= COL_ORANGE;
                    if (is_hex_pixel(dbg_blk_wr_idx[7:4], 620, 500, px, py)) pixel <= COL_ORANGE;
                    if (is_hex_pixel(dbg_blk_wr_idx[3:0], 640, 500, px, py)) pixel <= COL_ORANGE;

                    // Dir entry index (purple)
                    if (is_hex_pixel(dbg_dir_idx[9:8], 750, 500, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_idx[7:4], 770, 500, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_idx[3:0], 790, 500, px, py)) pixel <= COL_PURPLE;

                    // Row 3: part_lba (green), data_start (blue)
                    // part_lba - 8 hex digits
                    if (is_hex_pixel(dbg_part_lba[31:28], 100, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[27:24], 120, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[23:20], 140, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[19:16], 160, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[15:12], 180, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[11:8],  200, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[7:4],   220, 550, px, py)) pixel <= COL_GREEN;
                    if (is_hex_pixel(dbg_part_lba[3:0],   240, 550, px, py)) pixel <= COL_GREEN;

                    // data_start - 8 hex digits (blue)
                    if (is_hex_pixel(dbg_data_start[31:28], 300, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[27:24], 320, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[23:20], 340, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[19:16], 360, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[15:12], 380, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[11:8],  400, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[7:4],   420, 550, px, py)) pixel <= COL_BLUE;
                    if (is_hex_pixel(dbg_data_start[3:0],   440, 550, px, py)) pixel <= COL_BLUE;

                    // Row 4: root_cluster (yellow), dir_lba (purple)
                    // root_cluster - 8 hex digits
                    if (is_hex_pixel(dbg_root_cluster[31:28], 100, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[27:24], 120, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[23:20], 140, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[19:16], 160, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[15:12], 180, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[11:8],  200, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[7:4],   220, 600, px, py)) pixel <= COL_YELLOW;
                    if (is_hex_pixel(dbg_root_cluster[3:0],   240, 600, px, py)) pixel <= COL_YELLOW;

                    // dir_lba (actual LBA being read) - 8 hex digits (purple)
                    if (is_hex_pixel(dbg_dir_lba[31:28], 300, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[27:24], 320, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[23:20], 340, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[19:16], 360, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[15:12], 380, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[11:8],  400, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[7:4],   420, 600, px, py)) pixel <= COL_PURPLE;
                    if (is_hex_pixel(dbg_dir_lba[3:0],   440, 600, px, py)) pixel <= COL_PURPLE;
                end

                // Labels
                if (py >= 420 && py < 440) begin
                    // Simple label indicators as colored squares
                    if (px >= 195 && px < 215) pixel <= COL_CYAN;   // SD label
                    if (px >= 345 && px < 365) pixel <= COL_YELLOW; // State label
                    if (px >= 495 && px < 515) pixel <= COL_RED;    // Error label
                end
            end

            // MODE_FULLSCREEN (2) - Color bars test pattern
            3'd2: begin
                if (px < 183)       pixel <= COL_WHITE;
                else if (px < 366)  pixel <= COL_YELLOW;
                else if (px < 549)  pixel <= COL_CYAN;
                else if (px < 732)  pixel <= COL_GREEN;
                else if (px < 915)  pixel <= COL_PURPLE;
                else if (px < 1098) pixel <= COL_RED;
                else                pixel <= COL_BLUE;
            end

            // MODE_INFO (4) - Info display with boxes
            3'd4: begin
                pixel <= COL_BG;
                if (py < 80) pixel <= 24'h2D2D5A;
                if ((px >= 200) && (px < 1080) && (py >= 150) && (py < 570)) begin
                    pixel <= 24'h1E1E3E;
                    if ((px == 200) || (px == 1079) || (py == 150) || (py == 569))
                        pixel <= COL_PURPLE;
                end
                if (py >= 640) pixel <= 24'h2D2D5A;
            end

            default: begin
                pixel <= COL_BG;
            end
        endcase
    end
end

// Output RGB
always @(posedge clk) begin
    r <= pixel[7:0];
    g <= pixel[15:8];
    b <= pixel[23:16];
end

endmodule
