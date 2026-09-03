//------------------------------------------------------------------------------
// Bench wrapper (Verilator) for the JSA II board. Makes the clock enables the
// core will make (phase accumulators against CLK_HZ), holds the OKI ADPCM ROM
// image as a behavioural memory with a few cycles of latency, and exposes the
// board's debug taps.
//
// CLK_HZ defaults to 24 MHz for the bench: the RTL only cares about the ratio
// between the enables and the clock, so a quarter of the 96 MHz system clock
// runs four times faster for the same machine time.
//------------------------------------------------------------------------------
`default_nettype none

module tb_jsa_top #(
    parameter real CLK_HZ = 24_000_000.0
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        snd_reset,
    input  logic        cmd_wr,
    input  logic  [7:0] cmd_data,
    input  logic        resp_rd,
    output logic  [7:0] resp_data,
    output logic        main_irq,
    input  logic        rom_we,
    input  logic [15:0] rom_waddr,
    input  logic  [7:0] rom_wdata,
    input  logic        oki_we,
    input  logic [17:0] oki_waddr,
    input  logic  [7:0] oki_wdata,
    output logic signed [15:0] audio,
    output logic        audio_valid,
    output logic        cen_ym,
    output logic        dbg_ym_wr,
    output logic        dbg_ym_a0,
    output logic  [7:0] dbg_ym_d,
    output logic        dbg_io_wr,
    output logic  [1:0] dbg_io_sel,
    output logic  [7:0] dbg_io_d,
    output logic        dbg_sync,
    output logic [15:0] dbg_addr,
    output logic [17:0] dbg_oki_addr,
    output logic        dbg_oki_req,
    output logic        dbg_rd_cmd,     // 6502 read of the command latch
    output logic        dbg_cmd_full,   // command latch full (drives NMI_n low)
    output logic        dbg_cmd_pending // jsa2's hold-off for the 68k's next write
);
    localparam [31:0] INC_YM  = 32'(3579545.0 / CLK_HZ * 4294967296.0);
    localparam [31:0] INC_OKI = 32'(1193181.7 / CLK_HZ * 4294967296.0);

    logic [31:0] acc_ym, acc_oki;
    logic cen_oki;
    always_ff @(posedge clk) begin
        if (reset) begin
            acc_ym <= '0; acc_oki <= '0; cen_ym <= 1'b0; cen_oki <= 1'b0;
        end else begin
            {cen_ym,  acc_ym}  <= {1'b0, acc_ym}  + {1'b0, INC_YM};
            {cen_oki, acc_oki} <= {1'b0, acc_oki} + {1'b0, INC_OKI};
        end
    end

    // OKI ROM model: 256 KB, answers 3 clocks after the request
    logic [7:0] oki_rom [262144];
    logic [17:0] oki_addr;
    logic        oki_req, oki_ack;
    logic [7:0]  oki_data;
    logic [1:0]  oki_lat;
    always_ff @(posedge clk) begin
        if (oki_we) oki_rom[oki_waddr] <= oki_wdata;
        oki_ack <= 1'b0;
        if (reset) oki_lat <= '0;
        else if (oki_req && !oki_ack) begin
            oki_lat <= oki_lat + 2'd1;
            if (oki_lat == 2'd3) begin
                oki_data <= oki_rom[oki_addr];
                oki_ack  <= 1'b1;
                oki_lat  <= '0;
            end
        end else oki_lat <= '0;
    end
    assign dbg_oki_addr = oki_addr;
    assign dbg_oki_req  = oki_req;
    assign dbg_rd_cmd   = u_jsa.rd_cmd;
    assign dbg_cmd_full = u_jsa.cmd_full;
    assign dbg_cmd_pending = u_jsa.cmd_pending;

    jsa2 u_jsa (
        .clk        (clk),
        .reset      (reset),
        .cen_ym     (cen_ym),
        .cen_oki    (cen_oki),
        .snd_reset  (snd_reset),
        .cmd_wr     (cmd_wr),
        .cmd_data   (cmd_data),
        .resp_rd    (resp_rd),
        .resp_data  (resp_data),
        .main_irq   (main_irq),
        .coins      (3'b000),
        .test       (1'b0),
        .rom_we     (rom_we),
        .rom_waddr  (rom_waddr),
        .rom_wdata  (rom_wdata),
        .oki_addr   (oki_addr),
        .oki_req    (oki_req),
        .oki_data   (oki_data),
        .oki_ack    (oki_ack),
        .audio      (audio),
        .audio_valid(audio_valid),
        .dbg_ym_wr  (dbg_ym_wr),
        .dbg_ym_a0  (dbg_ym_a0),
        .dbg_ym_d   (dbg_ym_d),
        .dbg_io_wr  (dbg_io_wr),
        .dbg_io_sel (dbg_io_sel),
        .dbg_io_d   (dbg_io_d),
        .dbg_sync   (dbg_sync),
        .dbg_addr   (dbg_addr)
    );
endmodule

`default_nettype wire
