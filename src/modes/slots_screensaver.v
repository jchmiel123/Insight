// Slot Machine Screensaver
// Fun animated slot machine display for idle/screensaver mode
// Based on TangForge slots project

module slots_screensaver (
    input  wire        clk,          // 74.25 MHz pixel clock
    input  wire        rst_n,
    input  wire [11:0] px,           // Pixel X coordinate
    input  wire [11:0] py,           // Pixel Y coordinate
    input  wire        de,           // Data enable
    input  wire        frame_start,  // Frame sync pulse
    input  wire        btn_spin,     // Spin button
    input  wire        btn_bet,      // Bet button
    output reg  [7:0]  r,
    output reg  [7:0]  g,
    output reg  [7:0]  b
);

//==============================================================================
// Colors
//==============================================================================
localparam [23:0] COL_BG     = 24'h1A0A2E;  // Dark purple background
localparam [23:0] COL_GOLD   = 24'hFFD700;  // Gold
localparam [23:0] COL_BLACK  = 24'h000000;
localparam [23:0] COL_WHITE  = 24'hFFFFFF;
localparam [23:0] COL_CHERRY = 24'hFF2222;
localparam [23:0] COL_LEMON  = 24'hFFFF00;
localparam [23:0] COL_ORANGE = 24'hFF8800;
localparam [23:0] COL_PLUM   = 24'h8800FF;
localparam [23:0] COL_BELL   = 24'hFFDD00;
localparam [23:0] COL_BAR    = 24'h00FF00;
localparam [23:0] COL_SEVEN  = 24'hFF0000;
localparam [23:0] COL_WILD   = 24'h00FFFF;

//==============================================================================
// Button Debounce
//==============================================================================
reg [19:0] debounce_spin, debounce_bet;
reg btn_spin_stable, btn_bet_stable;
reg btn_spin_prev, btn_bet_prev;
wire spin_pressed, bet_pressed;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        debounce_spin <= 0;
        debounce_bet <= 0;
        btn_spin_stable <= 0;
        btn_bet_stable <= 0;
        btn_spin_prev <= 0;
        btn_bet_prev <= 0;
    end else begin
        // Debounce spin
        if (btn_spin)
            debounce_spin <= (debounce_spin != 20'hFFFFF) ? debounce_spin + 1 : debounce_spin;
        else
            debounce_spin <= 0;
        btn_spin_stable <= (debounce_spin == 20'hFFFFF);

        // Debounce bet
        if (btn_bet)
            debounce_bet <= (debounce_bet != 20'hFFFFF) ? debounce_bet + 1 : debounce_bet;
        else
            debounce_bet <= 0;
        btn_bet_stable <= (debounce_bet == 20'hFFFFF);

        btn_spin_prev <= btn_spin_stable;
        btn_bet_prev <= btn_bet_stable;
    end
end

assign spin_pressed = btn_spin_stable && !btn_spin_prev;
assign bet_pressed = btn_bet_stable && !btn_bet_prev;

//==============================================================================
// LFSR Random Number Generator
//==============================================================================
reg [31:0] lfsr;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        lfsr <= 32'hDEADBEEF;
    else
        lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
end

//==============================================================================
// Game State Machine
//==============================================================================
localparam STATE_IDLE  = 3'd0;
localparam STATE_SPIN  = 3'd1;
localparam STATE_STOP1 = 3'd2;
localparam STATE_STOP2 = 3'd3;
localparam STATE_STOP3 = 3'd4;
localparam STATE_WIN   = 3'd5;

reg [2:0]  game_state;
reg [15:0] credits;
reg [7:0]  bet;
reg [15:0] win_amount;
reg [7:0]  spin_timer;
reg [7:0]  state_timer;
reg [2:0]  reel1, reel2, reel3;
reg [2:0]  reel1_disp, reel2_disp, reel3_disp;
reg [23:0] frame_cnt;

// Frame counter
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)
        frame_cnt <= 0;
    else if (frame_start)
        frame_cnt <= frame_cnt + 1;
end

// Game logic (runs on frame ticks)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        game_state <= STATE_IDLE;
        credits <= 16'd100;
        bet <= 8'd1;
        win_amount <= 0;
        spin_timer <= 0;
        state_timer <= 0;
        reel1 <= 3'd0; reel2 <= 3'd1; reel3 <= 3'd2;
        reel1_disp <= 3'd0; reel2_disp <= 3'd1; reel3_disp <= 3'd2;
    end else if (frame_start) begin
        case (game_state)
            STATE_IDLE: begin
                if (spin_pressed && credits >= {8'd0, bet}) begin
                    credits <= credits - {8'd0, bet};
                    game_state <= STATE_SPIN;
                    spin_timer <= 8'd60;
                    win_amount <= 0;
                end
                if (bet_pressed) begin
                    case (bet)
                        8'd1:  bet <= 8'd5;
                        8'd5:  bet <= 8'd10;
                        8'd10: bet <= 8'd25;
                        default: bet <= 8'd1;
                    endcase
                end
            end

            STATE_SPIN: begin
                reel1_disp <= lfsr[2:0];
                reel2_disp <= lfsr[5:3];
                reel3_disp <= lfsr[8:6];
                if (spin_timer == 0) begin
                    reel1 <= lfsr[2:0];
                    reel1_disp <= lfsr[2:0];
                    game_state <= STATE_STOP1;
                    state_timer <= 8'd15;
                end else begin
                    spin_timer <= spin_timer - 1;
                end
            end

            STATE_STOP1: begin
                reel2_disp <= lfsr[5:3];
                reel3_disp <= lfsr[8:6];
                if (state_timer == 0) begin
                    reel2 <= lfsr[5:3];
                    reel2_disp <= lfsr[5:3];
                    game_state <= STATE_STOP2;
                    state_timer <= 8'd15;
                end else begin
                    state_timer <= state_timer - 1;
                end
            end

            STATE_STOP2: begin
                reel3_disp <= lfsr[8:6];
                if (state_timer == 0) begin
                    reel3 <= lfsr[8:6];
                    reel3_disp <= lfsr[8:6];
                    game_state <= STATE_STOP3;
                    state_timer <= 8'd5;
                end else begin
                    state_timer <= state_timer - 1;
                end
            end

            STATE_STOP3: begin
                // Calculate win
                if (reel1 == 3'd6 && reel2 == 3'd6 && reel3 == 3'd6)
                    win_amount <= {8'd0, bet} * 100;  // 777 JACKPOT
                else if (reel1 == reel2 && reel2 == reel3)
                    win_amount <= {8'd0, bet} * 10;   // Any triple
                else if (reel1 == reel2 || reel2 == reel3)
                    win_amount <= {8'd0, bet} * 2;    // Pair
                else if (reel1 == 3'd0 || reel2 == 3'd0 || reel3 == 3'd0)
                    win_amount <= {8'd0, bet};        // Cherry
                else
                    win_amount <= 0;
                game_state <= STATE_WIN;
                state_timer <= 8'd90;
            end

            STATE_WIN: begin
                if (state_timer == 0) begin
                    credits <= credits + win_amount;
                    game_state <= STATE_IDLE;
                end else begin
                    state_timer <= state_timer - 1;
                end
            end
        endcase
    end
end

//==============================================================================
// Symbol Color Lookup
//==============================================================================
function [23:0] sym_color;
    input [2:0] sym;
    case (sym)
        3'd0: sym_color = COL_CHERRY;
        3'd1: sym_color = COL_LEMON;
        3'd2: sym_color = COL_ORANGE;
        3'd3: sym_color = COL_PLUM;
        3'd4: sym_color = COL_BELL;
        3'd5: sym_color = COL_BAR;
        3'd6: sym_color = COL_SEVEN;
        3'd7: sym_color = COL_WILD;
    endcase
endfunction

//==============================================================================
// Graphics Rendering
//==============================================================================
// Reel positions
localparam REEL_W = 150;
localparam REEL_H = 200;
localparam REEL_GAP = 50;
localparam REEL_Y = 200;
localparam REEL1_X = (1280 - 3*REEL_W - 2*REEL_GAP) / 2;
localparam REEL2_X = REEL1_X + REEL_W + REEL_GAP;
localparam REEL3_X = REEL2_X + REEL_W + REEL_GAP;

// Check reel bounds
wire in_reel1 = (px >= REEL1_X) && (px < REEL1_X + REEL_W) && (py >= REEL_Y) && (py < REEL_Y + REEL_H);
wire in_reel2 = (px >= REEL2_X) && (px < REEL2_X + REEL_W) && (py >= REEL_Y) && (py < REEL_Y + REEL_H);
wire in_reel3 = (px >= REEL3_X) && (px < REEL3_X + REEL_W) && (py >= REEL_Y) && (py < REEL_Y + REEL_H);

// Symbol positions within reels
wire [7:0] sym1_cx = (px - REEL1_X);
wire [7:0] sym2_cx = (px - REEL2_X);
wire [7:0] sym3_cx = (px - REEL3_X);
wire [7:0] sym_cy = (py - REEL_Y);

// Symbol circles
wire in_sym1 = in_reel1 && (sym1_cx > 25) && (sym1_cx < 125) && (sym_cy > 50) && (sym_cy < 150);
wire in_sym2 = in_reel2 && (sym2_cx > 25) && (sym2_cx < 125) && (sym_cy > 50) && (sym_cy < 150);
wire in_sym3 = in_reel3 && (sym3_cx > 25) && (sym3_cx < 125) && (sym_cy > 50) && (sym_cy < 150);

// Borders
wire in_border1 = in_reel1 && ((sym1_cx < 5) || (sym1_cx > REEL_W-6) || (sym_cy < 5) || (sym_cy > REEL_H-6));
wire in_border2 = in_reel2 && ((sym2_cx < 5) || (sym2_cx > REEL_W-6) || (sym_cy < 5) || (sym_cy > REEL_H-6));
wire in_border3 = in_reel3 && ((sym3_cx < 5) || (sym3_cx > REEL_W-6) || (sym_cy < 5) || (sym_cy > REEL_H-6));

// Title bar
wire in_title = (py >= 50) && (py < 150) && (px >= 400) && (px < 880);

// Credits bar
wire in_credits = (py >= 500) && (py < 560) && (px >= 200) && (px < 1080);

// Generate pixel
reg [23:0] pixel;

always @(posedge clk) begin
    if (!de) begin
        pixel <= COL_BG;
    end else begin
        // Default background
        pixel <= COL_BG;

        // Title bar (gold)
        if (in_title)
            pixel <= COL_GOLD;

        // Reel backgrounds
        if (in_reel1 || in_reel2 || in_reel3)
            pixel <= COL_BLACK;

        // Reel borders
        if (in_border1 || in_border2 || in_border3)
            pixel <= COL_GOLD;

        // Symbol circles
        if (in_sym1) pixel <= sym_color(reel1_disp);
        if (in_sym2) pixel <= sym_color(reel2_disp);
        if (in_sym3) pixel <= sym_color(reel3_disp);

        // Credits bar
        if (in_credits)
            pixel <= 24'h220022;

        // Win flash effect
        if (game_state == STATE_WIN && win_amount > 0 && frame_cnt[3]) begin
            if (in_reel1 || in_reel2 || in_reel3)
                pixel <= COL_GOLD;
        end
    end
end

// Output RGB (note: BGR order for some displays)
always @(posedge clk) begin
    r <= pixel[7:0];
    g <= pixel[15:8];
    b <= pixel[23:16];
end

endmodule
