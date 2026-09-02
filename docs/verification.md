# Verification status

What has been checked against MAME, how, and with what result. Every entry is
reproducible with the script named. Updated as the core grows; an entry that
is not here has not been verified.

| Block | Bench | Oracle | Result (2026-08-27) |
|---|---|---|---|
| Reference frame renderer (`tools/render_model.py`) | `tools/capture_states.sh` | MAME snapshot PNG at the same frame | pixel-identical on 7 states: attract 600/1000/1500/2400, gameplay 1500/2000/2600 (0 of 122,880 pixels differ each) |
| SDRAM controller (`rtl/sdram_ctrl.sv`) | `sim/run_sdram.sh` | shadow memory, chip-model protocol checker | PASS: 33.6 k reads, 11.1 k byte-masked writes, 57 bursts of 1–512 words across SDRAM-row boundaries, 0 mismatches, 0 protocol errors; worst client wait 476 clocks; also PASS with `HAMMER=1` (one client re-requesting every cycle) and with the 5-clock burst spacing |
| Scan-out path (`gsp_video.sv` + SDRAM) | `sim/run_video.sh` | reference renderer / MAME PNG | pixel-identical on all 7 frozen states, including the lines whose 2 KB VRAM row wraps (two bursts) |
| 68010 board (`stunrun_main.sv`, TG68K, SDRAM ROM) | `sim/run_main.sh` | MAME 68010 instruction trace from reset (`artifacts/traces/m68k_boot.txt`, `-debug -debugger none`) | 43,000 of 43,000 compared PCs match in order (first 3 frames of boot: vector fetch, MOVEC VBR, RAM tests, latch setup); simulated time 0.051 s vs MAME 0.050 s (kernel pacing 3.75 cen_8m per step) |
| JSA II sound board (`rtl/jsa/jsa2.sv`) | `sim/run_jsa.sh` | MAME command/response log + YM2151/OKI/WRIO/MIX write log + `-wavwrite` | YM2151 register stream 130,514/130,514 identical over 40 s (timing offset median +0.011 ms); WRIO 9804/9804, MIX 14/14, OKI 9/9, WRP 5/5; audio envelope ratio RTL/MAME median 1.001 (+0.01 dB) over 50 windows — see `docs/jsa.md` |
| TMS34010 core (`rtl/gsp/`) | `sim/run_gsp.sh` | MAME GSP instruction trace (PC, ST, SP, A0–A14, B0–B14 per instruction) + end-of-window VRAM | PASS on 3 windows: boot/download (1,860,171 instr), 3D attract (88,534), title screens (3,917,724); 0 divergences over 5.87 M instructions; final VRAM word-identical; 60 mnemonics / 121 operand forms covered — `docs/gsp.md` |
| ADSP-2100 core (`rtl/adsp/`) | `sim/run_adsp.sh` | MAME ADSP instruction trace + every data-space access + 68k RAM writes replayed | PASS on 4 windows: 5,274,473 / 22,196,327 / 961,476 / 256,948 instructions (w4 = the 3D demo's first two frames from the trigger), 0 mismatches, final memories identical; also PASS with random `io_wait` stalls (`IOWAIT=N`, asserted from the `io_rd` clock) and random `halt` injection (`HALT=N`) — `docs/adsp.md` |
| Whole machine | `sim/run_system.sh` | MAME boot timeline (per-frame CPU PCs), MAME's title-screen frame, MAME's 68k/ADSP protocol trace (`tools/trace_som.lua`) | boots from the ROM download and reaches the title screen **pixel-identical to MAME (0 differing pixels, dy=0)** when captured on DE; palette word-identical (1024/1024); sound board answers the reset and receives the title-music command; **enters and runs the 3D attract demo** with the 68k/ADSP handshake matching MAME's per-frame counts (see below). Every SIM ROM word the ADSP receives is checked against the image (hard gate) |
| Synthesis (Quartus 18.1, 5CEBA4) | `./build-local.sh` | — | **fits, compiles and closes timing** (build of `4c8c24c`): Fitter 0 errors; 18,295 / 18,480 ALMs (99 %), 15,464 registers, block RAM 51 %, 22/66 DSP. **Zero negative slack** at every corner on the 96 MHz core clock: setup +0.235 ns (slow 85 °C), +0.359 (slow 0 °C), +3.56 / +3.73 (fast); hold +0.295 / +0.291 (slow), +0.127 / +0.053 (fast 85 / 0 °C). Which slow corner is worst for setup has flipped between builds (0 °C last time, 85 °C this time) — always read both. |
| Hardware (Pocket) | — | — | not yet built |

## Lessons recorded on the way

- **Timing closure on enable-stepped cores: prove the budget, don't assume it.**
  The first full compile fit the device but missed the 96 MHz core clock by
  -18 ns. The instinct -- "these cores run on clock enables, so everything
  inside them has 16 clocks; multicycle the whole module" -- is *wrong* and is
  the dangerous kind of wrong: a multicycle on a path that really does resolve
  in one clock silently produces hardware that fails where simulation passed.
  Both the GSP and the ADSP are micro-sequenced: the enable only *starts* an
  instruction, after which the FSM steps every single clock. What is provably
  stable is narrower -- a register written once per instruction and read N
  states later. So the rule used here:

  1. Ask STA which paths actually fail, by endpoint (`get_timing_paths` +
     `get_path_info -from/-to`), and fix them in tiers. Each tier cleared
     reveals the next; -18 -> -11.5 -> -9.2 -> -7.4 -> -7.0 -> -6.2 -> -6.0.
  2. For each failing source register, find *every* write site in the RTL and
     the state each one sits in (grep, mechanically -- one missed site
     invalidates the argument). Only then decide the class.
  3. If the source is genuinely per-instruction stable, write the multicycle
     **with the stability argument in a comment next to it**.
  4. If it is not -- if the capture really is one clock later -- do NOT
     multicycle it. Add a settle clock in the RTL (the `mph` / `alu_ph`
     pattern: `S_X: if (!mph) mph <= 1'b1; else begin mph <= 1'b0; ... end`),
     which makes the two-clock budget real, then constrain to match. Eleven
     GSP states and one ADSP state needed this.
  5. Re-run the trace bench after every RTL change. The settle clocks are free
     in wall-clock terms (the engine is enable-throttled, so the extra clock
     lands inside slack that already existed) and the bench proves it: GSP
     6/6 windows and the ADSP both stayed ALL PASS throughout.

  Iterate with `quartus_sta -t` against the already-fitted netlist (~2-3 min)
  rather than a full compile (~30 min); a relax-only SDC edit can only gain
  slack on an existing placement, so the fast loop is trustworthy for
  convergence. Scripts: `projects/worst15.tcl`, `projects/list_sources.tcl`.
  Never write a blanket `-from <module>|* -to <module>|*` for a
  micro-sequenced core; the FSM state, step counters and memory latches inside
  it change every clock.


- **TG68K bus sampling.** The kernel's `addr_out` settles one clock after
  `busstate` changes on a step; sampling the bus on the cycle right after
  `clkena` fetched the previous address (the second ROM read returned word 0
  again). The VHDL wrapper waits a state for the same reason. Found with a
  200-cycle VCD around the first reads once the symptom was clear from the
  per-step log.
- **`sim/waivers.vlt` must not contain comments.** Verilator's config parser
  stops silently at the first `//` line, so every waiver after it is ignored.
- **MAME Lua `set_value`** takes the logical (active) state: `set_value(1)` is
  a pressed coin on an active-low port; `set_value(0)` is *released*. The first
  coin experiments did nothing for exactly this reason. Taps must be kept in a
  global or they are garbage-collected after their first event.
- **SDRAM burst acceptance** must not sit inside the random-client priority
  chain, or a saturating client keeps the display fetch from ever starting.
  Round-robin among pending random clients was needed as well.
- **NVRAM defaults are interleaved.** `stunrun.200e`/`.210e` are the timekeeper
  and EEPROM contents as two 2 KB blocks; the 68k sees them as the high and
  low bytes of one word. Loading them linearly made every ZRAM record fail its
  checksum, and the game spent minutes in `ZramService` rewriting all records
  byte by byte (15 verified polls with a 15 ms delay each). Symptom: 68k
  parked at 0x209d6-0x209ec, GSP never released. MAME never shows this
  because it loads the NVRAM files straight into the devices.
- **First boot is slow by design.** With factory NVRAM the game initialises
  its EEPROM records byte by byte: MAME (fresh nvram directory) keeps the 68k
  in `ZramService` until frame ~400 and starts the GSP at ~420. The whole-
  machine bench can load an initialised image (`tools/make_sav.py` from
  MAME's nvram files, `artifacts/stunrun_initialised.sav`) exactly as the
  Pocket loads `stunrun.sav`, to skip those 7 seconds.
- **TG68K `skipFetch` is not optional.** In 68010 mode the kernel still walks
  its read-modify-write state for CLR (and friends) but raises `skipFetch` so
  the wrapper skips the bus cycle, as the 68010 does. Performing the read
  anyway looked harmless on RAM, but on the GSP host port with INCR set every
  `CLR.L (A0)` advanced HSTADR by a word: the command lists the 68k builds in
  VRAM were shifted by one word past their first CLR, the GSP misparsed
  them, and the title palette was never requested. Found by dumping the
  command list at the frame trigger in both MAME and the RTL and diffing:
  identical up to word 0x7b, then the RTL's list had an extra 0000.
- **Frame-capture alignment (bench only).** The whole-machine bench first
  counted raster lines from vsync, which put the 19 pre-VEBLNK blanking lines
  in as a black band at the top and dropped the last 19 visible lines. The
  core's raster is correct: counting rows on DE (as the frozen-state gate and
  the Pocket scaler do) makes the title-screen frame a 0-pixel, dy=0 match to
  MAME. The GSP's own DPYADR/DE bookkeeping was never wrong — the first
  visible line fetches VRAM row 0x3c in both MAME and the RTL.

## The attract-demo reboot (fixed)

Symptom on hardware: the machine reboots when the title screen gives way to the
3D attract demo. Reproduced in `sim/run_system.sh` at frame 713.

**Root cause: every word of the ADSP's SIM serial ROM was byte-swapped.** The
image stores the `.90h/.10h/.9h` byte at the even address and `.90k/.10k/.9k` at
the odd -- big-endian words, like the 68k program region -- and the core read
them through its little-endian SDRAM port unswapped. `docs/hardware.md`
recorded the evidence correctly (MAME word 0 = `0x0068` with `90h[0]=0x00,
90k[0]=0x68`) and then stated the opposite conclusion, and the packing followed
the sentence rather than the numbers.

Nothing reads the SIM ROM until the 3D demo starts. Its third read is the
demo's outer loop count (`011F: I0 = DM($2000)` ... `014D: CNTR = DM($0032)`):
MAME's ADSP gets `0x000a`; ours got `0x0a00`, a 2,560-iteration loop that
walked its DAG off the end of data RAM into the `0x2000-0x2007` I/O block --
~512 stray writes each to SOMLATCH, /SOMCLK, /XOUT and /GINT per frame where
MAME writes /GINT once every three. One of those landed on SOM word 0, the
block length the real program writes last; `SomCopyToGsp` read it as -1300,
`GspWriteWords` ran unbounded past the top of VRAM, the GSP interrupt vectors
went with it, and the 68k called `HaltForWatchdog()`.

Two further defects in the same path were found and fixed on the way, each
real, each insufficient alone:

- `stunrun_core.sv` SIM glue: the ADSP core samples `io_rdata` in the same
  clock it raises `io_rd` unless `io_wait` is high *in that clock*; the glue
  derived `io_wait` from a registered flag, one clock late, so the core latched
  the previous read's word. Then, with that fixed, the prefetcher retargeted
  `sim_next_idx` at fetch issue without dropping `sim_valid`, so a read landing
  before the SDRAM ack (12 clocks apart in a streaming loop; the ack can take
  hundreds under contention) took word N-1 as N.
- `stunrun_main.sv`: 68k reads of the ADSP program/data RAMs and the SOM buffer
  were given one cycle; their address is registered (the port is shared with
  the write path), so they need two. `B_RAM_RD1` supplies it.

**Why five verified cores did not catch it.** Every bench replays MAME's I/O
*values*, so the SIM path never executed under test; the whole-machine bench
reaches the title screen pixel-identical because nothing reads the SIM ROM, the
SOM buffer or the ADSP RAMs before the demo; a byte-wise compare of the SIM
region against MAME's passed because the bytes *are* identical; and the first
SIM self-check computed its expectation with the RTL's own assumption.

**How it was found**, recorded because three theories were wrong first:

1. *"We run at 77 % of MAME's speed so the 68k reads an unfilled buffer"* -- a
   category error. A uniformly slow machine cannot desynchronise a handshake.
2. Trace the **protocol**, not the instructions: `tools/trace_som.lua` (MAME)
   and `TB_SOMTRACE` (RTL) log the 68k/ADSP handshake, NVRAM-aligned so frame
   numbers compare. One 12-second MAME run showed a *structural* difference
   (/GINT 1-2 per frame vs 110).
3. Eliminate by measurement: I/O map, SIM bytes, ADSP PM+DM at the kick
   (2,718 nonzero words, 0 differ -- an earlier frame-60 compare was of two
   all-zero memories and proved nothing: **print the nonzero count next to the
   diff count**), /MP pages and SIMCLK range, registers at the kick.
4. With the state identical at the kick, replay MAME's kick window through the
   ADSP bench (`artifacts/adsp/w4`, now a permanent window): PASS, with
   `IOWAIT` stalls and the new `HALT` injection. So the core was right and an
   *input* was wrong. A PC-only diff (`tools/compare_adsp_pcs.py`) put the
   divergence at instruction #924, at the exit of a loop whose count came from
   the third SIM read -- and the ROM bytes at that index, read as MAME's ADSP
   reads them, were the swap.
5. `TB_SIMCHK` now expects big-endian words and is a hard gate (a mismatch, or
   a word served while its fetch is outstanding, turns PASS to FAIL).

**Result** (`TB_SIMCHK=1 TB_SOMTRACE=1 sim/run_system.sh 790`): the machine
enters the 3D demo at frame 705 and runs it to the end of the run, 85 frames,
without rebooting. SIM: 0 mismatches over ~2,700 reads per frame. The
68k/ADSP protocol now matches MAME's almost number for number -- SOM words per
frame 1860/1862/1657 then 471+1628 (MAME: 1828/1873/1675 then 474+1628), /GINT
1-2 per frame, /SOMCLK 2 per 3 frames, the bank flipping every 3 frames --
and every `SomCopyToGsp` length is sane (5847, 5936, 6145, ...; MAME's first
buffer is 5850 words).

Recorded so they are not hit again:

- **MAME Lua taps must be held in a GLOBAL table**, or they are garbage-
  collected and report zeros that look like measurements.
- **`dbg_68k_pc` in the system bench is the address bus, not the PC.** Use
  `dbg_68k_exepc`.
- **The ADSP data space is word-addressed in MAME Lua** (addrbus shift -1): do
  not `>> 1` a tap offset like a 68k byte address.
- **`tools/trace_adsp.lua` needs `-debug -debugger none`**; without it the
  window never closes and `adsp_io.txt` grows without bound (16 GB before it
  was noticed).
- **MAME's ADSP HALT is soft.** Its ADSP ran 21 more accesses after `/BR=0` in
  the kick window; ours stops at the next instruction boundary. Not the cause
  here, but the mailbox handshake in `AdspIrqService` depends on that slack.
- **Our ADSP reset clears every register; MAME's leaves I/M/L, CNTR and the
  compute registers alone.** Not exercised at the kick (the 68k only pulses
  reset at boot), but a latent difference.

Still open, and separate: the attract sequence runs ~147 frames late (MAME
starts the demo at frame 559, we start at 705). That is throughput, not logic;
this fix does not change it.
