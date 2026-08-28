//------------------------------------------------------------------------------
// Simulation wrapper (Verilator) for the ADSP-2100 trace bench (sim/adsp/tb_adsp.cpp).
// Just the core; the C++ side drives the clock, loads memories and register
// state through the public_flat signals, and models the data-space I/O.
//------------------------------------------------------------------------------
`default_nettype none

module tb_adsp_top (
    input  logic        clk,
    input  logic        reset,
    input  logic        cen,
    input  logic        halt,
    input  logic [12:0] pm_ext_addr,
    input  logic        pm_ext_we,
    input  logic [23:0] pm_ext_wdata,
    output logic [23:0] pm_ext_rdata,
    input  logic [12:0] dm_ext_addr,
    input  logic        dm_ext_we,
    input  logic [15:0] dm_ext_wdata,
    output logic [15:0] dm_ext_rdata,
    output logic [11:0] io_addr,
    output logic        io_rd,
    output logic        io_wr,
    output logic [15:0] io_wdata,
    input  logic [15:0] io_rdata,
    input  logic        io_wait,
    input  logic  [3:0] irq,
    input  logic        flag_in,
    output logic        flag_out,
    output logic [13:0] dbg_pc,
    output logic        dbg_instr_done
);

    adsp2100 u (
        .clk(clk), .reset(reset), .cen(cen), .halt(halt),
        .pm_ext_addr(pm_ext_addr), .pm_ext_we(pm_ext_we), .pm_ext_wdata(pm_ext_wdata), .pm_ext_rdata(pm_ext_rdata),
        .dm_ext_addr(dm_ext_addr), .dm_ext_we(dm_ext_we), .dm_ext_wdata(dm_ext_wdata), .dm_ext_rdata(dm_ext_rdata),
        .io_addr(io_addr), .io_rd(io_rd), .io_wr(io_wr), .io_wdata(io_wdata), .io_rdata(io_rdata), .io_wait(io_wait),
        .irq(irq), .flag_in(flag_in), .flag_out(flag_out),
        .dbg_pc(dbg_pc), .dbg_instr_done(dbg_instr_done)
    );

endmodule
