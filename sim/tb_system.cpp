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
#include <map>
#include <algorithm>
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
