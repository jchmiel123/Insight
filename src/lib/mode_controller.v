// Mode Controller
// Handles button input with debouncing for mode switching
// Future: IR remote control support

module mode_controller #(
    parameter NUM_MODES = 6,
    parameter DEBOUNCE_MS = 20,      // Debounce time in ms
    parameter CLK_FREQ = 74_250_000  // 74.25 MHz pixel clock
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       btn_mode,      // Mode cycle button (active low)
    input  wire       btn_select,    // Select/action button (active low)
    output reg  [2:0] current_mode,
    output reg        mode_changed   // Pulse when mode changes
);

// Calculate debounce counter size
localparam DEBOUNCE_CYCLES = (CLK_FREQ / 1000) * DEBOUNCE_MS;
localparam DEBOUNCE_BITS = $clog2(DEBOUNCE_CYCLES);

//==============================================================================
// Button debouncing
//==============================================================================
reg [DEBOUNCE_BITS-1:0] debounce_cnt;
reg btn_mode_clean, btn_mode_prev;
reg btn_pressed;

// Debounce state machine
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        debounce_cnt <= 0;
        btn_mode_clean <= 1'b1;  // Unpressed (active low)
        btn_mode_prev <= 1'b1;
        btn_pressed <= 1'b0;
    end else begin
        btn_mode_prev <= btn_mode_clean;
        btn_pressed <= 1'b0;

        // Debounce the mode button
        if (btn_mode == btn_mode_clean) begin
            debounce_cnt <= 0;
        end else begin
            if (debounce_cnt >= DEBOUNCE_CYCLES - 1) begin
                btn_mode_clean <= btn_mode;
                debounce_cnt <= 0;
            end else begin
                debounce_cnt <= debounce_cnt + 1;
            end
        end

        // Detect falling edge (button pressed - active low)
        if (!btn_mode_clean && btn_mode_prev) begin
            btn_pressed <= 1'b1;
        end
    end
end

//==============================================================================
// Mode cycling
//==============================================================================
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        current_mode <= 3'd1;  // Start in watermark mode
        mode_changed <= 1'b0;
    end else begin
        mode_changed <= 1'b0;

        if (btn_pressed) begin
            if (current_mode >= NUM_MODES - 1)
                current_mode <= 3'd0;
            else
                current_mode <= current_mode + 1'b1;

            mode_changed <= 1'b1;
        end
    end
end

endmodule
