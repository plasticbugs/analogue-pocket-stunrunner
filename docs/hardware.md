# S.T.U.N. Runner arcade hardware

Everything the core needs to know about the machine, taken from MAME 0.288
(`src/mame/atari/harddriv.cpp`, `harddriv_m.cpp`, `harddriv_v.cpp`,
`harddriv.h`, `atarijsa.cpp`, `atariscom.cpp`, `devices/cpu/tms34010/*`,
`devices/cpu/adsp2100/*`) and from interrogating the running driver with Lua.
Written first, per METHODOLOGY §3 Phase 1, and updated whenever a measurement
contradicts it.

Target set: **`stunrun`** — S.T.U.N. Runner (rev 6), Atari Games, 1989.
MAME sources it from the **Hard Drivin'** driver: this is not a tilemap/sprite
game at all but a polygon machine with three processors and a bitmapped
frame buffer.

---

## 1. Boards, chips and clocks

Three boards stacked on an expansion bus:

| Board | Part | Role | Clock | Source |
|---|---|---|---|---|
| "multisync" main board (A046901) | Motorola **MC68010** | game logic, host to everything else | **8.000 MHz** (32 MHz XTAL ÷4) | `M68010(config, m_maincpu, HARDDRIV_MASTER_CLOCK/4)` |
| | TI **TMS34010** "GSP" | draws polygons into VRAM, generates video timing | **48.000 MHz** CLKIN; instruction cycle = CLKIN/8 = **6 MHz** | `TMS34010(config, m_gsp, XTAL(48'000'000))`, `set_pixel_clock(5000000)`, `set_pixels_per_clock(2)` |
| | TMS34012 "PSP" (SCX6218UTP) | pixel expander / video shifter (fixed function, not emulated as a CPU) | 50 MHz | driver comment |
| | 512 KB VRAM (16× 42C4064) | GSP program + frame buffers | | |
| | ADC0809 | 8-bit ADC, joystick X (ch0) and Y (ch2) | 1 MHz (unknown) | `ADC0809(config, m_adc8, 1000000)` |
| | MC68681 DUART | serial link (unused standalone); its IRQ is 68k level 6 | 3.6864 MHz | |
| | M48T02 (200E) + 2816 EEPROM (210E) | "ZRAM": 2 KB timekeeper NVRAM + 2 KB EEPROM, byte-lanes of one 16-bit word | | |
| "ADSP II" board (A047046) | Analog Devices **ADSP-2100** | polygon transform/lighting/slopes | **8.000 MHz** (32 MHz ÷4), 1 instruction/cycle | `ADSP2100(config, m_adsp, XTAL(32'000'000)/4)` |
| | 8K×24 program RAM, 8K×16 data RAM, 2× 8K×16 "SOM" output buffers, 384 KB "SIM" serial ROM | | | |
| "JSA II" sound board | MOS **6502** | sound program | **1.789772 MHz** (3.579545 ÷2) | `M6502(config, m_jsacpu, JSA_MASTER_CLOCK/2)` |
| | Yamaha **YM2151** | FM music | **3.579545 MHz** | |
| | OKI **MSM6295** | ADPCM samples | **1.193181 MHz** (3.579545 ÷3), pin 7 switchable | |

No MSP (second 34010), no slapstic (`config.device_remove("slapstic")`), no
DSK board. Stun Runner is the simplest configuration of this family.

**Display** (as configured by the GSP at boot, measured with Lua, §5):
pixel clock 10 MHz (5 MHz GSP video clock × 2 px/clock), HTOTAL 317 clocks =
**634 px/line**, 512 visible; VTOTAL 262 lines, **240 visible** (lines 19–258
of the raster; MAME snapshots are 512×240). Refresh = 10 MHz / (634×262) =
**60.20 Hz**. Not rotated.

---

## 2. 68010 memory map (`multisync_68k_map` + `init_multisync` + `init_adsp`)

All accesses are 16-bit words unless noted. Unmapped reads return 0xFFFF.

```
000000-0fffff  ROM (768 KB populated: 000000-0bffff, 12× 64 KB, even=200x odd=210x)
600000-603fff  JSA sound: read  = sound->main response byte (D15:8), clears sound IRQ (level 4)
                          write = main->sound command byte (D15:8), raises 6502 NMI
604000-607fff  read  = sound board reset (returns 0xffff)
               write = /NWR latch (see §2.1)
608000-60bfff  write = watchdog kick (the FatalError path stops the CPU and waits for the watchdog to reboot the board; the core reboots after 1 s without a kick)
60c000-60ffff  read  = port 0 (see §2.2)      write = IRQ5 acknowledge
800000-807fff  ADSP program RAM, 8K× 24-bit; even 68k word = bits 23:16 (upper byte reads 0), odd = bits 15:0
808000-80bfff  ADSP data RAM, 8K× 16-bit; write to 80bffe (offset 0x1fff) also fires the ADSP IRQ trigger
810000-813fff  ADSP output ("SOM") buffer, 8K× 16-bit, bank selected by ADSP control bit 3
818000-81801f  ADSP control latch (see §2.3)
818060-81807f  write = clear ADSP->68k IRQ (level 2)
838000-83ffff  read  = ADSP IRQ state: 0xfffd ^ (xflag?2:0) ^ (irq?1:0)   -> bit0 low when IRQ pending... see below
a00000-a7ffff  write = /WR0 latch: offset&7 selects, offset bit3 is the value (SEL1-4, coin counters)
a80000-afffff  read  = port a80000 (buttons, §2.2)   write = /WR1 latch (shifter LEDs; unused here)
b00000-b7ffff  read  = ADC0809 data (byte on D7:0, mirror)   write = /WR2 latch (wheel; unused here)
b80000-bfffff  read  = 12-bit ADC (unused: always 0xfff)   write = ADC control (§2.4)
c00000-c03fff  GSP host interface (§4.1)
c04000-c07fff  MSP host interface: not populated, reads 0xffff
ff0000-ff001f  MC68681 DUART, registers on D15:8 (even bytes) -- 16 registers; only touched by the IRQ6 handler and the serial-download self-test paths (docs/boot-sequence.md)
ff4000-ff4fff  ZRAM: D7:0 = 210E EEPROM, D15:8 = 200E timekeeper; writes only when ZP1=0 and ZP2=1
ff8000-ffffff  work RAM, 32 KB
```

The ADSP IRQ state read: `result = 0xfffd; if (xflag) result ^= 2; if (irq) result ^= 1;`
so bit 1 is **set** when XFLAG is set and bit 0 is **set** when the ADSP
interrupt is pending (0xfffd has bit 1 clear, bit 0 set... careful: 0xfffd =
...1101, so bit 1 = 0, bit 0 = 1; XFLAG **sets** bit 1, IRQ pending **clears**
bit 0).

### 2.1 /NWR latch (604000, write): `offset&7` selects, `(offset>>3)&1` is the value

| sel | function |
|---|---|
| 0 | CR2 (unused) |
| 1 | CR1 (unused) |
| 2 | LC1 lamp |
| 3 | LC2 lamp |
| 4 | ZP1 (ZRAM write protect) |
| 5 | ZP2 (ZRAM write protect) |
| 6 | /GSPRES: 1 = run GSP, 0 = hold GSP in reset |
| 7 | /MSPRES (no MSP) |

### 2.2 Input ports

**Port 0 (60c000, read, 16 bits)** — low byte IN0, high byte SW1:

| bit | meaning | polarity |
|---|---|---|
| 0 | diagnostic jumper | 1 = off (default) |
| 1 | /HBLANK | 0 during hblank (MAME: hpos > 90 % of width) |
| 2 | /VBLANK | 0 during vblank |
| 3 | 12-bit ADC EOC | always 1 |
| 4 | 8-bit ADC EOC | 1 when the ADC0809 conversion is complete |
| 5 | self test | 0 = test mode |
| 6 | COIN2 | active low |
| 7 | COIN1 | active low |
| 8–15 | SW1 #8..#1 | stunrun defaults all **0 (On)** |

**Port a80000 (read)**: bit 0 = button 1, bit 1 = button 2, bit 2 = 1P start,
all active low, bits 3–15 read 1.

**ADC0809 (b00000)**: channel 0 = stick X, channel 2 = stick Y (8-bit,
0x80 centre); channels 1,3–7 unused (read 0xff in MAME since the ports are
`IP_ACTIVE_LOW, IPT_UNUSED`).

**Coins**: the game counts the main-board COIN1/COIN2 bits (port 0 bits 7/6,
active low); the JSA II board's own coin inputs are not used by the 68k code.
(Verified with MAME Lua: `IN0` field `Coin 1` `set_value(1)` … `clear_value()`
adds a credit; `set_value(0)` is the *inactive* state, which is why the first
attempts did nothing.)

### 2.3 ADSP control latch (818000, write): `offset&7` selects, `(offset>>3)&1` is the value

| sel | function |
|---|---|
| 0,1 | LEDs |
| 3 | SOM buffer bank seen by the 68k (the ADSP writes the *other* bank) |
| 5 | /BR: 0 = halt ADSP (bus request) |
| 6 | /HALT: 0 = halt ADSP |
| 7 | ADSP reset: 0 = hold in reset |

Power-up state: halt=1, br=0 (ADSP halted until the 68k releases it).

### 2.3b Yoke ADC polarity (b00000, ADC0809 channels 0 and 2)

Channel 0 = steering (X), channel 2 = yoke pitch (Y), 0x80 centre. Verified in
MAME on the level-select screen ("RAISE CONTROL TO SELECT LEVEL"): forcing
channel 2 to **0xf0 raises the control** (Novice -> Advanced); 0x10 does
nothing. MAME's `IPT_AD_STICK_Y` maps its *down* key to the high value, so on
the Pocket D-pad **up** must produce 0xf0 (`target/pocket/core_top.sv`); the
first build had it the other way round, which is why the D-pad appeared dead
on that screen. A dock controller's left stick is passed through unchanged
when it is off centre (deadzone 0x70-0x90) **and the framework reports pad
type 3 (a controller with analog sticks)**: the Pocket's own controls put
0x00 on the axis bytes, which without the type gate read as hard left and
yoke fully down and pinned both axes regardless of the D-pad.

### 2.4 ADC control (b80000, write)

Bits 2:0 = ADC0809 channel, bit 3 = start conversion (the 0809 START/ALE
pulse), bit 6 = latch 12-bit ADC (unused), bit 7 = 12-bit byte select.

---

## 3. 68010 interrupts

Auto-vectored, levels fixed by wiring (`update_interrupts`):

| level | source | set by | cleared by |
|---|---|---|---|
| 1 | MSP | — (absent) | |
| 2 | ADSP | ADSP writes /GINT (data space 0x2006) | 68k write 818060 |
| 3 | GSP | GSP sets INTOUT (HSTCTLL bit 7) | GSP or host clears INTOUT |
| 4 | sound | 6502 writes response byte (2a02) | 68k reads 600000 |
| 5 | timer | periodic: 32 MHz/16/16/16/16/2 = **244.14 Hz** | 68k write 60c000 |
| 6 | DUART | 68681 | DUART |

The 68k also watches /VBLANK in port 0 by polling. Vector base: the boot code
does `MOVEC A0,VBR` with A0=0 — a 68010 instruction, so a plain 68000 core
faults at the second instruction. **A 68010 core is mandatory** (TG68K.C in
`CPU="01"` mode).

Reset vector: SSP = 0xffffc000 (→ RAM at 0xffc000), PC = 0x000216. IRQ
handlers: L1 0x7fa, L2 0x7f0, L3 0x7d6, L4 0x81c, L5 0x82c, L6 0x812.

---

## 4. TMS34010 GSP

### 4.1 Host interface (68k side, c00000-c03fff)

`offset = (byte_offset/2 /2) ^ 1`, i.e. 68k word index `i` at c00000+2i maps
to host register `(i>>1)^1`, with MAME's numbering 0 = HSTADRL, 1 = HSTADRH,
2 = HSTDATA, 3 = HSTCTL (the boot code writes the 32-bit address as one long at
c00002: high word to c00002 = HSTADRH, low word to c00004 = HSTADRL):

| 68k address | host reg | |
|---|---|---|
| c00000 | 1 | HSTADRH (address high 16) |
| c00004 | 0 | HSTADRL (address low 16) |
| c00008 | 3 | HSTCTL: write splits into HSTCTLH (D15:8) and HSTCTLL (D7:0) |
| c0000c | 2 | HSTDATA: read/write the 16-bit word at {HSTADRH,HSTADRL} & ~0xf; post-increment by 0x10 (16 bits) if HSTCTLH bit 11 (write) / bit 12 (read) |

HSTCTLH bits: 15 = HLT (halt GSP), 11 = INCW, 12 = INCR, 9 = NMIM, 8 = NMI,
7 = CF (cache flush; ignored). HSTCTLL: bits 2:0 MSGIN (host writes), 6:4
MSGOUT (GSP writes), 3 = INTIN (host sets, GSP clears; raises HI interrupt in
GSP), 7 = INTOUT (GSP sets, host clears; drives 68k IRQ3).

The GSP starts **halted** (`set_halt_on_reset(true)`): the 68k loads the GSP
program into VRAM through HSTDATA, then clears HLT.

Host data accesses are inserted between the GSP's own memory cycles (the
TMS34010's host interface arbitrates per memory cycle, not per instruction):
`rtl/gsp/tms34010.sv` serves `host_pend` in `S_W0` and on a cache miss, plus at
`S_CHECK`. Before that, a HSTDATA write during a PIXBLT/FILL waited for the whole
blit; `SomCopyToGsp` (3-6k words per game loop) and `GspFeedDataStream` (the
starfield backdrop paint) crawled -- see docs/verification.md.

### 4.2 GSP address space (`multisync_gsp_map`; addresses are in **bits**)

```
00000000-0000200f  no-op (hit by self-test)
02000000-020fffff  2bpp "expander" write region (§4.4); reads return 0
c0000000-c00001ff  internal I/O registers (32 × 16-bit, one per 0x10)
f4000000-f40000ff  control_lo latch (16 words). word 0 = expander colour
f4800000-f48000ff  control_hi latch: (offset>>3)&1 is the value, offset&7 selects (§4.5)
f5000000-f5000fff  palette RAM lo (256 × 16-bit: D15:8 = red, D7:0 = green) of the current bank
f5800000-f5800fff  palette RAM hi (256 × 16-bit: D7:0 = blue)
ff800000-ffbfffff  VRAM 512 KB, mirrored at ffc00000-ffffffff (mirror 0x0400000)
```

The interrupt vectors live at fffffe80/a0/c0/e0 and the reset vector at
ffffffe0 — inside the VRAM mirror.

### 4.3 Video timing and frame buffer scan-out (`scanline_multisync`)

Registers set by the game (Lua, frames 480+):

```
HESYNC=0013 HEBLNK=0037 HSBLNK=0137 HTOTAL=013c   -> 634 px total, visible x = 2*0x37 .. 2*0x137-1 = 110..621 (512 px)
VESYNC=0004 VEBLNK=0013 VSBLNK=0103 VTOTAL=0105   -> 262 lines, visible y = 19..258 (240 lines)
DPYCTL=f004  (ENV=1, NIL=1, DXV=1(master), SRT=1, SRE=0, ORG=0, DUDATE=1)
DPYSTRT=fc3c DPYINT=0002 CONVSP=CONVDP=0015 PSIZE=0002 (later frames)
```

Per visible scanline the hardware emits, for x in [heblnk, hsblnk):

```
rowaddr = dpyadr >> 4           (dpyadr = DPYADR ^ 0xfffc when DPYCTL.ORG == 0)
coladdr = ((dpyadr & 0x7c) << 4) | (DPYTAP & 0x3fff)
yoffset = (DPYSTRT - DPYADR) & 3
vram_base = VRAM[(rowaddr << 10) & vram_mask]                  -- 16-bit word index; 1024 words = 2 KB per row
col = (yoffset << 9) + ((coladdr & 0xff) << 3) - 7 + (finescroll & 7)
pixel(x) = byte at vram_base[(col++ & 0x7ff)]                    -- 8 bpp, low byte first
colour = palette[palettebank * 256 + pixel]
```

So a VRAM "row" is 2048 pixels = **four 512-px display lines** selected by
`yoffset`. DPYADR is loaded from DPYSTRT at VSBLNK and advanced per line
(34010 rule): if `(dpyadr & 3) == 0` then `dpyadr = ((dpyadr & 0xfffc) -
(DPYCTL & 0x3fc)) | (DPYSTRT & 3)` else `dpyadr = (dpyadr & 0xfffc) |
((dpyadr - 1) & 3)`. DPYINT raises the display interrupt when VCOUNT ==
DPYINT (line 2). Palette entries are 8-bit R, G, B.

### 4.4 Expander writes (02000000-020fffff)

A 16-bit write to bit address `A` in this region writes **8 pixels** at VRAM
word index `((A - 0x02000000) >> 4) * 4`... precisely, MAME:
`dest = &vram[offset * 4]` (offset = word index within the region), mask from
`mask_table[data*2]`: pixel k (k = 0..3) of the first 32-bit word is written
if data bit `2k` is set, pixel k of the second word if bit `8+2k` is set;
written pixels take `control_lo[0]`: the 32-bit colour is
`{c16, c16}` so byte lane 0/2 gets `c16[7:0]` and byte lane 1/3 gets
`c16[15:8]`. (For a solid colour the game writes the same byte in both
halves.) The PSP also implements the shift-register transfers (§4.6).

### 4.5 control_hi latch (f4800000)

| sel | function |
|---|---|
| 0 | shift-register transfer enable |
| 1 | fine scroll = data & 7 |
| 2 | palette bank bit 0 = val |
| 3 | palette bank bit 1 = val |
| 4 | palette bank bit 2 (only with ≥2048-entry palette; ours is 1024, ignore) |
| 7 | LED |

Measured: palettebank = 0 and finescroll = 7 through attract mode.

### 4.6 VRAM shift-register transfers

The 34010's `DPYCTL.SRT` mode turns memory cycles with the SRT bit into VRAM
shift-register transfers. MAME's callbacks: *write to shiftreg* (a read
cycle with SRT) latches the source row: `address & ~255` words in the normal
VRAM region (a whole 512-byte row segment), or `(address >> 2) & ~(1024-1)`
in the 2bpp region; *read from shiftreg* (a write cycle) copies 512 bytes
(or 2048 in the expander region, i.e. `512*8 >> 1`) from the latched source
row to the destination row, only when control_hi sel 0 (enable) is 1. The
game uses this as a fast row copy / clear. Implement as a 256-word block
move in the VRAM controller.

### 4.7 GSP interrupts

INTPEND/INTENB bits: 0x0002 X1 (unused), 0x0004 X2 (unused), 0x0200 HI (host,
from HSTCTLL.INTIN), 0x0400 DI (display, VCOUNT==DPYINT), 0x0800 WV (window
violation). Vectors: HI fffffec0, DI fffffea0, WV fffffe80, NMI fffffee0,
reset ffffffe0. Priority NMI > HI > DI > WV. Taking an interrupt pushes PC
then ST, clears ST, loads PC from the vector; 16 cycles.

Speed-up hooks in MAME (`hdgsp_speedup*`, PC fff41070; the wait loop at
fff41650 `MOVE @FFF71670h,A0,1 / JRNE`) are performance hacks only, not
hardware.

---

## 5. ADSP-2100 board

### 5.1 ADSP memory

- Program memory 0x0000-0x1fff: 24-bit RAM, loaded by the 68k (§2). 0x2000-0x3fff unmapped.
- Data memory 0x0000-0x1fff: 16-bit RAM shared with the 68k at 808000.
- Data memory 0x2000-0x2fff: memory-mapped I/O, `offset & 7`:

| offset | read | write |
|---|---|---|
| 0 | /SIMBUF: next SIM word `sim[eprom_base + sim_address++]` (0xff past the end) | |
| 1 | | /SIMCLK: sim_address = data |
| 2 | | SOMLATCH: `som[(bank^1)*0x2000 + (som_address++ & 0x1fff)] = data` |
| 3 | | /SOMCLK: som_address = data |
| 5 | | /XOUT: xflag = data & 1 |
| 6 | | /GINT: raise 68k IRQ2 |
| 7 | | /MP: eprom_base = data * 0x10000 |

SIM ROM: 384 KB = 3 × 128 KB pages (`/MP` selects a 64 K-word page;
words 0..0x2ffff), 16-bit words, **high byte from the `.90h/.10h/.9h` ROMs,
low byte from `.90k/.10k/.9k`** (MAME region word 0 = 0x0068 with 90h[0]=0x00,
90k[0]=0x68; word 0x83 = 0x6653 as the ADSP reads it). An earlier revision of
this paragraph stated the opposite of its own evidence and the packing
followed it: the image stores the `.h` byte at the even address, i.e. the
words are big-endian like the 68k region, and `stunrun_core.sv` byte-swaps on
fetch. This inverted every SIM word whose bytes differ and was invisible to a
byte-wise compare of the region, to the ADSP bench (which replays MAME's
values) and to a self-check written with the same assumption.

### 5.2 ADSP-2100 core facts (for the RTL)

- 24-bit instructions, 1 per cycle at 8 MHz; separate 14-bit program and data
  address spaces; ALU/MAC/shifter with primary+secondary register banks
  (`MSTAT.BANK`), two DAGs (I0-3/M0-3/L0-3 on DAG1 with bit-reverse,
  I4-7/M4-7/L4-7 on DAG2), PC stack ×16, count stack ×4, status stack ×4,
  loop stack ×4 (`DO UNTIL`).
- **No internal peripherals** on the 2100 (no timer, no SPORTs; those are
  2101+). The only interrupts are IRQ0-3 pins; Stun Runner uses **none** —
  the 68k↔ADSP handshake is by polling data RAM and the trigger at 0x1fff
  (`signal_interrupt_trigger` is a MAME scheduler hint, not an IRQ).
- Halt/BR/reset from the 68k control latch (§2.3). Reset PC = 0, `IMASK`=0.
- MAME's `hdadsp_speedup_r` on data 0x1fff is a spin-loop optimisation, not hardware.
- Instruction encoding: `adsp2100.cpp::execute_run` (`switch (op >> 16)`), ALU/MAC/shift ops in `2100ops.hxx`.

---

## 6. JSA II sound board

### 6.1 6502 memory map (`atarijsa2_map`)

```
0000-1fff  RAM 8 KB
2000-2001  YM2151 (A0 = register/data)
2800       (mirror 01f9) read  OKI6295 status
2802       (mirror 01f9) read  command byte from 68k; clears 6502 NMI
2804       (mirror 01f9) read  I/O port (§6.2)
2806       (mirror 01f9) r/w   timed IRQ acknowledge
2a00       (mirror 01f9) write OKI6295 command
2a02       (mirror 01f9) write response byte to 68k; raises 68k IRQ4
2a04       (mirror 01f9) write /WRIO (§6.3)
2a06       (mirror 01f9) write /MIX  (§6.4)
3000-3fff  banked ROM: 4 × 4 KB pages from ROM offset 0x0000-0x3fff, page = WRIO bits 7:6
4000-ffff  ROM (offset 0x4000-0xffff of the 64 KB 136070-2123.10c)
```

Mirror 0x01f9 means address bits 0,3,4,5,6,7,8 are ignored: 2800-29ff decode
on A1,A2 only.

### 6.2 Read I/O port 2804

| bit | meaning |
|---|---|
| 0 | coin 1 (active high) |
| 1 | coin 2 (active high) |
| 2 | coin 3 / aux (active high) |
| 3,4 | unused (0) |
| 5 | output buffer full: response byte written and not yet read by 68k |
| 6 | **0** when a command from the 68k is waiting (`IP_ACTIVE_LOW` on main_to_sound_ready) |
| 7 | self test: 1 when the main board's test switch is **on** (`!m_test_read_cb()` xor) — result ^= 0x80 when test line reads 0 |

Precisely: the port field for bit 7 reads `!test_read_cb()`; stunrun wires
`test_read_cb` to IN0 bit 5 (1 = not in test), so bit 7 = 1 in test mode.

### 6.3 /WRIO (2a04)

| bits | function |
|---|---|
| 7:6 | ROM bank at 3000-3fff |
| 5 | coin counter 2 |
| 4 | coin counter 1 |
| 3 | OKI pin 7 (sample rate: 1 → clk/132 = 9.04 kHz, 0 → clk/165 = 7.23 kHz) |
| 2 | OKI reset (active low) |
| 1 | unused on JSA II |
| 0 | YM2151 reset (active low) |

### 6.4 /MIX (2a06)

| bits | function |
|---|---|
| 5 | low-pass filter enable (not emulated by MAME) |
| 3:1 | YM2151 volume: level/7 |
| 0 | OKI volume: 1 → 1.0, 0 → 0.5 |

Mix (MAME): YM2151 route 0.60, OKI 0.75, JSA output routed to mono at 0.5.
The YM2151's CT1 output gates the OKI (`oki gain *= ct1`); CT2 unused.

### 6.5 Interrupts and comm

- 6502 IRQ = timed_int OR ym2151_int. Timed interrupt: **3.579545 MHz/4/16/16/14 = 249.97 Hz**, cleared by any access to 2806.
- 6502 NMI = command latch full (set by 68k write to 600000, cleared by 6502 read of 2802).
- 68k IRQ4 = response latch full (set by 6502 write to 2a02, cleared by 68k read of 600000).
- **Command pacing (not on the real board, same effect).** The command latch has no
  FIFO and the 68k has no handshake for it: `SoundSendCmd` (0x23ede) polls a80000
  bit 15, which is `IPT_UNUSED` in MAME and reads 1 here too, so it always writes.
  A second write before the 6502's NMI handler has read 280a replaces the first, and
  the NMI is edge-triggered. The handler (57e3) reaches its single latch read 43.0 us
  after the edge; the 6502 samples NMI once per cycle (T65 too), so a write landing
  within one cycle (0.56 us) of that read leaves NMI_n low with no edge ever seen --
  the latch then stays full for good and every later command is ignored. The real
  68000 never gets there: `SoundQueueFlush` (0x3013c) costs it 46.7 us per queued
  byte, 3.7 us after the read. TG68K runs that loop ~7 % faster and, after the
  game's mid-level sound reset, put the second of `1d 1c 39 22` inside the window:
  one command read, the board deaf until the next reset (the "stuck song part").
  `jsa2` exports `cmd_pending` = latch full OR fewer than 8 6502 cycles since the
  read, and `stunrun_main` holds a write to 600000 while it is set (`snd_block`,
  85 us timeout so a dead board cannot wedge the 68k). JSA bench sweep
  (`sim/jsa`, `JSA_STALL=1`): with the burst re-spaced anywhere from 2 to 46.7 us
  all four commands are taken, and at 46.7 us the YM2151 stream stays identical to
  MAME's.
- Sound reset: 68k read of 604000 resets the 6502 and clears the response latch.

---

## 7. Memory budget and placement

| Memory | Size | Where |
|---|---|---|
| 68010 ROM | 768 KB | SDRAM |
| 68010 work RAM | 32 KB | BRAM |
| ZRAM (200E+210E) | 4 KB | BRAM, saved to SD (nonvolatile) |
| GSP VRAM | 512 KB | SDRAM |
| GSP palette | 1024 × 24 bit | BRAM |
| ADSP program RAM | 8K × 24 | BRAM |
| ADSP data RAM | 8K × 16 | BRAM |
| SOM buffers | 2 × 8K × 16 | BRAM |
| SIM ROM | 384 KB | SDRAM (sequential, prefetched) |
| JSA program ROM | 64 KB | BRAM |
| JSA RAM | 8 KB | BRAM |
| OKI ADPCM ROM | 256 KB | SDRAM |

BRAM total ≈ 185 KB of the 5CEBA4's 385 KB; SDRAM ≈ 1.9 MB.

**SDRAM bandwidth budget** (controller at 96 MHz, ~8 cycles per random
16-bit access): GSP ≤ 6 M accesses/s (instruction fetch + data; a small
instruction cache cuts this), 68010 ≤ 2 M/s, SIM ≤ 8 M/s peak but bursty and
sequential, OKI < 0.1 M/s, display 256 words/line in bursts. Worst case sums
to roughly 75 % of the controller; the GSP is the elastic client (a slower GSP
lowers the game's frame rate but stays correct because the 68k waits on it).

---

## 7b. Diagnostic overlay (compiled out of the Pocket build)

`rtl/dbg_overlay.sv` (METHODOLOGY section 4: the bottom 12 lines show the
68010 PC, GSP PC and flags/ADSP PC as bit squares) is instantiated behind
`stunrun_core`'s `DBG_OVERLAY` parameter -- 1 in the benches, **0 in
`target/pocket/core_top.sv`**. At 99 % device utilisation it costs 105 ALUTs
(about 10 LABs), and the build that added a four-comparator steering gate
missed the device by 2 LABs; the simulation probes now cover what the overlay
was for. Set the parameter back to 1 for a diagnostic build.

## 7c. D-pad ramp and the audio IIR (Pocket build)

`target/pocket/dpad_ramp.sv`: each yoke axis integrates toward the extreme
while a D-pad direction is held (full lock in ~0.7 s at a shared 183 Hz tick)
and returns to centre in ~0.25 s when released, so a tap is a small
deflection -- the same digital-to-analog ramp other Pocket/MiSTer cores use
for analog steering. A dock controller's stick still bypasses it.

The framework's optional IIR low-pass in the audio path (`audio_filters.sv`,
669 ALUTs including its loader) is compiled out with `audio_mixer`'s
`IIR = 0`; the DC blocker and mixer remain. It was the largest removable block
when the ramp build missed the device by 9 LABs.

## 8. ROM image layout (`stunrun.rom`, built by `tools/mra_build.py` from `stunrun.mra`)

| offset | size | content | byte order |
|---|---|---|---|
| 0x000000 | 0x0c0000 | 68010 program | big-endian words: even byte from `.200x`, odd from `.210x` |
| 0x0c0000 | 0x060000 | ADSP SIM data | big-endian words: even (high) byte `.90h/.10h/.9h`, odd (low) `.90k/.10k/.9k`; the core swaps on fetch |
| 0x120000 | 0x040000 | OKI ADPCM | `.1fh .1ef .1de .1cd` in order |
| 0x160000 | 0x010000 | JSA 6502 program | `136070-2123.10c` |
| 0x170000 | 0x000800 | 200E timekeeper default contents | `stunrun.200e` |
| 0x170800 | 0x000800 | 210E EEPROM default contents | `stunrun.210e` |

Total 0x171000 = 1,511,424 bytes.

---

## 9. Verification hooks

- `tools/dumpstate.lua`: dumps GSP IO registers, palette (both banks via the
  `gsp_palram_lo/hi` shares), control latches (reconstructed by tapping
  control_hi writes) and the 512 KB VRAM share, plus a PNG snapshot, at chosen
  frames. `tools/render_model.py` re-renders the frame from the dump (§4.3).
- `-debug -debugger none` with `manager.machine.debugger:command("trace ...")`
  produces instruction traces of any CPU headless; used to check the
  TMS34010 and ADSP-2100 RTL instruction by instruction.
- Coins/start: `ioport.ports[":mainpcb:IN0"].fields["Coin 1"]` (active low),
  `[":mainpcb:a80000"].fields["1 Player Start"]`, `[":mainpcb:jsa:JSAII"].fields["Coin 1"]` (active high).
