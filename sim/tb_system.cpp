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
#include <array>
#include <map>
#include <set>
#include <algorithm>
#include <string>
#include <zlib.h>

static Vtb_system_top *top;
static uint64_t cyc = 0;
static inline void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }

static long g_sim_mismatches = 0;   // TB_SIMCHK: SIM words that did not match the ROM image

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
    int prev_vs = 0, prev_hs = 0, prev_de = 0; int vec_lastf = -1;
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
        // TB_GSPRING: keep the last GSP PCs and dump them the moment the PC
        // leaves ROM (0xfffxxxxx), which is how the attract-demo crash shows up.
        // TB_ARB: SDRAM grants per client per frame, plus how long the burst port
        // holds the bus. Client 0 is the GSP; if it is starved on the dead frame
        // the arbiter is the throughput problem, not the GSP.
        if (getenv("TB_ARB")) {
            static long g[6] = {0,0,0,0,0,0}; static long bact = 0; static int lastf = -1;
            for (int i = 0; i < 6; i++) if (top->dbg_c_ack & (1u << i)) g[i]++;
            if (top->dbg_b_active) bact++;
            if (frame != lastf) {
                if (lastf >= 400 && lastf <= 412)
                    printf("frame %3d: grants gsp=%6ld rom=%6ld sim=%6ld oki=%5ld ldr=%4ld spare=%4ld | burst_active=%7ld (%4.1f%%)\n",
                           lastf, g[0], g[1], g[2], g[3], g[4], g[5], bact, 100.0*bact/1594636.0);
                for (int i = 0; i < 6; i++) g[i] = 0;
                bact = 0; lastf = frame;
            }
        }
        // TB_GSPSTALL: where does the GSP's frame go? Count clocks with a memory
        // request outstanding (req high, no ack yet) against instructions retired.
        // A 6 MHz 34010 can retire ~99,700 instructions per 60.2 Hz frame; if we
        // are far below that with heavy stall time, SDRAM latency is throttling it.
        if (getenv("TB_GSPSTALL")) {
            static long stall = 0, ins = 0, req = 0; static uint32_t pp = 0; static int lastf = -1;
            if (top->dbg_gmem_req && !top->dbg_gmem_ack) stall++;
            if (top->dbg_gmem_req && top->dbg_gmem_ack) req++;
            if (top->dbg_gsp_instr && top->dbg_gsp_pc != pp) { ins++; pp = top->dbg_gsp_pc; }
            if (frame != lastf) {
                if (lastf >= 400 && lastf <= 440)
                    printf("frame %3d: gsp_instr=%6ld mem_reqs=%5ld stall_clocks=%7ld (%4.1f%% of frame)\n",
                           lastf, ins, req, stall, 100.0*stall/1594636.0);
                stall = ins = req = 0; lastf = frame;
            }
        }
        // TB_BUFRATE: GSP command buffers completed per 20 frames, the pipeline's
        // real throughput. MAME manages 6-7; if we manage fewer the whole game
        // advances more slowly and the attract sequence falls behind.
        if (getenv("TB_BUFRATE")) {
            static int prev = 0; static long blk = 0; static int lastf = -1;
            if (top->dbg_gsp_int && !prev) blk++;
            prev = top->dbg_gsp_int;
            if (frame != lastf) {
                if (lastf > 0 && lastf % 20 == 0) {
                    if (lastf >= 380) printf("frames %d-%d: gsp buffers completed = %ld\n", lastf-19, lastf, blk);
                    blk = 0;
                }
                lastf = frame;
            }
        }
        // TB_68KHIST: which 68k routine is our machine running while MAME is
        // already driving the 3D demo? Histogram of the real PC (exe_pc, not the
        // address bus) over the frames where MAME starts the demo.
        if (getenv("TB_68KHIST")) {
            static std::map<uint32_t,long> h; static uint32_t pp = 0; static bool shown = false;
            if (frame >= 550 && frame <= 568 && top->dbg_68k_exepc != pp) {
                h[top->dbg_68k_exepc]++; pp = top->dbg_68k_exepc;
            }
            if (frame >= 569 && !shown && !h.empty()) {
                shown = true;
                std::vector<std::pair<long,uint32_t>> v;
                for (auto &kv : h) v.push_back({kv.second, kv.first});
                std::sort(v.rbegin(), v.rend());
                long tot = 0; for (auto &x : v) tot += x.first;
                printf("68k PC histogram frames 550-568 (%ld samples):\n", tot);
                for (size_t i = 0; i < v.size() && i < 15; i++)
                    printf("   %06x  %8ld  %4.1f%%\n", v[i].second, v[i].first, 100.0*v[i].first/tot);
                fflush(stdout);
            }
        }
        // TB_ADSPIN: what our 68k feeds the ADSP, in MAME's adsp_io.txt "X" format
        // (offset, data), so the two streams can be diffed directly.
        if (getenv("TB_ADSPIN") && frame >= 699 && frame <= 707) {
            static FILE *xf = nullptr;
            if (!xf) xf = fopen("../artifacts/adsp_in_rtl.txt", "w");
            if (top->dbg_dm_we_68k) fprintf(xf, "X %04x %04x\n", top->dbg_dm_addr_68k, top->dbg_dm_wdata_68k);
            if (frame == 707) fflush(xf);
        }
        // TB_ADSPRATE: ADSP throughput. At 8 MHz it should retire ~133,000
        // instructions per 60.2 Hz frame; io_wait counts clocks stalled waiting
        // for a SIM word from SDRAM (the prefetch is only one word deep).
        if (getenv("TB_ADSPRATE")) {
            static long ins = 0, wait = 0, somw = 0; static int lastf = -1;
            if (top->dbg_adsp_instr) ins++;
            if (top->dbg_adsp_wait) wait++;
            if (top->dbg_som_wr) somw++;
            if (frame != lastf) {
                if (lastf >= 703 && lastf <= 709)
                    printf("frame %3d: adsp_instr=%7ld  io_wait_clocks=%8ld (%4.1f%% of frame)  som_writes=%ld\n",
                           lastf, ins, wait, 100.0*wait/1594636.0, somw);
                ins = wait = somw = 0; lastf = frame;
            }
        }
        // TB_ADSPACT: is the ADSP being asked to work, and is it answering?
        //   trig  = 68k writes 0x80bffe (the ADSP IRQ trigger)
        //   int   = ADSP -> 68k interrupt
        //   somw  = ADSP SOMLATCH writes (its 3D output)
        // Plus a PC histogram so we can see whether it is computing or idling.
        if (getenv("TB_ADSPACT")) {
            static long trig = 0, intr = 0, somw = 0; static int lastf = -1;
            static int pt = 0, pi = 0; static std::map<uint32_t,long> h; static bool shown = false;
            if (top->dbg_adsp_trig && !pt) trig++;
            pt = top->dbg_adsp_trig;
            if (top->dbg_adsp_int && !pi) intr++;
            pi = top->dbg_adsp_int;
            if (top->dbg_som_wr) somw++;
            if (frame >= 700 && frame <= 706) h[top->dbg_adsp_pc]++;
            if (frame != lastf) {
                if (lastf >= 698 && lastf <= 709)
                    printf("frame %3d: adsp_trig=%ld adsp_int=%ld som_writes=%ld\n", lastf, trig, intr, somw);
                trig = intr = somw = 0; lastf = frame;
            }
            if (frame >= 707 && !shown && !h.empty()) {
                shown = true;
                std::vector<std::pair<long,uint32_t>> v;
                for (auto &kv : h) v.push_back({kv.second, kv.first});
                std::sort(v.rbegin(), v.rend());
                long tot = 0; for (auto &x : v) tot += x.first;
                printf("ADSP PC histogram frames 700-706 (%ld samples):\n", tot);
                for (size_t i = 0; i < v.size() && i < 10; i++)
                    printf("   %04x  %8ld  %4.1f%%\n", v[i].second, v[i].first, 100.0*v[i].first/tot);
                fflush(stdout);
            }
        }
        // TB_SOMBANK: dump the head of both SOM banks when the bad length is
        // latched. The 68k reads bank adsp_bank; the ADSP fills the other one.
        // If the sane length is sitting in the bank we are NOT reading, the bug
        // is the bank select, not the ADSP's arithmetic.
        if (getenv("TB_SOMBANK")) {
            static bool done = false;
            uint16_t len = top->rootp->vlSymsp->TOP__tb_system_top__core.__PVT__main__DOT__wram[0x2da7];
            if (!done && (int16_t)len < 0) {
                done = true;
                auto &som = top->rootp->vlSymsp->TOP__tb_system_top__core.som__DOT__mem;
                printf("frame %d: bad length %d latched; adsp_bank=%d\n", frame, (int16_t)len,
                       top->rootp->vlSymsp->TOP__tb_system_top__core.__PVT__adsp_bank);
                for (int b = 0; b < 2; b++) {
                    printf("  SOM bank %d head:", b);
                    for (int i = 0; i < 8; i++) printf(" %04x", som[b*0x2000 + i]);
                    printf("\n");
                }
                fflush(stdout);
            }
        }
        // TB_SIMCHK: every word the SIM serial ROM hands the ADSP, checked against
        // the ROM image itself. This is timeline-independent -- it does not care
        // what MAME was doing -- so it catches a wrong SIM address or a wrong
        // word regardless of how far our attract sequence has drifted.
        //
        // It matters because nothing else covers this path: the ADSP bench
        // replays MAME's /SIMBUF return VALUES, so our SIM addressing has never
        // been exercised. And from the frame the 3D demo starts, the ADSP loads
        // ~500 words of its own program memory per frame out of this ROM
        // (2,500-3,000 reads/frame, zero 68k involvement) -- so a single wrong
        // word here becomes corrupt ADSP code.
        if (getenv("TB_SIMCHK")) {
            static long n = 0, bad = 0;
            if (top->dbg_sim_rd) {
                uint32_t idx = top->dbg_sim_idx;
                uint16_t got = top->dbg_sim_word;
                n++;
                // Structural check, independent of the data: a word must never
                // be served while its fetch is still outstanding. Runs of
                // identical ROM words hide a stale buffer from the value
                // compare below; this does not depend on the data.
                if (top->dbg_sim_fetching) {
                    g_sim_mismatches++;
                    if (bad < 20) { bad++; printf("frame %3d: SIM SERVED DURING FETCH idx=%05x\n", frame, idx); fflush(stdout); }
                }
                if (idx < 0x30000) {
                    size_t b = 0x0c0000 + 2 * (size_t)idx;
                    // SIM words are big-endian in the image (see stunrun_core.sv); the
                    // value MAME's ADSP reads for word 0x83 is 0x6653.
                    uint16_t want = (b + 1 < rom.size()) ? (uint16_t)((rom[b] << 8) | rom[b + 1]) : 0xffff;
                    if (got != want) g_sim_mismatches++;
                    if (got != want && bad < 20) {
                        bad++;
                        printf("frame %3d: SIM MISMATCH #%ld idx=%05x got=%04x want=%04x\n",
                               frame, bad, idx, got, want);
                        fflush(stdout);
                    } else if (got != want) bad++;
                }
            }
            static int lastf = -1;
            if (frame != lastf) {
                if (n > 0 && lastf >= 0)
                    printf("frame %3d: SIM reads=%6ld  mismatches=%ld\n", lastf, n, bad);
                n = 0; lastf = frame;
            }
        }
        // TB_ADSPWR: where the ADSP actually writes in data space. MAME's ADSP
        // hammers one address (0x2002, SOMLATCH); ours spreads writes across the
        // whole 0x2000-0x2007 I/O block, so print the top addresses to see the
        // shape of the walk.
        if (getenv("TB_ADSPWR")) {
            static std::map<uint32_t,long> h; static bool shown = false;
            auto &core = top->rootp->vlSymsp->TOP__tb_system_top__core;
            if (frame >= 705 && frame <= 707 && core.adsp__DOT__dbg_dm_wr)
                h[core.adsp__DOT__dbg_dm_addr]++;
            if (frame > 707 && !shown && !h.empty()) {
                shown = true;
                std::vector<std::pair<long,uint32_t>> v;
                for (auto &kv : h) v.push_back({kv.second, kv.first});
                std::sort(v.rbegin(), v.rend());
                printf("ADSP data-space write addresses, frames 705-707 (top 20):\n");
                for (size_t i = 0; i < v.size() && i < 20; i++)
                    printf("   dm[%04x] %ld\n", v[i].second, v[i].first);
                fflush(stdout);
            }
        }
        // TB_REGDUMP: the ADSP's full register state at frame TB_REGDUMP, in the
        // exact name=hex format tools/trace_adsp.lua writes to adsp_start.txt,
        // so `diff` against MAME's dump at its equivalent frame answers "did
        // the ADSP arrive at the kick in the same state?" -- PM, DM and the
        // SIM stream are already verified identical, so this is what is left.
        if (getenv("TB_REGDUMP")) {
            static bool done = false;
            if (!done && frame >= atoi(getenv("TB_REGDUMP"))) {
                done = true;
                auto &c = top->rootp->vlSymsp->TOP__tb_system_top__core;
                FILE *g = fopen("../artifacts/rtl_adsp_regs.txt", "w");
                #define R(n, v) fprintf(g, "%s=%x\n", n, (unsigned)(v))
                R("AX0", c.adsp__DOT__r_ax0); R("AX1", c.adsp__DOT__r_ax1); R("AY0", c.adsp__DOT__r_ay0); R("AY1", c.adsp__DOT__r_ay1);
                R("AR", c.adsp__DOT__r_ar); R("AF", c.adsp__DOT__r_af);
                R("MX0", c.adsp__DOT__r_mx0); R("MX1", c.adsp__DOT__r_mx1); R("MY0", c.adsp__DOT__r_my0); R("MY1", c.adsp__DOT__r_my1);
                R("MR0", c.adsp__DOT__r_mr0); R("MR1", c.adsp__DOT__r_mr1); R("MR2", c.adsp__DOT__r_mr2); R("MF", c.adsp__DOT__r_mf);
                R("SI", c.adsp__DOT__r_si); R("SE", c.adsp__DOT__r_se); R("SB", c.adsp__DOT__r_sb); R("SR0", c.adsp__DOT__r_sr0); R("SR1", c.adsp__DOT__r_sr1);
                R("AX0_SEC", c.adsp__DOT__x_ax0); R("AX1_SEC", c.adsp__DOT__x_ax1); R("AY0_SEC", c.adsp__DOT__x_ay0); R("AY1_SEC", c.adsp__DOT__x_ay1);
                R("AR_SEC", c.adsp__DOT__x_ar); R("AF_SEC", c.adsp__DOT__x_af);
                R("MX0_SEC", c.adsp__DOT__x_mx0); R("MX1_SEC", c.adsp__DOT__x_mx1); R("MY0_SEC", c.adsp__DOT__x_my0); R("MY1_SEC", c.adsp__DOT__x_my1);
                R("MR0_SEC", c.adsp__DOT__x_mr0); R("MR1_SEC", c.adsp__DOT__x_mr1); R("MR2_SEC", c.adsp__DOT__x_mr2); R("MF_SEC", c.adsp__DOT__x_mf);
                R("SI_SEC", c.adsp__DOT__x_si); R("SE_SEC", c.adsp__DOT__x_se); R("SB_SEC", c.adsp__DOT__x_sb); R("SR0_SEC", c.adsp__DOT__x_sr0); R("SR1_SEC", c.adsp__DOT__x_sr1);
                for (int i = 0; i < 8; i++) { char n[4]; snprintf(n, 4, "I%d", i); R(n, c.adsp__DOT__r_i[i]); }
                for (int i = 0; i < 8; i++) { char n[4]; snprintf(n, 4, "L%d", i); R(n, c.adsp__DOT__r_l[i]); }
                for (int i = 0; i < 8; i++) { char n[4]; snprintf(n, 4, "M%d", i); R(n, c.adsp__DOT__r_m[i]); }
                R("PX", c.adsp__DOT__px); R("CNTR", c.adsp__DOT__cntr); R("ASTAT", c.adsp__DOT__astat); R("SSTAT", c.adsp__DOT__sstat); R("MSTAT", c.adsp__DOT__mstat);
                R("PCSP", c.adsp__DOT__pc_sp); R("CNTRSP", c.adsp__DOT__cntr_sp); R("STATSP", c.adsp__DOT__stat_sp); R("LOOPSP", c.adsp__DOT__loop_sp);
                R("IMASK", c.adsp__DOT__imask); R("ICNTL", c.adsp__DOT__icntl); R("PC", c.adsp__DOT__pc);
                #undef R
                fclose(g);
                printf("frame %3d: dumped ADSP registers to artifacts/rtl_adsp_regs.txt\n", frame); fflush(stdout);
            }
        }
        // TB_ADSPPC: one PC per retired ADSP instruction for frames 705-706, to
        // diff against MAME's PC-only trace from its own kick and find the first
        // instruction where the two machines part company.
        if (getenv("TB_ADSPPC")) {
            static FILE *pf = nullptr; static long n = 0;
            if (frame >= 705 && frame <= 706 && top->dbg_adsp_instr) {
                if (!pf) pf = fopen("../artifacts/rtl_adsp_pc.txt", "w");
                fprintf(pf, "%04x\n", top->dbg_adsp_pc); n++;
            }
            if (frame == 707 && pf) { fclose(pf); pf = nullptr; printf("ADSP PC trace: %ld instructions\n", n); fflush(stdout); }
        }
        // TB_ADSPIO: the ADSP's complete stimulus and access stream for frames
        // 704-706 in tools/trace_adsp.lua's adsp_io.txt format (R/W = ADSP
        // data-space accesses, X/P = 68k data/program writes, C = 68k control
        // latch), so it can be diffed line-for-line against MAME's window. The
        // PCs agree for 924 instructions after the kick and then part; the first
        // R line whose value differs, or the first X/P/C line that is out of
        // place, is the input that made them part.
        if (getenv("TB_ADSPIO")) {
            static FILE *f = nullptr; static int pbr = -1, phalt = -1, prst = -1, pbank = -1;
            auto &c = top->rootp->vlSymsp->TOP__tb_system_top__core;
            if (frame >= 704 && frame <= 706) {
                if (!f) f = fopen("../artifacts/rtl_adsp_io.txt", "w");
                if (c.adsp__DOT__dbg_dm_rd) fprintf(f, "R %04x %04x\n", c.adsp__DOT__dbg_dm_addr, c.adsp__DOT__dbg_dm_data);
                if (c.adsp__DOT__dbg_dm_wr) fprintf(f, "W %04x %04x\n", c.adsp__DOT__dbg_dm_addr, c.adsp__DOT__dbg_dm_data);
                if (top->dbg_dm_we_68k) fprintf(f, "X %04x %04x\n", top->dbg_dm_addr_68k, top->dbg_dm_wdata_68k);
                if (top->dbg_pm_we_68k) fprintf(f, "P %04x %06x\n", top->dbg_pm_addr_68k, top->dbg_pm_wdata_68k);
                if ((int)top->dbg_br_n != pbr)          { fprintf(f, "C 5 %d\n", top->dbg_br_n);  pbr = top->dbg_br_n; }
                if ((int)top->dbg_halt_n != phalt)      { fprintf(f, "C 6 %d\n", top->dbg_halt_n); phalt = top->dbg_halt_n; }
                if ((int)top->dbg_adsp_reset_o != prst) { fprintf(f, "C 7 %d\n", !top->dbg_adsp_reset_o); prst = top->dbg_adsp_reset_o; }
                if ((int)top->dbg_adsp_bank != pbank)   { fprintf(f, "C 3 %d\n", top->dbg_adsp_bank); pbank = top->dbg_adsp_bank; }
            }
            if (frame == 707 && f) { fclose(f); f = nullptr; printf("ADSP io stream written to artifacts/rtl_adsp_io.txt\n"); fflush(stdout); }
        }
        // TB_ROWLOG: is the display row pointer sane? Per visible line log
        // DPYADR on line_start; it must step by -DUDATE (or count its low two
        // bits down) monotonically from VSBLNK to the next VSBLNK. A jump back
        // toward DPYSTRT mid-frame means the row pointer restarted -- which is
        // what "the lower half shows the top half again" looks like. Also
        // counts late line fetches per frame (a fetch still running when the
        // next line started), the other candidate for the flicker.
        if (getenv("TB_ROWLOG")) {
            static int lastf = -1; static long late = 0, lines = 0, jumps = 0;
            static uint16_t prev_dpyadr = 0; static bool have_prev = false;
            static int shown = 0;
            if (top->dbg_line_late) late++;
            if (top->dbg_line_start) {
                uint16_t d = top->dbg_dpyadr; int vc = top->dbg_vcount;
                bool visible = (vc >= (int)top->dbg_veblnk) && (vc < (int)top->dbg_vsblnk);
                if (visible && have_prev) {
                    lines++;
                    // a visible-line step must not INCREASE the row part (rows count down through the frame)
                    if ((d & 0xfffc) > (prev_dpyadr & 0xfffc)) {
                        jumps++;
                        if (shown < 30) { shown++; printf("frame %3d vc %3d (gsp_vc %3d): DPYADR jumped %04x -> %04x (DPYSTRT %04x VSBLNK %04x)\n", frame, vc, top->dbg_gsp_vc, prev_dpyadr, d, top->dbg_dpystrt, top->dbg_vsblnk); fflush(stdout); }
                    }
                }
                prev_dpyadr = d; have_prev = visible;
            }
            if (frame != lastf) {
                if (lastf >= 0 && (late || jumps) && lastf >= 300)
                    printf("frame %3d: late_lines=%ld  row_jumps=%ld  (visible lines %ld)\n", lastf, late, jumps, lines);
                late = jumps = lines = 0; lastf = frame;
            }
        }
        // TB_GIOLOG: every GSP I/O-register write to the display/timing registers
        // (HESYNC..CONTROL = 0..11, DPYTAP = 27, DPYADR = 30) with the scan position,
        // in frames 380-400 -- to see what moves DPYADR back to DPYSTRT at line ~133
        // every third frame on the level-select screen.
        if (getenv("TB_GIOLOG")) {
            if (frame >= 380 && frame <= 400 && top->dbg_gio_we) {
                int idx = top->dbg_gio_addr;
                if (idx <= 11 || idx == 27 || idx == 30) {
                    static const char *nm[32] = {"HESYNC","HEBLNK","HSBLNK","HTOTAL","VESYNC","VEBLNK","VSBLNK","VTOTAL","DPYCTL","DPYSTRT","DPYINT","CONTROL",
                        "","HSTADRL","HSTADRH","HSTCTLL","HSTCTLH","INTENB","INTPEND","CONVSP","CONVDP","PSIZE","","","","","","DPYTAP","","","DPYADR",""};
                    printf("frame %3d gsp_vc %3d vid_vcount %3d: GSP writes %-7s = %04x   (gsp_pc %08x, DPYADR now %04x DPYSTRT %04x DPYINT %04x)\n",
                           frame, top->dbg_gsp_vc, top->dbg_vcount, nm[idx], top->dbg_gio_wdata, top->dbg_gsp_pc,
                           top->dbg_dpyadr, top->dbg_dpystrt, top->dbg_gsp_dpyint);
                    fflush(stdout);
                }
            }
        }
        // TB_LINELOG: per scan line, for frames TB_LINELOG..+7, what the GSP is
        // doing: instructions retired and memory requests in that line, PC at the
        // line start, ST.IE (bit 21 of the 34010 status word), INTPEND/INTENB,
        // HSTCTLH (HLT = bit 15, held by the 68k), and DPYADR. The DI handler
        // (DPYINT = 2) writes DPYADR at line 2 in MAME; on our flip frames it
        // lands at line ~133, and this shows where those lines went.
        if (getenv("TB_LINELOG")) {
            static int f0 = atoi(getenv("TB_LINELOG"));
            static long li = 0, lm = 0; static int lastvc = -1;
            if (frame >= f0 && frame < f0 + 8) {
                if (top->dbg_gsp_instr) li++;
                if (top->dbg_gmem_req && !top->dbg_gmem_ack) lm++;
                if (top->dbg_line_start) {
                    printf("f%3d vc %3d: instr %6ld memreq %6ld pc %08x IE %d P %d intpend %04x intenb %04x hstctlh %04x dpyadr %04x dpystrt %04x\n",
                           frame, top->dbg_vcount, li, lm, top->dbg_gsp_pc, (top->dbg_gsp_st >> 21) & 1, (top->dbg_gsp_st >> 25) & 1,
                           top->dbg_gsp_intpend, top->dbg_gsp_intenb, top->dbg_hstctlh, top->dbg_dpyadr, top->dbg_dpystrt);
                    li = lm = 0;
                }
            }
            if (frame == f0 + 8 && lastvc != -2) { lastvc = -2; fflush(stdout); }
        }
        // TB_SNDLOG: the sound pipeline per 30 frames, the same line MAME's
        // tools sndwatch.lua prints: 68k->6502 commands, 68k response reads,
        // YM2151 register writes, OKI writes, and whether the 6502 is alive
        // (distinct opcode-fetch addresses, min/max). A hang shows as YM writes
        // collapsing with one PC; a stalled 68k driver as commands stopping
        // while the YM keeps being written; a stuck command latch as cmd_full
        // held high for the whole window.
        if (getenv("TB_SNDLOG")) {
            static long cmd = 0, resp = 0, ym = 0, oki = 0, fetches = 0, fullclk = 0, irqclk = 0;
            static std::set<uint16_t> pcs; static uint16_t pcmin = 0xffff, pcmax = 0;
            static int lastblk = -1;
            if (top->dbg_snd_cmd_wr) cmd++;
            if (top->dbg_snd_resp_rd) resp++;
            if (top->dbg_ym_wr) ym++;
            if (top->dbg_oki_wr) oki++;
            if (top->dbg_snd_cmd_full) fullclk++;
            if (top->dbg_snd_irq) irqclk++;
            if (top->dbg_6502_sync) { fetches++; uint16_t a = top->dbg_6502_addr; if (pcs.size() < 4096) pcs.insert(a); if (a < pcmin) pcmin = a; if (a > pcmax) pcmax = a; }
            int blk = frame / 30;
            if (blk != lastblk) {
                if (lastblk >= 0 && (lastblk + 1) * 30 >= 300)
                    printf("frames %4d-%4d: cmd=%3ld resp=%3ld ym_writes=%5ld oki_writes=%3ld  6502: fetches=%7ld distinct_pc=%4zu range %04x-%04x  cmd_full %5.1f%% irq %5.1f%%\n",
                           lastblk * 30, lastblk * 30 + 29, cmd, resp, ym, oki, fetches, pcs.size(), pcmin, pcmax,
                           100.0 * fullclk / (30.0 * 1594636.0), 100.0 * irqclk / (30.0 * 1594636.0));
                fflush(stdout);
                cmd = resp = ym = oki = fetches = fullclk = irqclk = 0; pcs.clear(); pcmin = 0xffff; pcmax = 0; lastblk = blk;
            }
        }
        // TB_SNDCMD: every 68k -> sound-board command byte with its frame, and
        // every response the 68k reads, to artifacts/snd_cmds_rtl.txt -- the
        // stream the JSA bench replays, so it can be diffed against MAME's for
        // the same stimulus (tools/trace_sndcmd.lua) before blaming the board.
        if (getenv("TB_SNDCMD")) {
            static FILE *cf = nullptr;
            if (!cf) cf = fopen("../artifacts/snd_cmds_rtl.txt", "w");
            if (top->dbg_snd_cmd_wr) fprintf(cf, "C %4d %02x\n", frame, top->dbg_snd_cmd);
            if (top->dbg_snd_resp_rd) fprintf(cf, "R %4d %02x\n", frame, top->dbg_snd_resp);
            if (top->dbg_snd_reset) fprintf(cf, "X %4d\n", frame);
            if (frame % 100 == 0) fflush(cf);
        }
        // TB_BLITLOG: every FILL/PIXBLT the GSP retires in frames TB_BLITLOG..+6,
        // with the B-file values from just BEFORE it (sampled at the previous
        // retire), in MAME's trace field names -- to diff against the blit list
        // MAME's GSP executes in the equivalent frame (tools/blits_from_trace.py).
        if (getenv("TB_BLITLOG")) {
            static int f0 = atoi(getenv("TB_BLITLOG")); static FILE *bf = nullptr;
            static uint32_t p_saddr = 0, p_daddr = 0, p_dydx = 0, p_dptch = 0, p_sptch = 0, p_ws = 0, p_we = 0, p_ctl = 0;
            if (top->dbg_gsp_instr) {
                uint16_t ir = top->dbg_gsp_ir;
                if (frame >= f0 && frame < f0 + 7 && (ir & 0xff00) == 0x0f00) {
                    if (!bf) bf = fopen("../artifacts/blits_rtl.txt", "w");
                    static const char *nm[8] = {"PIXBLT L,L","PIXBLT L,XY","PIXBLT XY,L","PIXBLT XY,XY","PIXBLT B,L","PIXBLT B,XY","FILL L","FILL XY"};
                    fprintf(bf, "f%4d %-12s B0=%08x B1=%08x B2=%08x B3=%08x B7=%08x B5=%08x B6=%08x CTL=%04x\n", frame, nm[(ir >> 5) & 7], p_saddr, p_sptch, p_daddr, p_dptch, p_dydx, p_ws, p_we, p_ctl);
                }
                p_saddr = top->dbg_gsp_saddr; p_daddr = top->dbg_gsp_daddr; p_dydx = top->dbg_gsp_dydx; p_dptch = top->dbg_gsp_dptch; p_sptch = top->dbg_gsp_sptch;
                p_ws = top->dbg_gsp_wstart; p_we = top->dbg_gsp_wend; p_ctl = top->dbg_gsp_control;
            }
            if (frame == f0 + 7 && bf) { fclose(bf); bf = nullptr; printf("blit log written\n"); fflush(stdout); }
        }
        // TB_68KPROF=F0: per-frame 68k time budget from frame F0 on, to compare
        // with MAME's tools/trace_feed.lua. FrameUpdate (0x2c372) spins
        // `while (!adsp_done) GspFeedDataStream(5)` and the starfield backdrop is
        // painted only inside that loop, so the number of GspFeedDataStream
        // entries per frame IS the 68k's spare time (MAME: 0..363 per frame),
        // and host-port data writes issued from inside it are the paint rate.
        // Cycle buckets (96 MHz clocks by 68k PC range): the wait loop, the feed
        // routine, SomCopyToGsp, GspSendCameraBlock, AdspIrqService, GspFrameBegin/End,
        // everything else, and host-port stall (write pending, GSP not ready).
        if (getenv("TB_68KPROF")) {
            static int f0 = atoi(getenv("TB_68KPROF")); static int lastf = -1;
            static uint64_t iters = 0, feedw = 0, hostw = 0, c_wait = 0, c_feed = 0, c_som = 0, c_cam = 0, c_irq = 0, c_fb = 0, c_fe = 0, c_oth = 0, c_hst = 0;
            static bool in_feed = false;
            static uint64_t hw_tot = 0, hw_n = 0, hw_max = 0, rw_tot = 0, rw_n = 0, rw_max = 0, intout = 0, hstctlw = 0;
            uint32_t pc = top->dbg_68k_pc;
            bool feed = (pc >= 0x2274a && pc < 0x22954);
            if (feed && !in_feed) iters++;
            in_feed = feed;
            if (top->dbg_host_wr && top->dbg_host_addr == 2) { hostw++; if (feed) feedw++; }
            // boot handshake: GSP writes of HSTCTLL with INTOUT (bit 7) set = its IRQ3 to the
            // 68k; 68k writes to HSTCTL (host_addr 3). MAME: 1 and 34 per frame during boot.
            if (top->dbg_gio_we && top->dbg_gio_addr == 15 && (top->dbg_gio_wdata & 0x80)) intout++;
            if (top->dbg_host_wr && top->dbg_host_addr == 3) hstctlw++;
            if (top->dbg_host_wr && !top->dbg_host_ready) c_hst++;
            // 68k bus FSM parked in B_WAIT_GSP: clocks blocked on the host port,
            // number of accesses, and the longest single wait this frame
            { static uint64_t cur = 0; static uint64_t nacc = 0, maxw = 0, tot = 0;
              if (top->dbg_68k_waitgsp) { cur++; tot++; } else if (cur) { nacc++; if (cur > maxw) maxw = cur; cur = 0; }
              // TB_HOSTDIAG: when a host wait passes 2000 clocks, say what the GSP is doing
              if (getenv("TB_HOSTDIAG") && cur == 2000)
                  printf("hostdiag %4d: gsp state %3u pc %08x ir %04x host addr %u %s\n", frame, top->dbg_gsp_state, top->dbg_gsp_pc, top->dbg_gsp_ir, top->dbg_host_addr, top->dbg_host_wr ? "wr" : "rd?");
              if (frame != lastf) { hw_tot = tot; hw_n = nacc; hw_max = maxw; tot = nacc = maxw = 0; } }
            // and the same for B_WAIT_ROM: 68k clocks blocked on its own ROM/SDRAM accesses
            { static uint64_t cur = 0; static uint64_t nacc = 0, maxw = 0, tot = 0;
              if (top->dbg_68k_waitrom) { cur++; tot++; } else if (cur) { nacc++; if (cur > maxw) maxw = cur; cur = 0; }
              if (frame != lastf) { rw_tot = tot; rw_n = nacc; rw_max = maxw; tot = nacc = maxw = 0; } }
            if (feed) c_feed++;
            else if (pc >= 0x2c3b4 && pc < 0x2c3da) c_wait++;
            else if (pc >= 0x2f0ae && pc < 0x2f0f8) c_som++;
            else if (pc >= 0x2d706 && pc < 0x2d762) c_cam++;
            else if (pc >= 0x2e418 && pc < 0x2e468) c_irq++;
            else if (pc >= 0x2f126 && pc < 0x2f1be) c_fb++;
            else if (pc >= 0x2f1be && pc < 0x2f260) c_fe++;
            else c_oth++;
            if (frame != lastf) {
                if (lastf >= f0)
                    printf("68kprof %4d: iters %4llu feedw %5llu hostw %5llu | kcyc wait %4llu feed %4llu som %4llu cam %3llu irq %3llu fb %3llu fe %3llu other %4llu hstall %4llu | hostwait kcyc %4llu n %5llu max %6llu | romwait kcyc %4llu n %6llu max %5llu | intout %llu hstctl_w %llu\n",
                           lastf, (unsigned long long)iters, (unsigned long long)feedw, (unsigned long long)hostw,
                           (unsigned long long)(c_wait / 1000), (unsigned long long)(c_feed / 1000), (unsigned long long)(c_som / 1000), (unsigned long long)(c_cam / 1000),
                           (unsigned long long)(c_irq / 1000), (unsigned long long)(c_fb / 1000), (unsigned long long)(c_fe / 1000), (unsigned long long)(c_oth / 1000), (unsigned long long)(c_hst / 1000), (unsigned long long)(hw_tot / 1000), (unsigned long long)hw_n, (unsigned long long)hw_max, (unsigned long long)(rw_tot / 1000), (unsigned long long)rw_n, (unsigned long long)rw_max, (unsigned long long)intout, (unsigned long long)hstctlw);
                iters = feedw = hostw = c_wait = c_feed = c_som = c_cam = c_irq = c_fb = c_fe = c_oth = c_hst = 0; intout = hstctlw = 0;
                lastf = frame;
            }
        }
        // TB_DEMOSTATE=F0: the attract demo's state per frame from F0 on, in the
        // same fields as tools/trace_demo.lua (68k work RAM peeked directly):
        // ff9550 game state, ff9578 section, ffdbee track-list node, ffdbfe
        // distance, ff9bcc/ff9bce backdrop stream requested/current, ff9bd0
        // feed pointer. The starfield request (stream 0x17) is what goes missing.
        if (getenv("TB_DEMOSTATE")) {
            static int f0 = atoi(getenv("TB_DEMOSTATE")); static int lastf = -1;
            if (frame != lastf && frame >= f0) {
                auto &w = top->rootp->vlSymsp->TOP__tb_system_top__core.__PVT__main__DOT__wram;
                auto rd16 = [&](uint32_t a) -> uint16_t { return w[(a & 0x7fff) >> 1]; };
                auto rd32 = [&](uint32_t a) -> uint32_t { return ((uint32_t)rd16(a) << 16) | rd16(a + 2); };
                printf("demo %4d: state %02x sect %2d node %08x dist %5d bd %02x/%02x feed %08x wait %04x\n", frame,
                       rd16(0xff9550), rd16(0xff9578), rd32(0xffdbee), (int16_t)rd16(0xffdbfe),
                       rd16(0xff9bcc) & 0xff, rd16(0xff9bce) & 0xff, rd32(0xff9bd0), rd16(0xffdb48));
                lastf = frame;
            }
        }
        // TB_MBLOG=F0: every GSP memory write to the boot loop's frame counter at
        // GSP bit address FFF716A0 (word FFF716A) for frames F0..F0+39, with the
        // scan line, plus DI pending/enabled -- MAME: the DI handler (fff41fc0)
        // writes 1,2,3 at line 2 on consecutive frames and the main loop resets it.
        if (getenv("TB_MBLOG")) {
            static int f0 = atoi(getenv("TB_MBLOG"));
            if (frame >= f0 && frame < f0 + 40 && top->dbg_gmem_req && top->dbg_gmem_we && top->dbg_gmem_ack && top->dbg_gmem_addr == 0x0FFF716A)
                printf("mblog %4d vc %3d: write %04x (gsp pc %08x, INTPEND %04x INTENB %04x)\n", frame, top->dbg_gsp_vc, top->dbg_gmem_wdata, top->dbg_gsp_pc, top->dbg_gsp_intpend, top->dbg_gsp_intenb);
        }
        // TB_FLIPLOG=F0: every CPU write to DPYADR (a change not made by the
        // per-line raster step) with its scan line, from frame F0; the ones
        // inside the picture (VEBLNK..VSBLNK) are the late flips that bounce or
        // tear the frame.
        if (getenv("TB_FLIPLOG")) {
            static int f0 = atoi(getenv("TB_FLIPLOG")); static uint16_t prev = 0xffff; static bool first = true;
            if (!first && top->dbg_dpyadr != prev && !top->dbg_line_start && frame >= f0) {
                bool vis = top->dbg_vcount >= top->dbg_veblnk && top->dbg_vcount < top->dbg_vsblnk;
                printf("flip frame %d vc %d: dpyadr %04x -> %04x%s\n", frame, top->dbg_vcount, prev, top->dbg_dpyadr, vis ? "  LATE (inside the picture)" : "");
            }
            prev = top->dbg_dpyadr; first = false;
        }
        // TB_LISTRACE=F0: the game's two 68k->GSP display lists (VRAM rows 927 and
        // 975, 320 words each, at GSP bit addresses fff9fc00 / fffcfc00). Per frame
        // from F0: host (68k) writes and GSP reads of each list with the scan lines
        // of the first and last, to see whether the GSP is still reading a list
        // the 68k has begun to rewrite -- MAME never overlaps them.
        if (getenv("TB_LISTRACE")) {
            static int f0 = atoi(getenv("TB_LISTRACE")); static int lastf = -1;
            struct L { long hw, gr; int hw0, hw1, gr0, gr1; } static ls[2] = {{0,0,-1,-1,-1,-1},{0,0,-1,-1,-1,-1}};
            static uint32_t hstadr = 0;   // HSTADR as the 68k programs it (bit address)
            if (top->dbg_host_wr && top->dbg_host_addr == 0) hstadr = (hstadr & 0xffff0000u) | top->dbg_host_wdata;
            if (top->dbg_host_wr && top->dbg_host_addr == 1) hstadr = (hstadr & 0x0000ffffu) | ((uint32_t)top->dbg_host_wdata << 16);
            auto which = [](uint32_t bit) -> int { uint32_t row = (bit >> 12) & 0x3ff; uint32_t w = (bit >> 4) & 0xff; if (row == 927 && w >= 0xc0) return 0; if (row == 975 && w >= 0xc0) return 1; return -1; };
            if (top->dbg_host_wr && top->dbg_host_addr == 2) { int k = which(hstadr); if (k >= 0) { L &l = ls[k]; if (l.hw == 0) l.hw0 = top->dbg_vcount; l.hw1 = top->dbg_vcount; l.hw++; } hstadr += 16; }
            if (top->dbg_gmem_req && top->dbg_gmem_ack && !top->dbg_gmem_we) { int k = which((uint32_t)top->dbg_gmem_addr << 4); if (k >= 0) { L &l = ls[k]; if (l.gr == 0) l.gr0 = top->dbg_vcount; l.gr1 = top->dbg_vcount; l.gr++; } }
            if (frame != lastf) {
                if (lastf >= f0) printf("listrace %4d: listA(9fc00) 68k %4ld wr vc %3d..%3d gsp %4ld rd vc %3d..%3d | listB(cfc00) 68k %4ld wr vc %3d..%3d gsp %4ld rd vc %3d..%3d\n", lastf,
                    ls[0].hw, ls[0].hw0, ls[0].hw1, ls[0].gr, ls[0].gr0, ls[0].gr1, ls[1].hw, ls[1].hw0, ls[1].hw1, ls[1].gr, ls[1].gr0, ls[1].gr1);
                for (int k = 0; k < 2; k++) ls[k] = {0,0,-1,-1,-1,-1};
                lastf = frame;
            }
        }
        // TB_SNDFINE=F0: per FRAME sound-board activity for frames F0..F0+199:
        // 68k command writes and the 6502's reads of that latch (a write not
        // followed by a read before the next write is a lost command), NMI
        // edges, YM/OKI writes, distinct 6502 PCs, and the clock-enable counts
        // (nominal per frame: cen_cpu 29,730, cen_ym 59,460).
        if (getenv("TB_SNDFINE")) {
            static int f0 = atoi(getenv("TB_SNDFINE")); static int lastf = -1;
            static long cw = 0, cr = 0, nmi = 0, ym = 0, oki = 0, ccpu = 0, cym = 0, stall = 0; static int pfull = 0;
            static std::set<uint16_t> pcs; static std::string cmds;
            if (frame >= f0 && frame < f0 + 200) {
                if (top->dbg_snd_cmd_wr) { cw++; char b[8]; snprintf(b, 8, "%02x ", top->dbg_snd_cmd); cmds += b; }
                if (top->dbg_snd_rd_cmd) cr++;
                if (top->dbg_snd_block) stall++;
                if (top->dbg_snd_cmd_full && !pfull) nmi++;
                pfull = top->dbg_snd_cmd_full;
                if (top->dbg_ym_wr) ym++;
                if (top->dbg_oki_wr) oki++;
                if (top->dbg_cen_cpu_snd) ccpu++;
                if (top->dbg_cen_ym) cym++;
                if (top->dbg_6502_sync && pcs.size() < 4096) pcs.insert(top->dbg_6502_addr);
            }
            if (frame != lastf) {
                if (lastf >= f0 && lastf < f0 + 200)
                    printf("sf %4d: cmd_wr=%ld latch_rd=%ld nmi=%ld ym=%4ld oki=%ld pcs=%4zu cen_cpu=%ld cen_ym=%ld stall=%ld%s%s%s\n",
                           lastf, cw, cr, nmi, ym, oki, pcs.size(), ccpu, cym, stall, top->dbg_snd_reset ? " RESET" : "", cmds.empty() ? "" : "  cmds: ", cmds.c_str());
                cw = cr = nmi = ym = oki = ccpu = cym = stall = 0; pcs.clear(); cmds.clear(); lastf = frame;
            }
        }
        // TB_YMLOG: every YM2151 write (a0 = 0 register select / 1 data, byte)
        // with its frame, to artifacts/ym_rtl.txt -- the same stream MAME's
        // tools/trace_jsa.lua logs as YM0/YM1, so the two can be diffed by
        // sequence (tools/compare_ym.py) to find the first register write on
        // which the system's sound board and MAME's part company.
        if (getenv("TB_YMLOG")) {
            static FILE *yf = nullptr;
            if (!yf) yf = fopen("../artifacts/ym_rtl.txt", "w");
            if (top->dbg_ym_wr) fprintf(yf, "%d YM%d %02x\n", frame, top->dbg_ym_a0 ? 1 : 0, top->dbg_ym_d);
            if (top->dbg_snd_cmd_wr) fprintf(yf, "%d CMD %02x cyc=%llu\n", frame, top->dbg_snd_cmd, (unsigned long long)cyc);
            if (top->dbg_snd_rd_cmd) fprintf(yf, "%d LATCHRD cyc=%llu\n", frame, (unsigned long long)cyc);
            if (top->dbg_snd_reset) fprintf(yf, "%d SRESET cyc=%llu\n", frame, (unsigned long long)cyc);
            if (frame % 100 == 0) fflush(yf);
        }
        // TB_MEMDUMP: dump the ADSP program and data RAM at frame TB_MEMDUMP so it
        // can be diffed against MAME's at the same frame. The ADSP bench loads PM
        // from MAME's dump, so nothing has ever checked the copy our own 68k
        // downloads -- and a corrupt ADSP program would idle harmlessly for
        // hundreds of frames and only detonate when the 3D demo first runs it.
        if (getenv("TB_MEMDUMP")) {
            static bool done = false;
            int at = atoi(getenv("TB_MEMDUMP"));
            if (!done && frame >= at) {
                done = true;
                auto &pm = top->rootp->vlSymsp->TOP__tb_system_top__core.adsp__DOT__pmem;
                auto &dm = top->rootp->vlSymsp->TOP__tb_system_top__core.adsp__DOT__dmem;
                FILE *g = fopen("../artifacts/rtl_adsp_mem.txt", "w");
                fprintf(g, "PMEM\n");
                for (int i = 0; i < 8192; i++) fprintf(g, "%06x\n", pm[i] & 0xffffff);
                fprintf(g, "DMEM\n");
                for (int i = 0; i < 8192; i++) fprintf(g, "%04x\n", dm[i] & 0xffff);
                fclose(g);
                printf("frame %3d: dumped ADSP PMEM+DMEM to artifacts/rtl_adsp_mem.txt\n", frame);
                fflush(stdout);
            }
        }
        // TB_SOMTRACE: the whole 68k<->ADSP SOM protocol, reconstructed.
        //
        // MAME's deferred_adsp_bank_switch documents the buffer format: word 0
        // of a bank is the TOTAL LENGTH, word 1 the offset to the table. The
        // ADSP cannot know the length until it has emitted the whole block, so
        // it writes the body first and then rewinds with /SOMCLK to store word 0
        // last. A bank whose word 0 is stale therefore means the 68k looked at a
        // buffer the ADSP had not finished -- which is what -1300 is.
        //
        // FrameUpdate (68k 0x2c372) only reads a bank after AdspIrqService has
        // set ff9bb4, and it flips the hardware bank (818006/818016) from its own
        // shadow ff9bb2 immediately before. So there are exactly three ways to
        // land on an unfinished buffer:
        //   (A) the ADSP signalled done early,
        //   (B) the 68k read the wrong bank (bank phase inverted vs the ADSP),
        //   (C) the ADSP's words landed at the wrong offsets.
        // Shadowing both banks tells them apart: print word 0/1 of BOTH banks at
        // the moment SomCopyToGsp latches its length.
        if (getenv("TB_SOMTRACE")) {
            static uint16_t shadow[2][8192];
            static long wr[2] = {0,0}, wrf[2] = {0,0};
            static long gint = 0, xout = 0, somclk = 0;
            static int lastf = -1, pbank = -1, pbr = -1, phalt = -1;
            static uint16_t prevlen = 0xdead;
            static bool once = false;
            int lo = 690, hi = 716;

            // ADSP SOMLATCH: lands in the bank the 68k is NOT looking at
            if (top->dbg_som_wr) {
                int b = top->dbg_adsp_bank ? 0 : 1;
                shadow[b][top->dbg_som_ptr & 0x1fff] = top->dbg_io_wdata;
                wr[b]++; wrf[b]++;
            }
            if (top->dbg_somclk) {
                somclk++;
                if (frame >= lo && frame <= hi)
                    printf("  f%3d SOMCLK ptr=%u (adsp writes bank %d)\n",
                           frame, top->dbg_io_wdata & 0x1fff, top->dbg_adsp_bank ? 0 : 1);
            }
            if (top->dbg_gint_wr) gint++;
            if (top->dbg_xout_wr) xout++;

            // 68k-side control-latch events
            if ((int)top->dbg_adsp_bank != pbank) {
                if (frame >= lo && frame <= hi)
                    printf("  f%3d 68k BANK -> %d   (68k now reads bank %d, adsp writes bank %d)\n",
                           frame, top->dbg_adsp_bank, top->dbg_adsp_bank, top->dbg_adsp_bank ? 0 : 1);
                pbank = top->dbg_adsp_bank;
            }
            if ((int)top->dbg_br_n != pbr) {
                if (frame >= lo && frame <= hi)
                    printf("  f%3d 68k /BR = %d %s\n", frame, top->dbg_br_n,
                           top->dbg_br_n ? "(ADSP released)" : "(ADSP halted)");
                pbr = top->dbg_br_n;
            }
            if ((int)top->dbg_halt_n != phalt) {
                if (frame >= lo && frame <= hi)
                    printf("  f%3d 68k /HALT = %d\n", frame, top->dbg_halt_n);
                phalt = top->dbg_halt_n;
            }

            // the moment SomCopyToGsp latches a length
            uint16_t v = top->rootp->vlSymsp->TOP__tb_system_top__core.__PVT__main__DOT__wram[0x2da7];
            if (v != prevlen) {
                prevlen = v;
                int b = top->dbg_adsp_bank;
                bool bad = ((int16_t)v < 0 || v > 16000);
                printf("frame %3d: SomCopyToGsp len=%6d (0x%04x)%s\n"
                       "          68k reads bank %d: w0=%04x w1=%04x   (%ld words ever written here)\n"
                       "          adsp fills bank %d: w0=%04x w1=%04x   (%ld words ever written here)\n"
                       "          som_ptr=%u  this frame: bank0 +%ld, bank1 +%ld\n",
                       frame, (int16_t)v, v, bad ? "   <-- BAD" : "",
                       b,   shadow[b][0],   shadow[b][1],   wr[b],
                       b^1, shadow[b^1][0], shadow[b^1][1], wr[b^1],
                       top->dbg_som_ptr, wrf[0], wrf[1]);
                if (bad && !once) {
                    once = true;
                    // where does the -1 terminator actually sit in each bank?
                    for (int bb = 0; bb < 2; bb++) {
                        int term = -1;
                        for (int i = 1; i < 8192; i++) if (shadow[bb][i] == 0xffff) { term = i; break; }
                        printf("          bank %d: first 0xffff at word %d; first 8 words:", bb, term);
                        for (int i = 0; i < 8; i++) printf(" %04x", shadow[bb][i]);
                        printf("\n");
                    }
                }
                fflush(stdout);
            }

            if (frame != lastf) {
                if (lastf >= lo && lastf <= hi) {
                    printf("frame %3d: somlatch b0=%-5ld b1=%-5ld  somclk=%-3ld gint=%-4ld xout=%-3ld "
                           "| 68k reads bank %d  ptr=%u\n",
                           lastf, wrf[0], wrf[1], somclk, gint, xout,
                           top->dbg_adsp_bank, top->dbg_som_ptr);
                    fflush(stdout);
                }
                wrf[0] = wrf[1] = 0; somclk = gint = xout = 0; lastf = frame;
            }
        }
        // TB_SOMLEN: SomCopyToGsp reads the stream length from the first word of
        // the ADSP's SOM block and stashes it at 68k RAM 0xffdb4e (wram[0x2da7]).
        // A bad length there is what drives GspWriteWords off the end of memory.
        if (getenv("TB_SOMLEN")) {
            static uint16_t prev = 0xdead; static int n = 0;
            uint16_t v = top->rootp->vlSymsp->TOP__tb_system_top__core.__PVT__main__DOT__wram[0x2da7];
            if (v != prev && n < 40) {
                n++;
                printf("frame %3d: SOM stream length = %5d (0x%04x)%s\n", frame, (int16_t)v, v,
                       ((int16_t)v < 0 || v > 16000) ? "   <-- BAD" : "");
                fflush(stdout); prev = v;
            }
        }
        // TB_FLAGS: the two command-buffer flags and the trigger word. The 68k
        // waits for a flag to read 0 ("GSP consumed it"); the GSP waits for one
        // to read ffff ("buffer ready"). Any other value deadlocks both.
        if (getenv("TB_FLAGS")) {
            static int lastf = -1;
            if (frame != lastf) {
                if (lastf >= 698 && lastf <= 712) {
                    auto &v = top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem;
                    printf("frame %3d: buf0=%04x buf1=%04x trig=%04x  gsp_pc=%08x 68k=%08x\n",
                           lastf, v[0x100000u+0x39fc0], v[0x100000u+0x3cfc0], v[0x100000u+0x37167],
                           top->dbg_gsp_pc, top->dbg_68k_exepc);
                    fflush(stdout);
                }
                lastf = frame;
            }
        }
        // TB_GSPHIST: where does the GSP spend the stall frames?
        if (getenv("TB_GSPHIST")) {
            static std::map<uint32_t,long> h; static uint32_t pp = 0; static bool printed = false;
            if (frame >= 705 && frame <= 709 && top->dbg_gsp_instr && top->dbg_gsp_pc != pp) {
                h[top->dbg_gsp_pc]++; pp = top->dbg_gsp_pc;
            }
            if (frame >= 710 && !printed && !h.empty()) {
                printed = true;
                std::vector<std::pair<long,uint32_t>> v;
                for (auto &kv : h) v.push_back({kv.second, kv.first});
                std::sort(v.rbegin(), v.rend());
                long tot = 0; for (auto &x : v) tot += x.first;
                printf("GSP PC histogram frames 705-709 (%ld instructions):\n", tot);
                for (size_t i = 0; i < v.size() && i < 12; i++)
                    printf("   %08x  %8ld  %4.1f%%\n", v[i].second, v[i].first, 100.0*v[i].first/tot);
                fflush(stdout);
            }
        }
        // TB_DIWHY: every DI fire (with the vc it matched at) and every change
        // of DPYINT / DPYCTL, so a missed display interrupt can be explained.
        if (getenv("TB_DIWHY") && frame >= 700 && frame <= 712) {
            static uint16_t ip = 0, dpyint = 0xffff, dpyctl = 0xffff;
            if ((top->dbg_gsp_intpend & 0x0400) && !(ip & 0x0400))
                printf("frame %3d: DI fired at vc=%d (dpyint=%d dpyctl=%04x)\n",
                       frame, top->dbg_gsp_vc, top->dbg_gsp_dpyint, top->dbg_gsp_dpyctl);
            ip = top->dbg_gsp_intpend;
            if (top->dbg_gsp_dpyint != dpyint) {
                printf("frame %3d: DPYINT %d -> %d   (vc now %d)\n", frame, dpyint, top->dbg_gsp_dpyint, top->dbg_gsp_vc);
                dpyint = top->dbg_gsp_dpyint;
            }
            if (top->dbg_gsp_dpyctl != dpyctl) {
                printf("frame %3d: DPYCTL %04x -> %04x\n", frame, dpyctl, top->dbg_gsp_dpyctl);
                dpyctl = top->dbg_gsp_dpyctl;
            }
        }
        // TB_IPS: GSP instructions per frame. The core is throttled to one
        // instruction per cen_6m (16 clocks); if the FSM needs more clocks than
        // that on average, the emulated GSP runs slower than the real 6 MHz part
        // and the 68k's GspWaitIrq3 spins (streaming data) waiting for it.
        if (getenv("TB_IPS")) {
            static long n = 0; static int lastf = -1; static uint32_t pp = 0;
            if (top->dbg_gsp_instr && top->dbg_gsp_pc != pp) { n++; pp = top->dbg_gsp_pc; }
            if (frame != lastf) {
                if (lastf >= 700 && lastf <= 713) printf("frame %3d: gsp instructions = %ld\n", lastf, n);
                n = 0; lastf = frame;
            }
        }
        // TB_DILOG: is the GSP's display interrupt actually firing? Count DI
        // set-events per frame and show INTPEND/INTENB, plus the VRAM counter
        // the GSP spins on (FFF716A0 -> vram word 3f16a).
        if (getenv("TB_DILOG")) {
            static uint16_t ip_prev = 0; static int di_sets = 0; static int lastf = -1;
            static int intout_n = 0; static int io_prev2 = 0;
            if (top->dbg_gsp_int && !io_prev2) intout_n++;
            io_prev2 = top->dbg_gsp_int;
            if ((top->dbg_gsp_intpend & 0x0400) && !(ip_prev & 0x0400)) di_sets++;
            ip_prev = top->dbg_gsp_intpend;
            if (frame != lastf) {
                if (lastf >= 690 && lastf <= 715) {
                    auto &vram = top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem;
                    printf("frame %3d: DI sets=%2d intpend=%04x intenb=%04x  counter@fff716a0=%04x gsp_pc=%08x INTOUT=%d\n",
                           lastf, di_sets, top->dbg_gsp_intpend, top->dbg_gsp_intenb,
                           vram[0x100000u + 0x3716a], top->dbg_gsp_pc, intout_n);
                    fflush(stdout);
                }
                di_sets = 0; intout_n = 0; lastf = frame;
            }
        }
        // TB_PCHIST: which 68k routine is emitting the runaway command list?
        if (getenv("TB_PCHIST") && frame >= 705 && frame <= 712) {
            static std::map<uint32_t,long> hist; static long tot = 0;
            if (top->dbg_host_wr) { hist[top->dbg_68k_exepc]++; tot++; }
            if (frame == 712 && tot && !hist.empty()) {
                std::vector<std::pair<long,uint32_t>> v;
                for (auto &kv : hist) v.push_back({kv.second, kv.first});
                std::sort(v.rbegin(), v.rend());
                printf("68k PCs issuing host writes (top 10 of %ld):\n", tot);
                for (size_t i = 0; i < v.size() && i < 10; i++) printf("   %06x  %ld\n", v[i].second, v[i].first);
                fflush(stdout); hist.clear(); tot = 0;
            }
        }
        // TB_HOSTLOG: our 68k's host-port register writes, in MAME's w7.host
        // format (<n> W <reg> <data>), so the two sequences can be diffed.
        if (getenv("TB_HOSTLOG") && frame >= 704 && frame <= 713) {
            static FILE *hf = nullptr; static long hn = 0;
            if (!hf) hf = fopen("../artifacts/host_rtl.txt", "w");
            if (top->dbg_host_wr) { hn++; fprintf(hf, "%ld W %d %04x\n", hn, top->dbg_host_addr, top->dbg_host_wdata); }
            if (frame == 713) { fflush(hf); }
        }
        // TB_FILLLOG: the 68k fills VRAM through the host port; log the walk so
        // we can see where it starts, how long it runs and where it ends.
        if (getenv("TB_FILLLOG") && frame >= 705 && frame <= 715) {
            static int n = 0; static uint32_t first = 0, last = 0; static int lastf = -1;
            if (top->dbg_gmem_req && top->dbg_gmem_ack && top->dbg_gmem_we) {
                if (n == 0) { first = top->dbg_gmem_addr; printf("frame %d: host fill starts at %07x wd=%04x\n", frame, first, top->dbg_gmem_wdata); }
                last = top->dbg_gmem_addr; n++; lastf = frame;
                if (top->dbg_gmem_addr >= 0x0fffff00u && n < 100000)
                    printf("frame %d: write near top  addr=%07x wd=%04x (write #%d)\n", frame, top->dbg_gmem_addr, top->dbg_gmem_wdata, n);
            }
            if (frame == 715 && n) { printf("fill summary: %d writes, first=%07x last=%07x\n", n, first, last); n = 0; }
        }
        // TB_VECWATCH: catch the moment the DI vector word changes, with the
        // PCs of both CPUs and the GSP's current memory request, so we can see
        // who overwrites the vectors at the top of VRAM.
        if (getenv("TB_VECWATCH") && frame >= 640) {   // cheap until the window of interest
            auto &vram = top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem;
            static uint16_t prev_lo = 0, prev_hi = 0; static bool init = false; static int hits = 0;
            uint16_t lo = vram[0x100000u + 0x3ffea], hi = vram[0x100000u + 0x3ffeb];
            if (!init) { prev_lo = lo; prev_hi = hi; init = true; }
            else if ((lo != prev_lo || hi != prev_hi) && hits < 8) {
                hits++;
                printf("frame %d: DI vector %04x%04x -> %04x%04x  gsp_pc=%08x 68k_pc=%08x gmem(req=%d we=%d addr=%07x wd=%04x)\n",
                       frame, prev_hi, prev_lo, hi, lo, top->dbg_gsp_pc, top->dbg_68k_pc,
                       top->dbg_gmem_req, top->dbg_gmem_we, top->dbg_gmem_addr, top->dbg_gmem_wdata);
                fflush(stdout);
                prev_lo = lo; prev_hi = hi;
            }
        }
        // TB_VECDUMP: the GSP interrupt vectors live in the top of VRAM
        // (bit fffffe80..ffffffe0 -> vram words 3ffe8..3fffe). Print them once
        // per interval so we can see whether the 68k's GSP download ever wrote
        // them, and whether something later wipes them.
        if (getenv("TB_VECDUMP") && frame != vec_lastf && (frame % 60) == 0) {
            vec_lastf = frame;
            auto &vram = top->rootp->vlSymsp->TOP__tb_system_top.chip__DOT__mem;
            printf("frame %3d vectors:", frame);
            for (uint32_t w : {0x3ffe8u, 0x3ffeau, 0x3ffecu, 0x3ffeeu, 0x3fffeu}) {
                uint32_t base = 0x100000u + w;   // VRAM_BASE in the SDRAM word map
                printf(" %04x%04x", vram[base + 1], vram[base]);
            }
            printf("\n"); fflush(stdout);
        }
        if (getenv("TB_GSPRING")) {
            static uint16_t ip_prev = 0;
            if (top->dbg_gsp_intpend != ip_prev) {
                uint16_t set = top->dbg_gsp_intpend & ~ip_prev;
                if (set & 0x0800) printf("frame %d: WV interrupt REQUESTED  control=%04x intenb=%04x gsp_pc=%08x\n",
                                         frame, top->dbg_gsp_control, top->dbg_gsp_intenb, top->dbg_gsp_pc);
                ip_prev = top->dbg_gsp_intpend;
            }
            static std::vector<uint32_t> ring(256, 0); static size_t rp = 0; static bool dumped = false;
            static uint32_t prevpc = 0;
            if (top->dbg_gsp_instr && top->dbg_gsp_pc != prevpc) {
                prevpc = top->dbg_gsp_pc;
                ring[rp++ & 255] = top->dbg_gsp_pc;
                if (top->dbg_gsp_pc == 0xfffffff0)
                    printf("frame %d: GSP jumped to fffffff0  int_vec=%08x fr_addr=%08x fr_val=%08x intpend=%04x intenb=%04x\n",
                           frame, top->dbg_gsp_intvec, top->dbg_gsp_fraddr, top->dbg_gsp_frval,
                           top->dbg_gsp_intpend, top->dbg_gsp_intenb);
                if (!dumped && (top->dbg_gsp_pc >> 20) != 0xfff && top->dbg_gsp_pc != 0) {
                    dumped = true;
                    printf("GSP left ROM at frame %d, pc=%08x -- last %d PCs:\n", frame, top->dbg_gsp_pc, 64);
                    for (size_t k = (rp >= 64 ? rp - 64 : 0); k < rp; k++)
                        printf("   %08x\n", ring[k & 255]);
                    fflush(stdout);
                }
            }
        }
        if (top->cen_pix) {
            if (top->vsync && !prev_vs) {
                // frame done
                static int snap_from = getenv("TB_SNAP_FROM") ? atoi(getenv("TB_SNAP_FROM")) : 0;
                if (snap_every > 0 && frame >= snap_from && frame % snap_every == 0) {
                    static const char *sd = getenv("TB_SNAPDIR") ? getenv("TB_SNAPDIR") : "../artifacts/sim";
                    char name[256]; snprintf(name, sizeof name, "%s/frame%05d.png", sd, frame);
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
                // TB_STICKX / TB_STICKY = value (decimal), TB_STICK_FRAME = from which frame:
                // drive the yoke ADC inputs, to test the whole ADC path in-system.
                {
                    static int sf = getenv("TB_STICK_FRAME") ? atoi(getenv("TB_STICK_FRAME")) : -1;
                    if (sf >= 0 && frame >= sf) {
                        if (getenv("TB_STICKX")) top->stick_x = atoi(getenv("TB_STICKX")) & 0xff;
                        if (getenv("TB_STICKY")) top->stick_y = atoi(getenv("TB_STICKY")) & 0xff;
                    }
                }
                if (start_frame >= 0) { top->start = (frame >= start_frame && frame < start_frame + 6); }
                // TB_FIRE_FRAME: press Fire ("trigger") for 6 frames at that frame -- starts a level
                { static int ff = getenv("TB_FIRE_FRAME") ? atoi(getenv("TB_FIRE_FRAME")) : -1;
                  if (ff >= 0) top->fire = (frame >= ff && frame < ff + 6); }
                // TB_INPUTS=file: replay a tools/record_inputs.lua log ("frame x y fire boost coin start"
                // per line) -- the inputs MAME saw at frame N are applied at our frame N + TB_INPUTS_OFFSET
                // (default 18, our boot lag), so a played level can be reproduced frame for frame.
                {
                    static std::vector<std::array<int, 6>> rec; static bool loaded = false;
                    static int off = getenv("TB_INPUTS_OFFSET") ? atoi(getenv("TB_INPUTS_OFFSET")) : 18;
                    if (!loaded && getenv("TB_INPUTS")) {
                        loaded = true;
                        if (FILE *fi = fopen(getenv("TB_INPUTS"), "r")) {
                            int f, x, y, fr, bo, co, st;
                            while (fscanf(fi, "%d %d %d %d %d %d %d", &f, &x, &y, &fr, &bo, &co, &st) == 7) {
                                if ((int)rec.size() <= f) rec.resize(f + 1, {0x80, 0x80, 0, 0, 0, 0});
                                rec[f] = {x, y, fr, bo, co, st};
                            }
                            fclose(fi);
                            printf("TB_INPUTS: %zu frames of recorded inputs, offset %d\n", rec.size(), off);
                        }
                    }
                    int rf = frame - off;
                    if (!rec.empty() && rf >= 0 && rf < (int)rec.size()) {
                        top->stick_x = rec[rf][0] & 0xff; top->stick_y = rec[rf][1] & 0xff;
                        top->fire = rec[rf][2]; top->boost = rec[rf][3]; top->coin1 = rec[rf][4]; top->start = rec[rf][5];
                    }
                }
                printf("frame %d cyc %llu 68k %08x opc %08x gsp %08x adsp %04x flags %02x\n", frame, (unsigned long long)cyc,
                       top->dbg_68k_pc, top->dbg_68k_opc, top->dbg_gsp_pc, top->dbg_adsp_pc, top->dbg_flags);
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
    if (g_sim_mismatches) printf("SIM ROM words wrong: %ld\n", g_sim_mismatches);
    printf("%s\n", (merr || g_sim_mismatches) ? "FAIL" : "PASS");
    delete top;
    return merr ? 1 : 0;
}
