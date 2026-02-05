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
    output     [2:0]  O_tmds_data_n,   // HDMI data negative

    // SD Card (SPI mode)
    output            sd_clk,
    output            sd_mosi,
    input             sd_miso,
    output            sd_cs_n,

    // SDRAM (magic port names for Gowin internal SDRAM)
    output            O_sdram_clk,
    output            O_sdram_cke,
    output            O_sdram_cs_n,
    output            O_sdram_cas_n,
    output            O_sdram_ras_n,
    output            O_sdram_wen_n,
    inout      [31:0] IO_sdram_dq,
    output     [10:0] O_sdram_addr,
    output      [1:0] O_sdram_ba,
    output      [3:0] O_sdram_dqm
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

// SDRAM PLL - 27MHz + 180-degree shifted clock for SDRAM
wire clk_sdram;      // 27MHz for SDRAM controller
wire clk_sdram_p;    // 27MHz phase-shifted for SDRAM chip
wire sdram_pll_lock;

SDRAM_rPLL u_sdram_pll (
    .clkin  (I_clk),
    .clkout (clk_sdram),
    .clkoutp(clk_sdram_p),
    .lock   (sdram_pll_lock)
);

assign sys_rst_n = I_rst_n & pll_lock & sdram_pll_lock;

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
// SD Card Image Loader
//==============================================================================
wire        sd_ready;
wire [3:0]  sd_error_code;
wire [31:0] sd_rd_block;
wire        sd_rd_start;
wire [7:0]  sd_rd_data;
wire        sd_rd_data_valid;
wire        sd_rd_done;

sd_spi u_sd (
    .clk          (clk_sdram),     // 27MHz for SPI timing
    .rst_n        (sdram_pll_lock),
    .sd_clk       (sd_clk),
    .sd_mosi      (sd_mosi),
    .sd_miso      (sd_miso),
    .sd_cs_n      (sd_cs_n),
    .ready        (sd_ready),
    .error_code   (sd_error_code),
    .rd_block     (sd_rd_block),
    .rd_start     (sd_rd_start),
    .rd_data      (sd_rd_data),
    .rd_data_valid(sd_rd_data_valid),
    .rd_done      (sd_rd_done)
);

// FAT32 Filesystem Reader (finds first .BMP on SD card)
wire [7:0]  fat_file_data;
wire        fat_file_data_valid;
wire        fat_file_done;
wire        fat_ready;
wire        fat_error;
wire [3:0]  fat_error_code;

// Auto-start loading on boot
reg         boot_start;
reg  [1:0]  boot_delay;
always @(posedge clk_sdram or negedge sdram_pll_lock) begin
    if (!sdram_pll_lock) begin
        boot_start <= 0;
        boot_delay <= 0;
    end else if (boot_delay < 2'd3) begin
        boot_delay <= boot_delay + 1;
        boot_start <= (boot_delay == 2'd2);
    end else begin
        boot_start <= 0;
    end
end

fat32_reader u_fat32 (
    .clk            (clk_sdram),
    .rst_n          (sdram_pll_lock),
    .start          (boot_start),
    .sd_block       (sd_rd_block),
    .sd_rd_start    (sd_rd_start),
    .sd_data        (sd_rd_data),
    .sd_data_valid  (sd_rd_data_valid),
    .sd_rd_done     (sd_rd_done),
    .sd_ready       (sd_ready),
    .file_data      (fat_file_data),
    .file_data_valid(fat_file_data_valid),
    .file_done      (fat_file_done),
    .ready          (fat_ready),
    .error          (fat_error),
    .error_code     (fat_error_code)
);

// BMP Loader (receives byte stream from FAT32 reader)
wire [20:0] fb_wr_addr;
wire [15:0] fb_wr_data;
wire        fb_wr_en;
wire        image_loaded;
wire        image_error;

bmp_loader #(
    .IMG_W (1280),
    .IMG_H (720)
) u_bmp (
    .clk            (clk_sdram),
    .rst_n          (sdram_pll_lock),
    .start          (fat_ready),
    .file_data      (fat_file_data),
    .file_data_valid(fat_file_data_valid),
    .file_done      (fat_file_done),
    .fb_addr        (fb_wr_addr),
    .fb_data        (fb_wr_data),
    .fb_we          (fb_wr_en),
    .done           (image_loaded),
    .error          (image_error)
);

// SDRAM Controller
wire        sdram_rd;
wire        sdram_wr;
wire        sdram_refresh;
wire [22:0] sdram_addr;
wire  [7:0] sdram_din;
wire  [7:0] sdram_dout;
wire        sdram_data_ready;
wire        sdram_busy;

sdram #(
    .FREQ(27_000_000)
) u_sdram (
    .clk          (clk_sdram),
    .clk_sdram    (clk_sdram_p),
    .resetn       (sdram_pll_lock),
    .rd           (sdram_rd),
    .wr           (sdram_wr),
    .refresh      (sdram_refresh),
    .addr         (sdram_addr),
    .din          (sdram_din),
    .dout         (sdram_dout),
    .data_ready   (sdram_data_ready),
    .busy         (sdram_busy),
    .SDRAM_DQ     (IO_sdram_dq),
    .SDRAM_A      (O_sdram_addr),
    .SDRAM_BA     (O_sdram_ba),
    .SDRAM_nCS    (O_sdram_cs_n),
    .SDRAM_nWE    (O_sdram_wen_n),
    .SDRAM_nRAS   (O_sdram_ras_n),
    .SDRAM_nCAS   (O_sdram_cas_n),
    .SDRAM_CLK    (O_sdram_clk),
    .SDRAM_CKE    (O_sdram_cke),
    .SDRAM_DQM    (O_sdram_dqm)
);

// SDRAM Framebuffer (with line buffers for video scanout)
wire [15:0] line_buf_pixel;
wire        line_ready;

sdram_framebuffer #(
    .IMG_W (1280),
    .IMG_H (720)
) u_sdram_fb (
    .clk_sdram      (clk_sdram),
    .rst_n          (sdram_pll_lock),
    .sdram_rd       (sdram_rd),
    .sdram_wr       (sdram_wr),
    .sdram_refresh  (sdram_refresh),
    .sdram_addr     (sdram_addr),
    .sdram_din      (sdram_din),
    .sdram_dout     (sdram_dout),
    .sdram_data_ready(sdram_data_ready),
    .sdram_busy     (sdram_busy),
    .wr_pixel_addr  (fb_wr_addr),
    .wr_pixel_data  (fb_wr_data),
    .wr_en          (fb_wr_en),
    .pix_clk        (pix_clk),
    .px             (px),
    .py             (py),
    .de             (de),
    .hs             (hs),
    .rd_pixel_data  (line_buf_pixel),
    .image_loaded   (image_loaded),
    .line_ready     (line_ready)
);

// SD Image Display (native 720p, no scaling)
wire [7:0] sdimg_r, sdimg_g, sdimg_b;

sd_image_display u_sdimg (
    .clk         (pix_clk),
    .rst_n       (sys_rst_n),
    .px          (px),
    .py          (py),
    .de          (de),
    .image_ready (image_loaded),
    .pixel_data  (line_buf_pixel),
    .r           (sdimg_r),
    .g           (sdimg_g),
    .b           (sdimg_b)
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

        MODE_PASSTHROUGH: begin
            // Show SD card image if loaded, else background
            if (image_loaded) begin
                out_r <= sdimg_r;
                out_g <= sdimg_g;
                out_b <= sdimg_b;
            end else begin
                out_r <= bg_r;
                out_g <= bg_g;
                out_b <= bg_b;
            end
        end

        MODE_OFF: begin
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
