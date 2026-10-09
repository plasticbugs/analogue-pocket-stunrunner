//------------------------------------------------------------------------------
// The board's own raster, for the Analogizer, from the picture the Pocket gets.
//
// The core hands the Pocket each line's 512 visible pixels back to back at
// 24 MHz (clk_sys / 4) from the moment the visible window opens: the Pocket
// counts DE-high clocks, not time (gsp_video.sv).  The line and frame are the
// board's -- hsync, vsync and vblank keep their places -- but the pixels fill
// only the first 21.3 us of the 51.2 us window.  A CRT draws time, so the
// Analogizer has to get them at the board's 10 MHz instead.
//
// Each line's pixels are written into a one-line RAM as they arrive (clk_sys)
// and read back on the Analogizer's own clock, 40 MHz from the same PLL, one
// dot every four clocks: a line of HTOTAL dots is exactly HTOTAL * 4 clocks,
// the rate the core's 10 MHz pixel accumulator keeps on average.  The read
// line is the source's, started OFFSET dots after its hsync, so the 24 MHz
// write of a pixel is always well ahead of its 10 MHz read and finished long
// before the next line's begins: one buffer is enough.  hsync and the visible
// window are re-made from the dot counter (the game's fixed register values,
// docs/hardware.md 4.3); vsync and vblank are the source's, taken at the start
// of each line.  The dot counter free-runs and is put back on the source's
// hsync only when it has drifted by more than a clock -- in steady state never,
// as both rates come from one PLL.
//------------------------------------------------------------------------------
`default_nettype none

module ana_retime #(
    parameter int HTOTAL = 634,     // dots a line (HTOTAL register 0x13c, 2 dots a clock)
    parameter int HS_LEN = 38,      // hsync, dots from the line's start (HESYNC 0x13)
    parameter int HB_END = 110,     // first visible dot (HEBLNK 0x37)
    parameter int VIS    = 512,     // visible dots (HSBLNK 0x137 - HEBLNK)
    parameter int OFFSET = 10       // dots from the source's hsync to this line's start
) (
    // the Pocket's stream (clk_sys): one pixel per s_ce while s_de
    input  wire         clk_sys,
    input  wire         s_ce,
    input  wire  [23:0] s_rgb,
    input  wire         s_de,
    input  wire         s_hs,
    input  wire         s_vs,
    input  wire         s_vb,

    // the board's raster (clk_ana = 4 x the dot rate)
    input  wire         clk_ana,
    output logic        ce,         // one clock a dot, outputs already showing it
    output logic [23:0] rgb,
    output logic        hs,
    output logic        vs,
    output logic        hb,
    output logic        vb
);
    localparam int L   = HTOTAL * 4;            // clocks a line
    localparam int EXP = (HTOTAL - OFFSET) * 4; // where the counter is at the source's hsync

    // ------------------------------------------------------------- write
    logic [23:0] line_ram [512];
    logic  [8:0] wa;
    initial wa = 9'd0;
    always @(posedge clk_sys)
        if (s_ce) begin
            if (s_de) begin
                line_ram[wa] <= s_rgb;
                if (wa != 9'd511) wa <= wa + 9'd1;
            end else
                wa <= 9'd0;
        end

    // ------------------------------------------------- source syncs, here
    logic [2:0] hs_s;               // the third stage is for the edge
    logic [1:0] vs_s, vb_s;
    always @(posedge clk_ana) begin
        hs_s <= {hs_s[1:0], s_hs};
        vs_s <= {vs_s[0], s_vs};
        vb_s <= {vb_s[0], s_vb};
    end
    wire h_rise = hs_s[1] && !hs_s[2];

    // ------------------------------------------------------------ read
    logic [11:0] p;                 // clock within the line, 0 .. L-1
    initial p = '0;
    wire  [9:0] dot  = 10'(p >> 2);
    wire  [9:0] nd   = (dot == 10'(HTOTAL - 1)) ? 10'd0 : dot + 10'd1;   // the next dot
    wire        nvis = (nd >= 10'(HB_END)) && (nd < 10'(HB_END + VIS));
    wire  [8:0] nx   = 9'(nd - 10'(HB_END));   // the visible dot, while nvis
    logic [23:0] q;
    logic        line_vs, line_vb;

    always @(posedge clk_ana) begin
        // a clock early is a clock: |error| <= 1 is the sampling of the
        // source's 24 MHz hsync, not drift
        if (h_rise && p != 12'(EXP) && p != 12'(EXP - 1) && p != 12'(EXP + 1))
            p <= 12'(EXP + 1);
        else
            p <= (p == 12'(L - 1)) ? 12'd0 : p + 12'd1;

        ce <= 1'b0;
        if (p[1:0] == 2'd2) q <= line_ram[nx];
        if (p[1:0] == 2'd3) begin
            if (nd == 10'd0) begin line_vs <= vs_s[1]; line_vb <= vb_s[1]; end
            ce  <= 1'b1;
            rgb <= nvis ? q : 24'h0;
            hs  <= (nd < 10'(HS_LEN));
            hb  <= !nvis;
            vs  <= (nd == 10'd0) ? vs_s[1] : line_vs;
            vb  <= (nd == 10'd0) ? vb_s[1] : line_vb;
        end
    end
endmodule
