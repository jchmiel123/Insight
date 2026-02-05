// Dual-Port BSRAM Framebuffer
// 240x180 pixels, 16-bit RGB565
// Port A: Write (from BMP loader)
// Port B: Read (from video scanout)
//
// Total: 43,200 entries x 16 bits = 86,400 bytes
// Uses ~46 BSRAM blocks (nearly all of GW2AR-18C's 46 blocks)

module framebuffer #(
    parameter IMG_W  = 240,
    parameter IMG_H  = 180,
    parameter DEPTH  = 43200  // IMG_W * IMG_H
)(
    // Write port (SD loader side)
    input             wr_clk,
    input      [15:0] wr_addr,
    input      [15:0] wr_data,
    input             wr_en,

    // Read port (video scanout side)
    input             rd_clk,
    input      [15:0] rd_addr,
    output reg [15:0] rd_data
);

// Inferred dual-port BSRAM
// Gowin synthesis will map this to BSRAM blocks automatically
reg [15:0] mem [0:DEPTH-1];

// Write port
always @(posedge wr_clk) begin
    if (wr_en && wr_addr < DEPTH)
        mem[wr_addr] <= wr_data;
end

// Read port
always @(posedge rd_clk) begin
    if (rd_addr < DEPTH)
        rd_data <= mem[rd_addr];
    else
        rd_data <= 16'h0000;
end

endmodule
