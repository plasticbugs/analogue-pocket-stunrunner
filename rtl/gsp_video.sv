//------------------------------------------------------------------------------
// Frame-buffer scan-out for the multisync board (docs/hardware.md section 4.3).
//
// The real board's VRAM has a serial port: the TMS34010 latches a row into
// the VRAM shift registers at the start of each line and the PSP clocks
// pixels out. Here VRAM lives in SDRAM, so each line is fetched with a burst
// into one half of a double-buffered line RAM during the previous line, then
// streamed through the palette at the 10 MHz pixel clock.
//
// Per line, from the GSP's registers sampled on line_start (which is also
// when the GSP steps DPYADR, so the value seen here is the one MAME draws
// that line with):
//   a        = DPYADR ^ (ORG ? 0 : 0xfffc)
//   rowaddr  = a >> 4                      (2 KB VRAM row = 1024 words)
//   coladdr  = ((a & 0x7c) << 4) | (DPYTAP & 0x3fff)
//   yoffset  = (DPYSTRT - DPYADR) & 3
//   col0     = (yoffset << 9) + ((coladdr & 0xff) << 3) - 7 + finescroll
//   pixel(x) = VRAM byte [rowaddr*2048 + ((col0 + x) & 0x7ff)]
// The 2048-pixel row wraps, so a line can need two bursts.
//------------------------------------------------------------------------------
`default_nettype none

module gsp_video (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,          // 10 MHz pixel enable (2 per video clock)

    // from the GSP core
    input  logic [15:0] hcount, vcount,
    input  logic        line_start,
    input  logic [15:0] r_hesync, r_heblnk, r_hsblnk, r_vesync, r_veblnk, r_vsblnk,
    input  logic [15:0] r_dpyctl, r_dpystrt, r_dpytap, r_dpyadr,
    // from the control_hi latch
    input  logic  [2:0] finescroll,
    input  logic  [1:0] palbank,
    input  logic        display_on,       // DPYCTL.ENV

    // palette write ports (GSP palette RAM writes, already bank-resolved)
    input  logic        pal_we_rg, pal_we_b,
    input  logic  [9:0] pal_waddr,
    input  logic [15:0] pal_wdata,        // {r, g} for the lo RAM, {x, b} for the hi RAM

    // SDRAM burst port
    output logic [24:1] b_addr,
    output logic  [9:0] b_len,
    output logic        b_req,
    input  logic        b_wr,
    input  logic  [9:0] b_idx,
    input  logic [15:0] b_data,
    input  logic        b_done,

    // video out (valid on cen_out -- one pulse per emitted pixel, clk/4)
    output logic        cen_out,
    output logic  [7:0] r, g, b,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic        dbg_line_late      // pulse: a fetch was still running when the next line started
);
    localparam [24:1] VRAM_BASE = 24'h100000;   // byte 0x200000 >> 1

    // ---- palette RAM 1024 x 24 (block RAM, 1-cycle read) -----------------------
    logic [15:0] pal_rg_q;
    logic  [7:0] pal_b_q;
    logic  [7:0] pix;
    sdpram #(.AW(10), .DW(16)) pal_rg (.clk(clk), .we(pal_we_rg), .waddr(pal_waddr), .wdata(pal_wdata),       .raddr({palbank, pix}), .q(pal_rg_q));
    sdpram #(.AW(10), .DW(8))  pal_b  (.clk(clk), .we(pal_we_b),  .waddr(pal_waddr), .wdata(pal_wdata[7:0]),  .raddr({palbank, pix}), .q(pal_b_q));
    // ---- line buffers: 2 x 512 words, written by burst index ------------------
    logic        fill_sel;          // buffer being filled
    logic        show_sel;          // buffer being displayed
    logic [15:0] lq0, lq1;
    logic  [8:0] lb_raddr;
    logic  [9:0] widx;
    sdpram #(.AW(9), .DW(16)) lbuf0 (.clk(clk), .we(b_wr && !fill_sel), .waddr(widx[8:0]), .wdata(b_data), .raddr(lb_raddr), .q(lq0));
    sdpram #(.AW(9), .DW(16)) lbuf1 (.clk(clk), .we(b_wr &&  fill_sel), .waddr(widx[8:0]), .wdata(b_data), .raddr(lb_raddr), .q(lq1));

    // ---- per-line fetch ------------------------------------------------------
    logic [10:0] col0;              // start pixel within the 2048-px row
    logic  [7:0] rowaddr;           // 256 rows of 2 KB (the 512 KB VRAM is mirrored above)
    logic        need_second;
    logic [24:1] seg1_addr, seg2_addr;
    logic  [9:0] seg1_len, seg2_len;
    logic  [9:0] seg1_words;
    logic  [1:0] fst;               // 0 idle, 1 seg1, 2 seg2
    logic        fetch_busy;
    logic        fetch_pending;     // computed, not yet started
    logic        next_visible;      // the line being fetched is visible
    logic        show_visible;

    // The line to display next is the one whose start is coming: fetch for
    // line (vcount+1) during line vcount. DPYADR read here is the value for
    // the *current* line (the GSP steps it on line_start); the value for the
    // next line is what it will step to -- so mirror the step. Simpler and
    // exact: fetch at line_start for the current line and display it one
    // line later; i.e. the picture is delayed by one raster line, which the
    // Pocket's scaler cannot tell.
    wire [15:0] a = r_dpyadr ^ (r_dpyctl[10] ? 16'h0000 : 16'hfffc);
    // coladdr = ((a & 0x7c) << 4) | DPYTAP, of which only the low byte is used:
    // bits 7:6 come from a[3:2], the rest from DPYTAP
    wire  [7:0] coladdr8 = {a[3:2], 6'd0} | r_dpytap[7:0];
    wire  [1:0] yoffset  = r_dpystrt[1:0] - r_dpyadr[1:0];
    wire [10:0] col_calc = {yoffset, 9'd0} + {coladdr8, 3'd0} - 11'd7 + {8'd0, finescroll};

    // fetch state machine
    always_ff @(posedge clk) begin
        b_req <= b_req;   // level
        if (reset) begin
            fst <= 2'd0; b_req <= 1'b0; fetch_busy <= 1'b0; fetch_pending <= 1'b0;
            fill_sel <= 1'b0; show_sel <= 1'b1; dbg_line_late <= 1'b0;
            next_visible <= 1'b0; show_visible <= 1'b0;
        end else begin
            dbg_line_late <= 1'b0;
            if (line_start) begin
                // swap buffers: what was filled is now shown
                if (fetch_busy) dbg_line_late <= 1'b1;
                show_sel     <= fill_sel;
                fill_sel     <= ~fill_sel;
                show_visible <= next_visible;
                // set up the fetch for this line (displayed one line later)
                next_visible <= display_on && (vcount >= r_veblnk) && (vcount < r_vsblnk);
                rowaddr      <= a[11:4];
                col0         <= col_calc;
                fetch_pending <= 1'b1;
            end
            if (fetch_pending && !fetch_busy) begin
                fetch_pending <= 1'b0;
                if (next_visible) begin
                    // words from floor(col0/2); 257 words cover any odd start
                    seg1_addr   <= VRAM_BASE + {6'd0, rowaddr, col0[10:1]};
                    // words to the end of the 1024-word row
                    if ((11'd1024 - {1'b0, col0[10:1]}) >= 11'd257) begin
                        seg1_len <= 10'd257; need_second <= 1'b0; seg2_len <= '0;
                    end else begin
                        seg1_len <= 10'(11'd1024 - {1'b0, col0[10:1]});
                        seg2_len <= 10'(11'd257 - (11'd1024 - {1'b0, col0[10:1]}));
                        need_second <= 1'b1;
                    end
                    seg2_addr  <= VRAM_BASE + {6'd0, rowaddr, 10'd0};
                    fetch_busy <= 1'b1;
                    fst        <= 2'd1;
                end
            end
            case (fst)
                2'd1: begin
                    b_addr <= seg1_addr; b_len <= seg1_len; b_req <= 1'b1;
                    seg1_words <= seg1_len;
                    if (b_done) begin
                        b_req <= 1'b0;
                        if (need_second) fst <= 2'd2;
                        else begin fst <= 2'd0; fetch_busy <= 1'b0; end
                    end
                end
                2'd2: begin
                    b_addr <= seg2_addr; b_len <= seg2_len; b_req <= 1'b1;
                    if (b_done) begin
                        b_req <= 1'b0; fst <= 2'd0; fetch_busy <= 1'b0;
                    end
                end
                default: b_req <= 1'b0;
            endcase
            // b_done arrives with b_req high; drop req the cycle after (above)
        end
    end

    // burst data into the fill buffer; segment 2 indexes continue after seg 1
    assign widx = (fst == 2'd2) ? (b_idx + seg1_words) : b_idx;   // [9] unused: a line never exceeds 512 words

    // ---- pixel pipeline ------------------------------------------------------
    // The Pocket counts DE-high video_rgb_clock cycles as pixels. Its video
    // clock is clk/4 (24 MHz) while the machine's pixels are 10 MHz, which is
    // not an integer ratio -- a pixel held across 2-3 video clocks was counted
    // 2-3 times, so the scaler, told 512 in video.json, kept only the left part
    // of every line. Every other Pocket core emits exactly one pixel per video
    // clock (Punch-Out!! 24 MHz, Xenophobe 20 MHz, Time Pilot 6.144 MHz, each
    // equal to its own pixel rate); do the same here. The line has already been
    // fetched a line ahead, so it is read out back-to-back at clk/4 starting
    // when the visible window opens.
    //
    // The line and frame cadence is untouched -- hcount/vcount, the GSP's
    // interrupts and the 60.20 Hz refresh all still come from cen_pix -- so
    // only the position of the active pixels within the line moves earlier
    // (512 px in 21.3 us of the 63.4 us line). A framebuffer scaler cannot see
    // that; it sees HS, then 512 DE cycles, then the rest of the line.
    logic [15:0] hcount_d;                // hcount at the previous pixel: same value = second pixel of the clock
    logic        rd_odd, show_d;
    logic        de_1, de_2, hs_1, hs_2, vs_1, vs_2, hb_1, hb_2, vb_1, vb_2;
    logic        col_odd;                 // start pixel parity of the shown line
    logic        col_odd_next;

    wire in_h  = (hcount >= r_heblnk) && (hcount < r_hsblnk);
    wire hs_n  = (hcount < r_hesync);     // sync active for hcount < HESYNC
    wire vs_n  = (vcount < r_vesync);
    // the picture is one raster line behind the GSP's counters (fetched during
    // line v, shown during v+1), so vertical sync follows it by one line too
    logic vs_line;

    // clk/4 output beat, the rate the Pocket samples video_rgb at
    logic [1:0] pdiv;
    always_ff @(posedge clk) pdiv <= reset ? 2'd0 : pdiv + 2'd1;
    wire cen4 = (pdiv == 2'd3);
    assign cen_out = cen4;

    // visible-window readout: vis_len pixels, back to back, from the window's
    // opening edge. vis_len is taken from the GSP's own blanking registers (two
    // pixels per video clock), so it is exactly the pixel count the previous
    // cen_pix-paced loop produced -- 512 as the game programs them.
    logic  [9:0] vis_len;
    logic        vis_q, out_run;
    logic  [9:0] out_cnt;
    wire         vis_now = in_h && show_visible;

    always_ff @(posedge clk) begin
        if (reset) begin
            col_odd <= 1'b0; col_odd_next <= 1'b0; hcount_d <= '0; vs_line <= 1'b0;
            vis_q <= 1'b0; out_run <= 1'b0; out_cnt <= '0; vis_len <= 10'd512;
        end else begin
            if (line_start) begin
                col_odd <= col_odd_next; col_odd_next <= col0[0]; vs_line <= vs_n;
                vis_len <= {(r_hsblnk[8:0] - r_heblnk[8:0]), 1'b0};
            end
            if (cen_pix) begin
                hcount_d <= hcount;
                vis_q    <= vis_now;
            end
            if (cen_pix && vis_now && !vis_q) begin
                out_run <= 1'b1; out_cnt <= '0;          // window just opened
            end else if (cen4 && out_run) begin
                out_cnt <= out_cnt + 10'd1;
                if (out_cnt + 10'd1 == vis_len) out_run <= 1'b0;
            end
        end
    end

    // stage 1: read the line word for pixel x (both buffers; the select is
    // applied on the registered outputs so the RAMs infer cleanly)
    wire  [9:0] xidx  = out_cnt + {9'd0, col_odd};     // byte index into the 514-byte window
    wire [15:0] lw_q = show_d ? lq1 : lq0;
    always_ff @(posedge clk) begin
        if (cen4) begin
            lb_raddr <= xidx[9:1];            // RAM output follows one clk later, i.e. by the next pixel
            rd_odd  <= xidx[0];
            show_d  <= show_sel;
            de_1 <= out_run;
            hs_1 <= hs_n; vs_1 <= vs_line; hb_1 <= ~out_run; vb_1 <= ~show_visible;
            // stage 2: palette
            pix  <= rd_odd ? lw_q[15:8] : lw_q[7:0];
            de_2 <= de_1; hs_2 <= hs_1; vs_2 <= vs_1; hb_2 <= hb_1; vb_2 <= vb_1;
            // stage 3: palette RAM output (pix registered at stage 2; the RAM
            // reads on every clk, so its output is valid before the next pixel)
            {r, g, b} <= de_2 ? {pal_rg_q, pal_b_q} : 24'd0;
            de <= de_2; hsync <= hs_2; vsync <= vs_2; hblank <= hb_2; vblank <= vb_2;
        end
    end
endmodule
