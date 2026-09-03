//------------------------------------------------------------------------------
// Digital-to-analog ramp for the yoke: what other Pocket / MiSTer cores do for
// analog steering from a D-pad. Holding a direction moves the axis toward the
// extreme at a fixed rate (full lock in ~0.7 s); releasing it returns the axis
// to centre faster (~0.25 s). A short tap is a small, brief deflection instead
// of hard lock. Real analog sticks bypass this in core_top.
//------------------------------------------------------------------------------
`default_nettype none

module dpad_ramp #(
    parameter [7:0] OUT_STEP = 8'd1, // per tick toward the extreme: 127 ticks = 0.69 s at 183 ticks/s
    parameter [7:0] RET_STEP = 8'd3  // per tick back to centre: 43 ticks = 0.23 s
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       tick,          // 183 Hz (96 MHz / 2^19), shared between axes
    input  wire       neg,           // toward 0x00 (left / lower)
    input  wire       pos,           // toward 0xff (right / raise)
    output reg  [7:0] value          // 0x80 centre
);
    always @(posedge clk) begin
        if (reset) value <= 8'h80;
        else if (tick) begin
            if (neg && !pos)      value <= (value > OUT_STEP)          ? value - OUT_STEP : 8'h00;
            else if (pos && !neg) value <= (value < 8'hff - OUT_STEP)  ? value + OUT_STEP : 8'hff;
            else if (value > 8'h80) value <= (value - 8'h80 > RET_STEP) ? value - RET_STEP : 8'h80;
            else if (value < 8'h80) value <= (8'h80 - value > RET_STEP) ? value + RET_STEP : 8'h80;
        end
    end
endmodule
