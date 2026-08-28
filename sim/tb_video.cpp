// Frozen-state video bench driver: loads a MAME state dump (registers,
// palette, VRAM) into the bench, runs two frames and writes the second as
// raw RGB (512x240x3) for tools/diff_frames.py to compare with the reference
// renderer's output.
//   Vtb_video_top <state.txt> <state.vram> <out.rgb>
#include "Vtb_video_top.h"
#include "Vtb_video_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <vector>
#include <string>

static Vtb_video_top *top;
static uint64_t cyc = 0;
static inline void tick() { top->clk = 0; top->eval(); top->clk = 1; top->eval(); cyc++; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 4) { fprintf(stderr, "usage: %s state.txt state.vram out.rgb\n", argv[0]); return 2; }
    // parse the state
    std::vector<uint16_t> io(32, 0), plo, phi; int palbank = 0, fine = 0;
    { FILE *f = fopen(argv[1], "r"); if (!f) { perror(argv[1]); return 2; }
      char line[128]; int sec = 0, idx = 0;
      while (fgets(line, sizeof line, f)) {
          if (!strncmp(line, "IOREGS", 6)) { sec = 1; idx = 0; continue; }
          if (!strncmp(line, "PALETTE", 7)) { sec = 2; continue; }
          if (!strncmp(line, "CTLLO", 5)) { sec = 3; continue; }
          if (!strncmp(line, "PALBANK", 7)) { palbank = atoi(line + 8); continue; }
          if (!strncmp(line, "FINESCROLL", 10)) { fine = atoi(line + 11); continue; }
          if (!strncmp(line, "SHIFTREG", 8)) continue;
          if (sec == 1 && idx < 32) { io[idx++] = strtoul(line, nullptr, 16); }
          else if (sec == 2) { unsigned a, b; if (sscanf(line, "%x %x", &a, &b) == 2) { plo.push_back(a); phi.push_back(b); } }
      }
      fclose(f); }
    std::vector<uint8_t> vram; { FILE *f = fopen(argv[2], "rb"); if (!f) { perror(argv[2]); return 2; }
      uint8_t buf[65536]; size_t n; while ((n = fread(buf, 1, sizeof buf, f)) > 0) vram.insert(vram.end(), buf, buf + n); fclose(f); }
    printf("state: HEBLNK %x HSBLNK %x HTOTAL %x VEBLNK %x VSBLNK %x VTOTAL %x DPYCTL %x DPYSTRT %x DPYTAP %x palbank %d fine %d, vram %zu, palette %zu\n",
           io[1], io[2], io[3], io[5], io[6], io[7], io[8], io[9], io[27], palbank, fine, vram.size(), plo.size());

    top = new Vtb_video_top;
    top->reset = 1; top->cen_pix = 0; top->cen_vid = 0;
    top->r_hesync = io[0]; top->r_heblnk = io[1]; top->r_hsblnk = io[2]; top->r_htotal = io[3];
    top->r_vesync = io[4]; top->r_veblnk = io[5]; top->r_vsblnk = io[6]; top->r_vtotal = io[7];
    top->r_dpyctl = io[8]; top->r_dpystrt = io[9]; top->r_dpytap = io[27];
    top->finescroll = fine; top->palbank = palbank;
    top->pal_we_rg = 0; top->pal_we_b = 0;
    // VRAM into the chip model at word 0x100000: dump words are little-endian
    for (size_t i = 0; i + 1 < vram.size(); i += 2)
        top->rootp->tb_video_top__DOT__chip__DOT__mem[0x100000 + i / 2] = vram[i] | (vram[i + 1] << 8);
    for (int i = 0; i < 20; i++) tick();
    // palette
    for (size_t i = 0; i < plo.size() && i < 1024; i++) {
        top->pal_waddr = i; top->pal_wdata = plo[i]; top->pal_we_rg = 1; top->pal_we_b = 0; tick();
        top->pal_wdata = phi[i]; top->pal_we_rg = 0; top->pal_we_b = 1; tick();
    }
    top->pal_we_b = 0;
    top->reset = 0;

    // run: cen_vid every 19.2 clocks (5 MHz), cen_pix twice per cen_vid
    std::vector<uint8_t> fb(512 * 240 * 3, 0);
    uint32_t acc_v = 0, acc_p = 0; const uint32_t INC_V = 223696213u, INC_P = 447392427u;
    int frames = 0, x = 0, y = -1, prev_vs = 0, prev_hs = 0, prev_de = 0;
    while (frames < 3 && cyc < 96000000ULL) {
        uint64_t nv = (uint64_t)acc_v + INC_V; top->cen_vid = nv >> 32; acc_v = (uint32_t)nv;
        uint64_t np = (uint64_t)acc_p + INC_P; top->cen_pix = np >> 32; acc_p = (uint32_t)np;
        tick();
        if (getenv("TB_DEBUG")) {
            static int words = 0, dones = 0, reqs = 0; static int lines = 0;
            if (top->dbg_b_wr) words++;
            if (top->dbg_b_done) dones++;
            if (top->dbg_line_start) {
                if (frames == 1 && lines < 40) printf("line vcount=%d dpyadr=%04x rowaddr=%03x col0=%03x seg1=%d seg2=%d need2=%d | prev line: words %d dones %d busy_now %d\n",
                    top->vcount_o, top->dbg_dpyadr, top->dbg_rowaddr, top->dbg_col0, top->dbg_seg1_len, top->dbg_seg2_len, top->dbg_need_second, words, dones, top->dbg_fetch_busy);
                if (frames == 1) lines++;
                words = 0; dones = 0;
            }
        }
        if (top->cen_pix) {
            if (top->vsync && !prev_vs) { frames++; y = -1; }
            if (top->de && !prev_de) { y++; x = 0; }
            if (top->de && frames == 2 && y >= 0 && y < 240 && x < 512) {
                size_t o = (size_t(y) * 512 + x) * 3; fb[o] = top->r; fb[o + 1] = top->g; fb[o + 2] = top->b;
            }
            if (top->de) x++;
            prev_vs = top->vsync; prev_de = top->de; prev_hs = top->hsync;
        }
    }
    FILE *o = fopen(argv[3], "wb"); fwrite(fb.data(), 1, fb.size(), o); fclose(o);
    printf("frames %d, cycles %llu, line_late %d, model errors %u\n", frames, (unsigned long long)cyc, top->line_late, top->model_errors);
    return (frames >= 3 && !top->model_errors) ? 0 : 1;
}
