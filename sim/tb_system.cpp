// Whole-machine bench: loads stunrun.rom through the loader port, runs the
// machine for N frames, writes every Kth frame as a PNG (artifacts/sim/) and
// logs the three CPUs' program counters so a hang is easy to place.
//
//   Vtb_system_top <stunrun.rom> <frames> [snap_every] [coin_frame] [start_frame] [zram.sav]
#include "Vtb_system_top.h"
#include "Vtb_system_top___024root.h"
#include "Vtb_system_top__Syms.h"
#include "Vtb_system_top_stunrun_core.h"
#include "Vtb_system_top_tb_system_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>
#include <string>
#include <zlib.h>

static Vtb_system_top *top;
static uint64_t cyc = 0;
static inline void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }

static void write_png(const char *path, const std::vector<uint8_t> &rgb, int w, int h) {
    std::vector<uint8_t> raw; raw.reserve((w * 3 + 1) * h);
    for (int y = 0; y < h; y++) { raw.push_back(0); raw.insert(raw.end(), rgb.begin() + y * w * 3, rgb.begin() + (y + 1) * w * 3); }
    uLongf clen = compressBound(raw.size()); std::vector<uint8_t> comp(clen);
    compress2(comp.data(), &clen, raw.data(), raw.size(), 6);
    FILE *f = fopen(path, "wb"); if (!f) return;
    auto be32 = [&](uint32_t v) { uint8_t b[4] = {uint8_t(v >> 24), uint8_t(v >> 16), uint8_t(v >> 8), uint8_t(v)}; fwrite(b, 1, 4, f); };
    auto chunk = [&](const char *t, const uint8_t *d, uint32_t n) {
        be32(n); fwrite(t, 1, 4, f); if (n) fwrite(d, 1, n, f);
        uint32_t c = crc32(0, (const Bytef *)t, 4); if (n) c = crc32(c, d, n); be32(c);
    };
    const uint8_t sig[8] = {0x89, 'P', 'N', 'G', 13, 10, 26, 10}; fwrite(sig, 1, 8, f);
    uint8_t ihdr[13] = {uint8_t(w >> 24), uint8_t(w >> 16), uint8_t(w >> 8), uint8_t(w), uint8_t(h >> 24), uint8_t(h >> 16), uint8_t(h >> 8), uint8_t(h), 8, 2, 0, 0, 0};
    chunk("IHDR", ihdr, 13); chunk("IDAT", comp.data(), clen); chunk("IEND", nullptr, 0);
    fclose(f);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 3) { fprintf(stderr, "usage: %s stunrun.rom frames [snap_every] [coin_frame] [start_frame]\n", argv[0]); return 2; }
    int frames = atoi(argv[2]);
    int snap_every = argc > 3 ? atoi(argv[3]) : 60;
    int coin_frame = argc > 4 ? atoi(argv[4]) : -1;
    int start_frame = argc > 5 ? atoi(argv[5]) : -1;
    const char *sav = argc > 6 ? argv[6] : nullptr;
    FILE *rf = fopen(argv[1], "rb"); if (!rf) { perror(argv[1]); return 2; }
    std::vector<uint8_t> rom; { uint8_t buf[65536]; size_t n; while ((n = fread(buf, 1, sizeof buf, rf)) > 0) rom.insert(rom.end(), buf, buf + n); }
    fclose(rf);
    printf("rom %zu bytes\n", rom.size());

    top = new Vtb_system_top;
    top->hw_reset = 1; top->reset = 1; top->dl_active = 0; top->dl_we = 0; top->nv_we = 0; top->nv_addr = 0; top->nv_wdata = 0;
    top->coin1 = top->coin2 = top->service = top->start = top->fire = top->boost = 0;
    top->stick_x = 0x80; top->stick_y = 0x80; top->sw1 = 0x00;
    for (int i = 0; i < 20; i++) tick();
    top->hw_reset = 0;
    // wait for the SDRAM to initialise (dbg_flags[7])
    while (!(top->dbg_flags & 0x80)) tick();
    printf("sdram ready at %llu\n", (unsigned long long)cyc);

    // download: one byte every 8 clocks, like the APF at its fastest
    top->dl_active = 1;
    for (size_t i = 0; i < rom.size(); i++) {
        top->dl_addr = i; top->dl_data = rom[i]; top->dl_we = 1; tick(); tick();
        top->dl_we = 0; for (int k = 0; k < 6; k++) tick();
    }
    for (int k = 0; k < 2000; k++) tick();
    top->dl_active = 0;
    if (sav) {   // an initialised ZRAM image (tools/make_sav.py), as the Pocket would load a .sav
        FILE *sf = fopen(sav, "rb"); std::vector<uint8_t> z(4096, 0);
        if (sf) { size_t n = fread(z.data(), 1, 4096, sf); fclose(sf); printf("zram image %s: %zu bytes\n", sav, n); }
        for (int i = 0; i < 4096; i++) { top->nv_addr = i; top->nv_wdata = z[i]; top->nv_we = 1; tick(); top->nv_we = 0; tick(); }
    }
    top->reset = 0;
    printf("download done at %llu cycles\n", (unsigned long long)cyc);
    if (getenv("TB_ZRAM")) {
        // ZRAM word w should be {200e[w], 210e[w]}
        int bad = 0;
        for (int w = 0; w < 2048; w++) {
            uint16_t got = top->rootp->vlSymsp->TOP__tb_system_top__core.main__DOT__zram__DOT__mem[w];
            uint16_t want = (rom[0x170000 + w] << 8) | rom[0x170800 + w];
            if (got != want) { if (bad < 8) printf("zram[%03x] = %04x want %04x\n", w, got, want); bad++; }
        }
        printf("zram check: %d bad words\n", bad);
        if (atoi(getenv("TB_ZRAM")) == 1) return 0;
    }

    // run frames: count vsync rising edges
    std::vector<uint8_t> fb(512 * 240 * 3, 0);
    int frame = 0, x = 0, y = -1;
    int prev_vs = 0, prev_hs = 0, prev_de = 0;
    uint64_t last_report = cyc;
    uint32_t last_pc = 0; int same_pc = 0;
    while (frame < frames) {
        tick();
        if (getenv("TB_PCRING")) {
            // ring of the last 60000 executed 68k PCs; dumped with 60000 more after the first sound command
            static std::vector<uint32_t> ring(60000); static size_t rp = 0; static uint32_t lastpc = 0xffffffff; static int after = -1; static FILE *rf = nullptr;
            uint32_t pc = top->dbg_68k_exepc;
            if (pc != lastpc) {
                lastpc = pc;
                if (after < 0) { ring[rp] = pc; rp = (rp + 1) % ring.size(); }
                else if (after < 60000) { fprintf(rf, "%06x\n", pc); after++; if (after == 60000) { fclose(rf); printf("pc ring dumped\n"); } }
            }
            if (after < 0 && top->dbg_snd_cmd_wr && top->dbg_snd_cmd == 0x1e) {
                rf = fopen("../artifacts/sim/m68k_pcs_rtl.txt", "w");
                for (size_t i = 0; i < ring.size(); i++) fprintf(rf, "%06x\n", ring[(rp + i) % ring.size()]);
                fprintf(rf, "---SNDCMD---\n"); after = 0;
            }
        }
        if (getenv("TB_BURSTLOG") && frame == 241) {
            static int req_prev = 0, shown = 0;
            if (top->dbg_b_req && !req_prev && shown < 12) { printf("vcount %d: burst addr %06x len %d\n", top->dbg_vcount, top->dbg_b_addr, top->dbg_b_len); shown++; }
            req_prev = top->dbg_b_req;
            if (top->dbg_b_wr && top->dbg_b_idx < 2 && shown <= 12 && top->dbg_vcount < 24) printf("   idx %d data %04x\n", top->dbg_b_idx, top->dbg_b_data);
        }
        if (getenv("TB_DELOG") && top->cen_pix) {
            static int de_prev = 0, nlines = 0, first_vc = -1, last_vc = -1;
            if (top->de && !de_prev) { nlines++; if (first_vc < 0) first_vc = top->dbg_vcount; last_vc = top->dbg_vcount; }
            de_prev = top->de;
            static int vs_prev = 0;
            if (top->vsync && !vs_prev) { if (frame >= 240 && frame <= 243) printf("frame %d: DE lines %d, first at vcount %d, last at vcount %d\n", frame, nlines, first_vc, last_vc); nlines = 0; first_vc = -1; }
            vs_prev = top->vsync;
        }
        if (getenv("TB_RASTERLOG") && frame >= 250 && frame <= 251 && top->dbg_line_start) {
            int vc = top->dbg_vcount;
            if (vc <= 2 || (vc >= top->dbg_veblnk - 1 && vc <= top->dbg_veblnk + 2) || (vc >= top->dbg_vsblnk - 1 && vc <= top->dbg_vsblnk + 1))
                printf("frame %d line_start vcount=%d dpyadr=%04x dpystrt=%04x veblnk=%d vsblnk=%d\n", frame, vc, top->dbg_dpyadr, top->dbg_dpystrt, top->dbg_veblnk, top->dbg_vsblnk);
        }
        if (getenv("TB_LATELOG")) {
            static int nlate = 0, lastf = -1;
            if (top->dbg_line_late) nlate++;
            if (frame != lastf) { if (nlate) printf("frame %d: %d late line fetches\n", lastf, nlate); nlate = 0; lastf = frame; }
        }
        if (getenv("TB_CMDDUMP")) {
            static bool done = false;
            if (!done && frame >= 150 && top->dbg_gmem_req && top->dbg_gmem_we && top->dbg_gmem_ack && top->dbg_gmem_addr == 0x0fff7167 && top->dbg_gmem_wdata == 0xc000) {
                done = true;
                FILE *cf = fopen("../artifacts/sim/cmdlist_rtl.txt", "w");
                fprintf(cf, "frame %d\n", frame);
                const uint32_t bases[3] = {0xfff9fc00u, 0xfffcfc00u, 0xfff71600u};
                for (int r = 0; r < 3; r++) {
                    fprintf(cf, "REGION %08x\n", bases[r]);
                    for (int i = 0; i < 0x400; i++) {
                        uint32_t bit = bases[r] + i * 16; uint32_t word = ((bit - 0xff800000u) & 0x3fffffu) >> 4;
                        fprintf(cf, "%04x\n", top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem[0x100000 + word]);
                    }
                }
                fclose(cf); printf("command lists dumped at frame %d\n", frame);
            }
        }
        if (getenv("TB_SYNCLOG")) {
            static FILE *yf = nullptr; static int nctl = 0, io_prev = 0, lastf = -1;
            if (!yf) yf = fopen("../artifacts/sim/sync_rtl.txt", "w");
            bool on = frame >= 140;
            if (top->dbg_gmem_req && top->dbg_gmem_we && top->dbg_gmem_ack && top->dbg_gmem_addr == 0x0fff7167 && on) fprintf(yf, "%d TRIG %04x 68k=%06x\n", frame, top->dbg_gmem_wdata, top->dbg_68k_pc);
            if (top->dbg_gio_we && top->dbg_gio_addr == 15) nctl++;
            if (top->dbg_gmem_req && top->dbg_gmem_ack && (top->dbg_gmem_addr == 0x0fff7166 || top->dbg_gmem_addr == 0x0fff7165) && on) fprintf(yf, "%d FLAG%x %s %04x gsp=%08x 68k=%06x hostwr=%d\n", frame, top->dbg_gmem_addr & 0xffff, top->dbg_gmem_we ? "<=" : "read", top->dbg_gmem_we ? top->dbg_gmem_wdata : 0, top->dbg_gsp_pc, top->dbg_68k_pc, top->dbg_host_wr);
            static int npal = 0, nrout = 0, nrout2 = 0;
            if (top->dbg_gmem_req && top->dbg_gmem_we && top->dbg_gmem_ack && (top->dbg_gmem_addr >> 8) == 0x0f5000) npal++;
            if (top->dbg_gsp_instr && top->dbg_gsp_pc == 0xfff4aa70) nrout++;
            if (top->dbg_gsp_instr && (top->dbg_gsp_pc >> 8) == 0xfff4aa) nrout2++;
            if (top->dbg_gsp_int != io_prev) { if (on && top->dbg_gsp_int) fprintf(yf, "%d INTOUT-SET gsp=%08x 68k=%06x\n", frame, top->dbg_gsp_pc, top->dbg_68k_pc); io_prev = top->dbg_gsp_int; }
            if (top->dbg_host_wr && top->dbg_host_addr == 3 && on) fprintf(yf, "%d HOSTCTL %04x 68k=%06x\n", frame, top->dbg_host_wdata, top->dbg_68k_pc);
            if (top->dbg_snd_cmd_wr && on) fprintf(yf, "%d SNDCMD %02x\n", frame, top->dbg_snd_cmd);
            if (frame != lastf) { if (lastf >= 140 && lastf % 10 == 0) { fprintf(yf, "%d SUMMARY hstctll_writes=%d palwr=%d rout_aa70=%d rout_aaxx=%d gsppc=%08x\n", lastf, nctl, npal, nrout, nrout2, top->dbg_gsp_pc); fflush(yf); } if (lastf % 10 == 0) { nctl = 0; npal = 0; nrout = 0; nrout2 = 0; } lastf = frame; }
        }
        if (getenv("TB_SNDLOG")) {
            static FILE *sf = nullptr; static int gi_prev = 0, gi_count = 0, last_frame = -1;
            if (!sf) sf = fopen("../artifacts/sim/snd_rtl.txt", "w");
            if (top->dbg_snd_cmd_wr) fprintf(sf, "%d W %02x pc=%06x\n", frame, top->dbg_snd_cmd, top->dbg_68k_pc);
            if (top->dbg_snd_resp_rd) fprintf(sf, "%d R %02x pc=%06x\n", frame, top->dbg_snd_resp, top->dbg_68k_pc);
            if (top->dbg_snd_reset) fprintf(sf, "%d SRES pc=%06x\n", frame, top->dbg_68k_pc);
            if (top->dbg_host_wr && top->dbg_host_addr == 3) fprintf(sf, "%d HSTCTL %04x pc=%06x\n", frame, top->dbg_host_wdata, top->dbg_68k_pc);
            if (top->dbg_gsp_int && !gi_prev) gi_count++;
            gi_prev = top->dbg_gsp_int;
            if (frame != last_frame) { if (last_frame >= 0) fprintf(sf, "%d IRQ3x%d\n", last_frame, gi_count); gi_count = 0; last_frame = frame; fflush(sf); }
        }
        if (getenv("TB_PALLOG") && (top->dbg_pal_we_rg || top->dbg_pal_we_b)) {
            static FILE *pf = nullptr; static int pn = 0;
            if (!pf) pf = fopen("../artifacts/sim/pal_writes_rtl.txt", "w");
            if (pn < 400000) { fprintf(pf, "%d %s %03x %04x bank%d\n", frame, top->dbg_pal_we_rg ? "lo" : "hi", top->dbg_pal_waddr & 0xff, top->dbg_pal_wdata, top->dbg_palbank); pn++; fflush(pf); }
        }
        if (top->cen_pix) {
            if (top->vsync && !prev_vs) {
                // frame done
                if (snap_every > 0 && frame % snap_every == 0) {
                    char name[256]; snprintf(name, sizeof name, "../artifacts/sim/frame%05d.png", frame);
                    write_png(name, fb, 512, 240);
                }
                frame++; y = -1;
                if (getenv("TB_DUMP_FRAME") && frame == atoi(getenv("TB_DUMP_FRAME"))) {
                    // palette (gsp_bus read-back RAMs) and VRAM (chip model) in the dumpstate.lua format
                    char name[256]; snprintf(name, sizeof name, "../artifacts/sim/dump_f%05d.txt", frame);
                    FILE *df = fopen(name, "w");
                    fprintf(df, "PALETTE\n");
                    auto &core = top->rootp->vlSymsp->TOP__tb_system_top__core;
                    for (int i = 0; i < 1024; i++) fprintf(df, "%04x %04x\n", core.__PVT__gbus__DOT__pal_lo__DOT__mem[i], core.__PVT__gbus__DOT__pal_hi__DOT__mem[i]);
                    fclose(df);
                    snprintf(name, sizeof name, "../artifacts/sim/dump_f%05d.vram", frame);
                    FILE *vf = fopen(name, "wb");
                    for (int w = 0; w < 262144; w++) { uint16_t v = top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem[0x100000 + w]; fputc(v & 0xff, vf); fputc(v >> 8, vf); }
                    fclose(vf);
                    printf("dumped palette and VRAM at frame %d\n", frame);
                }
                if (coin_frame >= 0) { top->coin1 = (frame >= coin_frame && frame < coin_frame + 6); }
                if (start_frame >= 0) { top->start = (frame >= start_frame && frame < start_frame + 6); }
                printf("frame %d cyc %llu 68k %08x gsp %08x adsp %04x flags %02x\n", frame, (unsigned long long)cyc,
                       top->dbg_68k_pc, top->dbg_gsp_pc, top->dbg_adsp_pc, top->dbg_flags);
                fflush(stdout);
            }
            // rows are counted on DE, as the frozen-state gate and the Pocket's
            // scaler do: the 19 blanking lines before VEBLNK are not part of the
            // picture (counting hsyncs from vsync put them in as black rows and
            // dropped the last 19 visible lines)
            if (top->de && !prev_de) { y++; x = 0; }
            if (top->de) {
                if (y >= 0 && y < 240 && x < 512) {
                    size_t o = (size_t(y) * 512 + x) * 3;
                    fb[o] = top->r; fb[o + 1] = top->g; fb[o + 2] = top->b;
                }
                x++;
            }
            prev_vs = top->vsync; prev_hs = top->hsync; prev_de = top->de;
        }
        // hang detector: 68k PC unchanged for a long time
        if ((cyc & 0xffff) == 0) {
            if (top->dbg_68k_pc == last_pc) same_pc++; else same_pc = 0;
            last_pc = top->dbg_68k_pc;
        }
        if (cyc - last_report > 96000000ULL) {   // one simulated second without a frame
            printf("no vsync for 1 s: 68k %08x gsp %08x adsp %04x flags %02x\n", top->dbg_68k_pc, top->dbg_gsp_pc, top->dbg_adsp_pc, top->dbg_flags);
            last_report = cyc;
            if (frame == 0 && cyc > 96000000ULL * 5) { printf("FAIL: no video after 5 s\n"); return 1; }
        }
        if (top->vsync && !prev_vs) last_report = cyc;
    }
    unsigned merr = top->model_errors;
    printf("model errors %u\n", merr);
    printf("%s\n", merr ? "FAIL" : "PASS");
    delete top;
    return merr ? 1 : 0;
}
