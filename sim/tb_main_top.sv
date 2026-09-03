// 68010 board bench: stunrun_main with the real SDRAM controller/model for
// program ROM and stubs for the GSP host port, ADSP memories and sound board.
// The C++ side preloads the ROM into the chip model and logs the kernel's
// bus cycles to compare with a MAME trace from reset.
`default_nettype none

module tb_main_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen_8m,
    input  logic  [7:0] in0, sw1,
    input  logic  [2:0] a80000,
    input  logic        vblank_n,
    output logic [31:0] dbg_pc,
    output logic        dbg_step,
    output logic  [1:0] host_addr,
    output logic        host_rd, host_wr,
    output logic [15:0] host_wdata,
    input  logic [15:0] host_rdata,
    output logic        gsp_reset_n, adsp_halt, adsp_reset, adsp_bank,
    output logic        snd_cmd_wr, snd_reset,
    output logic  [7:0] snd_cmd,
    output logic        sd_ready,
    output logic [31:0] model_errors,
    output logic  [1:0] dbg_bs,
    output logic [15:0] dbg_din,
    output logic        dbg_clkena, dbg_rd_ack
);
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

    sdram_ctrl sdram (
        .clk(clk), .clk_pin(clk), .init(reset), .rd_late(1'b1), .burst_slow(1'b0), .ready(sd_ready),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(sba),
        .SDRAM_nCS(cs_n), .SDRAM_nWE(we_n), .SDRAM_nRAS(ras_n), .SDRAM_nCAS(cas_n), .SDRAM_CKE(cke), .SDRAM_CLK(sclk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(sd_rdata),
        .b_addr(24'd0), .b_len(10'd0), .b_req(1'b0), .b_wr(), .b_idx(), .b_data(), .b_done()
    );
    sdram_model #(.AW(22)) chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .cke(cke)
    );
    assign model_errors = chip.errors;
    always_comb for (int i = 0; i < 6; i++) if (i != 1) begin c_req[i] = 1'b0; c_addr[i] = '0; c_we[i] = 1'b0; c_wdata[i] = '0; c_be[i] = '0; end
    assign c_we[1] = 1'b0; assign c_wdata[1] = '0; assign c_be[1] = 2'b11;

    // ADSP memories: real dual-port RAMs (the 68k side only)
    logic [12:0] pm_addr, dm_addr;
    logic        pm_we, dm_we, som_we;
    logic [23:0] pm_wdata, pm_rdata;
    logic  [1:0] som_be;
    logic [15:0] dm_wdata, dm_rdata, som_wdata, som_rdata;
    logic [13:0] som_addr;
    logic [23:0] pm [0:8191];
    always_ff @(posedge clk) begin
        if (pm_we) pm[pm_addr] <= pm_wdata;
        pm_rdata <= pm[pm_addr];
    end
    dpram_be #(.AW(13)) dm  (.clk(clk), .a_addr(13'd0), .a_we(1'b0), .a_be(2'b00), .a_wdata(16'd0), .a_rdata(),
                             .b_addr(dm_addr), .b_we(dm_we), .b_be(2'b11), .b_wdata(dm_wdata), .b_rdata(dm_rdata));
    dpram_be #(.AW(14)) som (.clk(clk), .a_addr(14'd0), .a_we(1'b0), .a_be(2'b00), .a_wdata(16'd0), .a_rdata(),
                             .b_addr(som_addr), .b_we(som_we), .b_be(som_be), .b_wdata(som_wdata), .b_rdata(som_rdata));

    // GSP host stub: ready the cycle after a request
    logic host_ready;
    always_ff @(posedge clk) host_ready <= host_rd | host_wr;

    stunrun_main dut (
        .clk(clk), .reset(reset), .cen_8m(cen_8m),
        .rom_addr(c_addr[1]), .rom_req(c_req[1]), .rom_rdata(sd_rdata), .rom_ack(c_ack[1]),
        .in0(in0), .sw1(sw1), .a80000(a80000), .stick_x(8'h80), .stick_y(8'h80),
        .vblank_n(vblank_n), .hblank_n(1'b1),
        .nv_addr(12'd0), .nv_we(1'b0), .nv_wdata(8'd0), .nv_rdata(), .nv_dirty(),
        .host_addr(host_addr), .host_rd(host_rd), .host_wr(host_wr), .host_wdata(host_wdata),
        .host_rdata(host_rdata), .host_ready(host_ready), .gsp_int(1'b0), .gsp_reset_n(gsp_reset_n),
        .pm_addr(pm_addr), .pm_we(pm_we), .pm_wdata(pm_wdata), .pm_rdata(pm_rdata),
        .dm_addr(dm_addr), .dm_we(dm_we), .dm_wdata(dm_wdata), .dm_rdata(dm_rdata),
        .som_addr(som_addr), .som_we(som_we), .som_be(som_be), .som_wdata(som_wdata), .som_rdata(som_rdata),
        .adsp_bank(adsp_bank), .adsp_halt(adsp_halt), .adsp_reset(adsp_reset),
        .adsp_int(1'b0), .adsp_int_clr(), .adsp_xflag(1'b0),
        .snd_cmd_wr(snd_cmd_wr), .snd_cmd(snd_cmd), .snd_resp_rd(), .snd_resp(8'h00), .snd_busy(1'b0), .snd_int(1'b0), .snd_reset(snd_reset),
        .wdog_reset(),
        .dbg_pc(dbg_pc), .dbg_step(dbg_step)
    );
    assign dbg_bs = dut.busstate; assign dbg_din = dut.data_in; assign dbg_clkena = dut.clkena; assign dbg_rd_ack = c_ack[1];
endmodule
