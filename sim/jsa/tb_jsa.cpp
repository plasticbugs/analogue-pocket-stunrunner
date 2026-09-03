// JSA II board bench: replays the 68k's command stream captured from MAME
// (tools/trace_jsa.lua) into the RTL and records what comes out.
//
//   tb_jsa <jsa_rom.bin> <oki_rom.bin> <events.txt> <seconds> <out_dir> [clk_hz]
//
// Writes out_dir/rtl.wav (16-bit mono, 48 kHz), out_dir/rtl_events.txt with
// every YM2151 and I/O latch write the 6502 made (same format as MAME's log),
// and prints a few counters.
#include "Vtb_jsa_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>

struct Event { double t; std::string kind; int val; };

static std::vector<uint8_t> load(const char* p, size_t expect) {
    std::ifstream f(p, std::ios::binary);
    std::vector<uint8_t> d((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (d.size() != expect) { fprintf(stderr, "%s: %zu bytes, expected %zu\n", p, d.size(), expect); exit(2); }
    return d;
}

static void write_wav(const std::string& path, const std::vector<int16_t>& s, int rate) {
    FILE* f = fopen(path.c_str(), "wb");
    uint32_t datalen = s.size() * 2, riff = 36 + datalen;
    uint16_t ch = 1, bits = 16, blk = 2, fmt = 1; uint32_t brate = rate * 2, fmtlen = 16;
    fwrite("RIFF", 1, 4, f); fwrite(&riff, 4, 1, f); fwrite("WAVEfmt ", 1, 8, f);
    fwrite(&fmtlen, 4, 1, f); fwrite(&fmt, 2, 1, f); fwrite(&ch, 2, 1, f); fwrite(&rate, 4, 1, f);
    fwrite(&brate, 4, 1, f); fwrite(&blk, 2, 1, f); fwrite(&bits, 2, 1, f);
    fwrite("data", 1, 4, f); fwrite(&datalen, 4, 1, f); fwrite(s.data(), 2, s.size(), f); fclose(f);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 6) { fprintf(stderr, "usage: tb_jsa jsa.bin oki.bin events.txt seconds outdir [clk_hz]\n"); return 2; }
    double clk_hz = argc > 6 ? atof(argv[6]) : 24e6;
    auto jsa = load(argv[1], 65536);
    auto oki = load(argv[2], 262144);
    double seconds = atof(argv[4]);
    std::string out = argv[5];

    std::vector<Event> ev;
    { std::ifstream f(argv[3]); std::string line;
      while (std::getline(f, line)) {
          std::istringstream ss(line); double t; int fr; std::string k; std::string v;
          if (!(ss >> t >> fr >> k)) continue; ss >> v;
          if (k == "CMD" || k == "SRESET") ev.push_back({t, k, k == "CMD" ? (int)strtol(v.c_str(), nullptr, 16) : 0});
      } }
    fprintf(stderr, "events: %zu (CMD+SRESET)\n", ev.size());
    fprintf(stderr, "68k stall model: %s\n", getenv("JSA_STALL") ? "on" : "off");

    Vtb_jsa_top* top = new Vtb_jsa_top;
    auto tick = [&]() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); };

    // reset, load ROMs
    top->reset = 1; top->cmd_wr = 0; top->resp_rd = 0; top->snd_reset = 0; top->rom_we = 0; top->oki_we = 0;
    for (int i = 0; i < 8; i++) tick();
    for (int i = 0; i < 65536; i++) { top->rom_we = 1; top->rom_waddr = i; top->rom_wdata = jsa[i]; tick(); }
    top->rom_we = 0;
    for (int i = 0; i < 262144; i++) { top->oki_we = 1; top->oki_waddr = i; top->oki_wdata = oki[i]; tick(); }
    top->oki_we = 0;
    for (int i = 0; i < 8; i++) tick();
    top->reset = 0;

    const uint64_t total = (uint64_t)(seconds * clk_hz);
    const double samp_per = clk_hz / 48000.0;
    double samp_acc = 0;
    std::vector<int16_t> wav; wav.reserve((size_t)(seconds * 48000) + 100);
    FILE* fe = fopen((out + "/rtl_events.txt").c_str(), "w");
    size_t ei = 0; uint64_t n_ym = 0, n_io = 0, n_resp = 0, n_cmd = 0;
    int resp_wait = 0; int cmd_hold = 0;
    int16_t last_audio = 0;
    for (uint64_t cyc = 0; cyc < total; cyc++) {
        double t = cyc / clk_hz;
        top->cmd_wr = 0; top->snd_reset = 0; top->resp_rd = 0;
        if (cmd_hold > 0) cmd_hold--;
        while (ei < ev.size() && ev[ei].t <= t) {
            // 68k model of stunrun_main's snd_block: a command whose time has
            // come waits while jsa2 holds cmd_pending, up to 85 us; one write
            // per clock, and the next command sees the latch full again.
            static double stall_from = -1;
            if (ev[ei].kind == "CMD" && top->dbg_cmd_pending && getenv("JSA_STALL")) {
                if (stall_from < 0) stall_from = t;
                if (t - stall_from < 85e-6) break;      // hold the write, retry next clock
            }
            if (ev[ei].kind == "CMD") { top->cmd_wr = 1; top->cmd_data = ev[ei].val; n_cmd++; stall_from = -1; ei++; break; }
            else { top->snd_reset = 1; }
            ei++;
        }
        // the 68k takes IRQ4 and reads the response a few microseconds later
        if (top->main_irq && resp_wait == 0) resp_wait = (int)(clk_hz * 8e-6);
        if (resp_wait > 0) { if (--resp_wait == 0) { top->resp_rd = 1; n_resp++; } }
        tick();
        if (top->dbg_ym_wr) { fprintf(fe, "%.7f 0 YM%d %02x\n", t, top->dbg_ym_a0, top->dbg_ym_d); n_ym++; }
        // JSA_LOGFROM=<s>: for 0.3 s from that time, log the command-latch
        // protocol at clock resolution -- 68k writes, latch-full edges (the
        // 6502's NMI input), NMI handler entries (PC 57e3), the handler's latch
        // read, and its RTI (584e) -- so a lost command can be seen as the
        // write that landed between a read and the handler's exit.
        {
            static double logfrom = getenv("JSA_LOGFROM") ? atof(getenv("JSA_LOGFROM")) : -1.0;
            static int pfull = 0; static unsigned long long n_rd = 0, n_nmi = 0, n_edge = 0;
            bool win = logfrom >= 0 && t >= logfrom && t < logfrom + 0.3;
            if (top->cmd_wr && win) fprintf(fe, "%.7f 0 CMDW %02x\n", t, top->cmd_data);
            if (top->dbg_cmd_full && !pfull) { n_edge++; if (win) fprintf(fe, "%.7f 0 NMIEDGE\n", t); }
            pfull = top->dbg_cmd_full;
            if (top->dbg_rd_cmd) { n_rd++; if (win) fprintf(fe, "%.7f 0 LATCHRD\n", t); }
            { static int ppend = 0; if (win && top->dbg_cmd_pending != ppend) fprintf(fe, "%.7f 0 PEND%d\n", t, top->dbg_cmd_pending); ppend = top->dbg_cmd_pending; }
            if (top->dbg_sync && top->dbg_addr == 0x57e3) { n_nmi++; if (win) fprintf(fe, "%.7f 0 NMI\n", t); }
            if (top->dbg_sync && top->dbg_addr == 0x584e && win) fprintf(fe, "%.7f 0 RTI\n", t);
            if (top->dbg_sync && top->dbg_addr == 0x584e) { static bool once = false; if (!once) { once = true; } }
            if (t + 1.0 / clk_hz >= seconds) fprintf(stderr, "latch: edges %llu, reads %llu, nmi entries %llu\n", n_edge, n_rd, n_nmi);
        }
        if (top->dbg_io_wr) { static const char* nm[4] = {"OKI", "WRP", "WRIO", "MIX"}; fprintf(fe, "%.7f 0 %s %02x\n", t, nm[top->dbg_io_sel], top->dbg_io_d); n_io++; }
        if (top->audio_valid) last_audio = (int16_t)top->audio;
        samp_acc += 1.0;
        if (samp_acc >= samp_per) { samp_acc -= samp_per; wav.push_back(last_audio); }
    }
    fclose(fe);
    write_wav(out + "/rtl.wav", wav, 48000);
    fprintf(stderr, "done: %.2f s, %zu samples, cmds %llu, resp reads %llu, ym writes %llu, io writes %llu\n",
            seconds, wav.size(), (unsigned long long)n_cmd, (unsigned long long)n_resp,
            (unsigned long long)n_ym, (unsigned long long)n_io);
    delete top;
    return 0;
}
