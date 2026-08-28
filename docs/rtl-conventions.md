# RTL conventions for the Stun Runner core

Shared rules so the independently written blocks (TMS34010, ADSP-2100, JSA II
sound board, main-board glue, SDRAM) fit together without a second pass.
Read `docs/hardware.md` first.

## Language and tools

- SystemVerilog only (`.sv`), `default_nettype none`, one module per file,
  synthesisable with Quartus 18.1 **and** clean under
  `verilator --lint-only -Wall` (waivers go in `sim/waivers.vlt`, with a
  reason). No VHDL in new code: the two VHDL cores we reuse (TG68K, T65) are
  converted once with `ghdl synth --out=verilog` into
  `modules/<core>/gen/*.v` and that Verilog is what both Quartus and Verilator
  compile.
- No `initial` blocks for logic, no latches, no asynchronous resets: a single
  synchronous active-high `reset` input per module.
- Block RAMs: 2D-packed byte lanes (`logic [1:0][7:0] mem [N]`) for
  byte-enable writes (METHODOLOGY §5.5). Register the read data (1-cycle
  latency) so Quartus infers M10K.
- Verilator benches are C++ (`sim/tb_*.cpp`) driving a small SV wrapper
  (`sim/tb_*_top.sv`), run by a `sim/run_*.sh` script that prints PASS/FAIL
  and exits non-zero on failure. Every block ships with one.

## Clocks

One system clock, **`clk` = 96 MHz** (`core_pll` outclk_0), for everything
except the Pocket's video/audio output domains. Each machine part runs on a
clock-enable pulse from `clk_enables.sv`:

| enable | rate | derivation |
|---|---|---|
| `cen_8m`  | 8.000 MHz | 96/12 — 68010, ADSP-2100 |
| `cen_6m`  | 6.000 MHz | 96/16 — TMS34010 instruction cycle (CLKIN 48 MHz / 8) |
| `cen_vid` / `cen_pix` | 5.000 / 10.000 MHz | phase accumulators, lock-stepped; GSP video clock and the pixel clock (2 px per video clock) |
| `cen_snd` | 1.789772 MHz | phase accumulator (24-bit add of 1789772·2^24/96e6) — 6502 |
| `cen_ym`  | 3.579545 MHz | phase accumulator — YM2151 |
| `cen_oki` | 1.193181 MHz | phase accumulator — OKI6295 |

A block must never gate `clk`; it samples its `cen` and may also take a
`stall` input that holds it in the current cycle (used by cores whose memory
lives in SDRAM).

## Memory request interface (for anything that touches SDRAM)

```systemverilog
output logic [24:1] m_addr;    // SDRAM word address (byte address >> 1)
output logic        m_req;     // level: held high until m_ack
output logic        m_we;      // 1 = write
output logic [15:0] m_wdata;
output logic [1:0]  m_be;      // byte enables for writes ([0] = D7:0)
input  logic [15:0] m_rdata;   // valid on the cycle m_ack is high
input  logic        m_ack;     // one-cycle pulse; the client drops or changes req the next cycle
```

Variable latency; a client keeps `m_req` high and its address/data stable
until `m_ack`. The controller (`rtl/sdram_ctrl.sv`) gives each client its own
port with these signals; random clients are served round-robin, the display
line fetch uses the separate burst port (chunked so a client never waits more
than 32 words).

## SDRAM map (byte addresses)

| range | content |
|---|---|
| 0x000000-0x0bffff | 68010 ROM |
| 0x0c0000-0x11ffff | ADSP SIM ROM |
| 0x120000-0x15ffff | OKI ADPCM ROM |
| 0x200000-0x27ffff | GSP VRAM (512 KB; GSP bit address `A` → byte `0x200000 + ((A - 0xff800000) >> 3)`, mirror 0x400000 bits) |

## Block interfaces

### `tms34010` (rtl/gsp/tms34010.sv)

```systemverilog
module tms34010 (
    input  logic        clk, reset, cen,        // cen = 6 MHz instruction-cycle enable
    input  logic        halt_n,                 // /GSPRES from the 68k latch: 0 holds the core in reset
    // memory: everything outside the internal I/O register block (0xc0000000-0xc00001ff)
    output logic [31:4] mem_addr,               // 16-bit-word address (bit address >> 4)
    output logic        mem_req, mem_we,
    output logic [15:0] mem_wdata,
    input  logic [15:0] mem_rdata,
    input  logic        mem_ack,
    output logic        mem_srt,                // this access is a VRAM shift-register transfer (DPYCTL.SRT and the access type; see hardware.md §4.6)
    // host interface (68010 side, 16-bit registers 0..3 per hardware.md §4.1)
    input  logic  [1:0] host_addr,
    input  logic        host_rd, host_wr,       // one-cycle pulses in clk domain
    input  logic [15:0] host_wdata,
    output logic [15:0] host_rdata,
    output logic        host_ready,             // host_rdata valid / write done (HSTDATA goes through mem_*)
    output logic        int_out,                // HSTCTLL.INTOUT -> 68k IRQ3
    // video timing outputs (from the internal HCOUNT/VCOUNT)
    output logic        hblank, vblank,         // per HEBLNK/HSBLNK/VEBLNK/VSBLNK
    output logic  [8:0] vcount,
    output logic        line_start,             // pulse at the start of each raster line
    output logic [15:0] dpyadr, dpystrt, dpytap, dpyctl, heblnk, hsblnk,   // for the scan-out block
    // debug
    output logic [31:0] dbg_pc
);
```

Interrupts DI/HI/WV are internal. INT1/INT2 pins are unused on this board.

### `adsp2100` (rtl/adsp/adsp2100.sv)

```systemverilog
module adsp2100 (
    input  logic        clk, reset, cen,        // cen = 8 MHz
    input  logic        halt,                   // /HALT or /BR low: stop at the next instruction boundary
    // program memory port B (68010 load path; the ADSP owns port A internally): 8K x 24
    input  logic [12:0] pm_ext_addr,
    input  logic        pm_ext_we,
    input  logic [23:0] pm_ext_wdata,
    output logic [23:0] pm_ext_rdata,
    // data memory port B (68010): 8K x 16
    input  logic [12:0] dm_ext_addr,
    input  logic        dm_ext_we,
    input  logic [15:0] dm_ext_wdata,
    output logic [15:0] dm_ext_rdata,
    // data-space I/O (0x2000-0x2fff): one access per instruction at most
    output logic [11:0] io_addr,
    output logic        io_rd, io_wr,           // one-cycle pulses aligned to cen
    output logic [15:0] io_wdata,
    input  logic [15:0] io_rdata,               // must be valid when io_wait is low
    input  logic        io_wait,                // holds the instruction (SIM prefetch not ready)
    output logic [13:0] dbg_pc
);
```

Added by the ADSP sub-project: `input [3:0] irq` (IRQ0..3 pins, unused on this
board, tie 0), `input flag_in`, `output flag_out`, and `output dbg_instr_done`
(one-clock pulse per retired instruction, for benches). `pm_ext_rdata` /
`dm_ext_rdata` have one clock of latency. IO reads: the core pulses `io_rd`
with `io_addr` and samples `io_rdata` two clocks later, waiting while `io_wait`
is high; `io_wait` must be valid from the clock after the pulse. IO writes are
a one-clock `io_wr` pulse with `io_addr`/`io_wdata`.

The 68k read of 800000-807fff returns `pm_ext_rdata` split into two 16-bit
halves by the glue; the 68k writes one half at a time, so the glue does the
read-modify-write of the 24-bit word (the ADSP is halted while it loads).

### `jsa2` (rtl/jsa/jsa2.sv) — the whole JSA II board

```systemverilog
module jsa2 (
    input  logic        clk, reset,
    input  logic        cen_cpu, cen_ym, cen_oki,
    input  logic        snd_reset,               // pulse: 68k read of 604000
    // 68k command/response latch
    input  logic        cmd_wr,  input logic [7:0] cmd_data,     // 68k write 600000 (D15:8)
    input  logic        resp_rd, output logic [7:0] resp_data,   // 68k read 600000
    output logic        main_irq,                // response latch full -> 68k IRQ4
    // inputs
    input  logic  [2:0] coins,                   // active high
    input  logic        test,                    // 1 = test mode
    // ROMs: program in BRAM inside; ADPCM through the memory interface
    input  logic        rom_we, input logic [15:0] rom_waddr, input logic [7:0] rom_wdata,  // loader
    output logic [17:0] oki_addr, output logic oki_req, input logic [7:0] oki_data, input logic oki_ack,
    output logic signed [15:0] audio               // mixed, at clk rate
);
```

## Verification

Every CPU core is checked against a MAME instruction trace: `tools/trace_*.lua`
records PC + registers per instruction from a frozen state; the bench loads the
same memory image, runs the same number of instructions and diffs. The bench
lives in `sim/<block>/` and is run by `sim/run_<block>.sh`.

### `jsa2` — as built (deltas from the sketch above)

- `cen_cpu` is **not** an input: the board derives the 6502 enable by halving
  `cen_ym` inside `jsa2`, so the CPU and the YM2151 stay phase-locked as on
  the PCB (jt51's `cen_p1` is that same half-rate enable).
- `audio` is the signed 16-bit mono mix, recomputed on every YM2151 clock;
  `audio_valid` strobes for one `clk` each time it updates. Sample it at 48 kHz
  or feed the Pocket mixer from `audio` directly (it is stable between strobes).
- `oki_req` is a level held until `oki_ack`; the board turns the jt6295's
  `rom_addr`/`rom_ok` handshake into that request itself. Any latency is fine
  (the ADPCM engine allows ~7 µs per fetch).
- Bench-only outputs `dbg_ym_wr/a0/d`, `dbg_io_wr/sel/d`, `dbg_sync`,
  `dbg_addr`: leave unconnected in the core.
- The self-test bit at 2804.7 is `test` (hardware intent). MAME's `rdio_r`
  inverts it twice and always returns 0 there; the bench runs with `test=0`
  where the two agree.
- Program ROM: 64 KB block RAM inside, loaded through `rom_we/rom_waddr/rom_wdata`.

#### tms34010 interface notes (from the GSP sub-project)

- Added inputs `cen_vid` (5 MHz video clock enable; one HCOUNT step) and
  `cache_flush` (parent pulses it when it changes VRAM behind the core's back,
  e.g. shift-register row copies); added outputs `hcount`/`vcount` (16-bit),
  `line_start` (one-clock pulse at HCOUNT wrap; `r_dpyadr` sampled on that
  edge is the value MAME uses to draw the line, the step/load lands one clock
  later), `r_hesync..r_dpyadr` (the twelve display registers), `dbg_instr`,
  `dbg_halted`, and bench-only `dbg_force_di`, `dbg_int_inhibit`,
  `dbg_force_int`, `dbg_hold`, `dbg_idle` (tie the inputs low in the core).
- Host register numbering follows MAME's `host_w/host_r`: **0 = HSTADRL,
  1 = HSTADRH, 2 = HSTDATA, 3 = HSTCTL**. With the 68010's
  `offset = (word_index/2) ^ 1` decode that makes c00000/c00002 → HSTADRH,
  c00004/c00006 → HSTADRL, c00008/a → HSTCTL, c0000c/e → HSTDATA (the table
  in hardware.md §4.1 has L and H swapped).
- `host_ready` pulses one clock after HSTADR/HSTCTL accesses and when the
  HSTDATA access has completed (it goes through `mem_*`, so hold the 68010
  with DTACK until then). `host_rdata` is registered.
- `mem_srt` marks shift-register transfer accesses (DPYCTL.SRE): a read must
  latch the source row and return 0, a write must copy the row (only when the
  control_hi enable latch is set) — see hardware.md §4.6 and the bench model
  in `sim/gsp/tb_gsp.cpp` for the exact address arithmetic.
- The core is not cycle exact: one `cen` per instruction plus one per external
  word access (cache hits are free), so it is never faster than the real part.
