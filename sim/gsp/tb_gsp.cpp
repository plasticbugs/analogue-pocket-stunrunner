// TMS34010 trace bench: load a MAME snapshot (VRAM + registers), replay the
// 68010 host-interface accesses at the instruction they became visible, run the
// RTL and compare PC/ST/SP/A0-A14/B0-B14 against MAME's per-instruction trace.
// At the end compare VRAM against MAME's end-of-window dump.
//
//   tb_gsp <prefix> [max_instructions]
//   files: <prefix>_start.regs/.vram, <prefix>.trace, <prefix>.host, <prefix>_end.vram
//
// The bench models the multisync board's GSP address decode (VRAM + mirror,
// the 2bpp expander, control_lo/hi latches, palette RAM, shift-register
// transfers) exactly as harddriv_v.cpp does, because the final VRAM compare
// depends on it.
#include "Vtb_gsp_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <fstream>
#include <sstream>
#include <deque>

static const char *regnames[31] = {"A0","A1","A2","A3","A4","A5","A6","A7","A8","A9","A10","A11","A12","A13","A14","SP",
    "B14","B13","B12","B11","B10","B9","B8","B7","B6","B5","B4","B3","B2","B1","B0"};

struct TraceLine { uint32_t pc, st, sp, a[15], b[15]; uint32_t h; std::string dis; bool pflag; std::string mnem; };
struct HostAcc { uint32_t n; bool wr; int reg; uint16_t data; };

static std::vector<uint16_t> vram(262144);     // 512 KB
static uint16_t ctl_lo[16], ctl_hi[16], pal_lo[1024], pal_hi[1024];
static int palbank = 0, finescroll = 0, shiftreg_en = 0;
static uint32_t shiftreg_src = 0;
static uint32_t vram_mask = 262143;

// harddriv_v.cpp mask_table for the multisync board (2bpp write)
static long g_watch = -1; static const char *g_cur_dis = ""; static long g_cur_idx = 0; static const TraceLine *g_cur = nullptr; static uint16_t g_ctl = 0, g_convdp = 0;
static void watch_hit(uint32_t idx, const char *how, uint32_t bitaddr, uint16_t data) {
    if (g_watch >= 0 && (long)idx == g_watch) {
        printf("WATCH word %06lx via %s bitaddr=%08x data=%04x now=%04x at trace #%ld %s\n", g_watch, how, bitaddr, data, vram[idx], g_cur_idx, g_cur_dis);
        if (g_cur) { printf("      B:"); for (int i = 0; i < 15; i++) printf(" B%d=%08X", i, g_cur->b[i]); printf(" CONTROL=%04X CONVDP=%04X\n", g_ctl, g_convdp); }
    }
}
static void expander_write(uint32_t wordoff, uint16_t data) {
    // dest = &vram[offset*4] (uint16 units); two 32-bit words; mask bits 0,2,4,6 / 8,10,12,14
    uint32_t color = ctl_lo[0];
    uint32_t c32 = color | (color << 16);
    uint32_t base = (wordoff * 4) & vram_mask;
    for (int w = 0; w < 2; w++) {
        uint32_t mask = 0;
        int bits = (w == 0) ? data & 0xff : (data >> 8) & 0xff;
        if (bits & 0x01) mask |= 0x000000ff;
        if (bits & 0x04) mask |= 0x0000ff00;
        if (bits & 0x10) mask |= 0x00ff0000;
        if (bits & 0x40) mask |= 0xff000000;
        uint32_t idx = (base + w * 2) & vram_mask;
        uint32_t old = vram[idx] | ((uint32_t)vram[(idx + 1) & vram_mask] << 16);
        uint32_t nw = (old & ~mask) | (c32 & mask);
        vram[idx] = nw & 0xffff;
        vram[(idx + 1) & vram_mask] = nw >> 16;
        watch_hit(idx, "expander", 0x02000000 + (wordoff << 4), data); watch_hit((idx + 1) & vram_mask, "expander", 0x02000000 + (wordoff << 4), data);
    }
}

static void srt_read(uint32_t bitaddr) {   // to_shiftreg: latch source
    if (bitaddr >= 0x02000000 && bitaddr <= 0x020fffff) {
        uint32_t a = (bitaddr - 0x02000000) >> 2; a &= vram_mask; a &= ~1023u; shiftreg_src = a;
    } else if (bitaddr >= 0xff800000) {
        uint32_t a = (bitaddr - 0xff800000) / 16; a &= vram_mask; a &= ~255u; shiftreg_src = a;
    }
}
static void srt_write(uint32_t bitaddr) {  // from_shiftreg: copy row
    if (!shiftreg_en) return;
    if (bitaddr >= 0x02000000 && bitaddr <= 0x020fffff) {
        uint32_t a = (bitaddr - 0x02000000) >> 2; a &= vram_mask; a &= ~1023u;
        std::vector<uint16_t> tmp(1024); for (int i = 0; i < 1024; i++) tmp[i] = vram[(shiftreg_src + i) & vram_mask];
        for (int i = 0; i < 1024; i++) vram[(a + i) & vram_mask] = tmp[i];
    } else if (bitaddr >= 0xff800000) {
        uint32_t a = (bitaddr - 0xff800000) / 16; a &= vram_mask; a &= ~255u;
        std::vector<uint16_t> tmp(256); for (int i = 0; i < 256; i++) tmp[i] = vram[(shiftreg_src + i) & vram_mask];
        for (int i = 0; i < 256; i++) vram[(a + i) & vram_mask] = tmp[i];
        if (g_watch >= 0 && (uint32_t)g_watch >= a && (uint32_t)g_watch < a + 256)
            printf("WATCH word %06lx via srt-row-copy from row %u (word %06x) data=%04x at trace #%ld %s\n", g_watch, shiftreg_src / 256, shiftreg_src + ((uint32_t)g_watch - a), tmp[(uint32_t)g_watch - a], g_cur_idx, g_cur_dis);
    }
}

static uint16_t mem_read(uint32_t waddr, bool srt) {
    uint32_t bitaddr = waddr << 4;
    if (srt) { srt_read(bitaddr); return 0; }
    if (bitaddr >= 0xff800000) return vram[(waddr - 0x0ff80000) & vram_mask];
    if (bitaddr >= 0x02000000 && bitaddr <= 0x020fffff) return 0;
    if ((bitaddr & 0xffffff00) == 0xf4000000) return ctl_lo[(bitaddr >> 4) & 15];
    if ((bitaddr & 0xffffff00) == 0xf4800000) return ctl_hi[(bitaddr >> 4) & 15];
    if ((bitaddr & 0xfffff000) == 0xf5000000) return pal_lo[palbank * 256 + ((bitaddr >> 4) & 0xff)];
    if ((bitaddr & 0xfffff000) == 0xf5800000) return pal_hi[palbank * 256 + ((bitaddr >> 4) & 0xff)];
    return 0xffff;
}
static void mem_write(uint32_t waddr, uint16_t data, bool srt) {
    uint32_t bitaddr = waddr << 4;
    if (srt) { srt_write(bitaddr); return; }
    if (bitaddr >= 0xff800000) { vram[(waddr - 0x0ff80000) & vram_mask] = data; watch_hit((waddr - 0x0ff80000) & vram_mask, "vram", bitaddr, data); return; }
    if (bitaddr >= 0x02000000 && bitaddr <= 0x020fffff) { expander_write(waddr - 0x00200000, data); return; }
    if ((bitaddr & 0xffffff00) == 0xf4000000) { ctl_lo[(bitaddr >> 4) & 15] = data; return; }
    if ((bitaddr & 0xffffff00) == 0xf4800000) {
        int off = (bitaddr >> 4) & 15; int val = (off >> 3) & 1;
        ctl_hi[off] = data;
        switch (off & 7) {
            case 0: shiftreg_en = val; break;
            case 1: finescroll = data & 7; break;
            case 2: palbank = (palbank & ~1) | val; break;
            case 3: palbank = (palbank & ~2) | (val << 1); break;
            default: break;
        }
        return;
    }
    if ((bitaddr & 0xfffff000) == 0xf5000000) { pal_lo[palbank * 256 + ((bitaddr >> 4) & 0xff)] = data; return; }
    if ((bitaddr & 0xfffff000) == 0xf5800000) { pal_hi[palbank * 256 + ((bitaddr >> 4) & 0xff)] = data; return; }
}

static bool load_vram(const std::string &f, std::vector<uint16_t> &v) {
    FILE *fp = fopen(f.c_str(), "rb"); if (!fp) return false;
    std::vector<uint8_t> raw(524288);
    size_t n = fread(raw.data(), 1, raw.size(), fp); fclose(fp);
    if (n != raw.size()) return false;
    for (size_t i = 0; i < 262144; i++) v[i] = raw[2*i] | (raw[2*i+1] << 8);
    return true;
}

static bool parse_trace_line(const std::string &l, TraceLine &t) {
    // PC=%08X ST=%08X SP=%08X A0=.. .. B14=.. H=%04X
    if (l.compare(0, 3, "PC=") != 0) return false;
    const char *s = l.c_str();
    unsigned v;
    if (sscanf(s, "PC=%x ST=%x SP=%x", &t.pc, &t.st, &t.sp) != 3) return false;
    const char *p = s;
    for (int i = 0; i < 15; i++) { char key[8]; snprintf(key, sizeof key, " A%d=", i); p = strstr(p, key); if (!p) return false; sscanf(p + strlen(key), "%x", &v); t.a[i] = v; }
    for (int i = 0; i < 15; i++) { char key[8]; snprintf(key, sizeof key, " B%d=", i); p = strstr(p, key); if (!p) return false; sscanf(p + strlen(key), "%x", &v); t.b[i] = v; }
    p = strstr(p, " H="); if (!p) return false; sscanf(p + 3, "%x", &v); t.h = v;
    t.pflag = (t.st >> 25) & 1;
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: tb_gsp <prefix> [max]\n"); return 2; }
    std::string prefix = argv[1];
    long maxinstr = (argc > 2) ? atol(argv[2]) : 100000000L;
    if (getenv("GSP_WATCH")) g_watch = strtol(getenv("GSP_WATCH"), nullptr, 16);

    // ---- load start state
    std::vector<uint16_t> vram_end(262144);
    if (!load_vram(prefix + "_start.vram", vram)) { fprintf(stderr, "cannot read start vram\n"); return 2; }
    bool have_end = load_vram(prefix + "_end.vram", vram_end);
    uint32_t regs[31] = {0}, start_pc = 0, start_st = 0; uint16_t ioregs[32] = {0};
    {
        std::ifstream f(prefix + "_start.regs"); std::string line; int ioi = -1, cli = -1, chi = -1, pi = -1;
        while (std::getline(f, line)) {
            if (line == "IOREGS") { ioi = 0; continue; }
            if (line == "CTLLO") { ioi = -1; cli = 0; continue; }
            if (line == "CTLHI") { cli = -1; chi = 0; continue; }
            if (line == "PALETTE") { chi = -1; pi = 0; continue; }
            if (line.compare(0, 6, "LATCH ") == 0) { chi = -1; sscanf(line.c_str(), "LATCH %d %d %d", &palbank, &finescroll, &shiftreg_en); continue; }
            if (ioi >= 0 && ioi < 32) { ioregs[ioi++] = strtoul(line.c_str(), nullptr, 16); continue; }
            if (cli >= 0 && cli < 16) { ctl_lo[cli++] = strtoul(line.c_str(), nullptr, 16); continue; }
            if (chi >= 0 && chi < 16) { ctl_hi[chi++] = strtoul(line.c_str(), nullptr, 16); continue; }
            if (pi >= 0 && pi < 1024) { unsigned a, b; if (sscanf(line.c_str(), "%x %x", &a, &b) == 2) { pal_lo[pi] = a; pal_hi[pi] = b; } pi++; continue; }
            std::istringstream ss(line); std::string k, v; ss >> k >> v;
            if (k == "PC") start_pc = strtoul(v.c_str(), nullptr, 16);
            else if (k == "ST") start_st = strtoul(v.c_str(), nullptr, 16);
            else if (k == "SP") regs[15] = strtoul(v.c_str(), nullptr, 16);
            else for (int i = 0; i < 31; i++) if (k == regnames[i]) regs[i] = strtoul(v.c_str(), nullptr, 16);
        }
    }
    // ---- host log
    std::vector<HostAcc> host;
    {
        std::ifstream f(prefix + ".host"); std::string line;
        while (std::getline(f, line)) { HostAcc h; char rw; unsigned d; if (sscanf(line.c_str(), "%u %c %d %x", &h.n, &rw, &h.reg, &d) == 4) { h.wr = (rw == 'W'); h.data = d; host.push_back(h); } }
    }
    // ---- trace (streamed)
    std::ifstream tf(prefix + ".trace");
    if (!tf) { fprintf(stderr, "cannot read trace\n"); return 2; }

    // MAME's frame-boundary register dump can sit one instruction past the
    // first traced instruction (the dump reads m_pc after the scheduler moved
    // on); the trace's first entry is the pre-execution state, so prefer it.
    {
        std::streampos pos = tf.tellg(); std::string l0; TraceLine t0;
        while (std::getline(tf, l0)) if (parse_trace_line(l0, t0)) break;
        tf.clear(); tf.seekg(pos);
        if (t0.pc != start_pc) printf("note: dump PC %08x differs from first traced PC %08x; using the trace\n", start_pc, t0.pc);
        start_pc = t0.pc; start_st = t0.st; regs[15] = t0.sp;
        for (int i = 0; i < 15; i++) { regs[i] = t0.a[i]; regs[30 - i] = t0.b[i]; }
    }

    Vtb_gsp_top *top = new Vtb_gsp_top;
    auto tick = [&]() {
        top->clk = 0; top->eval();
        // memory model: respond to requests with a random 1..6 cycle latency
        static int lat = 0; static bool busy = false;
        top->mem_ack = 0;
        if (top->mem_req && !busy) { busy = true; lat = 1 + (rand() % 6); }
        if (busy) {
            if (--lat == 0) {
                busy = false;
                if (top->mem_we) mem_write(top->mem_addr, top->mem_wdata, top->mem_srt);
                else top->mem_rdata = mem_read(top->mem_addr, top->mem_srt);
                top->mem_ack = 1;
            }
        }
        top->clk = 1; top->eval();
        top->host_rd = 0; top->host_wr = 0; top->dbg_force_di = 0; top->dbg_force_int = 0; top->ld_en = 0;
        top->clk = 0; top->eval();
    };

    top->clk = 0; top->reset = 1; top->cen = 1; top->halt_n = 1; top->mem_ack = 0; top->mem_rdata = 0;
    top->host_rd = 0; top->host_wr = 0; top->dbg_force_di = 0; top->dbg_int_inhibit = 1; top->dbg_force_int = 0; top->dbg_hold = 1; top->cache_flush = 0; top->ld_en = 0;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0; tick();
    // load state
    auto load = [&](int idx, uint32_t v) { top->ld_en = 1; top->ld_idx = idx; top->ld_val = v; tick(); };
    // the core comes out of reset halted (HSTCTLH.HLT); load everything else
    // first and HSTCTLH last so it only starts running with the full state
    for (int i = 0; i < 31; i++) load(i, regs[i]);
    load(32, start_pc); load(33, start_st);
    for (int i = 0; i < 32; i++) if (i != 16) load(40 + i, ioregs[i]);
    bool halted = (ioregs[16] & 0x8000) != 0;
    load(34, (halted && start_pc == 0) ? 1 : 0);
    load(40 + 16, ioregs[16]);

    // vectors for interrupt detection
    auto rlong = [&](uint32_t bitaddr) { uint32_t w = bitaddr >> 4; return (uint32_t)vram[(w - 0x0ff80000) & vram_mask] | ((uint32_t)vram[(w + 1 - 0x0ff80000) & vram_mask] << 16); };

    size_t hostidx = 0;
    auto apply_host = [&](uint32_t upto) {
        while (hostidx < host.size() && host[hostidx].n <= upto) {
            const HostAcc &h = host[hostidx++];
            top->host_addr = h.reg; top->host_wdata = h.data;
            if (h.wr) top->host_wr = 1; else top->host_rd = 1;
            tick();
            int guard = 0;
            while (!top->host_ready && guard++ < 100000) tick();
            if (guard >= 100000) { printf("FAIL: host access %u never completed\n", h.n); exit(1); }
        }
    };

    long ninstr = 0, ncmp = 0, nforced = 0, nskipped = 0;
    std::deque<std::string> ctx;
    std::string line;
    uint32_t lasth = 0;
    TraceLine t; bool have = false;
    long cycles = 0;
    auto wait_idle = [&]() { int g = 0; while (!top->dbg_idle && g++ < 4000000) { tick(); cycles++; } return g < 4000000; };
    auto wait_instr = [&]() { int g = 0; while (!top->dbg_instr && g++ < 4000000) { tick(); cycles++; } return g < 4000000; };
    if (!wait_idle()) { printf("FAIL: core never idle after load\n"); return 1; }
    // One-entry lookahead. A PIXBLT/FILL whose next traced entry is an interrupt
    // vector was deferred by the hardware, not executed: the 34010 hands the
    // interrupt over before touching SADDR/DADDR/DYDX and re-runs the
    // instruction afterwards. Without the lookahead the bench compares our
    // completed blit against MAME's untouched registers.
    TraceLine tla; bool have_la = false;
    uint32_t deferred_pc = 0xffffffffu;   // a blit the hardware deferred to an interrupt
    auto read_entry = [&](TraceLine &out) -> bool {
        std::string ln;
        while (std::getline(tf, ln)) {
            if (parse_trace_line(ln, out)) {
                std::string dis; std::getline(tf, dis); out.dis = dis;
                size_t c = dis.find(": "); std::string m = (c == std::string::npos) ? "" : dis.substr(c + 2);
                out.mnem = m.substr(0, m.find(' '));
                // MAME re-executes FILL/PIXBLT while it eats cycles: drop the continuation entries
                if ((out.mnem == "FILL" || out.mnem == "PIXBLT") && out.pflag) { nskipped++; continue; }
                return true;
            }
        }
        return false;
    };
    while (ninstr < maxinstr) {
        // next trace entry (tracelog line then disassembly line)
        if (have_la) { t = tla; have = true; have_la = false; }
        else have = read_entry(t);
        if (!have) break;
        have_la = read_entry(tla);
        {
            bool blit = (t.mnem == "FILL" || t.mnem == "PIXBLT");
            uint32_t vdi = rlong(0xfffffea0) & ~0xfu, vhi = rlong(0xfffffec0) & ~0xfu,
                     vwv = rlong(0xfffffe80) & ~0xfu, vnmi = rlong(0xfffffee0) & ~0xfu;
            bool next_is_vec = have_la && (tla.pc == vdi || tla.pc == vhi || tla.pc == vwv || tla.pc == vnmi);
            top->dbg_int_pending = (blit && next_is_vec) ? 1 : 0;
            if (blit && next_is_vec) deferred_pc = t.pc;
        }
        // host accesses that became visible before this instruction (core is parked at the boundary)
        uint32_t h = t.h | (lasth & 0xffff0000u);
        if (h < lasth) h += 0x10000;      // 16-bit counter wrapped
        lasth = h;
        apply_host(h);
        if (!wait_idle()) { printf("FAIL: core not idle after host accesses\n"); return 1; }
        // release and run to the instruction boundary
        top->dbg_hold = 0;
        if (!wait_instr()) { printf("FAIL: no instruction boundary after %ld instructions (pc=%08x halted=%d)\n", ninstr, top->dbg_pc, top->dbg_halted); return 1; }
        // interrupt taken by MAME here?
        if (top->rd_pc != t.pc) {
            uint32_t vdi = rlong(0xfffffea0) & ~0xfu, vhi = rlong(0xfffffec0) & ~0xfu, vwv = rlong(0xfffffe80) & ~0xfu, vnmi = rlong(0xfffffee0) & ~0xfu;
            if (t.pc == vdi || t.pc == vhi || t.pc == vwv || t.pc == vnmi) {
                if (t.pc == vdi) top->dbg_force_di = 1;
                top->dbg_force_int = 1;
                tick(); cycles++;
                nforced++;
                if (!wait_instr()) { printf("FAIL: no boundary after forced interrupt\n"); return 1; }
            }
        }
        // A deferred blit re-executes when the handler returns. MAME traces that
        // re-execution as P-flagged continuation entries, which are filtered out
        // above, so our core sits one instruction behind here: let it run the
        // resumed blit and land on the instruction MAME is showing.
        if (top->rd_pc != t.pc && top->rd_pc == deferred_pc) {
            deferred_pc = 0xffffffffu;
            tick(); cycles++;      // step off the current boundary first
            if (!wait_instr()) { printf("FAIL: no boundary after resumed blit\n"); return 1; }
        }
        // compare
        bool ok = (top->rd_pc == t.pc) && (top->rd_st == t.st) && (top->rd_rf[15] == t.sp);
        for (int i = 0; i < 15 && ok; i++) ok = ok && (top->rd_rf[i] == t.a[i]) && (top->rd_rf[30 - i] == t.b[i]);
        ncmp++;
        if (!ok) {
            printf("FAIL: divergence at instruction %ld (trace entry) after %ld cycles\n", ninstr, cycles);
            for (auto &c : ctx) printf("   %s\n", c.c_str());
            printf(" > %s\n", t.dis.c_str());
            printf("      MAME  PC=%08X ST=%08X SP=%08X\n      RTL   PC=%08X ST=%08X SP=%08X\n", t.pc, t.st, t.sp, top->rd_pc, top->rd_st, top->rd_rf[15]);
            for (int i = 0; i < 15; i++) {
                if (top->rd_rf[i] != t.a[i]) printf("      A%-2d MAME=%08X RTL=%08X\n", i, t.a[i], top->rd_rf[i]);
                if (top->rd_rf[30 - i] != t.b[i]) printf("      B%-2d MAME=%08X RTL=%08X\n", i, t.b[i], top->rd_rf[30 - i]);
            }
            printf("   instructions compared: %ld, forced interrupts: %ld, skipped continuation entries: %ld\n", ncmp, nforced, nskipped);
            return 1;
        }
        ctx.push_back(t.dis); if (ctx.size() > 8) ctx.pop_front();
        g_cur_dis = ctx.back().c_str(); g_cur_idx = ninstr; g_cur = &t; g_ctl = top->rd_io[11]; g_convdp = top->rd_io[20];
        // let the instruction execute and park at the next boundary
        top->dbg_hold = 1;
        tick(); cycles++;
        if (!wait_idle()) { printf("FAIL: instruction at %08x never completed\n", t.pc); return 1; }
        ninstr++;
    }
    // remaining host accesses (after the last traced instruction)
    apply_host(0xffffffffu);
    wait_idle();

    if (getenv("GSP_VRAM_OUT")) {
        FILE *fo = fopen(getenv("GSP_VRAM_OUT"), "wb");
        for (uint32_t i = 0; i < 262144; i++) { uint8_t b[2] = {(uint8_t)(vram[i] & 0xff), (uint8_t)(vram[i] >> 8)}; fwrite(b, 1, 2, fo); }
        fclose(fo);
    }
    printf("compared %ld instructions, %ld forced interrupts, %ld continuation entries skipped, %ld cycles\n", ncmp, nforced, nskipped, cycles);
    if (have_end) {
        long diff = 0; uint32_t first = 0;
        for (uint32_t i = 0; i < 262144; i++) if (vram[i] != vram_end[i]) { if (!diff) first = i; diff++; }
        if (diff) {
            printf("FAIL: VRAM differs in %ld words (first at word %06x: rtl %04x mame %04x)\n", diff, first, vram[first], vram_end[first]);
            return 1;
        }
        printf("VRAM matches MAME end-of-window dump\n");
    }
    printf("PASS\n");
    delete top;
    return 0;
}
