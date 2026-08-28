# JSA II sound board: implementation and verification

`rtl/jsa/jsa2.sv` is the whole sound board of hardware.md §6. This note is
what was built, how it was checked against MAME, and what is left.

## What is in the module

| Part | Implementation |
|---|---|
| 6502 @ 1.789772 MHz | T65 (`modules/cpu-t65/gen/t65.v`, GHDL-converted VHDL), NMOS mode, BCD on. Enable = every other `cen_ym` pulse, so the CPU is phase-locked to the FM chip as on the PCB |
| 8 KB RAM, 64 KB ROM | block RAM; ROM loaded through `rom_we/rom_waddr/rom_wdata`; 3000-3FFF is a 4 KB window into ROM 0000-3FFF selected by WRIO bits 7:6 |
| YM2151 @ 3.579545 MHz | jt51 (`modules/sound-jt51`), full-resolution outputs; its IRQ is OR-ed with the timed interrupt into the 6502 IRQ; CT1 gates the OKI |
| OKI MSM6295 @ 1.193181 MHz | jt6295 (`modules/sound-jt6295`, no interpolator); pin 7 from WRIO bit 3; ROM fetched through `oki_addr/oki_req/oki_data/oki_ack` (the core serves it from SDRAM) |
| Latches | command (68k → 6502, NMI while full, cleared by a 6502 read of 2802), response (6502 → 68k, `main_irq` while full, cleared by the 68k read), WRIO, MIX |
| Timed IRQ | 14336 YM clocks = 249.69 Hz, cleared by any access to 2806 |
| Sound reset | `snd_reset` (68k read of 604000) holds the board in reset for 15 CPU cycles and resets the chips and latches, as MAME's `m_jsa->reset()` does |
| Mixer | YM `(L+R) × vol/7 × 0.6 × 0.5`, OKI `(sample<<4) × (1.0|0.5) × 0.75 × 0.5`, gated by CT1, saturated to 16 bits — MAME's routing, so the two peak at the same level |

Address decode follows the schematic-derived MAME map: 2800-29FF reads and
2A00-2BFF writes are selected on A2:1 only (MAME's `mirror(0x01f9)`), 2000-27FF
is the YM2151 (A0 = register/data), 4000-FFFF the fixed ROM.

Not modelled, as in MAME: the MIX bit-5 low-pass filter, coin counters. The
JSA-side coin inputs exist (`coins`) but Stun Runner counts coins on the main
board — pressing them in MAME does nothing — so the core ties them low.

## Bench (`sim/run_jsa.sh`)

1. `tools/trace_jsa.lua` runs MAME headless with `-wavwrite`, coins up and
   starts a game (attract mode is silent), and logs with the machine time:
   every 68k command byte and response read, the sound resets, every 6502
   write to the YM2151 (2000/2001), the OKI (2A00), WRP (2A02), WRIO (2A04),
   MIX (2A06) and the reads of 2802/2800. Two MAME lessons: taps must be kept
   in a global or Lua collects them and they silently vanish after the first
   event; taps spanning the 6502's *mirrored* I/O ranges crash MAME 0.288, so
   the I/O taps are single-address.
2. `sim/jsa/tb_jsa.cpp` (Verilator, 24 MHz bench clock — the RTL only sees the
   enable ratios) loads the two ROM images, replays the command bytes and
   resets at their logged times, reads the response 8 µs after `main_irq`
   like the 68k's IRQ4 handler, records the mix at 48 kHz to
   `artifacts/jsa/rtl.wav` and logs the same events the MAME tap logs.
3. `tools/compare_audio.py` holds the RTL to MAME:
   - the YM2151 (register, data) write sequence must be **identical** — this
     checks the 6502, its memory map, the latches and the interrupt timing
     without depending on how either FM implementation sounds;
   - WRIO/MIX/OKI/WRP write sequences likewise;
   - audio: RMS per 0.5 s window, the rtl/mame ratio over windows where MAME
     is audible (PASS needs the median within ±1.5 dB), peak, and the energy
     split into <500 Hz / 500-2 kHz / >2 kHz bands.

## Results (`sim/run_jsa.sh 40`, 40 s of machine time, 4 min wall)

```
YM2151 writes within 40.0 s: rtl 130514, mame 130514
  register/data sequence: IDENTICAL
  timing offset rtl-mame over the matching prefix: median +0.011 ms, min -0.030, max +0.138
  WRIO writes: rtl 9804, mame 9804, identical     MIX 14/14, OKI 9/9, WRP 5/5 identical
audio: peak rtl 24831, mame 22671
  envelope ratio rtl/mame over 50 active 0.5 s windows: median 1.001 (+0.01 dB), min 0.863, max 1.351
  band energy share   <500Hz  500-2k  >2k
    rtl                0.724   0.157  0.119
    mame               0.699   0.213  0.088
PASS
```

Every one of the 130,514 YM2151 register writes the 6502 makes in 40 s is the
same byte to the same register as in MAME, within 0.14 ms of the same time,
through two board resets, 76 commands and the coin/start/music sequence. The
mixed level matches MAME's to 0.01 dB in the median and tracks the envelope
window by window; the spectral split differs a little (jt51 and MAME's ymfm
are different implementations of the chip, and MAME's peak is 8 % lower),
which is the expected residual, not a bug.

Two things this found on the way:

- **jt51 samples its write strobe on its own clock enable** (for the BUSY
  flag; register data is taken on any clock). A one-clock strobe that misses
  the enable leaves the chip looking never-busy, and since the sound program
  polls BUSY between writes the RTL ran one poll iteration (7 µs) faster per
  write than MAME. Over a burst of instrument loads that moved the
  timed-interrupt ticks by 4 ms steps and the music diverged at 11.76 s. The
  strobe is now held for the whole CPU cycle.
- Attract mode is silent; coins count only on the main board's IN0 (a 12-frame
  `set_value(1)`/`clear_value()` on `Coin 1`), the JSA-side coin inputs do
  nothing in this game.

## Gaps

- The MIX low-pass filter bit (2A06.5) is not modelled (MAME does not either).
- The OKI path is exercised by 9 commands in the window (34-40 s, ratio ≈1.0
  there); a longer game capture would cover more samples.
- Self-test bit at 2804.7 is `test` (hardware); MAME returns 0 — differs only
  in test mode.
