// SDRAM-backed Framebuffer with Line Buffers
//
// Stores a full 1280x720 RGB565 image in SDRAM (1,843,200 bytes).
// Uses double-buffered BSRAM line buffers for glitch-free video scanout.
//
// Architecture:
//   SDRAM (8MB) holds the full frame.
//   Two BSRAM line buffers (1280 x 16-bit = 2560 bytes each, ~5KB total).
//   While one line buffer is being read by the video scanout,
//   the other is being filled from SDRAM.
//   They swap at each new scanline.
//
// Write interface: byte-at-a-time from BMP loader (clk_sdram domain)
// Read interface: pixel-at-a-time from video scanout (pix_clk domain)
//
// SDRAM layout: pixel(x,y) at address (y * 1280 + x) * 2 (RGB565, 2 bytes each)

module sdram_framebuffer #(
    parameter IMG_W = 1280,
    parameter IMG_H = 720
)(
    // SDRAM controller clock domain
    input             clk_sdram,     // 27MHz SDRAM clock
    input             rst_n,

    // SDRAM controller interface
    output reg        sdram_rd,
    output reg        sdram_wr,
    output reg        sdram_refresh,
    output reg [22:0] sdram_addr,
    output reg  [7:0] sdram_din,
    input       [7:0] sdram_dout,
    input             sdram_data_ready,
    input             sdram_busy,

    // Write interface (from BMP loader, clk_sdram domain)
    input      [20:0] wr_pixel_addr, // pixel index (0 to 1280*720-1)
    input      [15:0] wr_pixel_data, // RGB565
    input             wr_en,

    // Read interface (from video scanout, pix_clk domain)
    input             pix_clk,       // 74.25MHz pixel clock
    input      [11:0] px,            // current pixel X
    input      [11:0] py,            // current pixel Y
    input             de,            // display enable
    input             hs,            // h-sync (active low)
    output     [15:0] rd_pixel_data, // RGB565 output

    // Status
    input             image_loaded,  // image is fully written
    output reg        line_ready     // current line buffer has valid data
);

//==============================================================================
// Line Buffers (double-buffered in BSRAM)
//==============================================================================
// Two line buffers, each 1280 x 16-bit
reg [15:0] line_buf_0 [0:1279];
reg [15:0] line_buf_1 [0:1279];

reg        active_buf;     // Which buffer video is reading from (0 or 1)
reg [10:0] lb_wr_addr;     // Write address into fill buffer
reg [15:0] lb_wr_data;
reg        lb_wr_en;

// Write to the non-active (fill) buffer
always @(posedge clk_sdram) begin
    if (lb_wr_en) begin
        if (active_buf)
            line_buf_0[lb_wr_addr] <= lb_wr_data;
        else
            line_buf_1[lb_wr_addr] <= lb_wr_data;
    end
end

// Read from the active buffer (pix_clk domain)
reg [15:0] lb_rd_data;
always @(posedge pix_clk) begin
    if (active_buf)
        lb_rd_data <= line_buf_1[px[10:0]];
    else
        lb_rd_data <= line_buf_0[px[10:0]];
end
assign rd_pixel_data = lb_rd_data;

//==============================================================================
// Sync py into SDRAM clock domain
//==============================================================================
reg [11:0] py_sync_0, py_sync_1;
reg        hs_sync_0, hs_sync_1, hs_sync_2;
wire       hs_rising = hs_sync_1 & ~hs_sync_2; // detect start of new line

always @(posedge clk_sdram) begin
    py_sync_0 <= py;
    py_sync_1 <= py_sync_0;
    hs_sync_0 <= hs;
    hs_sync_1 <= hs_sync_0;
    hs_sync_2 <= hs_sync_1;
end

//==============================================================================
// SDRAM Write State Machine (loading phase)
//==============================================================================
// During loading: BMP loader provides pixel address + RGB565 data
// We write two bytes per pixel to SDRAM
localparam WR_IDLE    = 3'd0;
localparam WR_BYTE_LO = 3'd1;  // Write low byte
localparam WR_WAIT_LO = 3'd2;
localparam WR_BYTE_HI = 3'd3;  // Write high byte
localparam WR_WAIT_HI = 3'd4;

reg [2:0]  wr_state;
reg [20:0] wr_pix_addr_buf;
reg [15:0] wr_pix_data_buf;

//==============================================================================
// SDRAM Read State Machine (display phase — line buffer fill)
//==============================================================================
// During display: prefetch the next scanline into the fill line buffer
localparam RD_IDLE      = 3'd0;
localparam RD_START     = 3'd1;
localparam RD_BYTE_LO   = 3'd2;  // Read low byte of pixel
localparam RD_WAIT_LO   = 3'd3;
localparam RD_BYTE_HI   = 3'd4;  // Read high byte of pixel
localparam RD_WAIT_HI   = 3'd5;
localparam RD_STORE     = 3'd6;

reg [2:0]  rd_state;
reg [10:0] rd_pixel_x;          // Current pixel X being fetched
reg [11:0] rd_line_y;           // Which line we're fetching
reg  [7:0] rd_lo_byte;          // Temporary low byte storage
reg        line_fetch_done;     // Current line fully fetched

//==============================================================================
// Refresh Timer
//==============================================================================
// Must refresh every ~15us. At 27MHz that's 405 clocks.
reg [8:0]  refresh_timer;
reg        refresh_needed;
localparam REFRESH_INTERVAL = 9'd400;

always @(posedge clk_sdram or negedge rst_n) begin
    if (!rst_n) begin
        refresh_timer <= 0;
        refresh_needed <= 0;
    end else begin
        if (refresh_timer >= REFRESH_INTERVAL) begin
            refresh_needed <= 1;
            refresh_timer <= 0;
        end else begin
            refresh_timer <= refresh_timer + 1;
        end
        if (sdram_refresh)
            refresh_needed <= 0;
    end
end

//==============================================================================
// Main Arbitrator
//==============================================================================
// Priority: refresh > write (loading) > read (line fill)
always @(posedge clk_sdram or negedge rst_n) begin
    if (!rst_n) begin
        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_refresh <= 0;
        sdram_addr <= 0;
        sdram_din <= 0;
        wr_state <= WR_IDLE;
        rd_state <= RD_IDLE;
        lb_wr_en <= 0;
        lb_wr_addr <= 0;
        lb_wr_data <= 0;
        active_buf <= 0;
        rd_pixel_x <= 0;
        rd_line_y <= 0;
        rd_lo_byte <= 0;
        line_fetch_done <= 0;
        line_ready <= 0;
    end else begin
        sdram_rd <= 0;
        sdram_wr <= 0;
        sdram_refresh <= 0;
        lb_wr_en <= 0;

        // ---- Refresh (highest priority) ----
        if (refresh_needed && !sdram_busy &&
            wr_state == WR_IDLE && rd_state == RD_IDLE) begin
            sdram_refresh <= 1;
        end

        // ---- Write: store pixels during loading ----
        else if (!image_loaded) begin
            case (wr_state)
                WR_IDLE: begin
                    if (wr_en) begin
                        wr_pix_addr_buf <= wr_pixel_addr;
                        wr_pix_data_buf <= wr_pixel_data;
                        wr_state <= WR_BYTE_LO;
                    end
                end
                WR_BYTE_LO: begin
                    if (!sdram_busy) begin
                        sdram_wr <= 1;
                        sdram_addr <= {wr_pix_addr_buf, 1'b0};     // byte addr = pixel * 2
                        sdram_din <= wr_pix_data_buf[7:0];          // low byte first
                        wr_state <= WR_WAIT_LO;
                    end
                end
                WR_WAIT_LO: begin
                    if (!sdram_busy) begin
                        wr_state <= WR_BYTE_HI;
                    end
                end
                WR_BYTE_HI: begin
                    if (!sdram_busy) begin
                        sdram_wr <= 1;
                        sdram_addr <= {wr_pix_addr_buf, 1'b1};     // byte addr + 1
                        sdram_din <= wr_pix_data_buf[15:8];         // high byte
                        wr_state <= WR_WAIT_HI;
                    end
                end
                WR_WAIT_HI: begin
                    if (!sdram_busy) begin
                        wr_state <= WR_IDLE;
                    end
                end
            endcase
        end

        // ---- Read: prefetch scanlines during display ----
        else begin
            case (rd_state)
                RD_IDLE: begin
                    // Detect new scanline: on h-sync rising edge, start fetching next line
                    if (hs_rising && py_sync_1 < IMG_H) begin
                        rd_line_y <= py_sync_1;  // Fetch the line that's about to display
                        rd_pixel_x <= 0;
                        line_fetch_done <= 0;
                        rd_state <= RD_START;
                    end
                end
                RD_START: begin
                    if (!sdram_busy && !refresh_needed) begin
                        rd_state <= RD_BYTE_LO;
                    end
                end
                RD_BYTE_LO: begin
                    if (!sdram_busy) begin
                        if (refresh_needed) begin
                            sdram_refresh <= 1;
                            // Stay in RD_BYTE_LO, retry after refresh
                        end else begin
                            sdram_rd <= 1;
                            // Byte address = (y * 1280 + x) * 2
                            sdram_addr <= (rd_line_y * 16'd1280 + {12'd0, rd_pixel_x}) << 1;
                            rd_state <= RD_WAIT_LO;
                        end
                    end
                end
                RD_WAIT_LO: begin
                    if (sdram_data_ready) begin
                        rd_lo_byte <= sdram_dout;
                        rd_state <= RD_BYTE_HI;
                    end
                end
                RD_BYTE_HI: begin
                    if (!sdram_busy) begin
                        if (refresh_needed) begin
                            sdram_refresh <= 1;
                        end else begin
                            sdram_rd <= 1;
                            sdram_addr <= ((rd_line_y * 16'd1280 + {12'd0, rd_pixel_x}) << 1) | 23'd1;
                            rd_state <= RD_WAIT_HI;
                        end
                    end
                end
                RD_WAIT_HI: begin
                    if (sdram_data_ready) begin
                        // Store reconstructed RGB565 into line buffer
                        lb_wr_data <= {sdram_dout, rd_lo_byte};
                        lb_wr_addr <= rd_pixel_x;
                        lb_wr_en <= 1;
                        rd_state <= RD_STORE;
                    end
                end
                RD_STORE: begin
                    rd_pixel_x <= rd_pixel_x + 1;
                    if (rd_pixel_x + 1 >= IMG_W) begin
                        // Line done, swap buffers
                        active_buf <= ~active_buf;
                        line_ready <= 1;
                        line_fetch_done <= 1;
                        rd_state <= RD_IDLE;
                    end else begin
                        rd_state <= RD_BYTE_LO;
                    end
                end
            endcase
        end
    end
end

endmodule
