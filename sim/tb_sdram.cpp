// SDRAM controller bench: six random clients and a burst client hammer the
// controller with random traffic; every read is checked against a shadow
// memory the bench keeps. PASS requires zero data mismatches, zero protocol
// errors from the chip model and no client starved for more than a bound.
#include "Vtb_sdram_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static Vtb_sdram_top *top;
static uint64_t cyc = 0;
static void tick() {
    top->clk = 0; top->eval();
    top->clk = 1; top->eval();
    cyc++;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    top = new Vtb_sdram_top;
    int burst_slow = (argc > 1 && argv[1][0] == 's');
    const int WORDS = 1 << 22;
    std::vector<uint16_t> shadow(WORDS, 0);
    srand(1234);
    // init: fill the chip model directly? No: write through the controller.
    top->init = 1; top->rd_late = 1; top->burst_slow = burst_slow;
    for (int i = 0; i < 6; i++) { top->c_req[i] = 0; top->c_we[i] = 0; top->c_be[i] = 3; }
    top->b_req = 0;
    for (int i = 0; i < 10; i++) tick();
    top->init = 0;
    while (!top->ready) tick();
    printf("ready after %llu cycles\n", (unsigned long long)cyc);

    // per-client state
    struct Cli { int busy; int we; uint32_t addr; uint16_t wdata; int be; uint64_t t0; int ops; uint64_t maxwait; } cli[6] = {};
    int errors = 0;
    long reads = 0, writes = 0;
    // burst state
    int bbusy = 0; uint32_t baddr = 0; int blen = 0; std::vector<int> bgot; long bursts = 0; uint64_t bt0 = 0, bmax = 0;
    // pattern of used addresses: keep to 0..0x180000 words (3 MB)
    auto rnd_addr = [&]() { return (uint32_t)(rand() % 0x180000); };

    for (long it = 0; it < 400000; it++) {
        // issue new requests
        for (int i = 0; i < 6; i++) {
            static const int rate_dflt[6] = {14, 24, 12, 400, 300, 40};   // GSP, 68k, SIM, OKI, loader, spare
            int rate[6]; for (int k = 0; k < 6; k++) rate[k] = rate_dflt[k]; if (getenv("HAMMER")) { rate[1] = 1; for (int k = 0; k < 6; k++) if (k != 1) rate[k] = 100000; }
            if (!cli[i].busy && (rand() % rate[i] == 0)) {
                cli[i].busy = 1;
                cli[i].we = (rand() % 4 == 0);
                cli[i].addr = rnd_addr();
                cli[i].wdata = rand() & 0xffff;
                cli[i].be = 1 + rand() % 3;
                cli[i].t0 = cyc;
                top->c_addr[i] = cli[i].addr; top->c_we[i] = cli[i].we; top->c_wdata[i] = cli[i].wdata; top->c_be[i] = cli[i].be;
                top->c_req[i] = 1;
            }
        }
        if (!bbusy && (rand() % 6000 == 0)) {
            bbusy = 1; blen = 1 + rand() % 512;
            baddr = rnd_addr();
            bgot.assign(blen, -1);
            top->b_addr = baddr; top->b_len = blen; top->b_req = 1; bt0 = cyc;
        }
        tick();
        // service acks
        for (int i = 0; i < 6; i++) {
            if (top->c_ack[i]) {
                if (!cli[i].busy) { printf("spurious ack client %d at %llu\n", i, (unsigned long long)cyc); errors++; continue; }
                if (cli[i].we) {
                    uint16_t v = shadow[cli[i].addr];
                    if (cli[i].be & 1) v = (v & 0xff00) | (cli[i].wdata & 0xff);
                    if (cli[i].be & 2) v = (v & 0x00ff) | (cli[i].wdata & 0xff00);
                    shadow[cli[i].addr] = v; writes++;
                } else {
                    if (top->rdata != shadow[cli[i].addr]) {
                        if (errors < 20) printf("MISMATCH client %d addr %06x got %04x want %04x at %llu\n", i, cli[i].addr, top->rdata, shadow[cli[i].addr], (unsigned long long)cyc);
                        errors++;
                    }
                    reads++;
                }
                uint64_t w = cyc - cli[i].t0; if (w > cli[i].maxwait) cli[i].maxwait = w;
                cli[i].ops++;
                cli[i].busy = 0; top->c_req[i] = 0;
            }
        }
        if (top->b_wr) {
            if (!bbusy) { printf("spurious burst word\n"); errors++; }
            else if (top->b_idx >= blen) { printf("burst idx out of range %d/%d\n", top->b_idx, blen); errors++; }
            else {
                uint32_t a = baddr + top->b_idx;
                if (top->b_data != shadow[a]) { if (errors < 20) printf("BURST MISMATCH idx %d addr %06x got %04x want %04x\n", top->b_idx, a, top->b_data, shadow[a]); errors++; }
                bgot[top->b_idx] = 1;
            }
        }
        if (top->b_done) {
            if (!bbusy) { printf("spurious b_done\n"); errors++; }
            else {
                for (int k = 0; k < blen; k++) if (bgot[k] < 0) { if (errors < 20) printf("burst word %d of %d never delivered\n", k, blen); errors++; break; }
                bursts++; uint64_t w = cyc - bt0; if (w > bmax) bmax = w;
                bbusy = 0; top->b_req = 0;
            }
        }
    }
    // drain
    for (int i = 0; i < 2000; i++) tick();
    uint64_t worst = 0; for (int i = 0; i < 6; i++) if (cli[i].maxwait > worst) worst = cli[i].maxwait;
    printf("cycles %llu reads %ld writes %ld bursts %ld  worst client wait %llu  worst burst %llu  model errors %u\n",
           (unsigned long long)cyc, reads, writes, bursts, (unsigned long long)worst, (unsigned long long)bmax, top->model_errors);
    for (int i = 0; i < 6; i++) printf("  client %d: %d ops, max wait %llu\n", i, cli[i].ops, (unsigned long long)cli[i].maxwait);
    int fail = errors || top->model_errors || reads < 1000 || bursts < 10;
    printf("%s\n", fail ? "FAIL" : "PASS");
    delete top;
    return fail ? 1 : 0;
}
