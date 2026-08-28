// Frozen-state video bench: the scan-out path (gsp_video + sdram_ctrl + chip
// model) driven by a stand-in for the GSP's raster counters and display
// registers, so a dumped MAME state can be rendered and diffed against the
// reference renderer without a GSP core.
`default_nettype none

module tb_video_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_pix,
    input  logic        cen_vid,
    // display registers from the state dump
    input  logic [15:0] r_hesync, r_heblnk, r_hsblnk, r_htotal, r_vesync, r_veblnk, r_vsblnk, r_vtotal,
    input  logic [15:0] r_dpyctl, r_dpystrt, r_dpytap,
    input  logic  [2:0] finescroll,
    input  logic  [1:0] palbank,
    // palette load
    input  logic        pal_we_rg, pal_we_b,
    input  logic  [9:0] pal_waddr,
    input  logic [15:0] pal_wdata,
    // video out
    output logic  [7:0] r, g, b,
    output logic        hsync, vsync, de,
    output logic        line_late,
    output logic [15:0] vcount_o,
    output logic [31:0] model_errors,
    output logic        dbg_line_start, dbg_b_wr, dbg_b_done, dbg_b_req, dbg_fetch_busy, dbg_need_second,
    output logic [10:0] dbg_col0,
    output logic  [8:0] dbg_rowaddr,
    output logic  [9:0] dbg_seg1_len, dbg_seg2_len, dbg_b_len,
    output logic [24:1] dbg_b_addr,
    output logic [15:0] dbg_dpyadr
);
    // ---- raster counters and DPYADR bookkeeping, as tms34010.cpp ----------
    logic [15:0] hcount, vcount, dpyadr;
    logic        line_start;
    always_ff @(posedge clk) begin
        line_start <= 1'b0;
        if (reset) begin
            hcount <= '0; vcount <= '0; dpyadr <= r_dpystrt;
        end else if (cen_vid) begin
            if (hcount == r_htotal) begin
                hcount <= '0;
                line_start <= 1'b1;
                // end of line: MAME's scanline_callback for the *next* line
                // (vcount+1) fires now; step DPYADR for the line just drawn
                if (vcount >= r_veblnk && vcount < r_vsblnk) begin
                    if (dpyadr[1:0] == 2'b00)
                        dpyadr <= ((dpyadr & 16'hfffc) - (r_dpyctl & 16'h03fc)) | (r_dpystrt & 16'h0003);
                    else
                        dpyadr <= (dpyadr & 16'hfffc) | ((dpyadr - 16'd1) & 16'h0003);
                end
                if (vcount == r_vtotal) vcount <= '0;
                else vcount <= vcount + 16'd1;
                if (vcount + 16'd1 == r_vsblnk) dpyadr <= r_dpystrt;
            end else
                hcount <= hcount + 16'd1;
        end
    end
    assign vcount_o = vcount;

    // ---- SDRAM ---------------------------------------------------------------
    wire  [15:0] dq;
    wire  [12:0] sa;
    wire   [1:0] sba;
    wire         dqml, dqmh, cs_n, we_n, ras_n, cas_n, cke, sclk;
    logic [24:1] c_addr  [6];
    logic        c_req   [6];
    logic        c_we    [6];
    logic [15:0] c_wdata [6];
    logic  [1:0] c_be    [6];
    logic        c_ack   [6];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx;
    logic        b_req, b_wr, b_done, sd_ready;
    logic [15:0] b_data;
    always_comb for (int i = 0; i < 6; i++) begin c_req[i] = 1'b0; c_addr[i] = '0; c_we[i] = 1'b0; c_wdata[i] = '0; c_be[i] = '0; end

    sdram_ctrl sdram (
        .clk(clk), .clk_pin(clk), .init(reset), .rd_late(1'b1), .burst_slow(1'b0), .ready(sd_ready),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(sba),
        .SDRAM_nCS(cs_n), .SDRAM_nWE(we_n), .SDRAM_nRAS(ras_n), .SDRAM_nCAS(cas_n), .SDRAM_CKE(cke), .SDRAM_CLK(sclk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done)
    );
    sdram_model #(.AW(22)) chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .cke(cke)
    );
    assign model_errors = chip.errors;

    logic hb, vb;
    gsp_video video (
        .clk(clk), .reset(reset | ~sd_ready), .cen_pix(cen_pix),
        .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .r_hesync(r_hesync), .r_heblnk(r_heblnk), .r_hsblnk(r_hsblnk),
        .r_vesync(r_vesync), .r_veblnk(r_veblnk), .r_vsblnk(r_vsblnk),
        .r_dpyctl(r_dpyctl), .r_dpystrt(r_dpystrt), .r_dpytap(r_dpytap), .r_dpyadr(dpyadr),
        .finescroll(finescroll), .palbank(palbank), .display_on(r_dpyctl[15]),
        .pal_we_rg(pal_we_rg), .pal_we_b(pal_we_b), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .r(r), .g(g), .b(b), .hsync(hsync), .vsync(vsync), .hblank(hb), .vblank(vb), .de(de),
        .dbg_line_late(line_late)
    );
    assign dbg_line_start = line_start; assign dbg_b_wr = b_wr; assign dbg_b_done = b_done; assign dbg_b_req = b_req;
    assign dbg_fetch_busy = video.fetch_busy; assign dbg_need_second = video.need_second; assign dbg_col0 = video.col0;
    assign dbg_rowaddr = video.rowaddr; assign dbg_seg1_len = video.seg1_len; assign dbg_seg2_len = video.seg2_len;
    assign dbg_b_len = b_len; assign dbg_b_addr = b_addr; assign dbg_dpyadr = dpyadr;
endmodule
