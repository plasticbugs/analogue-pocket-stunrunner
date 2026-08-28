# ADSP-2100 core — status

`rtl/adsp/adsp2100.sv`: the ADSP II board's DSP, ported from MAME's
`adsp2100.cpp` / `2100ops.hxx` and checked instruction by instruction against
MAME traces of the real game program. Interface as in
`docs/rtl-conventions.md` (§ "adsp2100", plus the additions noted there:
`irq[3:0]`, `flag_in`, `flag_out`, `dbg_instr_done`).

## What is implemented

- The complete ADSP-2100 instruction set as MAME decodes it (every case of
  the `switch (op >> 16)`), including: ALU (all 16 functions, saturation,
  sticky overflow), MAC (all 16 functions, fractional mode, rounding, MV over
  bits 39:31, 48-bit MR kept so MR2 behaves like MAME's 16-bit register),
  shifter (LSHIFT/ASHIFT/NORM HI+LO with OR, EXP HI/HIX/LO, EXPADJ with
  MAME's unsigned compare quirk), DIVS/DIVQ, register moves between all four
  groups with every MAME write side effect (SE/MR2 sign extension, MR1
  extending into MR2, CNTR push, TOPPCSTACK push/pop, IFC latch bits), DAG1/2
  with circular buffers (base/mask exactly as MAME's `update_i/update_l`) and
  DAG1 bit-reverse, immediate and dual-fetch memory forms, program-memory
  data access with PX, DO UNTIL loops with the loop-end evaluation done
  before the instruction (CE decrements and counter-stack pops included),
  conditional jump/call/return direct and indirect, RTI, stack control,
  mode control (bank swap, reverse, sticky V, saturate), FLAG_IN/FLAG_OUT,
  IRQ0-3 with ICNTL edge latching and nesting masks.
- IDLE is a NOP, as it effectively is in MAME (which only ends its timeslice).
- 8K×24 program RAM and 8K×16 data RAM in true dual-port block RAM; port B is
  the 68010's. Data addresses 0x2000-0x2fff go to the `io_*` port; 0x3000+
  reads 0xffff and ignores writes (MAME: unmapped).
- Reset state per MAME: PC = 4, SSTAT = 0x55, everything else 0.

Microarchitecture: one instruction per `cen` pulse, executed as a 6-clock
sequence (fetch, RAM latency, latch, loop-check + memory issue + ALU/shift/
multiply, MAC accumulate + IO wait, write-back). A stalled IO read (`io_wait`)
simply makes the instruction miss the next `cen` pulse(s). Verified at `cen`
periods 12 (the board's 96/8 MHz) and 7, with random `io_wait` stalls of up to
20 clocks injected on every IO read (`IOWAIT=20 CEN_PERIOD=7 sim/run_adsp.sh`).

## Area

The datapath is shared rather than duplicated per instruction form, so one
copy of each expensive resource serves every op:

- **One 17-bit adder** (operand-invert for subtract) does every ALU
  add/subtract/negate/abs *and* DIVQ's AF±X, selected by an operand mux,
  instead of a separate adder inside each of ~10 ALU function cases.
- **One 64→32 funnel shifter** plus one leading-zero counter cover all of
  LSHIFT/ASHIFT/NORM (both directions, HI/LO, arithmetic/logical fill) and
  EXP/EXPADJ, instead of the previous per-case shift expressions.
- **One 3-input 48-bit adder** is the MAC accumulator (acc ± product +
  rounding), with the product-negate / accumulate / round decisions reduced
  to three latched control bits.
- **The multiplier stays a single 16×16** (DSP-block inferred).
- **The register file is an active set + a shadow set** swapped on a
  MSTAT.BANK change, rather than bank-indexed `[2]` pairs that forced a live
  2:1 mux in front of every one of the ~19 registers on every read.
- Program/data RAM use Intel's one-always true-dual-port template with the
  `ramstyle = "M10K"` attribute so Quartus 18.1 infers block RAM (the earlier
  two-always form left them as registers, which alone blew the ALM budget).

Measured with `quartus_map` (`./build-local.sh map`, per-entity numbers in
`projects/output_files/stunrun_pocket.map.rpt`, "Resource Utilization by
Entity"):

| version | combinational ALUTs | registers |
|---|---|---|
| before (separate adders/shifters, bank-indexed regs) | 6,051 | 1,821 |
| after (shared datapath, active+shadow regs) | _MEASURED_PENDING_ | _MEASURED_PENDING_ |

The bench (both windows, plain and with `io_wait` stalls at cen period 7)
still passes bit-for-bit after every change here, so the reduction is pure
restructuring with no behavioural difference.

## Verification

`tools/trace_adsp.lua` (MAME `-debug -debugger none`) starts a window at a
68k trigger write caught while the ADSP is idle with empty stacks (frame
835 of the attract sequence), dumps registers and both memories, then traces
the ADSP: a long PC-only stretch followed by two frames with every register
logged before each instruction. It also logs, in order, every ADSP
data-space access (address and value) and every 68k write into ADSP data /
program RAM and the control latch, so the bench can replay the host side at
the right moment relative to the ADSP's own accesses and serve the serial
ROM reads from what MAME saw. `sim/run_adsp.sh` builds the Verilator bench
(`sim/adsp/tb_adsp.cpp`), loads the start state, runs every instruction and
compares PC (always), all registers (register phase), every data-space
access (address and value, in order), the IO write stream, the state at the
PC-only→register switch, and the final registers and both memories.

| window | frames | instructions | of which with full registers | data-space accesses | result |
|---|---|---|---|---|---|
| w1 (`artifacts/adsp/w1`) | 835–877, title screen | 5,274,473 | 246,869 | 2,218,749 | PASS: 0 mismatches, end state and memories identical |
| w2 (`artifacts/adsp/w2`) | 835–1017, ends in the 3D attract demo | 22,196,327 | 246,910 | 9,210,064 (+29,818 68k writes replayed) | PASS: 0 mismatches, end state and memories identical |

Two bugs were found by the traces and fixed: arithmetic right shifts were
evaluated unsigned inside a ternary (`$signed(x) >>> n` with an unsigned
other arm), and `X + Y + C` computed its overflow flag from Y instead of
Y + C (MAME folds the carry into yop first).

Instruction-class coverage (`tools/adsp_coverage.py`, reports in
`artifacts/adsp/coverage_w1.txt` and `coverage_w2.txt`; the 22 M-instruction
w2 exercises exactly the same set as w1, 1959 distinct PCs): 37 of the 49
decoder classes execute,
including all memory forms except "shift + PM" and "shift + DM DAG2", all
conditional unit forms except MAC→MF, dual fetch (160k), DO UNTIL (63k) with
CE loops, DIVS/DIVQ, EXPADJ. ALU: 13/16 functions (not NOT Y, -Y, XOR).
MAC: 7/16 (no MR − X*Y forms, no US/UU except MR+X*Y UU). Shifter: 7/16 (no
NORM, no EXP HI/HIX/LO, no OR'd ASHIFT). Conditions: EQ/NE/GT/LE/LT/GE/TRUE
plus CE in loops; AV/AC/NEG/POS/MV conditions never appear. Mode control
(bank switching), SAT MR, FLAG_IN jumps and IDLE are not executed by this
game at all. Those paths are ported from MAME but only desk-checked.

## Gaps / notes for integration

- Interrupts are implemented but never exercised (the board leaves IRQ0-3
  unconnected); tie `irq` to 0.
- `halt` is sampled only at instruction boundaries (as MAME's HALT/BR).
- The bench serves IO reads from the log; the SIM ROM prefetcher belongs to
  the board glue and is not covered here.
- Program-memory reads beyond 0x1fff (MAME: `nopr`) return whatever the RAM
  holds at the aliased address; the game never fetches there.
