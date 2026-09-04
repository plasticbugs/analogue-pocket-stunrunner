// Whole-machine bench wrapper: stunrun_core + the behavioural SDRAM chip.
// The C++ side feeds the ROM image through the loader port exactly as the
// APF does, drives the controls, and collects video/audio.
`default_nettype none

module tb_system_top (
    input  logic        clk,
    input  logic        hw_reset,
    input  logic        reset,
    input  logic        dl_active,
    input  logic [24:0] dl_addr,
    input  logic  [7:0] dl_data,
    input  logic        dl_we,
    input  logic [11:0] nv_addr,
    input  logic        nv_we,
    input  logic  [7:0] nv_wdata,
    input  logic        coin1, coin2, service, start, fire, boost,
    input  logic  [7:0] stick_x, stick_y,
    input  logic  [7:0] sw1,
    output logic        cen_pix,
    output logic  [7:0] r, g, b,
    output logic        hsync, vsync, hblank, vblank, de,
    output logic signed [15:0] audio,
    output logic        audio_valid,
    output logic [31:0] dbg_68k_pc, dbg_gsp_pc, dbg_68k_opc,
    output logic [13:0] dbg_adsp_pc,
    output logic  [7:0] dbg_flags,
    output logic [31:0] model_errors,
    output logic        dbg_pal_we_rg, dbg_pal_we_b,
    output logic  [9:0] dbg_pal_waddr,
    output logic [15:0] dbg_pal_wdata,
    output logic  [1:0] dbg_palbank,
    output logic        dbg_snd_cmd_wr, dbg_snd_resp_rd, dbg_snd_reset, dbg_gsp_int, dbg_host_wr, dbg_host_ready, dbg_snd_block, dbg_68k_waitgsp, dbg_68k_waitrom,
    output logic  [7:0] dbg_snd_cmd, dbg_snd_resp,
    output logic  [1:0] dbg_host_addr,
    output logic [15:0] dbg_host_wdata,
    output logic        dbg_gmem_req, dbg_gmem_we, dbg_gmem_ack, dbg_gio_we, dbg_adsp_trig, dbg_adsp_int, dbg_adsp_int_clr,
    output logic [31:4] dbg_gmem_addr,
    output logic [15:0] dbg_gmem_wdata, dbg_gio_wdata,
    output logic  [4:0] dbg_gio_addr,
    output logic [15:0] dbg_hstctll, dbg_hstctlh,
    output logic        dbg_gsp_instr,
    output logic        dbg_som_wr, dbg_adsp_wait, dbg_adsp_instr,
    output logic  [5:0] dbg_c_ack,
    output logic        dbg_b_active,
    output logic        dbg_dm_we_68k,
    output logic [12:0] dbg_dm_addr_68k,
    output logic [15:0] dbg_dm_wdata_68k,
    output logic        dbg_sim_rd, dbg_sim_fetching,
    output logic [31:0] dbg_gsp_st,
    output logic  [7:0] dbg_gsp_state,
    output logic [15:0] dbg_gsp_ir,
    output logic [31:0] dbg_gsp_saddr, dbg_gsp_daddr, dbg_gsp_dydx, dbg_gsp_dptch, dbg_gsp_sptch, dbg_gsp_wstart, dbg_gsp_wend,
    output logic        dbg_ym_wr, dbg_oki_wr, dbg_6502_sync, dbg_snd_cmd_full, dbg_snd_irq, dbg_snd_rd_cmd, dbg_cen_cpu_snd, dbg_cen_ym, dbg_ym_a0,
    output logic  [7:0] dbg_ym_d,
    output logic [15:0] dbg_6502_addr,
    output logic [17:0] dbg_sim_idx,
    output logic [15:0] dbg_sim_word,
    output logic        dbg_adsp_bank,
    output logic [12:0] dbg_som_ptr,
    output logic [15:0] dbg_io_wdata,
    output logic        dbg_somclk, dbg_gint_wr, dbg_xout_wr,
    output logic        dbg_br_n, dbg_halt_n, dbg_adsp_reset_o, dbg_pm_we_68k,
    output logic [12:0] dbg_pm_addr_68k,
    output logic [23:0] dbg_pm_wdata_68k,
    output logic [15:0] dbg_gsp_intpend, dbg_gsp_intenb, dbg_gsp_control,
    output logic [31:0] dbg_gsp_fraddr, dbg_gsp_frval, dbg_gsp_intvec,
    output logic [15:0] dbg_gsp_dpyint, dbg_gsp_vc, dbg_gsp_dpyctl,
    output logic [31:0] dbg_68k_exepc,
    output logic        dbg_line_late,
    output logic [15:0] dbg_vcount, dbg_dpyadr, dbg_dpystrt, dbg_vsblnk, dbg_veblnk,
    output logic        dbg_line_start,
    output logic [24:1] dbg_b_addr,
    output logic  [9:0] dbg_b_len, dbg_b_idx,
    output logic        dbg_b_req, dbg_b_wr, dbg_b_done,
    output logic [15:0] dbg_b_data
);
    wire  [15:0] dq;
    wire  [12:0] sa;
    wire   [1:0] sba;
    wire         dqml, dqmh, cs_n, we_n, ras_n, cas_n, cke, sclk;

    stunrun_core core (
        .clk(clk), .clk_sdram(clk), .hw_reset(hw_reset), .reset(reset), .rd_late(1'b1), .burst_slow(1'b0),
        .dl_active(dl_active), .dl_addr(dl_addr), .dl_data(dl_data), .dl_we(dl_we),
        .nv_addr(nv_addr), .nv_we(nv_we), .nv_wdata(nv_wdata), .nv_rdata(), .nv_dirty(),
        .coin1(coin1), .coin2(coin2), .service(service), .start(start), .fire(fire), .boost(boost),
        .stick_x(stick_x), .stick_y(stick_y), .sw1(sw1),
        .cen_pix(cen_pix), .r(r), .g(g), .b(b), .hsync(hsync), .vsync(vsync), .hblank(hblank), .vblank(vblank), .de(de),
        .audio(audio), .audio_valid(audio_valid),
        .dram_dq(dq), .dram_a(sa), .dram_ba(sba), .dram_dqm_l(dqml), .dram_dqm_h(dqmh),
        .dram_cs_n(cs_n), .dram_ras_n(ras_n), .dram_cas_n(cas_n), .dram_we_n(we_n), .dram_cke(cke), .dram_clk(sclk),
        .dbg_68k_pc(dbg_68k_pc), .dbg_gsp_pc(dbg_gsp_pc), .dbg_adsp_pc(dbg_adsp_pc), .dbg_flags(dbg_flags)
    );

    sdram_model #(.AW(22)) chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .cke(cke)
    );
    assign model_errors = chip.errors;
    assign dbg_pal_we_rg = core.pal_we_rg; assign dbg_pal_we_b = core.pal_we_b; assign dbg_pal_waddr = core.pal_waddr; assign dbg_pal_wdata = core.pal_wdata; assign dbg_palbank = core.palbank;
    assign dbg_snd_cmd_wr = core.snd_cmd_wr; assign dbg_snd_resp_rd = core.snd_resp_rd; assign dbg_snd_reset = core.snd_reset; assign dbg_gsp_int = core.gsp_int; assign dbg_host_wr = core.host_wr; assign dbg_host_ready = core.host_ready; assign dbg_snd_block = core.main.snd_block; assign dbg_68k_opc = core.main.cpu.last_opc_pc; assign dbg_68k_waitgsp = (core.main.bst == core.main.B_WAIT_GSP); assign dbg_68k_waitrom = (core.main.bst == core.main.B_WAIT_ROM);
    assign dbg_snd_cmd = core.snd_cmd; assign dbg_snd_resp = core.snd_resp; assign dbg_host_addr = core.host_addr; assign dbg_host_wdata = core.host_wdata;
    assign dbg_gmem_req = core.gmem_req; assign dbg_gmem_we = core.gmem_we; assign dbg_gmem_ack = core.gmem_ack; assign dbg_gmem_addr = core.gmem_addr; assign dbg_gmem_wdata = core.gmem_wdata;
    assign dbg_gio_we = core.gsp.w_we && core.gsp.w_is_io; assign dbg_gio_addr = core.gsp.w_addr[4:0]; assign dbg_gio_wdata = core.gsp.w_wdata;
    assign dbg_adsp_trig = core.main.dm_we && core.main.dm_addr == 13'h1fff; assign dbg_adsp_int = core.adsp_int; assign dbg_adsp_int_clr = core.adsp_int_clr;
    assign dbg_hstctll = core.gsp.io[15]; assign dbg_hstctlh = core.gsp.io[16];
    assign dbg_gsp_instr = core.gsp.dbg_instr;
    assign dbg_som_wr = core.io_wr && (core.io_addr[2:0] == 3'd2);
    assign dbg_adsp_wait = core.io_wait;
    assign dbg_c_ack = {core.c_ack[5], core.c_ack[4], core.c_ack[3], core.c_ack[2], core.c_ack[1], core.c_ack[0]};
    assign dbg_b_active = core.sdram.b_active;
    assign dbg_dm_we_68k    = core.main.dm_we;
    assign dbg_dm_addr_68k  = core.main.dm_addr;
    assign dbg_dm_wdata_68k = core.main.dm_wdata;
    assign dbg_adsp_instr = core.adsp.dbg_instr_done;
    assign dbg_sim_rd   = core.sim_consume;
    assign dbg_sim_fetching = core.sim_fetching;
    assign dbg_sim_idx  = core.sim_idx;
    assign dbg_sim_word = core.sim_word;
    assign dbg_adsp_bank = core.adsp_bank;
    assign dbg_som_ptr   = core.som_ptr;
    assign dbg_io_wdata  = core.io_wdata;
    assign dbg_somclk    = core.io_wr && (core.io_addr[2:0] == 3'd3);
    assign dbg_gint_wr   = core.io_wr && (core.io_addr[2:0] == 3'd6);
    assign dbg_xout_wr   = core.io_wr && (core.io_addr[2:0] == 3'd5);
    assign dbg_br_n      = core.main.br_n_lat;
    assign dbg_halt_n    = core.main.halt_n_lat;
    assign dbg_adsp_reset_o = core.adsp_reset;
    assign dbg_pm_we_68k = core.main.pm_we; assign dbg_pm_addr_68k = core.main.pm_addr; assign dbg_pm_wdata_68k = core.main.pm_wdata;
    assign dbg_gsp_intpend = core.gsp.io[18];
    assign dbg_gsp_st = core.gsp.st;
    assign dbg_gsp_state = 8'(core.gsp.state);
    assign dbg_gsp_ir = core.gsp.ir;
    assign dbg_gsp_saddr = core.gsp.rf[30]; assign dbg_gsp_daddr = core.gsp.rf[28]; assign dbg_gsp_dydx = core.gsp.rf[23];
    assign dbg_gsp_dptch = core.gsp.rf[27]; assign dbg_gsp_sptch = core.gsp.rf[29];
    assign dbg_gsp_wstart = core.gsp.rf[25]; assign dbg_gsp_wend = core.gsp.rf[24];
    assign dbg_ym_wr = core.sound.dbg_ym_wr;
    assign dbg_ym_a0 = core.sound.dbg_ym_a0; assign dbg_ym_d = core.sound.dbg_ym_d;
    assign dbg_oki_wr = core.sound.dbg_io_wr && (core.sound.dbg_io_sel == 2'd0);
    assign dbg_6502_sync = core.sound.dbg_sync;
    assign dbg_6502_addr = core.sound.dbg_addr;
    assign dbg_snd_cmd_full = core.sound.cmd_full;
    assign dbg_snd_irq = core.sound.irq;
    assign dbg_snd_rd_cmd = core.sound.rd_cmd;
    assign dbg_cen_cpu_snd = core.sound.cen_cpu;
    assign dbg_cen_ym = core.cen_ym;
    assign dbg_gsp_fraddr  = core.gsp.fr_addr;
    assign dbg_gsp_frval   = core.gsp.fr_val;
    assign dbg_gsp_intvec  = core.gsp.int_vec;
    assign dbg_gsp_dpyint  = core.gsp.io[10];
    assign dbg_gsp_vc      = core.gsp.vc;
    assign dbg_gsp_dpyctl  = core.gsp.io[8];
    assign dbg_gsp_intenb  = core.gsp.io[17];
    assign dbg_gsp_control = core.gsp.io[11];
    assign dbg_68k_exepc = core.main.cpu.exe_pc;
    assign dbg_line_late = core.line_late_p;
    assign dbg_vcount = core.vcount; assign dbg_dpyadr = core.r_dpyadr; assign dbg_dpystrt = core.r_dpystrt; assign dbg_vsblnk = core.r_vsblnk; assign dbg_veblnk = core.r_veblnk; assign dbg_line_start = core.line_start;
    assign dbg_b_addr = core.b_addr; assign dbg_b_len = core.b_len; assign dbg_b_idx = core.b_idx; assign dbg_b_req = core.b_req; assign dbg_b_wr = core.b_wr; assign dbg_b_done = core.b_done; assign dbg_b_data = core.b_data;
endmodule
