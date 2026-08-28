# TMS34010 (GSP) core — status

`rtl/gsp/tms34010.sv` (+ `gsp_icache.sv`, `gsp_div.sv`) is a from-scratch
TMS34010 written against MAME 0.288's `devices/cpu/tms34010` sources, for the
multisync Hard Drivin' board that Stun Runner runs on. It is verified
instruction-by-instruction against MAME traces (see §3).

## 1. What is implemented

- Full register model: A0-A14, B0-B14, shared SP, 32-bit bit-addressed PC,
  ST (N C Z V P IE FE1 FS1 FE0 FS0). MAME's flag quirks are reproduced (ADDC
  carry ignores the carry-in, CMPI compares against the complemented
  immediate, ABS/NEG V semantics, SLA overflow mask, RL/SRA/SRL counts).
- Every non-reserved 34010 opcode in MAME's table: arithmetic, logic, shifts,
  field moves in all 20 addressing forms for both fields plus the byte moves,
  MOVI/MOVK/ADDK/SUBK/BTST, MPYS/MPYU (32×32→64), DIVS/DIVU/MODS/MODU
  (sequential 64/32 divider), LMO, SEXT/ZEXT/SETF/EXGF, XY ops (ADDXY, SUBXY,
  CMPXY, CPW, CVXYL, MOVX, MOVY), all jumps/calls/returns/DSJ*, TRAP, RETI,
  MMTM/MMFM, PUSHST/POPST/GETST/PUTST, EMU/REV/NOP.
- Graphics: PIXT (all six forms), DRAV, LINE (one pixel per instruction
  execution, restartable, like the silicon and MAME), FILL L/XY, PIXBLT B,L /
  B,XY (binary expand), PIXBLT L,L / L,XY / XY,L / XY,XY (forward direction),
  with window checking modes 0-3 (clip, V flag, WV interrupt for mode 1),
  transparency, the 22 raster ops for single pixels and the 22 pixel ops for
  blits (including MAME's `op13 == op11` typo), PSIZE 1/2/4/8/16, CONVSP/CONVDP
  XY conversion, and DPYCTL.SRE shift-register transfers (flagged on `mem_srt`
  for the parent to implement).
- Interrupts: NMI (HSTCTLH, with NMIM), HI (host INTIN), DI (VCOUNT ==
  DPYINT), WV, ILLOP vector, TRAP vectors. Priority and stacking as MAME.
- Host interface: HSTADRL/H, HSTDATA with INCR/INCW post-increment,
  HSTCTL with the host/GSP write-permission rules, HLT, INTOUT → `int_out`.
- Internal I/O registers, including the raster counters (HCOUNT/VCOUNT from
  `cen_vid`), the per-line DPYADR step/load and the DPYINT display interrupt.
- 1 KB direct-mapped instruction cache on the fetch path; invalidated per line
  on any GSP or host write, flushed by `cache_flush`.

## 2. Microarchitecture and timing

Not cycle exact: a multi-cycle state machine built around one shared 32-bit
ALU, one shared 32-bit rotator/shifter (SHL/SHR/SAR/ROL from a single
rotator plus a mask), one shared 33x33 signed multiplier and a sequential
64/32 divider. Instructions load registered operands into those units and a
small writeback sequencer (S_ALU / S_SH: destination and flag-mode selectors)
commits the result a clock later; the register file has a single write port
and two combinational read ports (plus one indexed port for MMTM/MMFM/DIV).
Field extract/insert, pixel and blit operations are sequences over the same
shifter (field read: 2 passes, field write: 2 passes + range masks; blit:
per-pixel incremental destination mask, source word kept pixel-aligned, one
shifter pass per pixel only for PIXBLT). This is the area-reduced version;
the first version had per-instruction adders/shifters and synthesised to
32.8 k ALUTs, more than the whole FPGA.

Every instruction costs at least one `cen` (6 MHz) and every external word
access one more (cache hits are free), so the core is never faster than the
real part on memory-bound work. Over the six trace windows the rewrite needs
about 10 % more clocks than the first version (e.g. w3: 61.1 M vs 54.9 M
clocks for 3.92 M instructions, i.e. ~15.6 clocks per instruction at 96 MHz,
against the real part's 16 clocks per 6 MHz cycle).

## 3. Verification

`tools/trace_gsp.lua` captures, from MAME running headless with
`-debug -debugger none`: the VRAM (512 KB), I/O registers, control latches,
palette and register file at a frame boundary, then a per-instruction trace
(PC, ST, SP, A0-A14, B0-B14) with a running count of 68010 host-interface
accesses (each access is logged separately with the same count, so the bench
replays it between the same two instructions), and VRAM again at the end.

`sim/run_gsp.sh` builds the Verilator bench (`sim/gsp/tb_gsp.cpp`), which
models the multisync board's GSP address decode (VRAM + mirror, the 2 bpp
expander, control_lo/hi, palette, shift-register row copies) and a memory
port with random 1-6 cycle latency, loads the snapshot, runs the RTL and
compares every instruction; interrupts that MAME took (MAME only checks them
at scheduler timeslice boundaries) are injected at the same instruction. At
the end of the window the RTL's VRAM is compared word for word with MAME's.

Results (all windows: zero register/PC divergences, VRAM identical):

| window | content | instructions compared | host accesses replayed | interrupts | VRAM |
|---|---|---|---|---|---|
| w1 (frames 365-420) | GSP held in reset, 68010 downloads the program through HSTDATA, GSP boot and init, first frames of attract | **1,860,171** | 2,818 | 55 | identical |
| w2 (frames 1500-1503) | attract-mode 3D demo (polygon fills, lines, sprites) | **88,534** | 3,354 | 3 | identical |
| w3 (frames 2300-2420) | end of attract demo → title / "insert coin" text screens (PIXBLT B text, fills, sprites) | **3,917,724** | 86,090 | 120 | identical |

Opcode coverage of the game (`tools/gsp_coverage.py` over the three traces,
full table in `artifacts/gsp/coverage.txt`): 60 mnemonics / 121
mnemonic-operand shapes executed, 5.87 M executions, all of them compared
(`artifacts/gsp/results.txt` is the bench log).
Executed and verified: MOVE (all forms the game uses), MOVB, MOVI, MOVK, MOVX,
MOVY, ADD, ADDC, ADDI, ADDK, ADDXY, SUB, SUBI, SUBXY, CMP, CMPI, CMPXY, AND,
ANDI, OR, ORI, BTST, CLR, INC, LMO, ZEXT, SETF, SLL, SRA, SRL, RL, MPYU, MPYS,
DIVU, DSJS,
all JRcc forms, JR, CALL, CALLR, CALLA, RETS, RETI, MMTM, MMFM, PUSHST, POPST,
FILL L/XY, PIXBLT B,XY, PIXT (register/indirect/XY forms), LINE.
Implemented but **not exercised by the game** in these windows (unverified):
DIVS, MODS, MODU, SLA, NEG, NEGB, NOT, ABS, ANDN, XOR, XORI,
SEXT, EXGF, EXGPC, GETPC, GETST, PUTST, JUMP, TRAP, DRAV, CPW, CVXYL, PIXBLT
L/XY variants, PIXBLT B,L, window mode 1/2, SRE shift-register transfers,
NMI, WV.

## 4. Known gaps

- PIXBLT with PBH (horizontal reverse, `pixblt_r` in MAME) is not
  implemented; the game never sets CONTROL.PBH in the captured windows.
- PSIZE 32 is treated as 1 bpp for pixel ops (MAME's pixelshift quirk is
  reproduced but the 32-bit pixel read/write paths are not).
- PMASK (plane masking) is ignored, as in MAME.
- MAME's `WFIELDMAC_BIG` writes the third word of an unaligned 18-31-bit
  field back to the first word (a MAME bug); the RTL writes it to the correct
  word. No such access occurs in the traces.
- Interrupt latency: the silicon samples interrupts at every instruction
  boundary; MAME only at timeslice starts. The RTL does the former, which is
  what the bench's injection mode hides. In the system this only moves the
  DI a few instructions earlier than MAME.

## 5. Interface for the parent

See `docs/rtl-conventions.md` (tms34010 section and the appended notes):
`cen` 6 MHz, `cen_vid` 5 MHz, `mem_*` word port (bit address >> 4), `mem_srt`,
host registers 0 = HSTADRL, 1 = HSTADRH, 2 = HSTDATA, 3 = HSTCTL, the display
register outputs and `line_start` semantics. Tie `dbg_force_di`,
`dbg_int_inhibit`, `dbg_force_int`, `dbg_hold` low.

Resource expectation (not measured): ~2.5-3k ALMs for the FSM/decoder/ALU, 2-3
DSP blocks for the multiplier, 3 M10K for the cache, plus the 31×32 register
file in flops.
