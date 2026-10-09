# The Analogizer

[Analogizer](https://github.com/RndMnkIII/Analogizer) is RndMnkIII's adapter
for the Pocket's cartridge slot. It gives analog video out of a VGA connector
(RGBS, RGsB, YPbPr, Y/C, and a scandoubled RGBHV) and takes native controllers
through SNAC adapters. Its wiki is the authority on the adapter itself:
[specifications](https://github.com/RndMnkIII/Analogizer/wiki/Analogizer-Specifications),
[how to configure it](https://github.com/RndMnkIII/Analogizer/wiki/Supported-Cores-and-How-to-Configure-Them).

This core supports it (`USE_ANALOGIZER = 1` in `core_top.sv`), added after
release from plasticbugs' pocket-core-template, whose
`docs/analogizer-retrofit.md` is the order of work it followed. This page is
what the player needs, how this core feeds the adapter, and what has been
proven.

## For the player

**Settings are in the core's own menu**, under the game's other options,
like RndMnkIII's own "Pocket Menu" Analogizer cores (the wiki's list calls the
other kind, which reads a shared `analogizer.bin`, "Analogizer File"; a core
from this core does not read that file). The Pocket remembers them per
core.

| entry | options |
|---|---|
| Analogizer | Off (the default), On, On, Pocket off (the picture goes to the CRT only) |
| Analogizer Video | RGBS, RGsB, YPbPr, Y/C NTSC, Y/C PAL, Scandoubler, Scandoubler 25% / 50% / 75%, Scandoubler HQ2x |
| SNAC Adapter | None, DB15, NES, SNES, PCE 2-button, PCE 6-button, PCE Multitap, DB15 Fast, SNES A,B<->X,Y, PSX Digital, PSX Digital Fast, PSX Analog, PSX Analog Fast |
| SNAC Assignment | the six below |
| Analogizer H Position | -32 to +12 dots; + moves the picture right |
| Analogizer V Position | -15 to +3 lines; + moves the picture down |

With **Analogizer** off the core behaves exactly as it did without Analogizer
support. The adapter itself is set up as its wiki's
[How to use it](https://github.com/RndMnkIII/Analogizer/wiki/How-to-use-it%3F)
says: SNAC switch in position A, 5 V into its USB-C port, the SCART cable's
audio jack in the Pocket's headphone socket.

**Position.** The two sliders move the picture on the CRT, in the core's
own dots and lines, for a set whose picture sits off centre (the first one
tried with Moo Mesa showed it about 10 lines high). They move the syncs,
not the picture, so nothing is cropped and every mode follows; the size is
still the set's to adjust. 0 is the board's own timing.

**Video.** The core sends the board's own raster: 10 MHz dots, 634 × 262,
512 × 240 visible, **15.77 kHz, 60.20 Hz** -- a standard 15 kHz signal for a
TV or arcade monitor through RGBS, RGsB, YPbPr or Y/C. The scandoubler modes
are 31.5 kHz at the same 60.20 Hz, for a VGA monitor. (The multisync board's
name is its monitor's, which S.T.U.N. Runner drives at 15 kHz; the game's own
timing registers are in docs/hardware.md 4.3.)

| mode | SOG switch | notes |
|---|---|---|
| RGBS | off | VGA-to-SCART or VGA-to-BNC |
| RGsB | on | R2/R3 adapters only |
| YPbPr | on | R2/R3 adapters only |
| Y/C NTSC, Y/C PAL | off | needs an active Y/C adapter on the VGA port |
| SC 0% / 25% / 50% / 75% / HQ2x | off | scandoubled for a VGA monitor: twice the line rate |

"On, Pocket off" turns the Pocket's own picture black while the CRT keeps
it.

**Controllers.** SNAC pads (DB15, NES, SNES, PC Engine 2/6-button and
multitap, PlayStation) replace the Pocket's controls according to the
**SNAC Assignment** chosen in the menu:

| assignment | player 1 | player 2 | player 3 | player 4 |
|---|---|---|---|---|
| SNAC P1 → Pocket P1 | SNAC 1 | the Pocket's own controls | dock 3 | dock 4 |
| SNAC P1 → Pocket P2 | Pocket | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P1,P2 | SNAC 1 | SNAC 2 | dock 3 | dock 4 |
| SNAC P1,P2 → P2,P1 | SNAC 2 | SNAC 1 | dock 3 | dock 4 |
| SNAC P1,P2 → P3,P4 | Pocket | dock 2 | SNAC 1 | SNAC 2 |
| SNAC P1-P4 → P1-P4 | SNAC 1 | SNAC 2 | SNAC 3 | SNAC 4 |

Four SNAC players need the PC Engine multitap. A pad's buttons arrive as the
Pocket's own (SNAC's A is the Pocket's A, and so on), so they do whatever the
core maps those to. A PlayStation pad in analog mode steers with its left
stick.

**Cart power is on for everyone.** `core.json` declares the cartridge adapter,
so the Pocket powers the slot whether or not an Analogizer is in it. Do not
leave a game cartridge in the slot while this core runs.

Say in the core's README whether it has been tried on an Analogizer. What
the bench proves is listed under *What was measured* below. Send problems with
the adapter itself to the Analogizer project.

**On hardware, in this order** (each reading tells the next where to look):

1. **"Analogizer: Off"** (the default). The game must play exactly as
   before, picture and controls. If not, the cartridge port is not idle:
   stop there.
2. **Analogizer On, Video RGBS, SNAC Adapter None**, on a 15 kHz set. The
   same picture as the Pocket's, full width (a picture squeezed into the
   left 40 % means the re-timer is not in the path), 15.77 kHz / 60.20 Hz
   on a PVM's info screen. No picture at all: say whether the set reports a
   signal.
3. **Each other mode** (RGsB and YPbPr need the SOG switch on; the
   scandoubler modes need a VGA monitor).
4. **SNAC**: one pad, "SNAC P1 -> P1"; it steers, fires and boosts. The
   Pocket's own stick and buttons keep working too: the board has one
   player, and the core takes the first two controller words together
   (`JOY_ALT`). Start is player 1's only, so it is the pad's Start that
   starts a game; the Pocket's Select still coins (coin 2).
5. **The menu's memory**: change Video, quit and reload; the setting is
   still there, and changing one entry leaves the others alone.
6. **Position**: V Position + moves the picture down, H Position + right;
   both kept across a reload. A picture that rolls or tears at either end
   of a slider means the range is too wide for that set.

## For the developer

### The pieces

| file | what |
|---|---|
| `target/pocket/analogizer/` | RndMnkIII's `openFPGA_Pocket_Analogizer` and what it instantiates, **verbatim** (modules/VENDOR.md has the commit). Its `analogizer.qip` is ours: only what is used. |
| `target/pocket/pocket_analogizer.sv` | the wrapper: clock hand-over, Y/C constants, picture position, SNAC → controller words. Core-agnostic; the template's file unchanged. |
| `target/pocket/ana_retime.sv` | this core's own: the Pocket's stream back into the board's raster (below). |
| `target/pocket/core_top.sv` | `USE_ANALOGIZER`, the re-timer and the wrapper (`LINE_LEN` 634, `CLK_HZ` 40 MHz), `key1..key4` into the `gamepad` helper in place of `cont1..4_key`, the bridge read at `0xF7xxxxxx`, the Pocket-screen blank, and the cart pins' idle levels when it is off. |
| `core_pll` `outclk_4` | the Analogizer's 40 MHz, four clocks a dot, from the same VCO as `clk_sys`; in a clock group of its own in the SDC (below). |
| `pkg/.../interact.json` | the entries above: ids 70–73, each a masked field of the word at `0xF7000000`, and 74–75, signed sliders at `0xF7000004` and `0xF7000008`. The game's 8 entries are unchanged: 14 in all, with 2 data slots (Analogue's limits: 16, and 20 with the slots; `tools/check_json.py`) |
| `pkg/.../core.json` | `"cartridge_adapter": 0` (powers the slot) |
| `sim/run_analogizer.sh` | the bench (below): a model of the core's Pocket stream through `ana_retime` and the wrapper, read at the pins |
| `tools/check_json.py` | fails if an entry writes outside its mask, none sets the enable, a position slider is not signed within ±127, a data slot also writes `0xF7000000`, or the slot is not powered |

### The settings word

One 32-bit word at `0xF7000000`, the layout RndMnkIII's adapter module (1.4)
decodes. Each menu entry is a list with a mask that keeps every bit but its
own field (or fields), so the four entries share the word:

| bits | field | values |
|---|---|---|
| 4:0 | SNAC type | 0 none, 1 DB15, 2 NES, 3 SNES, 4 PCE 2-button, 5 PCE 6-button, 6 PCE multitap, 9 DB15 fast, 0xB SNES A/B↔X/Y, 0xC–0xF PS/2 keyboard (+ pad; not in the menu, the wrapper does not wire the keyboard out), 0x10/0x11 PSX digital (125/250 kHz), 0x12/0x13 PSX analog. 16 and up select the adapter's B wiring. |
| 5 | enable | 0: the port stays idle and nothing else applies |
| 9:6 | SNAC assignment | 0–5 as in the table above |
| 13:10 | video | 0 RGBS, 1 RGsB, 2 YPbPr, 3 Y/C NTSC, 4 Y/C PAL, 5–9 scandoubler 0/25/50/75%/HQ2x |
| 14 | blank the Pocket screen | |
| 15 | OSD on the Analogizer output | not used by this core; no menu entry |

**Read-back.** The word is written as a number (the adapter module is told
`bridge_endian_little = 1`, so it does not byte-swap it as it would a file),
and `pocket_analogizer` keeps its own copy to read back, combinationally.
The Pocket's bridge (`io_bridge_peripheral.sv`) samples read data four clocks
after it presents the address and pulses `bridge_rd` only afterwards; the
adapter module updates its read-back on that pulse, so it would hand back
the *previous* read's value. The firmware merges a masked entry by
reading the word back (Analogue's interact.json docs: every entry not
`writeonly` is read back every frame), so that stale value would wipe the
other fields: in the bench, choosing a video mode turned the Analogizer off. RndMnkIII's menu
cores (Gauntlet) read the word back the same way, from a register.

**Picture position.** Two more words, each a whole signed slider value
(no mask): `0xF7000004` horizontal in dots, + right, and `0xF7000008`
vertical in lines, + down. `pocket_analogizer` reads the low 8 bits and
reads both words back. The adapter module stores them in a table it never
reads (`config_mem`). They move the syncs, not the picture: hsync n dots
earlier puts the picture n dots right, vsync n lines earlier puts it n
lines down. Earlier is built as a line (or frame) less n later: each sync
is re-made from the source's own rising edge after a delay counted in
dots, as wide as the source's, with the line and frame measured from the
source's syncs; the vsync's delay is whole lines, so its edges keep their
place in the line. RGB and blanking go through one clock later with them,
and at 0 each sync passes straight through.

A re-made sync starts only once it has been off at least as long as it is
on. The adapter module's `sync_fix` decides each sync's polarity afresh
every period, by whether the signal was high longer than low. A jump
between settings in one write (one "large" slider step, or a value loaded
at start) can put the next pulse just after the last one ends, and that
period reads as active-low: csync turned inside out for a frame (a line,
for hsync). With the rule such a jump skips one pulse instead.

**The range is this core's, from its blanking** (docs/hardware.md 4.3):
hsync is the line's first 38 dots and the picture dots 110–621 of 634, so
hsync can come 12 dots earlier before it meets the end of the picture, and
32 later before the Y/C colour burst (it ends about 3.5 µs, 35 dots, after
hsync does) would reach the picture's start. Vsync is the first 4 lines and
the picture lines 19–258 of 262: it can come 3 lines earlier and 15 later
and stay in the blanking. `sim/run_analogizer.sh` tries both ends; one step
past either (+13 dots, +4 or -16 lines) fails it with csync inside the
picture.

**The file scheme, not used here.** The adapter module 1.4 was written for
`analogizer.bin`, a file Pupdate and AnalogizerConfigurator write to
`/Assets/analogizer/common/`, loaded through a data slot at the same address.
It needs a data slot naming the file, a second platform id `analogizer`
that the slot's parameters point at, and the file on the card before the
adapter does anything. A player who has never heard of the file has an
Analogizer that stays dark, so this core uses the menu. A data slot at
`0xF7000000` would load the file over the menu's word; `tools/check_json.py`
refuses one.

### The board's raster, back from the Pocket's stream

What the core gives the Pocket is not what a CRT needs. The board scans a
512-dot line at 10 MHz, but the Pocket counts pixels as DE-high clocks of its
video clock (24 MHz), so `gsp_video.sv` sends each line's 512 pixels back to
back at 24 MHz as soon as the visible window opens: hsync, vsync and vblank
keep the board's timing, while the pixels fill only the first 21.3 µs of the
51.2 µs window. Fed to a CRT as is, the picture would be squeezed into the
left 40 % of the screen.

`target/pocket/ana_retime.sv` undoes it. Each burst is written into a
one-line RAM as it arrives (`clk_sys`) and read back on the Analogizer's own
clock, `clk_ana` = 40 MHz, one dot every four clocks: a line of 634 dots is
exactly 2,536 clocks, the rate the core's 10 MHz phase accumulator keeps on
average, as both come from one VCO. The read line starts 10 dots (1 µs)
after the source's hsync, so the 24 MHz write of each pixel is always ahead
of its 10 MHz read, and finished before the next line's starts: one buffer
is enough. hsync (38 dots) and the visible window (dots 110–621) are re-made
from the dot counter -- the game programs fixed timing registers -- and
vsync and vblank are the source's, taken at each line's start. The counter
free-runs, and is put back on the source's hsync only when it is more than
a clock out: in steady state never. The whole Analogizer picture is 1 µs
later than the Pocket's; nothing else about it changes.

### Clocks

`openFPGA_Pocket_Analogizer` runs its logic on `i_clk`, puts `video_clk` on the
cartridge pin that clocks the ADV7123, and assumes that is `i_clk` too. The
scandoubler halves the pixel period, so the clock has to be at least four
times the dot rate. The shipped Analogizer cores use 42.95–48 MHz; this core
uses 40 MHz, exactly four times its 10 MHz dot, so every dot is four clocks
and every line the same length (48 MHz would make dots of 4 and 5 clocks).
It is the PLL's spare fifth output, from the same 960 MHz VCO as `clk_sys`,
`clk_vid` and the SDRAM clock. The re-timer feeds the wrapper on that clock
(`clk_src` = `clk`), so the wrapper's own hand-over is within one domain.

The only crossings are the re-timer's -- a dual-clock line RAM and two-flop
synchronisers on hsync, vsync and vblank -- and the wrapper's to `clk_74a`.
96 and 40 MHz edges come within 1 ns of each other, a requirement none of
those paths needs, so the SDC puts `general[4]` in an asynchronous group of
its own rather than in the core PLL's group.

The Y/C encoder's subcarrier step and colour-burst window are computed in
integers from `CLK_HZ`. The reals used elsewhere lose the bits past 32 in some
tools, and MSX2's hand-typed NTSC step is a few counts off.

### Using SNAC in the game's inputs

`pocket_analogizer` outputs `key1..key4`, the Pocket's controller words with
SNAC pads put in place by the assignment. SNAC's bit order is the Pocket's
(0 up, 1 down, 2 left, 3 right, 4 A, 5 B, 6 X, 7 Y, 8 L1, 9 R1, … 14 select,
15 start). They feed the `gamepad` helper and the direct player-3/4 reads in
place of `cont1..4_key`. **Wherever a core reads `cont*_key` directly**
(players 3 and 4 often are), read `key*` instead, or SNAC will not reach it.

### What was measured

- `sim/run_analogizer.sh`: a model of the core's Pocket stream (the board's
  raster from a 5-in-48 phase accumulator on 96 MHz, each visible line's 512
  pixels at clk_sys / 4 from 3 beats after the window opens, as
  `gsp_video.sv` emits them) through `ana_retime` and the wrapper on 40 MHz,
  read at the cartridge pins as the DAC reads them. 96 and 40 MHz are kept
  in exact ratio, as one PLL makes them.
  - With the menu at its defaults, every pin sits as on a core without the
    adapter, and the controller words pass through.
  - Every option of every Analogizer entry in the package's `interact.json`
    (32), set as the firmware sets a masked entry, read back the word as the
    bridge samples it, merged and written: the word, the adapter's copy and
    the enable each followed. With the adapter's own read-back in place of
    the wrapper's, the same run fails at the second entry.
  - RGBS: all 122,880 visible dots of a frame (512 × 240) reach the DAC
    pins, in raster order, each exactly four clocks, as their top six bits
    per channel, with 0 differing. Csync is one 38-dot pulse a line.
  - Scandoubler: 524 lines per frame (twice 262) at 1268 clocks, half the
    board's 2,536-clock line; the frame 664,432 clocks, the board's.
  - YPbPr and Y/C NTSC/PAL: no unknown on any pin for a frame.
  - All six SNAC assignments, the analog stick, and type "none" map as
    tabled.
  - Position, at both ends of the shipped sliders: read back as written,
    the settings word untouched; at the pins csync moves by exactly the
    dots (in clocks) and lines asked, the picture is still every dot with
    0 differing, csync is never low while a dot is drawn, and the
    scandoubler's lines and period are unchanged; back at 0, csync is
    where it started (+12,+3: csync to picture 488 clocks from 440, 22
    lines from 19; -32,-15: 312 clocks, 4 lines). One step past either end
    (+13 dots and +4 lines, or -16 lines) fails it. A jump written just
    after a pulse that puts the next right after it (V +3 to -2, H +12 to
    -27) leaves csync out of the picture for three frames.
  - The blank bit, and enable off again returning the port to idle.
- `sim/lint.sh`: `ana_retime` and the wrapper lint clean. The vendored
  files' warnings are dropped by path; their errors are not.
- `sim/run_video.sh`: the frozen-state video gate, unchanged (nothing under
  `rtl/` changed): 13 states, 0 differing pixels.
- Quartus 18.1: **does not fit.** The fitter needs 1,900 LABs and the
  5CEBA4 has 1,848: 18,788 ALMs needed of 18,480. The released build is
  16,568 (90 %, already with `OPTIMIZATION_MODE "AGGRESSIVE AREA"`); the
  Analogizer path adds 1,818 -- the wrapper 292 of its own, the adapter
  module 1,490 (scandoubler 143 + HQ2x 599, Y/C 246, SNAC 288 with PSX 73,
  YPbPr 104, its top level 51), and the re-timer 36 (and one block RAM).
  Nothing here is timed yet: the fit stopped before timing analysis. To
  fit with the margin the 0.2.0 build closed timing at (96 %), about 1,050
  ALMs have to go; the candidates are the adapter's own modes (HQ2x and
  the scandoubler, Y/C), which means a local change to the vendored module
  or to which of its parts the wrapper builds -- a decision for the core's
  owner, not made here.

**Not proven:** that it fits (above); anything on hardware with this core (the adapter module itself
ships in RndMnkIII's cores and in plasticbugs' MSX2, Moo Mesa, NBA Jam and
Namco Classic Collection), the re-timer against the real core's stream (the
bench models `gsp_video`'s output; the system benches do not include
`core_top`), that the firmware writes a signed slider as a two's complement
word, and the SNAC serial protocols, which are
the adapter module's and are forced at its outputs in the bench rather than
driven over the pins. The Y/C and YPbPr encodings have no reference to compare
against, only a run without unknowns.

### Turning it off

Set `USE_ANALOGIZER = 0` in `core_top.sv`, remove the `general[4]` group
from the SDC (it would match nothing), and take the six menu entries out of
`interact.json` and set `cartridge_adapter` back to -1 in `core.json`.
