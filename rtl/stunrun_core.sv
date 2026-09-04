//------------------------------------------------------------------------------
// S.T.U.N. Runner: the whole machine (docs/hardware.md), platform-agnostic.
//
//   stunrun_main   68010 + main-board latches, RAM, ZRAM, ADC, IRQs
//   tms34010       GSP (rtl/gsp) + gsp_bus (VRAM/expander/palette glue) + gsp_video (scan-out)
//   adsp2100       ADSP board (rtl/adsp) + SIM/SOM glue here
//   jsa2           JSA II sound board (rtl/jsa)
//   sdram_ctrl     one SDRAM for 68k ROM, GSP VRAM, SIM ROM, OKI ROM
//
// SDRAM clients (fixed order, round-robin): 0 GSP, 1 68010 ROM, 2 SIM, 3 OKI,
// 4 loader, 5 spare. The display line fetch uses the burst port.
//------------------------------------------------------------------------------
`default_nettype none

module stunrun_core #(
    parameter DBG_OVERLAY = 1    // on-panel PC/flags overlay (METHODOLOGY 4); 105 ALUTs, compiled out of the Pocket build
) (
    input  logic        clk,            // 96 MHz
    input  logic        clk_sdram,      // 96 MHz phase-shifted, SDRAM pin clock
    input  logic        hw_reset,       // PLL not locked: everything, including the loader path
    input  logic        reset,          // machine reset (menu action / host)
    input  logic        rd_late,        // SDRAM read capture diagnostic
    input  logic        burst_slow,     // SDRAM burst spacing diagnostic
    input  logic        overlay,        // diagnostic overlay on the bottom lines

    // ROM image download (byte writes, tools/mra_build.py layout)
    input  logic        dl_active,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_we,

    // NVRAM (ZRAM) external port, 4 KB
    input  logic [11:0] nv_addr,
    input  logic        nv_we,
    input  logic  [7:0] nv_wdata,
    output logic  [7:0] nv_rdata,
    output logic        nv_dirty,

    // controls
    input  logic        coin1, coin2, service, start, fire, boost,   // active high
    input  logic  [7:0] stick_x, stick_y,                             // 0x80 centre
    input  logic  [7:0] sw1,

    // video (valid on cen_pix -- one pulse per emitted pixel, clk/4)
    output logic        cen_pix,
    output logic  [7:0] r, g, b,
    output logic        hsync, vsync, hblank, vblank, de,

    // audio
    output logic signed [15:0] audio,
    output logic        audio_valid,

    // SDRAM pins
    inout  wire  [15:0] dram_dq,
    output logic [12:0] dram_a,
    output logic  [1:0] dram_ba,
    output logic        dram_dqm_l, dram_dqm_h,
    output logic        dram_cs_n, dram_ras_n, dram_cas_n, dram_we_n, dram_cke, dram_clk,

    // diagnostics
    output logic [31:0] dbg_68k_pc,
    output logic [31:0] dbg_gsp_pc,
    output logic [13:0] dbg_adsp_pc,
    output logic  [7:0] dbg_flags       // {sdram_ready, gsp_reset_n, adsp_halt, adsp_reset, line_late, snd_int, gsp_int, adsp_int}
);
    // ------------------------------------------------------------------------
    // clocks and resets
    // ------------------------------------------------------------------------
    logic cen_8m, cen_6m, cen_vid, cen_ym, cen_oki;
    logic cen_pix_10m;   // 10 MHz machine pixel rate; the core's cen_pix output is the clk/4 scan-out beat
    clk_enables cen (
        .clk(clk), .reset(hw_reset),
        .cen_8m(cen_8m), .cen_6m(cen_6m), .cen_vid(cen_vid), .cen_pix(cen_pix_10m),
        .cen_snd(), .cen_ym(cen_ym), .cen_oki(cen_oki)
    );
    logic sd_ready, wdog_reset;
    // the machine stays in reset while loading and until the SDRAM is up; the
    // board's watchdog reboots everything when the 68k stops kicking it
    wire  mreset = reset | hw_reset | dl_active | ~sd_ready | wdog_reset;

    // ------------------------------------------------------------------------
    // SDRAM
    // ------------------------------------------------------------------------
    logic [24:1] c_addr  [6];
    logic        c_req   [6];
    logic        c_we    [6];
    logic [15:0] c_wdata [6];
    logic  [1:0] c_be    [6];
    logic        c_ack   [6];
    logic [15:0] sd_rdata;
    logic [24:1] b_addr;
    logic  [9:0] b_len, b_idx, b_widx;
    logic        b_req, b_wr, b_done, b_we;
    logic  [1:0] b_be;
    logic [15:0] b_data, b_wdata;
    // Burst port arbiter: the display line fetch (vb_*) first, the GSP bus's
    // shift-register rows (sb_*) otherwise; a grant lasts one request, and the
    // GSP side asks in 32-word pieces so the display waits at most one piece.
    logic [24:1] vb_addr, sb_addr;
    logic  [9:0] vb_len, sb_len;
    logic        vb_req, sb_req, sb_we, vb_wr, sb_wr, vb_done, sb_done;
    logic [15:0] sb_wdata;
    logic  [1:0] sb_be;
    logic        bsel, bbusy;
    // row fast path between the GSP core and the memory glue
    logic        rc_req, rc_fill, rc_transp, rc_ack;
    logic [31:0] rc_src, rc_dst;
    logic [15:0] rc_len, rc_color;
    always_ff @(posedge clk) begin
        if (mreset) begin bbusy <= 1'b0; bsel <= 1'b0; end
        else if (!bbusy) begin
            if (vb_req)      begin bbusy <= 1'b1; bsel <= 1'b0; end
            else if (sb_req) begin bbusy <= 1'b1; bsel <= 1'b1; end
        end else if (b_done) bbusy <= 1'b0;
    end
    assign b_req   = bbusy && (bsel ? sb_req : vb_req);
    assign b_addr  = bsel ? sb_addr : vb_addr;
    assign b_len   = bsel ? sb_len  : vb_len;
    assign b_we    = bsel && sb_we;
    assign b_wdata = sb_wdata;
    assign b_be    = sb_be;
    assign vb_wr   = b_wr   && !bsel;
    assign sb_wr   = b_wr   &&  bsel;
    assign vb_done = b_done && !bsel;
    assign sb_done = b_done &&  bsel;

    sdram_ctrl sdram (
        .clk(clk), .clk_pin(clk_sdram), .init(hw_reset), .rd_late(rd_late), .burst_slow(burst_slow), .ready(sd_ready),
        .SDRAM_DQ(dram_dq), .SDRAM_A(dram_a), .SDRAM_DQML(dram_dqm_l), .SDRAM_DQMH(dram_dqm_h), .SDRAM_BA(dram_ba),
        .SDRAM_nCS(dram_cs_n), .SDRAM_nWE(dram_we_n), .SDRAM_nRAS(dram_ras_n), .SDRAM_nCAS(dram_cas_n),
        .SDRAM_CKE(dram_cke), .SDRAM_CLK(dram_clk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done),
        .b_we(b_we), .b_wdata(b_wdata), .b_be(b_be), .b_widx(b_widx)
    );

    // ------------------------------------------------------------------------
    // loader: bytes 0x000000-0x15ffff to SDRAM (client 4), 0x160000-0x16ffff
    // to the JSA program ROM, 0x170000-0x170fff to ZRAM (factory defaults)
    // ------------------------------------------------------------------------
    logic        dl_we_d;
    wire         dl_pulse = dl_we && !dl_we_d;
    wire         dl_is_sdram = (dl_addr < 25'h160000);
    wire         dl_is_jsa   = (dl_addr[24:16] == 9'h016);
    wire         dl_is_zram  = (dl_addr[24:12] == 13'h0170);
    // a small FIFO decouples the APF's byte cadence from SDRAM service time
    logic [32:0] wfifo [0:63];
    logic  [6:0] wf_wp, wf_rp;
    wire         wf_empty = (wf_wp == wf_rp);
    always_ff @(posedge clk) begin
        dl_we_d <= dl_we;
        if (hw_reset) begin wf_wp <= '0; wf_rp <= '0; c_req[4] <= 1'b0; end
        else begin
            if (dl_pulse && dl_is_sdram) begin
                wfifo[wf_wp[5:0]] <= {dl_addr, dl_data};
                wf_wp <= wf_wp + 7'd1;
            end
            if (!c_req[4] && !wf_empty) begin
                c_addr[4]  <= wfifo[wf_rp[5:0]][32:9];
                c_wdata[4] <= {wfifo[wf_rp[5:0]][7:0], wfifo[wf_rp[5:0]][7:0]};
                // 68010 ROM (below 0x0c0000) is big-endian: the even byte sits on
                // D15:8; the SIM and OKI images are little-endian byte streams
                c_be[4]    <= (wfifo[wf_rp[5:0]][32:9] < 24'h060000) ? (wfifo[wf_rp[5:0]][8] ? 2'b01 : 2'b10)
                                                                     : (wfifo[wf_rp[5:0]][8] ? 2'b10 : 2'b01);
                c_we[4]    <= 1'b1;
                c_req[4]   <= 1'b1;
                wf_rp      <= wf_rp + 7'd1;
            end else if (c_req[4] && c_ack[4]) begin
                c_req[4] <= 1'b0;
            end
        end
    end
    assign c_req[5] = 1'b0; assign c_addr[5] = '0; assign c_we[5] = 1'b0; assign c_wdata[5] = '0; assign c_be[5] = '0;

    // ------------------------------------------------------------------------
    // 68010 main board
    // ------------------------------------------------------------------------
    logic  [1:0] host_addr;
    logic        host_rd, host_wr, host_ready;
    logic [15:0] host_wdata, host_rdata;
    logic        gsp_int, gsp_reset_n;
    logic [12:0] pm_addr, dm_addr;
    logic        pm_we, dm_we, som_we;
    logic [23:0] pm_wdata, pm_rdata;
    logic  [1:0] som_be;
    logic [15:0] dm_wdata, dm_rdata, som_wdata, som_rdata_b;
    logic [13:0] som_addr_b;
    logic        adsp_bank, adsp_halt, adsp_reset, adsp_int, adsp_int_clr, adsp_xflag;
    logic        snd_cmd_wr, snd_resp_rd, snd_int, snd_reset;
    logic        snd_busy;
    logic  [7:0] snd_cmd, snd_resp;
    logic        v_hblank, v_vblank;
    logic [11:0] nv_addr_m;
    logic        nv_we_m;
    logic  [7:0] nv_wdata_m;

    // ZRAM: the loader's factory defaults share the external port. The image
    // holds 200E (2 KB) then 210E (2 KB) as separate blocks; the 68k sees them
    // as the high and low bytes of one word, so byte o of 200E lands at 2o
    // and byte o of 210E at 2o+1 (the layout of the save file as well).
    assign nv_addr_m  = (dl_active && dl_is_zram) ? {dl_addr[10:0], dl_addr[11]} : nv_addr;
    assign nv_we_m    = (dl_active && dl_is_zram) ? dl_pulse : nv_we;
    assign nv_wdata_m = (dl_active && dl_is_zram) ? dl_data : nv_wdata;

    wire [7:0] in0 = {~coin1, ~coin2, ~service, 4'b1111, 1'b1};

    stunrun_main main (
        .clk(clk), .reset(mreset), .cen_8m(cen_8m),
        .rom_addr(c_addr[1]), .rom_req(c_req[1]), .rom_rdata(sd_rdata), .rom_ack(c_ack[1]),
        .in0(in0), .sw1(sw1), .a80000({start, boost, fire}), .stick_x(stick_x), .stick_y(stick_y),
        .vblank_n(~v_vblank), .hblank_n(~v_hblank),
        .nv_addr(nv_addr_m), .nv_we(nv_we_m), .nv_wdata(nv_wdata_m), .nv_rdata(nv_rdata), .nv_dirty(nv_dirty),
        .host_addr(host_addr), .host_rd(host_rd), .host_wr(host_wr), .host_wdata(host_wdata),
        .host_rdata(host_rdata), .host_ready(host_ready), .gsp_int(gsp_int), .gsp_reset_n(gsp_reset_n),
        .pm_addr(pm_addr), .pm_we(pm_we), .pm_wdata(pm_wdata), .pm_rdata(pm_rdata),
        .dm_addr(dm_addr), .dm_we(dm_we), .dm_wdata(dm_wdata), .dm_rdata(dm_rdata),
        .som_addr(som_addr_b), .som_we(som_we), .som_be(som_be), .som_wdata(som_wdata), .som_rdata(som_rdata_b),
        .adsp_bank(adsp_bank), .adsp_halt(adsp_halt), .adsp_reset(adsp_reset),
        .adsp_int(adsp_int), .adsp_int_clr(adsp_int_clr), .adsp_xflag(adsp_xflag),
        .snd_cmd_wr(snd_cmd_wr), .snd_cmd(snd_cmd), .snd_resp_rd(snd_resp_rd), .snd_resp(snd_resp), .snd_busy(snd_busy),
        .snd_int(snd_int), .snd_reset(snd_reset),
        .wdog_reset(wdog_reset),
        .dbg_pc(dbg_68k_pc), .dbg_step()
    );
    assign c_we[1] = 1'b0; assign c_wdata[1] = '0; assign c_be[1] = 2'b11;

    // ------------------------------------------------------------------------
    // GSP: core, bus glue, scan-out
    // ------------------------------------------------------------------------
    logic [31:4] gmem_addr;
    logic        gmem_req, gmem_we, gmem_ack, gmem_srt;
    logic [15:0] gmem_wdata, gmem_rdata;
    logic [15:0] hcount, vcount;
    logic        line_start;
    logic [15:0] r_hesync, r_heblnk, r_hsblnk, r_vesync, r_veblnk, r_vsblnk;
    logic [15:0] r_dpyctl, r_dpystrt, r_dpytap, r_dpyadr;
    logic  [2:0] finescroll;
    logic  [1:0] palbank;
    logic        pal_we_rg, pal_we_b;
    logic  [9:0] pal_waddr;
    logic [15:0] pal_wdata;
    logic        line_late, line_late_p, gsp_cache_flush;
    always_ff @(posedge clk) if (mreset) line_late <= 1'b0; else if (line_late_p) line_late <= 1'b1;   // sticky for the overlay

    tms34010 gsp (
        .clk(clk), .reset(mreset), .cen(cen_6m), .cen_vid(cen_vid), .halt_n(gsp_reset_n),
        .cache_flush(gsp_cache_flush),
        .mem_addr(gmem_addr), .mem_req(gmem_req), .mem_we(gmem_we), .mem_wdata(gmem_wdata),
        .mem_rdata(gmem_rdata), .mem_ack(gmem_ack), .mem_srt(gmem_srt),
        .host_addr(host_addr), .host_rd(host_rd), .host_wr(host_wr), .host_wdata(host_wdata),
        .host_rdata(host_rdata), .host_ready(host_ready), .int_out(gsp_int),
        .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .r_hesync(r_hesync), .r_heblnk(r_heblnk), .r_hsblnk(r_hsblnk), .r_htotal(),
        .r_vesync(r_vesync), .r_veblnk(r_veblnk), .r_vsblnk(r_vsblnk), .r_vtotal(),
        .r_dpyctl(r_dpyctl), .r_dpystrt(r_dpystrt), .r_dpytap(r_dpytap), .r_dpyadr(r_dpyadr),
        .hblank(), .vblank(),
        .dbg_pc(dbg_gsp_pc), .dbg_halted(), .dbg_instr(), .dbg_idle(),
        .dbg_force_di(1'b0), .dbg_int_inhibit(1'b0), .dbg_force_int(1'b0), .dbg_int_pending(1'b0), .dbg_hold(1'b0),
        .rc_req(rc_req), .rc_fill(rc_fill), .rc_src(rc_src), .rc_dst(rc_dst), .rc_len(rc_len), .rc_color(rc_color), .rc_transp(rc_transp), .rc_ack(rc_ack)
    );

    gsp_bus gbus (
        .clk(clk), .reset(mreset),
        .mem_addr(gmem_addr), .mem_req(gmem_req), .mem_we(gmem_we), .mem_wdata(gmem_wdata),
        .mem_rdata(gmem_rdata), .mem_ack(gmem_ack), .mem_srt(gmem_srt),
        .sd_addr(c_addr[0]), .sd_req(c_req[0]), .sd_we(c_we[0]), .sd_wdata(c_wdata[0]), .sd_be(c_be[0]),
        .sd_rdata(sd_rdata), .sd_ack(c_ack[0]),
        .sb_addr(sb_addr), .sb_len(sb_len), .sb_req(sb_req), .sb_we(sb_we), .sb_wdata(sb_wdata),
        .sb_wr(sb_wr), .sb_idx(b_idx), .sb_data(b_data), .sb_done(sb_done), .sb_widx(b_widx), .sb_be(sb_be),
        .rc_req(rc_req), .rc_fill(rc_fill), .rc_src(rc_src), .rc_dst(rc_dst), .rc_len(rc_len), .rc_color(rc_color), .rc_transp(rc_transp), .rc_ack(rc_ack),
        .finescroll(finescroll), .palbank(palbank),
        .pal_we_rg(pal_we_rg), .pal_we_b(pal_we_b), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .vram_copied(gsp_cache_flush)
    );

    gsp_video video (
        .clk(clk), .reset(mreset), .cen_pix(cen_pix_10m), .cen_out(cen_pix),
        .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .r_hesync(r_hesync), .r_heblnk(r_heblnk), .r_hsblnk(r_hsblnk),
        .r_vesync(r_vesync), .r_veblnk(r_veblnk), .r_vsblnk(r_vsblnk),
        .r_dpyctl(r_dpyctl), .r_dpystrt(r_dpystrt), .r_dpytap(r_dpytap), .r_dpyadr(r_dpyadr),
        .finescroll(finescroll), .palbank(palbank), .display_on(r_dpyctl[15]),
        .pal_we_rg(pal_we_rg), .pal_we_b(pal_we_b), .pal_waddr(pal_waddr), .pal_wdata(pal_wdata),
        .b_addr(vb_addr), .b_len(vb_len), .b_req(vb_req), .b_wr(vb_wr), .b_idx(b_idx), .b_data(b_data), .b_done(vb_done),
        .r(v_r), .g(v_g), .b(v_b), .hsync(hsync), .vsync(vsync), .hblank(v_hblank), .vblank(v_vblank), .de(de),
        .dbg_line_late(line_late_p)
    );
    logic [7:0] v_r, v_g, v_b;
    generate if (DBG_OVERLAY) begin : g_ovl
        dbg_overlay ovl (
            .clk(clk), .cen_pix(cen_pix), .enable(overlay), .de(de), .vsync(vsync),
            .r_in(v_r), .g_in(v_g), .b_in(v_b),
            .status({dbg_68k_pc, dbg_gsp_pc, dbg_flags, 10'd0, dbg_adsp_pc}),
            .r_out(r), .g_out(g), .b_out(b)
        );
    end else begin : g_noovl
        assign r = v_r; assign g = v_g; assign b = v_b;
    end endgenerate
    assign hblank = v_hblank;
    assign vblank = v_vblank;

    // ------------------------------------------------------------------------
    // ADSP board: core + SIM (serial ROM in SDRAM, prefetched) + SOM buffers
    // ------------------------------------------------------------------------
    logic [11:0] io_addr;
    logic        io_rd, io_wr, io_wait;
    logic [15:0] io_wdata, io_rdata;

    adsp2100 adsp (
        .clk(clk), .reset(mreset | adsp_reset), .cen(cen_8m), .halt(adsp_halt),
        .pm_ext_addr(pm_addr), .pm_ext_we(pm_we), .pm_ext_wdata(pm_wdata), .pm_ext_rdata(pm_rdata),
        .dm_ext_addr(dm_addr), .dm_ext_we(dm_we), .dm_ext_wdata(dm_wdata), .dm_ext_rdata(dm_rdata),
        .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_rdata(io_rdata), .io_wait(io_wait),
        .irq(4'b0000), .flag_in(1'b0), .flag_out(),
        .dbg_pc(dbg_adsp_pc), .dbg_instr_done()
    );

    // SIM: word index = eprom_base + sim_addr, valid below 0x30000; one word
    // buffered ahead so a read costs no wait when the sequence is linear
    logic [15:0] sim_addr;
    logic  [1:0] mp;                      // eprom page (data * 0x10000)
    logic [17:0] sim_next_idx;            // index the buffer holds
    logic        sim_valid, sim_fetching;
    logic [15:0] sim_word;
    logic        rd_pend;                 // an /SIMBUF read is waiting for its word
    logic        xflag_r, gint_r;
    logic [13:0] som_addr_a;
    logic [12:0] som_ptr;
    wire  [17:0] sim_idx = {mp, sim_addr};
    wire         sim_hit = sim_valid && (sim_next_idx == sim_idx);
    // The ADSP samples io_rdata in the SAME clock it raises io_rd unless io_wait
    // is high in that clock (S_MEM: `if (io_pending_rd && !io_wait) latch`).
    // So the word must be on io_rdata combinationally, and io_wait must cover
    // the io_rd clock itself -- a registered "pending" flag is one clock late
    // and lets the core latch the previous read's word. That off-by-one fed
    // the ADSP its 3D overlay code shifted by one word out of the SIM ROM.
    wire         sim_rd_now  = io_rd && (io_addr[2:0] == 3'd0);
    wire         sim_consume = (sim_rd_now || rd_pend) && sim_hit;

    always_ff @(posedge clk) begin
        if (mreset) begin
            sim_addr <= '0; mp <= '0; sim_valid <= 1'b0; sim_fetching <= 1'b0; c_req[2] <= 1'b0;
            xflag_r <= 1'b0; gint_r <= 1'b0; som_ptr <= '0; sim_next_idx <= '0; rd_pend <= 1'b0;
        end else begin
            // /SIMBUF read: serve from the one-word buffer the clock io_rd is
            // raised if it already holds the word, else hold io_wait until it
            // does; advance only when a word is actually consumed. MAME does
            // not advance past the end of the ROM (it returns 0xff and leaves
            // the address alone), so neither do we.
            if (sim_rd_now && !sim_hit) rd_pend <= 1'b1;
            if (sim_consume) begin
                if (sim_idx < 18'h30000) sim_addr <= sim_addr + 16'd1;
                rd_pend <= 1'b0;
            end
            if (adsp_int_clr) gint_r <= 1'b0;
            // prefetch whenever the buffer does not hold the next word
            if (!sim_fetching && !sim_hit) begin
                if (sim_idx < 18'h30000) begin
                    c_addr[2] <= 24'h060000 + {6'd0, sim_idx};      // byte 0x0c0000 >> 1
                    c_req[2]  <= 1'b1; sim_fetching <= 1'b1; sim_next_idx <= sim_idx;
                    // The buffer does not hold this word until the SDRAM
                    // answers. Retargeting sim_next_idx without dropping
                    // sim_valid made sim_hit true one clock later with the
                    // PREVIOUS word still in sim_word: a read landing before
                    // the ack (12 clocks apart in a streaming loop; the ack
                    // can be hundreds under contention) took word N-1 as N.
                    sim_valid <= 1'b0;
                end else begin
                    sim_word <= 16'h00ff; sim_valid <= 1'b1; sim_next_idx <= sim_idx;
                end
            end
            if (sim_fetching && c_ack[2]) begin
                // The image stores SIM words high byte first (the .90h/.10h/.9h
                // byte at the even address, .90k/.10k/.9k at the odd), the same
                // big-endian layout as the 68k program region; the SDRAM client
                // port is little-endian, so swap. MAME's ADSP reads word 0x83 as
                // 0x6653; unswapped we handed it 0x5366, and the 3D demo's first
                // loop count came out as 0x0a00 instead of 0x000a.
                c_req[2] <= 1'b0; sim_fetching <= 1'b0; sim_word <= {sd_rdata[7:0], sd_rdata[15:8]}; sim_valid <= 1'b1;
            end
            if (io_wr) begin
                case (io_addr[2:0])
                    3'd1: sim_addr <= io_wdata;
                    3'd2: som_ptr  <= som_ptr + 13'd1;
                    3'd3: som_ptr  <= io_wdata[12:0];
                    3'd5: xflag_r  <= io_wdata[0];
                    3'd6: gint_r   <= 1'b1;
                    3'd7: mp       <= io_wdata[1:0];
                    default: ;
                endcase
            end
        end
    end
    assign c_we[2] = 1'b0; assign c_wdata[2] = '0; assign c_be[2] = 2'b11;
    assign io_wait  = (sim_rd_now || rd_pend) && !sim_hit;
    assign io_rdata = (io_addr[2:0] == 3'd0) ? sim_word : 16'h0000;
    assign adsp_int = gint_r;
    assign adsp_xflag = xflag_r;

    // SOM: the ADSP writes the bank the 68k is *not* looking at
    assign som_addr_a = {~adsp_bank, som_ptr};
    dpram_be #(.AW(14)) som (
        .clk(clk),
        .a_addr(som_addr_a), .a_we(io_wr && io_addr[2:0] == 3'd2), .a_be(2'b11), .a_wdata(io_wdata), .a_rdata(),
        .b_addr(som_addr_b), .b_we(som_we), .b_be(som_be), .b_wdata(som_wdata), .b_rdata(som_rdata_b)
    );

    // ------------------------------------------------------------------------
    // JSA II sound board; OKI ROM bytes from SDRAM (client 3)
    // ------------------------------------------------------------------------
    logic [17:0] oki_addr;
    logic        oki_req, oki_ack;
    logic  [7:0] oki_data;
    logic        oki_hi;
    always_ff @(posedge clk) begin
        oki_ack <= 1'b0;
        if (mreset) c_req[3] <= 1'b0;
        else begin
            if (oki_req && !c_req[3] && !oki_ack) begin
                c_addr[3] <= 24'h090000 + {7'd0, oki_addr[17:1]};   // byte 0x120000 >> 1
                oki_hi    <= oki_addr[0];
                c_req[3]  <= 1'b1;
            end
            if (c_req[3] && c_ack[3]) begin
                c_req[3] <= 1'b0; oki_ack <= 1'b1;
                oki_data <= oki_hi ? sd_rdata[15:8] : sd_rdata[7:0];
            end
        end
    end
    assign c_we[3] = 1'b0; assign c_wdata[3] = '0; assign c_be[3] = 2'b11;

    jsa2 sound (
        .clk(clk), .reset(mreset), .cen_ym(cen_ym), .cen_oki(cen_oki),
        .snd_reset(snd_reset),
        .cmd_wr(snd_cmd_wr), .cmd_data(snd_cmd), .resp_rd(snd_resp_rd), .resp_data(snd_resp), .main_irq(snd_int), .cmd_pending(snd_busy),
        .coins({1'b0, coin2, coin1}), .test(service),
        .rom_we(dl_pulse && dl_is_jsa), .rom_waddr(dl_addr[15:0]), .rom_wdata(dl_data),
        .oki_addr(oki_addr), .oki_req(oki_req), .oki_data(oki_data), .oki_ack(oki_ack),
        .audio(audio), .audio_valid(audio_valid)
    );

    assign dbg_flags = {sd_ready, gsp_reset_n, adsp_halt, adsp_reset, line_late, snd_int, gsp_int, adsp_int};
endmodule
