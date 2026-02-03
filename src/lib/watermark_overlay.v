// Watermark Overlay
// Renders a semi-transparent logo/text watermark in corner
// Future: load from SD card, configurable position

module watermark_overlay (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] px,
    input  wire [11:0] py,
    input  wire        de,
    input  wire        enabled,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b,
    output reg  [7:0]  alpha,     // 0=transparent, 255=opaque
    output reg         active     // Pixel is part of watermark
);

// Watermark position (bottom-right corner)
localparam WM_X = 1080;   // Start X
localparam WM_Y = 640;    // Start Y
localparam WM_W = 180;    // Width
localparam WM_H = 60;     // Height

// Animation counter for subtle effects
reg [23:0] anim;
always @(posedge clk) begin
    if (!rst_n)
        anim <= 0;
    else
        anim <= anim + 1;
end

// Check if pixel is in watermark region
wire in_watermark = enabled && de &&
                    (px >= WM_X) && (px < WM_X + WM_W) &&
                    (py >= WM_Y) && (py < WM_Y + WM_H);

// Local coordinates within watermark
wire [7:0] local_x = px - WM_X;
wire [7:0] local_y = py - WM_Y;

// Simple "INSIGHT" text pattern (8x8 font, scaled 2x)
// Each character is 16px wide after scaling
// "INSIGHT" = 7 chars = 112px, plus padding

// Character ROM for "INSIGHT" (simplified bitmap)
// We'll draw a simple bordered box with text placeholder
wire in_border = in_watermark && (
    (local_x < 3) || (local_x >= WM_W - 3) ||
    (local_y < 3) || (local_y >= WM_H - 3)
);

wire in_text_area = in_watermark && !in_border &&
    (local_x >= 10) && (local_x < WM_W - 10) &&
    (local_y >= 10) && (local_y < WM_H - 10);

// Simple letter patterns (very basic - would use font ROM for real)
// For now, just show a pulsing "INSIGHT" box
wire [7:0] char_x = (local_x - 10) >> 4;  // Which character (0-6)
wire [3:0] pixel_x = (local_x - 10) & 4'hF; // Pixel within char
wire [3:0] pixel_y = (local_y - 10);

// Simple "I" pattern check (column 0)
wire is_I = (char_x == 0 || char_x == 3) &&
            ((pixel_x >= 4) && (pixel_x < 12));

// Simple "N" pattern (columns 1)
wire is_N = (char_x == 1) && (
    (pixel_x < 4) || (pixel_x >= 12) ||
    (pixel_x == (pixel_y >> 1) + 2) // diagonal
);

// Simple "S" pattern (column 2)
wire is_S = (char_x == 2) && (
    (pixel_y < 6 && pixel_x > 4) ||
    (pixel_y >= 6 && pixel_y < 12 && pixel_x >= 4 && pixel_x < 12) ||
    (pixel_y >= 12 && pixel_x < 12)
);

// Simplified: just show filled rectangles for letters
wire show_letter = in_text_area && (
    // I
    (char_x == 0 && ((pixel_x >= 5 && pixel_x < 11) || pixel_y < 4 || pixel_y > 35)) ||
    // N
    (char_x == 1 && (pixel_x < 4 || pixel_x > 11 || (pixel_x >= pixel_y/3 && pixel_x <= pixel_y/3 + 4))) ||
    // S
    (char_x == 2 && (pixel_y < 8 || (pixel_y >= 16 && pixel_y < 24) || pixel_y >= 32)) ||
    // I
    (char_x == 3 && ((pixel_x >= 5 && pixel_x < 11) || pixel_y < 4 || pixel_y > 35)) ||
    // G
    (char_x == 4 && (pixel_x < 4 || pixel_y < 4 || pixel_y > 35 || (pixel_y > 16 && pixel_x > 8))) ||
    // H
    (char_x == 5 && (pixel_x < 4 || pixel_x > 11 || (pixel_y >= 16 && pixel_y < 24))) ||
    // T
    (char_x == 6 && (pixel_y < 4 || (pixel_x >= 5 && pixel_x < 11)))
);

// Output pixels
always @(posedge clk) begin
    if (!de || !enabled || !in_watermark) begin
        r <= 8'h00;
        g <= 8'h00;
        b <= 8'h00;
        alpha <= 8'h00;
        active <= 1'b0;
    end else begin
        active <= 1'b1;

        if (in_border) begin
            // Border: gold with slight pulse
            r <= 8'hD7 + anim[21:19];
            g <= 8'hAA + anim[21:19];
            b <= 8'h00;
            alpha <= 8'hC0;  // ~75% opaque
        end else if (show_letter) begin
            // Text: white
            r <= 8'hFF;
            g <= 8'hFF;
            b <= 8'hFF;
            alpha <= 8'hE0;  // ~87% opaque
        end else begin
            // Background: dark semi-transparent
            r <= 8'h1A;
            g <= 8'h0A;
            b <= 8'h2E;
            alpha <= 8'h80;  // 50% opaque
        end
    end
end

endmodule
