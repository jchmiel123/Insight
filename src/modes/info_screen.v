// Info Screen / Test Pattern
// Shows mode info, test patterns, and placeholder content

module info_screen (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] px,
    input  wire [11:0] py,
    input  wire        de,
    input  wire [2:0]  mode,
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

// Screen dimensions
localparam SCREEN_W = 1280;
localparam SCREEN_H = 720;

// Colors
localparam [23:0] COL_BG      = 24'h1A0A2E;
localparam [23:0] COL_PURPLE  = 24'h6B2D73;
localparam [23:0] COL_BLUE    = 24'h2D5573;
localparam [23:0] COL_CYAN    = 24'h2D7373;
localparam [23:0] COL_GREEN   = 24'h2D7340;
localparam [23:0] COL_YELLOW  = 24'h73732D;
localparam [23:0] COL_ORANGE  = 24'h734D2D;
localparam [23:0] COL_RED     = 24'h732D2D;
localparam [23:0] COL_WHITE   = 24'hFFFFFF;

// Animated gradient counter
reg [23:0] anim_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        anim_cnt <= 0;
    else
        anim_cnt <= anim_cnt + 1;
end

// Generate various test patterns based on mode
reg [23:0] pixel;

always @(posedge clk) begin
    if (!de) begin
        pixel <= 24'h000000;
    end else begin
        case (mode)
            // MODE_PASSTHROUGH (0) - gradient showing system is alive
            3'd0: begin
                // Animated horizontal gradient
                pixel[7:0]  <= px[7:0] + anim_cnt[20:13];
                pixel[15:8] <= py[6:0] + anim_cnt[21:14];
                pixel[23:16] <= (px[7:0] ^ py[6:0]) + anim_cnt[22:15];
            end

            // MODE_WATERMARK (1) - show background for watermark testing
            3'd1: begin
                // Subtle animated background
                if ((px[5:0] == 0) || (py[5:0] == 0))
                    pixel <= 24'h2A1A4E;  // Grid lines
                else
                    pixel <= COL_BG;
            end

            // MODE_FULLSCREEN (2) - Color bars test pattern
            3'd2: begin
                // SMPTE-like color bars
                if (px < 183)
                    pixel <= COL_WHITE;
                else if (px < 366)
                    pixel <= COL_YELLOW;
                else if (px < 549)
                    pixel <= COL_CYAN;
                else if (px < 732)
                    pixel <= COL_GREEN;
                else if (px < 915)
                    pixel <= COL_PURPLE;
                else if (px < 1098)
                    pixel <= COL_RED;
                else
                    pixel <= COL_BLUE;
            end

            // MODE_SLOTS (3) - handled by slots_screensaver module
            3'd3: begin
                pixel <= COL_BG;
            end

            // MODE_INFO (4) - Info display with boxes
            3'd4: begin
                // Background
                pixel <= COL_BG;

                // Header bar
                if (py < 80)
                    pixel <= 24'h2D2D5A;

                // Center content area
                if ((px >= 200) && (px < 1080) && (py >= 150) && (py < 570)) begin
                    // Content box background
                    pixel <= 24'h1E1E3E;

                    // Border
                    if ((px == 200) || (px == 1079) || (py == 150) || (py == 569))
                        pixel <= COL_PURPLE;
                end

                // Bottom info bar
                if (py >= 640)
                    pixel <= 24'h2D2D5A;
            end

            // MODE_OFF (5) - Blank/standby
            3'd5: begin
                // Very dim logo or completely off
                if ((px >= 600) && (px < 680) && (py >= 340) && (py < 380)) begin
                    // Small "INSIGHT" marker so you know it's working
                    pixel <= 24'h101020;
                end else begin
                    pixel <= 24'h000000;
                end
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
