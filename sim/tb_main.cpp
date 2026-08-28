// 68010 board bench: run the kernel from reset on the real ROM and compare
// its instruction-fetch addresses with a MAME trace (PCs) until they
// diverge, and report the kernel's execution rate.
//   Vtb_main_top <stunrun.rom> <mame_trace.txt> [max_instructions]
#include "Vtb_main_top.h"
#include "Vtb_main_top___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>
#include <cstring>

static Vtb_main_top *top;
static uint64_t cyc = 0;
static VerilatedVcdC *vcd = nullptr;
static uint64_t vcd_from = 0, vcd_to = 0;
static inline void tick() {
    top->clk = 0; top->eval(); if (vcd && cyc >= vcd_from && cyc < vcd_to) vcd->dump(cyc * 10);
    top->clk = 1; top->eval(); if (vcd && cyc >= vcd_from && cyc < vcd_to) vcd->dump(cyc * 10 + 5);
    cyc++;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s rom trace [max]\n", argv[0]); return 2; }
    long maxi = argc > 3 ? atol(argv[3]) : 200000;
    FILE *rf = fopen(argv[1], "rb"); if (!rf) { perror(argv[1]); return 2; }
    std::vector<uint8_t> rom; { uint8_t buf[65536]; size_t n; while ((n = fread(buf, 1, sizeof buf, rf)) > 0) rom.insert(rom.end(), buf, buf + n); } fclose(rf);
    // MAME trace: lines "PC: mnemonic ..." -> list of PCs
    std::vector<uint32_t> tpc;
    { FILE *tf = fopen(argv[2], "r"); if (!tf) { perror(argv[2]); return 2; }
      char line[512]; while (fgets(line, sizeof line, tf)) { unsigned pc; const char *p = strstr(line, "SR="); p = p ? p + 8 : line; while (*p == ' ') p++; if (sscanf(p, "%x:", &pc) == 1) tpc.push_back(pc); } fclose(tf); }
    printf("rom %zu bytes, trace %zu instructions\n", rom.size(), tpc.size());

    top = new Vtb_main_top;
    if (getenv("TB_VCD")) { Verilated::traceEverOn(true); vcd = new VerilatedVcdC; top->trace(vcd, 99); vcd->open("main.vcd"); vcd_from = atol(getenv("TB_VCD")); vcd_to = vcd_from + 200; }
    top->reset = 1; top->cen_8m = 0; top->in0 = 0xe1; top->sw1 = 0x00; top->a80000 = 0; top->vblank_n = 1; top->host_rdata = 0;
    // preload the 68k ROM into the chip model: word i = big-endian bytes 2i,2i+1 stored as {hi,lo}? The
    // controller stores D15:8 from the even byte (loader be), so model word = (b[2i] << 8) | b[2i+1]
    for (size_t i = 0; i + 1 < rom.size() && i < 0xc0000; i += 2)
        top->rootp->tb_main_top__DOT__chip__DOT__mem[i / 2] = (rom[i] << 8) | rom[i + 1];
    for (int i = 0; i < 20; i++) tick();
    top->reset = 0;
    while (!top->sd_ready) tick();
    // hold reset a little after SDRAM init, then release
    top->reset = 1; for (int i = 0; i < 50; i++) tick(); top->reset = 0;

    // Compare on instruction fetches: the kernel's busstate 00 fetches are not
    // exposed, so use dbg_pc (addr_out) at each step and match opcode fetch
    // addresses against the trace's PC sequence: any fetch address equal to
    // the next expected PC advances the trace pointer.
    size_t ti = 0; long steps = 0; uint64_t t_start = cyc; int div12 = 0;
    uint32_t last_match = 0; long since_match = 0;
    uint64_t vb_period = 96000000ULL / 60; uint64_t next_vb = vb_period;
    while (ti < tpc.size() && (long)ti < maxi) {
        div12 = (div12 + 1) % 12; top->cen_8m = (div12 == 0);
        // crude vblank: 60 Hz, ~1.4 ms low
        top->vblank_n = !((cyc % vb_period) < (vb_period / 12));
        tick();
        if (getenv("TB_DEBUG") && steps < 40 && (top->dbg_clkena || top->dbg_rd_ack)) printf("   cyc %llu clkena %d ack %d pc %08x bs %d din %04x\n", (unsigned long long)cyc, top->dbg_clkena, top->dbg_rd_ack, top->dbg_pc, top->dbg_bs, top->dbg_din);
        if (top->dbg_step) {
            steps++;
            if (getenv("TB_DEBUG") && steps < 60) printf("step %ld cyc %llu pc %08x bs %d din %04x\n", steps, (unsigned long long)cyc, top->dbg_pc, top->dbg_bs, top->dbg_din);
            if (top->dbg_pc == tpc[ti]) { ti++; since_match = 0; last_match = top->dbg_pc; }
            else if (++since_match > 2000) {
                printf("DIVERGED after %zu matched PCs (last %06x, expected next %06x, kernel at %06x) at cycle %llu\n",
                       ti, last_match, tpc[ti], top->dbg_pc, (unsigned long long)cyc);
                break;
            }
        }
        if (cyc - t_start > 96000000ULL * 4) { printf("timeout\n"); break; }
    }
    double secs = (cyc - t_start) / 96e6;
    printf("matched %zu of %zu trace PCs; kernel steps %ld in %.3f s simulated (%.2f M steps/s)\n", ti, tpc.size(), steps, secs, steps / secs / 1e6);
    printf("host: gsp_reset_n=%d adsp_halt=%d adsp_reset=%d model errors %u\n", top->gsp_reset_n, top->adsp_halt, top->adsp_reset, top->model_errors);
    if (vcd) vcd->close();
    printf("%s\n", (ti >= 1000 && !top->model_errors) ? "PASS" : "FAIL");
    return (ti >= 1000 && !top->model_errors) ? 0 : 1;
}
