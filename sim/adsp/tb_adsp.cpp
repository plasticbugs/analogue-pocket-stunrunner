// ADSP-2100 trace bench.
//
//   tb_adsp <dir> [cen_period] [max_mismatches]
//
// <dir> holds the files written by tools/trace_adsp.lua:
//   adsp_start.txt    registers + PMEM/DMEM at the window start
//   adsp_trace_pc.txt (optional) PC-only stretch
//   adsp_mid.txt      (optional) registers at the switch to the register trace
//   adsp_trace.txt    register trace (registers before each instruction, then PC)
//   adsp_io.txt       ordered data-space access log (R/W by the ADSP, X/P/C by the 68k, M marker)
//   adsp_end.txt      registers + memories at the end
//
// The RTL is loaded with the start state, then run one instruction at a time.
// Before every instruction its architectural state is compared with the trace
// line describing the same moment (PC only in the PC stretch). Every
// data-space access the RTL performs is matched against the log in order; the
// 68k's writes into ADSP data/program RAM (X/P lines) are applied at the
// position the log gives them, which is relative to the ADSP's own accesses.
// I/O reads (0x2000-0x2fff) are served from the logged values, so the SIM ROM
// is not needed; I/O writes are checked against the log.
//
// Exit code 0 = PASS, 1 = FAIL, 2 = usage / file error.
#include "Vtb_adsp_top.h"
#include "Vtb_adsp_top___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <map>
#include <fstream>
#include <sstream>

static Vtb_adsp_top *top;
static Vtb_adsp_top___024root *rp;
static uint64_t cycles = 0;

static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cycles++;
}

// ---- access to the core's state through the public signals -----------------
#define U(x) (rp->tb_adsp_top__DOT__u__DOT__##x)

struct RegState {
    std::map<std::string, uint32_t> v;
};

static bool parse_state_file(const std::string &path, RegState &rs, std::vector<uint32_t> *pmem, std::vector<uint16_t> *dmem) {
    std::ifstream f(path);
    if (!f) { fprintf(stderr, "cannot open %s\n", path.c_str()); return false; }
    std::string line; int mode = 0;
    while (std::getline(f, line)) {
        if (line == "PMEM") { mode = 1; continue; }
        if (line == "DMEM") { mode = 2; continue; }
        if (mode == 0) {
            auto eq = line.find('=');
            if (eq == std::string::npos) continue;
            rs.v[line.substr(0, eq)] = (uint32_t)strtoul(line.c_str() + eq + 1, nullptr, 16);
        } else if (mode == 1) { if (pmem) pmem->push_back((uint32_t)strtoul(line.c_str(), nullptr, 16)); }
        else { if (dmem) dmem->push_back((uint16_t)strtoul(line.c_str(), nullptr, 16)); }
    }
    return true;
}

static uint32_t rv(const RegState &rs, const char *n) {
    auto it = rs.v.find(n);
    return it == rs.v.end() ? 0 : it->second;
}

static void load_state(const RegState &rs) {
    // active set = MAME's primary (current bank), shadow set = _SEC
    uint32_t mstat = rv(rs, "MSTAT") & 0xf;
#define SET(reg, pri, sec) do { U(r_##reg) = (SData)rv(rs, pri); U(x_##reg) = (SData)rv(rs, sec); } while (0)
    SET(ax0, "AX0", "AX0_SEC"); SET(ax1, "AX1", "AX1_SEC");
    SET(ay0, "AY0", "AY0_SEC"); SET(ay1, "AY1", "AY1_SEC");
    SET(ar, "AR", "AR_SEC");    SET(af, "AF", "AF_SEC");
    SET(mx0, "MX0", "MX0_SEC"); SET(mx1, "MX1", "MX1_SEC");
    SET(my0, "MY0", "MY0_SEC"); SET(my1, "MY1", "MY1_SEC");
    SET(mr0, "MR0", "MR0_SEC"); SET(mr1, "MR1", "MR1_SEC");
    SET(mf, "MF", "MF_SEC");    SET(si, "SI", "SI_SEC");
    SET(sr0, "SR0", "SR0_SEC"); SET(sr1, "SR1", "SR1_SEC");
#undef SET
    // MR2 / SE / SB are exported masked+signed by MAME: sign-extend them back
    auto sx = [](uint32_t v, int bits) -> uint16_t { uint32_t m = (1u << bits) - 1; v &= m; if (v & (1u << (bits - 1))) v |= ~m; return (uint16_t)v; };
    U(r_mr2) = sx(rv(rs, "MR2"), 8); U(x_mr2) = sx(rv(rs, "MR2_SEC"), 8);
    U(r_se) = sx(rv(rs, "SE"), 8);   U(x_se) = sx(rv(rs, "SE_SEC"), 8);
    U(r_sb) = sx(rv(rs, "SB"), 5);   U(x_sb) = sx(rv(rs, "SB_SEC"), 5);
    for (int k = 0; k < 8; k++) {
        char n[8];
        snprintf(n, sizeof n, "I%d", k); U(r_i)[k] = rv(rs, n) & 0x3fff;
        snprintf(n, sizeof n, "M%d", k); U(r_m)[k] = rv(rs, n) & 0x3fff;
        snprintf(n, sizeof n, "L%d", k); U(r_l)[k] = rv(rs, n) & 0x3fff;
    }
    // base = i & lmask(l) (steady-state invariant of the circular buffers)
    for (int k = 0; k < 8; k++) {
        uint32_t l = U(r_l)[k], mask;
        if (l > 0x2000) mask = 0; else if (l > 0x1000) mask = 0x2000; else if (l > 0x800) mask = 0x3000;
        else if (l > 0x400) mask = 0x3800; else if (l > 0x200) mask = 0x3c00; else if (l > 0x100) mask = 0x3e00;
        else if (l > 0x80) mask = 0x3f00; else if (l > 0x40) mask = 0x3f80; else if (l > 0x20) mask = 0x3fc0;
        else if (l > 0x10) mask = 0x3fe0; else if (l > 8) mask = 0x3ff0; else if (l > 4) mask = 0x3ff8;
        else if (l > 2) mask = 0x3ffc; else if (l > 1) mask = 0x3ffe; else mask = 0x3fff;
        U(r_base)[k] = U(r_i)[k] & mask;
    }
    U(pc) = rv(rs, "PC") & 0x3fff;
    U(cntr) = rv(rs, "CNTR") & 0x3fff;
    U(astat) = rv(rs, "ASTAT") & 0xff;
    U(sstat) = rv(rs, "SSTAT") & 0xff;
    U(mstat) = mstat;
    U(px) = rv(rs, "PX") & 0xff;
    U(imask) = rv(rs, "IMASK") & 0xf;
    U(icntl) = rv(rs, "ICNTL") & 0x1f;
    U(pc_sp) = rv(rs, "PCSP") & 0x1f;
    U(cntr_sp) = rv(rs, "CNTRSP") & 7;
    U(stat_sp) = rv(rs, "STATSP") & 7;
    U(loop_sp) = rv(rs, "LOOPSP") & 7;
    U(loop_end) = 0x3fff; U(loop_cond) = 0;
}

struct TraceLine {
    uint32_t pc;
    bool has_regs;
    std::map<std::string, uint32_t> regs;
    std::string text;
};

// parse "name=VAL ... PPPP: disasm"  or  "PPPP: disasm"
static bool parse_trace_line(const std::string &line, TraceLine &t) {
    t.has_regs = false; t.regs.clear(); t.text = line;
    // find "XXXX: " token: hex4 followed by ": "
    size_t pos = 0;
    while (true) {
        size_t c = line.find(": ", pos);
        if (c == std::string::npos) return false;
        if (c >= 4) {
            bool ok = true;
            for (size_t k = c - 4; k < c; k++) if (!isxdigit((unsigned char)line[k])) ok = false;
            // MAME's tracelog text ends without a separator, so the PC may be
            // glued to the last register value: the PC is the 4 hex digits
            // right before ": " (14-bit address space, always 4 digits).
            if (ok) {
                t.pc = (uint32_t)strtoul(line.substr(c - 4, 4).c_str(), nullptr, 16);
                if (c > 4) {
                    t.has_regs = true;
                    std::istringstream ss(line.substr(0, c - 4));
                    std::string tok;
                    while (ss >> tok) {
                        auto eq = tok.find('=');
                        if (eq != std::string::npos) t.regs[tok.substr(0, eq)] = (uint32_t)strtoul(tok.c_str() + eq + 1, nullptr, 16);
                    }
                }
                return true;
            }
        }
        pos = c + 1;
    }
}

// current RTL register view in MAME's exported form
static std::map<std::string, uint32_t> rtl_regs() {
    std::map<std::string, uint32_t> r;
    r["ax0"] = U(r_ax0); r["ax1"] = U(r_ax1); r["ay0"] = U(r_ay0); r["ay1"] = U(r_ay1);
    r["ar"] = U(r_ar); r["af"] = U(r_af); r["mx0"] = U(r_mx0); r["mx1"] = U(r_mx1);
    r["my0"] = U(r_my0); r["my1"] = U(r_my1); r["mr0"] = U(r_mr0); r["mr1"] = U(r_mr1);
    r["mr2"] = U(r_mr2) & 0xff; r["mf"] = U(r_mf); r["si"] = U(r_si); r["se"] = U(r_se) & 0xff;
    r["sb"] = U(r_sb) & 0x1f; r["sr0"] = U(r_sr0); r["sr1"] = U(r_sr1);
    for (int k = 0; k < 8; k++) {
        char n[8];
        snprintf(n, sizeof n, "i%d", k); r[n] = U(r_i)[k];
        snprintf(n, sizeof n, "m%d", k); r[n] = U(r_m)[k];
        snprintf(n, sizeof n, "l%d", k); r[n] = U(r_l)[k];
    }
    r["px"] = U(px); r["cntr"] = U(cntr); r["astat"] = U(astat); r["sstat"] = U(sstat); r["mstat"] = U(mstat);
    r["pcsp"] = U(pc_sp); r["cntrsp"] = U(cntr_sp); r["statsp"] = U(stat_sp); r["loopsp"] = U(loop_sp);
    r["imask"] = U(imask); r["icntl"] = U(icntl);
    return r;
}

struct IoEntry { char kind; uint32_t addr; uint32_t val; };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: tb_adsp <dir> [cen_period] [max_mismatches]\n"); return 2; }
    std::string dir = argv[1];
    int cen_period = argc > 2 ? atoi(argv[2]) : 12;
    int max_mis = argc > 3 ? atoi(argv[3]) : 20;
    // IOWAIT=N: hold io_wait for a pseudo-random 0..N clocks after every io_rd,
    // to prove the core tolerates a slow SIM prefetcher (it must skip cen pulses).
    int iowait_max = getenv("IOWAIT") ? atoi(getenv("IOWAIT")) : 0;
    // HALT=N: assert `halt` for a pseudo-random 1..N clocks at pseudo-random
    // moments -- including mid-instruction -- the way the 68k's /BR does in
    // AdspIrqService on the real board. The core must stop only at an
    // instruction boundary and resume with no state disturbed.
    int halt_max = getenv("HALT") ? atoi(getenv("HALT")) : 0;
    int halt_hold = 0;
    uint32_t lfsr = 0xACE1u;

    RegState st0, stmid, stend;
    std::vector<uint32_t> pmem; std::vector<uint16_t> dmem;
    if (!parse_state_file(dir + "/adsp_start.txt", st0, &pmem, &dmem)) return 2;
    bool have_mid = parse_state_file(dir + "/adsp_mid.txt", stmid, nullptr, nullptr);
    std::vector<uint32_t> pmem_end; std::vector<uint16_t> dmem_end;
    bool have_end = parse_state_file(dir + "/adsp_end.txt", stend, &pmem_end, &dmem_end);

    // io log
    std::vector<IoEntry> io;
    {
        std::ifstream f(dir + "/adsp_io.txt");
        if (!f) { fprintf(stderr, "cannot open adsp_io.txt\n"); return 2; }
        std::string line;
        while (std::getline(f, line)) {
            if (line.empty()) continue;
            IoEntry e; e.kind = line[0]; e.addr = 0; e.val = 0;
            if (e.kind != 'M') sscanf(line.c_str() + 2, "%x %x", &e.addr, &e.val);
            io.push_back(e);
        }
    }
    // trace files
    std::vector<std::string> trace_files;
    { std::ifstream f(dir + "/adsp_trace_pc.txt"); if (f) trace_files.push_back(dir + "/adsp_trace_pc.txt"); }
    trace_files.push_back(dir + "/adsp_trace.txt");

    top = new Vtb_adsp_top;
    rp = top->rootp;
    top->clk = 0; top->reset = 1; top->cen = 0; top->halt = 0;
    top->pm_ext_we = 0; top->dm_ext_we = 0; top->pm_ext_addr = 0; top->dm_ext_addr = 0;
    top->io_rdata = 0; top->io_wait = 0; top->irq = 0; top->flag_in = 0;
    for (int i = 0; i < 4; i++) tick();
    top->reset = 0; tick();

    // memories via the 68k ports (exercises them)
    for (size_t i = 0; i < pmem.size() && i < 8192; i++) { top->pm_ext_addr = i; top->pm_ext_wdata = pmem[i]; top->pm_ext_we = 1; tick(); }
    top->pm_ext_we = 0;
    for (size_t i = 0; i < dmem.size() && i < 8192; i++) { top->dm_ext_addr = i; top->dm_ext_wdata = dmem[i]; top->dm_ext_we = 1; tick(); }
    top->dm_ext_we = 0;
    load_state(st0);
    top->eval();

    // the trigger write recorded with the start state (tap fired before it landed)
    // is the first X line of the io log; nothing to do here.

    size_t io_idx = 0;
    uint64_t n_instr = 0, n_acc = 0, n_x = 0, n_p = 0;
    int mismatches = 0;
    bool in_pc_phase = trace_files.size() == 2;
    bool failed = false;
    uint64_t phase_instr = 0;

    auto apply_pending_host = [&]() {
        // apply 68k-side entries that precede the next ADSP access
        while (io_idx < io.size()) {
            IoEntry &e = io[io_idx];
            if (e.kind == 'X') { top->dm_ext_addr = e.addr & 0x1fff; top->dm_ext_wdata = e.val; top->dm_ext_we = 1; tick(); top->dm_ext_we = 0; n_x++; io_idx++; }
            else if (e.kind == 'P') {
                // 68k half-word write: even offset = bits 23:16, odd = bits 15:0
                uint32_t w = e.addr >> 1;
                top->pm_ext_addr = w & 0x1fff; top->pm_ext_we = 0; tick(); tick();
                uint32_t cur = top->pm_ext_rdata;
                uint32_t nv = (e.addr & 1) ? ((cur & 0xff0000) | (e.val & 0xffff)) : ((cur & 0x00ffff) | ((e.val & 0xff) << 16));
                top->pm_ext_wdata = nv; top->pm_ext_we = 1; tick(); top->pm_ext_we = 0; n_p++; io_idx++;
            }
            else if (e.kind == 'C') io_idx++;   // 68k control latch: not replayable by log position -- MAME's
                                                 // HALT line is soft (its ADSP ran ~21 more accesses after /BR=0
                                                 // in the kick window), so use HALT=N random injection instead
            else break;
        }
    };

    auto report_regs = [&](const TraceLine &t, uint64_t idx) {
        auto r = rtl_regs();
        fprintf(stderr, "  instr #%llu trace: %s\n", (unsigned long long)idx, t.text.c_str());
        fprintf(stderr, "  RTL pc=%04X", U(pc));
        for (auto &kv : t.regs) {
            auto it = r.find(kv.first);
            if (it != r.end() && it->second != kv.second)
                fprintf(stderr, " %s=%04X(exp %04X)", kv.first.c_str(), it->second, kv.second);
        }
        fprintf(stderr, "\n");
    };

    auto check_state_file = [&](const RegState &rs, const char *what) {
        // compare the RTL against a full state dump (primary bank + stack pointers)
        auto r = rtl_regs();
        int bad = 0;
        const char *names[] = {"AX0","AX1","AY0","AY1","AR","AF","MX0","MX1","MY0","MY1","MR0","MR1","MR2","MF","SI","SE","SB","SR0","SR1",
                               "I0","I1","I2","I3","I4","I5","I6","I7","L0","L1","L2","L3","L4","L5","L6","L7","M0","M1","M2","M3","M4","M5","M6","M7",
                               "PX","CNTR","ASTAT","SSTAT","MSTAT","PCSP","CNTRSP","STATSP","LOOPSP","IMASK","ICNTL"};
        for (const char *n : names) {
            std::string ln = n; for (auto &c : ln) c = tolower(c);
            uint32_t exp = rv(rs, n), got = r[ln];
            if (ln == "mr2" || ln == "se") exp &= 0xff; else if (ln == "sb") exp &= 0x1f;
            else if (ln[0] == 'm' && ln.size() == 2) exp &= 0x3fff;
            if (exp != got) { fprintf(stderr, "  %s: %s RTL=%04X MAME=%04X\n", what, n, got, exp); bad++; }
        }
        if (U(pc) != (rv(rs, "PC") & 0x3fff)) { fprintf(stderr, "  %s: PC RTL=%04X MAME=%04X\n", what, U(pc), rv(rs, "PC")); bad++; }
        return bad;
    };

    for (size_t tf = 0; tf < trace_files.size() && !failed; tf++) {
        std::ifstream f(trace_files[tf]);
        if (!f) { fprintf(stderr, "cannot open %s\n", trace_files[tf].c_str()); return 2; }
        bool pc_only = in_pc_phase && tf == 0;
        if (!pc_only && have_mid && tf == 1) {
            // consume the M marker and check the mid state
            while (io_idx < io.size() && io[io_idx].kind != 'M') { apply_pending_host(); if (io_idx < io.size() && io[io_idx].kind != 'M') { fprintf(stderr, "io log: unexpected %c entry before the M marker at index %zu\n", io[io_idx].kind, io_idx); failed = true; break; } }
            if (io_idx < io.size() && io[io_idx].kind == 'M') io_idx++;
            int bad = check_state_file(stmid, "mid");
            fprintf(stderr, "mid-window state check: %d differences\n", bad);
            if (bad) { mismatches += bad; }
        }
        std::string line; TraceLine t;
        while (std::getline(f, line) && !failed) {
            if (!parse_trace_line(line, t)) continue;
            // --- compare state before executing this instruction ---
            if (U(pc) != t.pc) {
                fprintf(stderr, "PC mismatch at instr #%llu: RTL %04X, trace %04X (%s)\n", (unsigned long long)n_instr, U(pc), t.pc, t.text.c_str());
                mismatches++;
                if (mismatches >= max_mis) { failed = true; break; }
                U(pc) = t.pc;   // resynchronise to keep going
            }
            if (t.has_regs) {
                auto r = rtl_regs();
                bool bad = false;
                for (auto &kv : t.regs) { auto it = r.find(kv.first); if (it != r.end() && it->second != kv.second) { bad = true; break; } }
                if (bad) { fprintf(stderr, "register mismatch:\n"); report_regs(t, n_instr); mismatches++; if (mismatches >= max_mis) { failed = true; break; } }
            }
            // --- run one instruction ---
            apply_pending_host();
            bool done = false; int guard = 0;
            int io_hold = 0;
            while (!done) {
                // cen pulse every cen_period clocks
                top->cen = (cycles % cen_period) == 0;
                if (io_hold > 0) { top->io_wait = 1; io_hold--; } else top->io_wait = 0;
                if (halt_max) {
                    if (halt_hold > 0) { top->halt = 1; halt_hold--; }
                    else {
                        top->halt = 0;
                        lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u);
                        if ((lfsr % 23) == 0) halt_hold = 1 + (lfsr >> 4) % halt_max;
                    }
                }
                tick();
                top->cen = 0;
                // IO read request: serve from the log
                if (top->io_rd) {
                    apply_pending_host();
                    if (io_idx < io.size() && io[io_idx].kind == 'R' && io[io_idx].addr >= 0x2000) {
                        if (io[io_idx].addr != (0x2000 | top->io_addr)) { fprintf(stderr, "IO read addr mismatch at instr #%llu: RTL %04X log %04X\n", (unsigned long long)n_instr, 0x2000 | top->io_addr, io[io_idx].addr); mismatches++; }
                        top->io_rdata = io[io_idx].val;
                    } else {
                        fprintf(stderr, "IO read at instr #%llu (addr %04X) but log has %c %04X %04X at %zu\n", (unsigned long long)n_instr, 0x2000 | top->io_addr, io_idx < io.size() ? io[io_idx].kind : '-', io_idx < io.size() ? io[io_idx].addr : 0, io_idx < io.size() ? io[io_idx].val : 0, io_idx);
                        mismatches++; top->io_rdata = 0xffff;
                    }
                    if (iowait_max) { lfsr = (lfsr >> 1) ^ (-(lfsr & 1u) & 0xB400u); io_hold = lfsr % (iowait_max + 1); }
                }
                if (top->io_wr) {
                    apply_pending_host();
                    if (io_idx < io.size() && io[io_idx].kind == 'W' && io[io_idx].addr >= 0x2000) {
                        if (io[io_idx].addr != (0x2000 | top->io_addr) || io[io_idx].val != top->io_wdata) {
                            fprintf(stderr, "IO write mismatch at instr #%llu: RTL %04X=%04X log %04X=%04X\n", (unsigned long long)n_instr, 0x2000 | top->io_addr, top->io_wdata, io[io_idx].addr, io[io_idx].val); mismatches++; }
                    } else {
                        fprintf(stderr, "IO write at instr #%llu but log has %c at %zu\n", (unsigned long long)n_instr, io_idx < io.size() ? io[io_idx].kind : '-', io_idx); mismatches++;
                    }
                }
                // data-space accesses as the core performs them
                if (U(dbg_dm_wr)) {
                    apply_pending_host();
                    n_acc++;
                    if (io_idx < io.size() && io[io_idx].kind == 'W') {
                        if (io[io_idx].addr != U(dbg_dm_addr) || io[io_idx].val != U(dbg_dm_data)) {
                            fprintf(stderr, "DM write mismatch at instr #%llu: RTL %04X=%04X log %04X=%04X (%s)\n", (unsigned long long)n_instr, U(dbg_dm_addr), U(dbg_dm_data), io[io_idx].addr, io[io_idx].val, t.text.c_str()); mismatches++; }
                        io_idx++;
                    } else { fprintf(stderr, "DM write at instr #%llu but log has %c at %zu (%s)\n", (unsigned long long)n_instr, io_idx < io.size() ? io[io_idx].kind : '-', io_idx, t.text.c_str()); mismatches++; }
                }
                if (U(dbg_dm_rd)) {
                    apply_pending_host();
                    n_acc++;
                    if (io_idx < io.size() && io[io_idx].kind == 'R') {
                        if (io[io_idx].addr != U(dbg_dm_addr) || io[io_idx].val != U(dbg_dm_data)) {
                            fprintf(stderr, "DM read mismatch at instr #%llu: RTL %04X=%04X log %04X=%04X (%s)\n", (unsigned long long)n_instr, U(dbg_dm_addr), U(dbg_dm_data), io[io_idx].addr, io[io_idx].val, t.text.c_str()); mismatches++; }
                        io_idx++;
                    } else { fprintf(stderr, "DM read at instr #%llu but log has %c at %zu (%s)\n", (unsigned long long)n_instr, io_idx < io.size() ? io[io_idx].kind : '-', io_idx, t.text.c_str()); mismatches++; }
                }
                if (top->dbg_instr_done) done = true;
                if (++guard > 1000 + 4 * halt_max) { fprintf(stderr, "instruction #%llu did not complete (pc %04X)\n", (unsigned long long)n_instr, U(pc)); failed = true; break; }
                if (mismatches >= max_mis) { failed = true; break; }
            }
            n_instr++; phase_instr++;
        }
        fprintf(stderr, "%s: %llu instructions\n", trace_files[tf].c_str(), (unsigned long long)phase_instr);
        phase_instr = 0;
    }

    // end-of-window checks
    int endbad = 0;
    if (!failed && have_end) {
        apply_pending_host();
        endbad = check_state_file(stend, "end");
        // memories: compare data RAM and program RAM through the 68k ports
        int dbad = 0, pbad = 0;
        for (size_t i = 0; i < dmem_end.size() && i < 8192; i++) {
            top->dm_ext_addr = i; tick(); tick();
            if (top->dm_ext_rdata != dmem_end[i]) { if (dbad < 10) fprintf(stderr, "  DMEM[%04zx] RTL=%04X MAME=%04X\n", i, top->dm_ext_rdata, dmem_end[i]); dbad++; }
        }
        for (size_t i = 0; i < pmem_end.size() && i < 8192; i++) {
            top->pm_ext_addr = i; tick(); tick();
            if (top->pm_ext_rdata != pmem_end[i]) { if (pbad < 10) fprintf(stderr, "  PMEM[%04zx] RTL=%06X MAME=%06X\n", i, top->pm_ext_rdata, pmem_end[i]); pbad++; }
        }
        fprintf(stderr, "end-of-window: %d register differences, %d data words differ, %d program words differ\n", endbad, dbad, pbad);
        endbad += dbad + pbad;
    }
    // unconsumed log entries (other than host-side ones) mean the RTL did fewer accesses
    size_t leftover = 0;
    for (size_t k = io_idx; k < io.size(); k++) if (io[k].kind == 'R' || io[k].kind == 'W') leftover++;

    printf("instructions=%llu accesses=%llu host_writes=%llu pgm_writes=%llu leftover_log=%zu mismatches=%d end_diffs=%d cycles=%llu\n",
           (unsigned long long)n_instr, (unsigned long long)n_acc, (unsigned long long)n_x, (unsigned long long)n_p, leftover, mismatches, endbad, (unsigned long long)cycles);
    bool pass = !failed && mismatches == 0 && endbad == 0 && leftover == 0;
    printf("%s\n", pass ? "PASS" : "FAIL");
    delete top;
    return pass ? 0 : 1;
}
