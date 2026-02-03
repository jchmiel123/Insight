// Insight Display System - Top Module
// Tang Nano 20K HDMI Overlay System
//
// Features:
//   - 1280x720 @ 60Hz HDMI output
//   - Multiple display modes (passthrough, overlay, fullscreen content)
//   - Text/logo watermark overlay with alpha blending
//   - Slot machine screensaver mode
//   - IR remote / button control
//   - Real-time clock display
//
// Architecture:
//   [HDMI In] -> [Input Buffer] -> [Overlay Engine] -> [HDMI Out]
//                                       ^
//                    [Mode Controller] -+- [Content Generator]
//                           ^               (slots, images, video)
//                    [IR/Buttons]

module insight_top (
    input             I_clk,           // 27MHz crystal
    input             I_rst_n,         // Button S1 - active low
    input             I_btn,           // Button S2 - active low
    output     [5:0]  O_led,           // 6 LEDs (active low)
    output            O_tmds_clk_p,    // HDMI clock positive
    output            O_tmds_clk_n,    // HDMI clock negative
    output     [2:0]  O_tmds_data_p,   // HDMI data positive
    output     [2:0]  O_tmds_data_n    // HDMI data negative
);

//==============================================================================
// Display Modes
//==============================================================================
localparam MODE_PASSTHROUGH  = 3'd0;  // Pass HDMI through (future - needs input)
localparam MODE_WATERMARK    = 3'd1;  // Show watermark overlay on content
localparam MODE_FULLSCREEN   = 3'd2;  // Full screen content (images/video)
localparam MODE_SLOTS        = 3'd3;  // Slot machine screensaver
localparam MODE_INFO         = 3'd4;  // Info screen (time, messages)
localparam MODE_OFF          = 3'd5;  // Display off / passthrough only

//==============================================================================
// Clock Generation
//==============================================================================
wire serial_clk;     // 371.25 MHz TMDS serial clock
wire pix_clk;        // 74.25 MHz pixel clock
wire pll_lock;
wire sys_rst_n;

// TMDS PLL - 27MHz -> 371.25MHz
TMDS_rPLL u_pll (
    .clkin  (I_clk),
    .clkout (serial_clk),
    .lock   (pll_lock)
);

// Divide by 5 for pixel clock: 371.25 / 5 = 74.25 MHz
CLKDIV u_clkdiv (
    .RESETN (I_rst_n & pll_lock),
    .HCLKIN (serial_clk),
    .CLKOUT (pix_clk),
    .CALIB  (1'b1)
);
defparam u_clkdiv.DIV_MODE = "5";
defparam u_clkdiv.GSREN = "false";

assign sys_rst_n = I_rst_n & pll_lock;

//==============================================================================
// Video Timing Generator (720p)
//==============================================================================
wire [11:0] h_cnt, v_cnt;
wire [11:0] px, py;          // Active pixel coordinates
wire        de, hs, vs;      // Display enable, h-sync, v-sync
wire        frame_start;     // Pulse at start of each frame

video_timing u_timing (
    .clk         (pix_clk),
    .rst_n       (sys_rst_n),
    .h_cnt       (h_cnt),
    .v_cnt       (v_cnt),
    .px          (px),
    .py          (py),
    .de          (de),
    .hs          (hs),
    .vs          (vs),
    .frame_start (frame_start)
);

//==============================================================================
// Mode Controller (Button/IR input)
//==============================================================================
wire [2:0] current_mode;
wire       mode_changed;
wire       btn_pressed;

mode_controller u_mode (
    .clk          (pix_clk),
    .rst_n        (sys_rst_n),
    .btn_mode     (I_btn),      // Mode cycle button
    .btn_select   (I_rst_n),    // Select/action button (active low)
    .current_mode (current_mode),
    .mode_changed (mode_changed)
);

//==============================================================================
// Content Generators
//==============================================================================

// Slot machine screensaver
wire [7:0] slots_r, slots_g, slots_b;
wire       slots_active;

slots_screensaver u_slots (
    .clk         (pix_clk),
    .rst_n       (sys_rst_n),
    .px          (px),
    .py          (py),
    .de          (de),
    .frame_start (frame_start),
    .btn_spin    (~I_rst_n),    // Use reset button as spin
    .btn_bet     (~I_btn),      // Use other button as bet
    .r           (slots_r),
    .g           (slots_g),
    .b           (slots_b)
);

// Info/test pattern for other modes
wire [7:0] info_r, info_g, info_b;

info_screen u_info (
    .clk   (pix_clk),
    .rst_n (sys_rst_n),
    .px    (px),
    .py    (py),
    .de    (de),
    .mode  (current_mode),
    .r     (info_r),
    .g     (info_g),
    .b     (info_b)
);

//==============================================================================
// Watermark Overlay
//==============================================================================
wire [7:0] wm_r, wm_g, wm_b;
wire [7:0] wm_alpha;
wire       wm_active;

watermark_overlay u_watermark (
    .clk      (pix_clk),
    .rst_n    (sys_rst_n),
    .px       (px),
    .py       (py),
    .de       (de),
    .enabled  (current_mode == MODE_WATERMARK || current_mode == MODE_PASSTHROUGH),
    .r        (wm_r),
    .g        (wm_g),
    .b        (wm_b),
    .alpha    (wm_alpha),
    .active   (wm_active)
);

//==============================================================================
// Output Pixel Multiplexer
//==============================================================================
reg [7:0] out_r, out_g, out_b;

// Background color (when no input source)
wire [7:0] bg_r = 8'h1A;
wire [7:0] bg_g = 8'h0A;
wire [7:0] bg_b = 8'h2E;

always @(posedge pix_clk) begin
    case (current_mode)
        MODE_SLOTS: begin
            out_r <= slots_r;
            out_g <= slots_g;
            out_b <= slots_b;
        end

        MODE_INFO, MODE_FULLSCREEN: begin
            out_r <= info_r;
            out_g <= info_g;
            out_b <= info_b;
        end

        MODE_WATERMARK: begin
            // Blend watermark over background (or future HDMI input)
            if (wm_active) begin
                // Simple alpha blend: out = wm * alpha + bg * (1-alpha)
                out_r <= bg_r + (((wm_r - bg_r) * wm_alpha) >> 8);
                out_g <= bg_g + (((wm_g - bg_g) * wm_alpha) >> 8);
                out_b <= bg_b + (((wm_b - bg_b) * wm_alpha) >> 8);
            end else begin
                out_r <= bg_r;
                out_g <= bg_g;
                out_b <= bg_b;
            end
        end

        MODE_OFF, MODE_PASSTHROUGH: begin
            // Just background for now (HDMI input passthrough future)
            out_r <= bg_r;
            out_g <= bg_g;
            out_b <= bg_b;
        end

        default: begin
            out_r <= info_r;
            out_g <= info_g;
            out_b <= info_b;
        end
    endcase
end

//==============================================================================
// LED Status Display
//==============================================================================
reg [25:0] heartbeat;
always @(posedge pix_clk) begin
    if (!sys_rst_n)
        heartbeat <= 0;
    else
        heartbeat <= heartbeat + 1;
end

// LEDs show current mode (active low)
assign O_led[2:0] = ~current_mode;
assign O_led[3] = ~pll_lock;           // PLL lock indicator
assign O_led[4] = ~heartbeat[25];      // Heartbeat (~1Hz)
assign O_led[5] = ~de;                 // DE activity (always flickering)

//==============================================================================
// HDMI/DVI Transmitter
//==============================================================================
DVI_TX_Top u_dvi_tx (
    .I_rst_n       (sys_rst_n),
    .I_serial_clk  (serial_clk),
    .I_rgb_clk     (pix_clk),
    .I_rgb_vs      (vs),
    .I_rgb_hs      (hs),
    .I_rgb_de      (de),
    .I_rgb_r       (out_r),
    .I_rgb_g       (out_g),
    .I_rgb_b       (out_b),
    .O_tmds_clk_p  (O_tmds_clk_p),
    .O_tmds_clk_n  (O_tmds_clk_n),
    .O_tmds_data_p (O_tmds_data_p),
    .O_tmds_data_n (O_tmds_data_n)
);

endmodule
