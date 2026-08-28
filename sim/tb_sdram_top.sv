// Bench wrapper: sdram_ctrl + behavioural chip. The C++ side drives the
// client ports and checks data against its own copy of memory.
`default_nettype none

module tb_sdram_top (
    input  logic        clk,
    input  logic        init,
    input  logic        rd_late,
    input  logic        burst_slow,
    output logic        ready,
    input  logic [24:1] c_addr  [6],
    input  logic        c_req   [6],
    input  logic        c_we    [6],
    input  logic [15:0] c_wdata [6],
    input  logic  [1:0] c_be    [6],
    output logic        c_ack   [6],
    output logic [15:0] rdata,
    input  logic [24:1] b_addr,
    input  logic  [9:0] b_len,
    input  logic        b_req,
    output logic        b_wr,
    output logic  [9:0] b_idx,
    output logic [15:0] b_data,
    output logic        b_done,
    output logic [31:0] model_errors
);
    wire  [15:0] dq;
    wire  [12:0] sa;
    wire   [1:0] sba;
    wire         dqml, dqmh, cs_n, we_n, ras_n, cas_n, cke, sclk;

    sdram_ctrl dut (
        .clk(clk), .clk_pin(clk), .init(init), .rd_late(rd_late), .burst_slow(burst_slow), .ready(ready),
        .SDRAM_DQ(dq), .SDRAM_A(sa), .SDRAM_DQML(dqml), .SDRAM_DQMH(dqmh), .SDRAM_BA(sba),
        .SDRAM_nCS(cs_n), .SDRAM_nWE(we_n), .SDRAM_nRAS(ras_n), .SDRAM_nCAS(cas_n),
        .SDRAM_CKE(cke), .SDRAM_CLK(sclk),
        .c_addr(c_addr), .c_req(c_req), .c_we(c_we), .c_wdata(c_wdata), .c_be(c_be), .c_ack(c_ack), .rdata(rdata),
        .b_addr(b_addr), .b_len(b_len), .b_req(b_req), .b_wr(b_wr), .b_idx(b_idx), .b_data(b_data), .b_done(b_done)
    );

    sdram_model #(.AW(22)) chip (
        .clk(clk), .dq(dq), .a(sa), .ba(sba), .dqml(dqml), .dqmh(dqmh),
        .cs_n(cs_n), .ras_n(ras_n), .cas_n(cas_n), .we_n(we_n), .cke(cke)
    );
    assign model_errors = chip.errors;
endmodule
