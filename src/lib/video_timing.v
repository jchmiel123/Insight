// Video Timing Generator
// 1280x720 @ 60Hz (720p) timing
//
// Pixel clock: 74.25 MHz
// H: 1650 total (40 sync + 220 back porch + 1280 active + 110 front porch)
// V: 750 total (5 sync + 20 back porch + 720 active + 5 front porch)

module video_timing (
    input  wire        clk,          // 74.25 MHz pixel clock
    input  wire        rst_n,
    output reg  [11:0] h_cnt,        // Horizontal counter (0-1649)
    output reg  [11:0] v_cnt,        // Vertical counter (0-749)
    output wire [11:0] px,           // Active pixel X (0-1279)
    output wire [11:0] py,           // Active pixel Y (0-719)
    output wire        de,           // Data enable (active video)
    output reg         hs,           // Horizontal sync
    output reg         vs,           // Vertical sync
    output wire        frame_start   // Pulse at frame start
);

// 720p timing parameters
localparam H_TOTAL  = 12'd1650;
localparam H_SYNC   = 12'd40;
localparam H_BPORCH = 12'd220;
localparam H_ACTIVE = 12'd1280;
localparam H_FPORCH = 12'd110;

localparam V_TOTAL  = 12'd750;
localparam V_SYNC   = 12'd5;
localparam V_BPORCH = 12'd20;
localparam V_ACTIVE = 12'd720;
localparam V_FPORCH = 12'd5;

// Derived boundaries
localparam H_ACT_START = H_SYNC + H_BPORCH;
localparam H_ACT_END   = H_ACT_START + H_ACTIVE;
localparam V_ACT_START = V_SYNC + V_BPORCH;
localparam V_ACT_END   = V_ACT_START + V_ACTIVE;

//==============================================================================
// Horizontal counter
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        h_cnt <= 12'd0;
    else if (h_cnt >= H_TOTAL - 1)
        h_cnt <= 12'd0;
    else
        h_cnt <= h_cnt + 1'b1;
end

//==============================================================================
// Vertical counter
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        v_cnt <= 12'd0;
    else if (h_cnt >= H_TOTAL - 1) begin
        if (v_cnt >= V_TOTAL - 1)
            v_cnt <= 12'd0;
        else
            v_cnt <= v_cnt + 1'b1;
    end
end

//==============================================================================
// Sync signals (active high for 720p standard)
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        hs <= 1'b0;
        vs <= 1'b0;
    end else begin
        hs <= (h_cnt < H_SYNC);
        vs <= (v_cnt < V_SYNC);
    end
end

//==============================================================================
// Data enable and pixel coordinates
//==============================================================================
wire h_active = (h_cnt >= H_ACT_START) && (h_cnt < H_ACT_END);
wire v_active = (v_cnt >= V_ACT_START) && (v_cnt < V_ACT_END);

assign de = h_active && v_active;
assign px = h_active ? (h_cnt - H_ACT_START) : 12'd0;
assign py = v_active ? (v_cnt - V_ACT_START) : 12'd0;

// Frame start pulse (at 0,0)
assign frame_start = (h_cnt == 0) && (v_cnt == 0);

endmodule
