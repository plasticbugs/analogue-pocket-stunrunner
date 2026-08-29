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
| ADSP-2100 core (`rtl/adsp/`) | `sim/run_adsp.sh` | MAME ADSP instruction trace + every data-space access + 68k RAM writes replayed | PASS on 2 windows: 5,274,473 and 22,196,327 instructions, 0 mismatches, final memories identical; also PASS with random `io_wait` stalls — `docs/adsp.md` |
| Whole machine | `sim/run_system.sh` | MAME boot timeline (per-frame CPU PCs), MAME's title-screen frame | boots from the ROM download and reaches the title screen **pixel-identical to MAME (0 differing pixels, dy=0)** when captured on DE. Palette word-identical to MAME (1024/1024). Sound board answers the reset and receives the title-music command; all three processors run their MAME loops |
| Synthesis (Quartus 18.1, 5CEBA4) | `./build-local.sh` | — | **fits, compiles and closes timing**: Fitter successful, 0 errors; 18,286 / 18,480 ALMs (99 %), 15,533 registers, block RAM 51 %, 22/66 DSP, 224/224 pins. **Zero negative slack** — setup and hold met at every corner (slow 0 °C / 85 °C, fast 0 °C / 85 °C), worst margin +0.116 ns. Note the worst setup corner is slow **0 °C**, not 85 °C (temperature inversion): analyse that corner explicitly, `create_timing_netlist -model slow -temperature 0 -voltage 1100`. |
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
