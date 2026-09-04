//------------------------------------------------------------------------------
// Simulation wrapper for the TMS34010 trace bench. Exposes the core's register
// state so the C++ bench can load a MAME snapshot and compare per instruction.
//------------------------------------------------------------------------------
`default_nettype none

module tb_gsp_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,
    input  logic        halt_n,
    output logic [31:4] mem_addr,
    output logic        mem_req,
    output logic        mem_we,
    output logic [15:0] mem_wdata,
    input  logic [15:0] mem_rdata,
    input  logic        mem_ack,
    output logic        mem_srt,
    input  logic  [1:0] host_addr,
    input  logic        host_rd,
    input  logic        host_wr,
    input  logic [15:0] host_wdata,
    output logic [15:0] host_rdata,
    output logic        host_ready,
    output logic        rc_req, rc_fill,
    output logic [31:0] rc_src, rc_dst,
    output logic [15:0] rc_len, rc_color,
    output logic        rc_transp,
    input  logic        rc_ack,
    output logic        int_out,
    output logic [31:0] dbg_pc,
    output logic        dbg_halted,
    output logic        dbg_instr,
    input  logic        dbg_force_di,
    input  logic        dbg_int_inhibit,
    input  logic        dbg_force_int,
    input  logic        dbg_int_pending,
    input  logic        dbg_hold,
    output logic        dbg_idle,
    input  logic        cache_flush,
    // state access
    input  logic        ld_en,
    input  logic  [5:0] ld_idx,        // 0..30 rf, 32 pc, 33 st, 34 reset_deferred, 40..71 io
    input  logic [31:0] ld_val,
    output logic [31:0] rd_rf [0:30],
    output logic [31:0] rd_pc,
    output logic [31:0] rd_st,
    output logic [15:0] rd_io [0:31]
);
    logic hblank, vblank, line_start;
    logic [15:0] hcount, vcount;
    logic [15:0] r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11;

    tms34010 dut (
        .clk(clk), .reset(reset), .cen(cen), .cen_vid(1'b0), .halt_n(halt_n), .cache_flush(cache_flush),
        .mem_addr(mem_addr), .mem_req(mem_req), .mem_we(mem_we), .mem_wdata(mem_wdata),
        .mem_rdata(mem_rdata), .mem_ack(mem_ack), .mem_srt(mem_srt),
        .host_addr(host_addr), .host_rd(host_rd), .host_wr(host_wr), .host_wdata(host_wdata),
        .host_rdata(host_rdata), .host_ready(host_ready), .int_out(int_out),
        .rc_req(rc_req), .rc_fill(rc_fill), .rc_src(rc_src), .rc_dst(rc_dst), .rc_len(rc_len), .rc_color(rc_color), .rc_transp(rc_transp), .rc_ack(rc_ack),
        .hblank(hblank), .vblank(vblank), .hcount(hcount), .vcount(vcount), .line_start(line_start),
        .r_hesync(r0), .r_heblnk(r1), .r_hsblnk(r2), .r_htotal(r3), .r_vesync(r4), .r_veblnk(r5),
        .r_vsblnk(r6), .r_vtotal(r7), .r_dpyctl(r8), .r_dpystrt(r9), .r_dpytap(r10), .r_dpyadr(r11),
        .dbg_pc(dbg_pc), .dbg_halted(dbg_halted), .dbg_instr(dbg_instr),
        .dbg_force_di(dbg_force_di), .dbg_int_inhibit(dbg_int_inhibit), .dbg_force_int(dbg_force_int), .dbg_int_pending(dbg_int_pending),
        .dbg_hold(dbg_hold), .dbg_idle(dbg_idle)
    );

    // state load (bench only; hierarchical writes)
    always_ff @(posedge clk) begin
        if (ld_en) begin
            if (ld_idx < 6'd31) dut.rf[ld_idx[4:0]] <= ld_val;
            else if (ld_idx == 6'd32) dut.pc <= ld_val;
            else if (ld_idx == 6'd33) dut.st <= ld_val;
            else if (ld_idx == 6'd34) dut.reset_deferred <= ld_val[0];
            else if (ld_idx >= 6'd40) begin logic [4:0] k; k = 5'(ld_idx - 6'd40); dut.io[k] <= ld_val[15:0]; end
        end
    end
    always_comb begin
        for (int i = 0; i < 31; i++) rd_rf[i] = dut.rf[i];
        for (int i = 0; i < 32; i++) rd_io[i] = dut.io[i];
        rd_pc = dut.pc;
        rd_st = dut.st;
    end

    logic unused;
    assign unused = &{1'b0, hblank, vblank, line_start, hcount, vcount, r0, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11};
endmodule
