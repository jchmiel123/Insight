// SD Image Display Mode
// Displays a full 1280x720 image from SDRAM framebuffer.
// Reads RGB565 pixels from the line buffer and converts to RGB888.
// No scaling needed — native 1:1 pixel mapping.

module sd_image_display (
    input             clk,
    input             rst_n,
    input      [11:0] px,            // Active pixel X (0-1279)
    input      [11:0] py,            // Active pixel Y (0-719)
    input             de,            // Display enable
    input             image_ready,   // Image loaded in framebuffer

    // Line buffer read (from sdram_framebuffer)
    input      [15:0] pixel_data,    // RGB565 from line buffer

    // Output RGB888
    output reg  [7:0] r,
    output reg  [7:0] g,
    output reg  [7:0] b
);

//==============================================================================
// RGB565 -> RGB888 Conversion
//==============================================================================
// RGB565 layout: {R[4:0], G[5:0], B[4:0]}
// Expand by replicating MSBs into LSBs for better color accuracy
wire [4:0] r5 = pixel_data[15:11];
wire [5:0] g6 = pixel_data[10:5];
wire [4:0] b5 = pixel_data[4:0];

reg de_d1;

always @(posedge clk) begin
    de_d1 <= de;

    if (!rst_n || !image_ready) begin
        // Loading indicator: dark blue
        r <= 8'h00;
        g <= 8'h00;
        b <= 8'h20;
    end else if (de) begin
        r <= {r5, r5[4:2]};
        g <= {g6, g6[5:4]};
        b <= {b5, b5[4:2]};
    end else begin
        r <= 8'h00;
        g <= 8'h00;
        b <= 8'h00;
    end
end

endmodule
