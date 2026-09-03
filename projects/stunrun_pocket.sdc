# ==============================================================================
# Quartus Prime Synopsys Design Constraint File
# ==============================================================================
# Punch-Out!! core constraints.
#
# The Pocket BSP (platform/pocket/bsp/pocket/sys_constr.sdc) creates the APF
# clocks; this file describes what is specific to this core.
# ==============================================================================

# ==============================================================================
# Clock groups
#
# core_pll general[0] = clk_sys       96.0 MHz  machine, renderer, SDRAM
#          general[1] = clk_vid       24.0 MHz  dot clock, exactly clk_sys / 4
#          general[2] = clk_vid 90deg 24.0 MHz
#          general[3], general[4]     unused
#
# clk_sys and the two pixel clocks stay in ONE group on purpose. The renderer
# emits a pixel every fourth clk_sys cycle and the APF scaler samples it on
# clk_vid; they are integer-related outputs of the same PLL, so that crossing is
# synchronous by construction and should be verified rather than cut. Cutting it
# would let each build route it blind and make the picture depend on the fitter
# seed.
#
# clk_74a, clk_74b, the bridge SPI clock and the audio PLL are genuinely
# asynchronous to the machine. The one multi-bit bus that crosses into clk_74b
# -- the audio sample -- is handed over with a toggle flag in core_top, so the
# capture is always of a value that has been still for several cycles
# (METHODOLOGY 5.4).
# ==============================================================================
set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|core_pll|core_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|core_pll|core_pll_inst|altera_pll_i|general[4].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|pocket_audio_mixer|audio_pll|mf_audio_pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# ==============================================================================
# SDRAM
#
# The chip is clocked from core_pll general[3]: the same 96 MHz as the
# controller, phase-shifted. The phase and the exception below are DERIVED from
# the analyser's own numbers on a real fit, not assumed:
#
#   clock network, PLL output -> dram_clk pin          12.56 ns
#   clock network, PLL output -> dq_in register clock   7.9 ns
#   dram_dq pin -> dq_in register                        2.84 ns
#   chip access time tAC (max) + board                   7.0 ns
#   chip output hold tOH (min)                           2.5 ns
#
# The pin edge therefore trails the same nominal PLL edge by 4.66 ns more than
# the register's clock does. With phase 3650 ps the chip's edge at its pin
# lands about 1.2 ns BEFORE the controller's internal edge, which puts every
# transfer near the middle of its window:
#
#   command launched on our edge E: at the pin E+3, sampled by the chip at its
#     edge E+8.3 -- 5.3 ns setup; the previous chip edge was E-2.1 and the old
#     command holds until E+3 -- 5.1 ns hold.
#   read data: the chip drives it 7.0 ns after its edge, it reaches dq_in 9.84
#     after, i.e. 7.7 ns after our edge -- captured on our NEXT edge with 2.7 ns
#     to spare; the following word cannot arrive before 13.3 -- 2.9 ns hold.
#
# That capture is one full internal period after the chip's edge, but the
# nominal relationship between the two clocks is only 6.76 ns, because the
# extra 4.66 ns of network delay to the pin is not part of the waveform. So the
# analyser's default pairing checks a capture edge the data cannot possibly
# meet, and a multicycle of 2 (hold 1) moves it to the edge the RTL actually
# uses -- READ+4 at the pins, rd_late=1 in sdram16. This is the exception the
# first build lacked a basis for: it had the same numbers on a clock inverted
# by hand, and there the second edge was still 5.2 ns short.
#
# The original controller clocked the chip on an inverted copy of our clock and
# captured on the first edge, leaving 5.2 ns for a 7 ns access. With the
# exception that hid it removed, every dram_dq input missed by 7.5 ns, and on
# the Pocket every sprite was garbage while the block-RAM backgrounds were
# perfect.
#
# The clock is named dram_clk because the BSP (sys_constr.sdc) applies the
# chip's tDS/tDH to a clock of that name -- though it runs before this file and
# never finds it, so those two lines are repeated below.
# ==============================================================================
create_generated_clock -name dram_clk -source \
    [get_pins {ic|core_pll|core_pll_inst|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {dram_clk}]

set_input_delay -max -clock dram_clk 7.0 [get_ports {dram_dq[*]}]
set_input_delay -min -clock dram_clk 2.5 [get_ports {dram_dq[*]}]

# The BSP's sys_constr.sdc carries these same two lines, but it is read before
# this file -- it has to be, it creates the PLL clocks -- so dram_clk does not
# exist yet when it runs and they are silently ignored. Repeated here, after
# the clock is created. tDS 1.5 ns, tDH 0.8 ns from the datasheet.
set SDRAM_OUT [get_ports {dram_a[*] dram_ba[*] dram_cke dram_dqm[*] dram_dq[*] dram_ras_n dram_cas_n dram_we_n}]
set_output_delay -max -clock dram_clk  1.5 $SDRAM_OUT
set_output_delay -min -clock dram_clk -0.8 $SDRAM_OUT

# Read capture is on the second internal edge after the chip's -- see above.
#
# Setup only. The usual "-hold N-1" that accompanies a -setup N is for a path
# whose source launches once per N cycles; the chip launches a new word on
# EVERY edge, and the hazard is the next word arriving before this capture.
# That is the analyser's default hold edge for a -setup 2 path, one period
# before the setup edge. A -hold 1 moved the check back to the edge coincident
# with the launch, which cannot fail, and reported +11 ns where the real margin
# is about +3.
set_multicycle_path -setup 2 -from [get_clocks {dram_clk}] -to [get_registers {*|sdram_ctrl:*|dq_in[*]}]

# --- controller round-robin arbiter ------------------------------------------
# A client's `req` is a genuinely single-cycle input -- it can rise on the clock
# before the controller happens to be sitting in S_IDLE -- so req -> SDRAM_A can
# never be multicycled. It measured 15.3 ns (rom_req, the last failing path
# outside the CPU cores) and was fixed in the RTL instead: the S_ARB state now
# splits the accept from the address drive, leaving req -> pick -> cur (~5.5 ns)
# and c_addr -> mux -> SDRAM_A (~9 ns) as two honest single-cycle paths.
#
# `last` is different. It is the index of the client served last and is written
# only when S_IDLE accepts a client. Everything it feeds -- the round-robin
# scan, hence pick -> cur, any_req -> state, and the burst branch's
# (b_yield && any_req) gate -- is read only in S_IDLE, and after an acceptance
# the controller cannot be back in S_IDLE for 7 clocks (ARB, OPEN1, OPEN2,
# WAIT3..WAIT1 on a write; 9 on a read). 3/2 is well inside that.
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|last[*]}] -to [get_registers {*|sdram_ctrl:*|*}]

# ==============================================================================
# CPU cores that step on clock enables.
#
# The TG68K.C kernel advances only on clkena_in, which stunrun_main raises at
# most once every STEP_DIV cen_8m pulses (24 system clocks); every register in
# the kernel is written under that enable, so kernel-to-kernel paths have 24
# clocks and a 4-cycle allowance is a fraction of the provable margin. T65
# runs on the 1.79 MHz 6502 enable (53 clocks): 8 as in the Punch-Out!! core.
# ==============================================================================
set_multicycle_path -setup 4 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -hold  3 -from [get_registers {*|TG68KdotC_Kernel:*|*}] -to [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -setup 8 -from [get_registers {*|T65:*|*}] -to [get_registers {*|T65:*|*}]
set_multicycle_path -hold  7 -from [get_registers {*|T65:*|*}] -to [get_registers {*|T65:*|*}]

# ==============================================================================
# TMS34010 GSP instruction datapath.
#
# The GSP runs a per-clock micro-sequenced FSM: cen_6m only *starts* a fetch
# (S_FT0) and a memory access (S_W0); once started the FSM steps every 96 MHz
# clock. So NOT every intra-instruction path has 16 clocks -- only paths whose
# SOURCE register genuinely holds still for N clocks before the capture can be
# multicycled by N. Five source classes are provably stable ((5), the register
# file, is written out where its exception is set, below the ir ones); each is
# backed by an RTL change so the multicycle reflects real silicon, never masks
# it:
#
# (1) THE FETCHED OPCODE -- ir.
#     opc/fsel/rbit/immn are now COMBINATIONAL functions of `ir` (not registers
#     latched in S_DECODE one clock before S_EXEC), so every decode/read cone is
#     anchored on `ir`. `ir` is loaded at opcode fetch and held until the next
#     fetch (>=16 clocks away, cen-throttled); it is first read in S_EXEC, >=3
#     clocks after fetch (FT1 -> FTDONE -> DECODE -> EXEC). The worst cones it
#     drives -- the 32:1 register-file read mux (ir -> ridx/rf -> rsv/rdv ->
#     xy_in/xy_sh/pw_data) and the opcode-selected S_EXEC action mux -- measure
#     ~21.7 ns, which fits the 3-clock (31.2 ns) window but not one clock (this
#     was the -11.5 ns worst tier). 3/2 tells STA the real 3-clock budget. Before
#     the decode was made combinational, rbit/opc were registered in S_DECODE,
#     one clock before S_EXEC used them -- a genuine single-cycle path a
#     multicycle would have masked; anchoring on `ir` makes this exception honest.
#
# (2) ALU OPERANDS -- alu_a, alu_b.
#     The shared combinational ALU (~19.5 ns adder+flags) is fed from these
#     registered operands (set in S_EXEC) and its result committed in S_ALU.
#     S_ALU now spends one settle clock (alu_ph) before committing, so
#     alu_a/alu_b -> alu_r -> {rf,pc,T,fr_addr,...} spans two clocks in real
#     silicon; 2/1 tells STA the same. Every alu_a/alu_b consumer goes through
#     S_ALU (or the >=3-clock DSJS alu_z re-read), so -to * is safe at 2.
#
# (3) SHIFTER OPERANDS -- sh_x, sh_k, sh_mode.
#     Every state that captures the combinational funnel-shifter result sh_r
#     (S_SH, S_FR*/S_FW* via their return states, S_PW2/S_PW3, S_XY2,
#     S_BLT_SRC0X/S_BLT_SRCNX/S_BLT_PIX2/S_BLT_WRW) now spends one mph settle
#     clock before acting, so sh_* -> sh_r -> {w_wdata, blt_dword, T, fw_*} spans
#     two real clocks. 2/1 mirrors that. (This was the -9.2 ns tier.)
#     sh_x has one consumer that is not the shifter: OP_LMO's second S_EXEC
#     pass counts leading zeros from it. Its first pass writes sh_x on an
#     S_EXEC acting tick and the second reads it on the next one, one mph
#     settle later -- the same two clocks.
#
# (4) PIXEL-PATH CONFIG IO REGISTERS -- io[11] CONTROL, io[19] CONVSP,
#     io[20] CONVDP, io[21] PSIZE. Their combinational decode (pm/pmsk_a/psz/
#     dp_sh/sp_sh/rop) feeds the same pixel/blit cones. These indices are
#     written ONLY by the engine's io_write commit, once per (cen-throttled)
#     IO-write instruction -- the host write port reaches only io[15]/io[16] --
#     and the writing instruction never uses the pixel cone itself, so the
#     earliest dependent capture is the next instruction, >=16 clocks later.
#     3/2 is a fraction of that. io[15]/io[16]/io[18] (host/interrupt regs,
#     writable on arbitrary clocks) are deliberately NOT included.
#
# NOT relaxed (left single-cycle): the memory-handshake FSM `state`, the
# step counters istep/immcnt, the memory-read latch mrd, blt_dx and the blit
# datapath -- all of which can change on consecutive clocks.
# ==============================================================================
set GSP_ALL [get_registers {*|tms34010:*|*}]
set_multicycle_path -setup 3 -from [get_registers {*|tms34010:*|ir[*]}] -to $GSP_ALL
set_multicycle_path -hold  2 -from [get_registers {*|tms34010:*|ir[*]}] -to $GSP_ALL
# (5) THE REGISTER FILE -- rf.  TWO clocks, not three.
#     An earlier version of this file claimed 3 here, justified as "the value
#     read was written by a prior instruction (>=16 clocks)". That is false:
#     S_EXEC reads the register file combinationally (rdv/rsv through the 32:1
#     port mux) and writes it back on the SAME acting tick -- OP_LMO,
#     OP_MOVX/MOVY, OP_ADD_XY/SUB_XY, OP_NOT, OP_SEXT/ZEXT, OP_DRAV and the
#     MMFM/MOVE post-increment writes are all direct combinational rf -> rf
#     inside one tick. The real budget is the distance between two rf-writing
#     ticks, and S_EXEC is (settle, act), so that is 2 clocks. Every rf write
#     site, with the state it fires in and the state that runs on the very next
#     clock:
#
#       S_ALU  acting tick (alu_ph): WB_RD / WB_RD_IFPOS / WB_PUSH / WB_SP /
#              WB_RD_FWADDR / WB_RD_FRADDR / WB_PUSHR. Next state is wb_next,
#              which for every one of those selectors is S_CHECK, S_EXEC's
#              settle tick, S_FR0 or S_FW0 -- none of which reads rf.
#       S_SH   acting tick (mph): WB_RD; wb_next is S_CHECK.
#       S_EXEC acting tick (mph): the opcode action mux. Its successors are
#              S_CHECK, S_EXEC's settle, S_ALU/S_SH settle, S_FR0, S_FW0,
#              S_PW0, S_PR0, S_XY0, S_MUL1, S_DIV0, S_BLT0 and S_INT0. All of
#              those except S_INT0 read only registered operands on their first
#              tick (fr_addr, fw_addr/fw_data, pw_addr/pw_data, pr_addr,
#              xy_in/xy_sh, blt_dstxy/blt_dx/blt_dy, mul_a/mul_b, div_in), none
#              of them rf. S_INT0 does read rf (`alu_a <= rf[15]`), but the only
#              two S_EXEC branches that go there -- OP_ILL and OP_TRAP -- set no
#              rfw_en, and its other entry is from S_CHECK, which never writes
#              rf; so that capture is never one clock after an rf write either.
#       S_MUL2 -> S_MUL3, and S_BLT_END3 -> S_BLT_END4, were the only two
#              places where rf was written on consecutive clocks. Both second
#              states are now mph-settled in the RTL, so the pairs are 2 clocks
#              apart and this exception does not have to rest on which input of
#              the shared write mux happens to be selected.
#       S_DIV2 -> S_CHECK or S_EXEC settle; S_BLT2C -> S_EXEC settle.
#
#     So no register anywhere in the core captures an rf-derived value one
#     clock after an rf write: 2/1 to the whole core, and it is exact -- the
#     S_EXEC settle+act pair really is the shortest gap.
#
#     Making it fit needed one more RTL change. The rf -> rf cone measured
#     35.6 ns, of which 23.2 ns was the LMO leading-zero count: `lzc` was a
#     "count while not found" loop, which synthesises to 32 chained 6-bit
#     incrementers. It is now a five-stage binary search, and OP_LMO takes two
#     S_EXEC passes -- the first stages Rs into sh_x (the read mux alone), the
#     second counts from that register -- so the read mux and the count are no
#     longer in series inside one rf -> rf window. With that, the worst
#     rf-sourced cone is the ~18.6 ns tier, inside the 2-clock 20.8 ns.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|rf[*][*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|rf[*][*]}] -to $GSP_ALL

# (6) EVERYTHING THE SEQUENCER OWNS -> THE REGISTER FILE.
#     The rf write cone is one shared ~14 ns block: rfw_en / rfw_idx / rfw_val,
#     the opcode action mux, the 32:1 read ports and the 31-way write decode.
#     EVERY control input into it is a violation at one clock, and constraining
#     them one at a time is whack-a-mole (alu_cin, alu_op, istep, blt_dx and
#     state.S_BLT2C were the tier that surfaced once rf -> rf was tightened to
#     the honest 2). The RTL now carries a single invariant instead:
#
#       every register-file write happens on the acting tick of an mph/alu_ph
#       settled state -- S_ALU, S_SH, S_EXEC, S_MUL2, S_MUL3, S_DIV2, S_BLT2C,
#       S_BLT_END3, S_BLT_END4 (the last six settle ticks were added for this;
#       S_BLT_END2 also handed its `mul_b <= SPTCH` to S_BLT_END3 so the new
#       settle tick does not reload mul_p with the next product).
#
#     That is the complete list of rfw_en sites, checked against the source. The
#     clock before an acting tick is that state's settle tick, and a settle tick
#     assigns nothing but mph/alu_ph -- so no register the sequencer owns can
#     change less than two clocks before an rf write, whatever the instruction.
#
#     Three registers are NOT the sequencer's and are excluded, along with the
#     two submodules:
#       mph, alu_ph  -- written on the settle tick itself; they gate rfw_en, so
#                       they genuinely are one-clock sources. Left at 1.
#       Mult0*       -- the DSP block that carries `mul_p <= mul_a * mul_b`
#                       (Quartus absorbs mul_p into the DSP output register and
#                       names the result Mult0...). It reloads on every clock,
#                       settle ticks included: the value is stable across
#                       S_MUL2/S_MUL3 and S_BLT_END3/S_BLT_END4 because mul_a and
#                       mul_b are, but the register relaunches, so STA's one
#                       clock is the honest number. It passes at 1.
#       io[*], hc, vc, line_start, host_*, nmi_pend, force_pend and the pulse
#                       defaults -- written outside the FSM case (host accesses
#                       and the video raster run on arbitrary clocks). None of
#                       them reaches rfw_val; excluded so nothing is claimed
#                       about them. io[11]/[19]/[20]/[21] keep their own 3/2
#                       below, which rests on a different argument.
set GSP_FREE [get_registers {*|tms34010:*|mph *|tms34010:*|alu_ph *|tms34010:*|Mult0*}]
set GSP_FREE [add_to_collection $GSP_FREE [get_registers {*|tms34010:*|io[*][*] *|tms34010:*|hc[*] *|tms34010:*|vc[*] *|tms34010:*|line_start}]]
set GSP_FREE [add_to_collection $GSP_FREE [get_registers {*|tms34010:*|host_pend *|tms34010:*|host_we *|tms34010:*|host_data[*] *|tms34010:*|host_rdata[*] *|tms34010:*|host_ready}]]
set GSP_FREE [add_to_collection $GSP_FREE [get_registers {*|tms34010:*|force_pend *|tms34010:*|nmi_pend *|tms34010:*|dbg_instr *|tms34010:*|div_start}]]
set GSP_FREE [add_to_collection $GSP_FREE [get_registers {*|tms34010:*|ic_lu_en *|tms34010:*|ic_fill *|tms34010:*|ic_inv}]]
set GSP_FREE [add_to_collection $GSP_FREE [get_registers {*|gsp_div:*|* *|gsp_icache:*|*}]]
set GSP_SEQ [remove_from_collection $GSP_ALL $GSP_FREE]
set GSP_RF  [get_registers {*|tms34010:*|rf[*][*]}]
set_multicycle_path -setup 2 -from $GSP_SEQ -to $GSP_RF
set_multicycle_path -hold  1 -from $GSP_SEQ -to $GSP_RF

# The DSP product itself (Mult0*, i.e. mul_p) is excluded above because it
# reloads on every clock -- but it only ever *transitions* on the clock after
# mul_a/mul_b change, and the sequencer keeps two clocks between that and every
# consumer (rf and the MPYS/MPYU flag bits, its only readers):
#   MPY   S_EXEC act sets mul_a/mul_b -> S_MUL1 loads the product -> S_MUL2
#         settles -> S_MUL2 acts. Product changes at S_MUL1's edge, is read two
#         clocks later; S_MUL3 reads it four clocks later.
#   blit  S_BLT_END sets mul_a and DPTCH -> S_BLT_END2 loads DYDX.y*DPTCH ->
#         S_BLT_END3 settles and acts (two clocks). S_BLT_END3's acting tick
#         hands over SPTCH -> S_BLT_END3B loads the second product ->
#         S_BLT_END4 settles and acts (two clocks). S_BLT_END3B exists only to
#         provide that gap; without it S_BLT_END4 read a product that had
#         changed one clock earlier.
# 2/1, the same number the sequencer registers get.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|Mult0*}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|Mult0*}] -to $GSP_ALL

# istep, the per-instruction step counter. It is READ at exactly one place, the
# opcode branches of S_EXEC, which is mph-settled; and it is written in S_CHECK,
# on S_DECODE's acting tick, on S_EXEC's own acting tick, and on the acting
# ticks of S_DIV2 and S_BLT2C -- every one of which is followed by S_EXEC's
# settle tick before S_EXEC acts. So the shortest istep -> capture distance is 2
# (S_EXEC act -> settle -> act); from S_CHECK it is the whole fetch. 2/1.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|istep[*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|istep[*]}] -to $GSP_ALL

# st, the status register. Written on the acting ticks of the settled S_EXEC,
# S_ALU, S_SH, S_MUL2, S_DIV2 and S_BLT2C, and on the single-clock S_BLT0 /
# S_BLT1 / S_BLT1C / S_BLT_END / S_INT2 (which write constants or bc_*-derived
# window bits). Its readers are S_EXEC's acting tick -- the field size and sign
# (fsz/fext) for SEXT/ZEXT/MPYS/MPYU, the carry into alu_cin, cond_true for
# JR/DSJ, the flag read-backs -- and the flag commits on S_ALU's and S_SH's
# acting ticks. Every one of those is at least two clocks after any st write,
# the nearest pairing being S_EXEC act -> S_EXEC settle -> S_EXEC act. The cone
# that needed it is st[10:6] -> field mask -> the MPY operand register, 11.1 ns.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|st[*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|st[*]}] -to $GSP_ALL
# ... with one exception put back to a single cycle: S_CHECK reads st[IE] on the
# clock right after S_EXEC's acting tick to decide whether to take a pending
# interrupt, so state / int_vec / int_push / force_pend / ft_dst really are
# one-clock destinations from st.
set ST_1CY [get_registers {*|tms34010:*|state* *|tms34010:*|int_vec[*] *|tms34010:*|int_push *|tms34010:*|force_pend *|tms34010:*|ft_dst[*]}]
set_multicycle_path -setup 1 -from [get_registers {*|tms34010:*|st[*]}] -to $ST_1CY
set_multicycle_path -hold  0 -from [get_registers {*|tms34010:*|st[*]}] -to $ST_1CY

# pw_data. Written only on S_EXEC's acting tick (PIXT_RI / PIXT_RIXY / DRAV /
# PIXT_II / LINE). It has two readers: S_PW0's `w_wdata <= pw_data`, one clock
# later and left single-cycle because it is a straight copy; and S_PW2's raster
# op, which also decides whether a transparent pixel skips the write and so
# reaches the state register. S_PW2 is mph-settled and is reached through
# S_PW0 -> S_W0 (which waits for cen_6m) -> S_PW1, so that cone has at least
# five clocks. Scoped to `state`, the only destination that takes a pw_data
# value through the raster op. 2/1; the cone measures 10.9 ns.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|pw_data[*]}] -to [get_registers {*|tms34010:*|state*}]
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|pw_data[*]}] -to [get_registers {*|tms34010:*|state*}]

# fw_size. Written on S_EXEC's acting tick and in S_INT0/S_INT1. S_FW0 reads it
# one clock later to work out how many words the field spans (fw_nw), and that
# stays single-cycle. Every other reader goes through the write mask fw_mk in
# S_FW1/S_FW2, which are reached only after S_FW0B and S_FW0C (two mph settles)
# and a cen-gated S_W0 -- six clocks at the very least. 2/1 with fw_nw put back
# to 1/0; the cone that needed it is fw_size -> fw_mk -> w_wdata, 10.5 ns.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|fw_size[*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|fw_size[*]}] -to $GSP_ALL
set_multicycle_path -setup 1 -from [get_registers {*|tms34010:*|fw_size[*]}] -to [get_registers {*|tms34010:*|fw_nw[*]}]
set_multicycle_path -hold  0 -from [get_registers {*|tms34010:*|fw_size[*]}] -to [get_registers {*|tms34010:*|fw_nw[*]}]

# ALU operands: S_ALU spends a settle clock (alu_ph), so these span two clocks.
# alu_op and alu_cin are written at exactly the same sites as alu_a/alu_b (the
# S_EXEC acting tick, S_INT0/S_INT1, S_XY1) and consumed by the same adder on
# S_ALU's acting tick, so they belong here; leaving them out was what put
# alu_cin -> rf (445 paths, -4.12) at the top of the second tier.
set ALU_SRC [get_registers {*|tms34010:*|alu_a[*] *|tms34010:*|alu_b[*] *|tms34010:*|alu_op* *|tms34010:*|alu_cin}]
set_multicycle_path -setup 2 -from $ALU_SRC -to $GSP_ALL
set_multicycle_path -hold  1 -from $ALU_SRC -to $GSP_ALL
# Shifter operands: every sh_r-capturing state spends an mph settle clock.
set SH_SRC [get_registers {*|tms34010:*|sh_x[*] *|tms34010:*|sh_k[*] *|tms34010:*|sh_mode*}]
set_multicycle_path -setup 2 -from $SH_SRC -to $GSP_ALL
set_multicycle_path -hold  1 -from $SH_SRC -to $GSP_ALL
# Engine-written pixel-config IO registers (see (4) above).
set IOCFG_SRC [get_registers {*|tms34010:*|io[11][*] *|tms34010:*|io[19][*] *|tms34010:*|io[20][*] *|tms34010:*|io[21][*]}]
set_multicycle_path -setup 3 -from $IOCFG_SRC -to $GSP_ALL
set_multicycle_path -hold  2 -from $IOCFG_SRC -to $GSP_ALL

# ==============================================================================
# jt51 (YM2151). Every state register advances on cen (cen_ym, 3.58 MHz = one
# pulse per ~26.8 clocks) or cen_p1 (half that); the only per-clock writes are
# the MMR / CSR register-file commits, and those are driven exclusively by
# ym_wr_p/ym_a0_p/ym_d_p, which jsa2 registers ONLY on cen_cpu -- so even those
# registers change solely in the clock after a cen boundary, >=26 clocks before
# the next cen-gated capture. Every jt51-internal path therefore has a full cen
# period; 8 is a third of the provable margin (same argument as T65's 8 on the
# 53-clock 6502 enable).
# ==============================================================================
set_multicycle_path -setup 8 -from [get_registers {*|jt51:*|*}] -to [get_registers {*|jt51:*|*}]
set_multicycle_path -hold  7 -from [get_registers {*|jt51:*|*}] -to [get_registers {*|jt51:*|*}]

# Blit-mode configuration latches: each is assigned at exactly ONE site (the
# S_EXEC blit setup, which is mph-settled), verified mechanically, and then
# held for the entire multi-hundred-clock blit; every consumer state is >=2
# clocks after that latch. 2/1.
set BLTCFG_SRC [get_registers {*|tms34010:*|blt_mode_fill* *|tms34010:*|blt_mode_b* *|tms34010:*|blt_dst_lin* *|tms34010:*|blt_src_lin* *|tms34010:*|blt_yrev* *|tms34010:*|blt_sbpp* *|tms34010:*|blt_sbpp_l*}]
set_multicycle_path -setup 2 -from $BLTCFG_SRC -to $GSP_ALL
set_multicycle_path -hold  1 -from $BLTCFG_SRC -to $GSP_ALL

# Blit inner datapath, second pass: blt_pix is written only in S_BLT_PIX1 and
# consumed only on S_BLT_PIX2's acting tick (mph settle = 2 clocks later);
# blt_dmask is written only on the acting ticks of the mph-gated S_BLT_ROWB /
# S_BLT_PIX2 and next read no earlier than S_BLT_PIX1, which is always >=2
# clocks away (via the intermediate S_BLT_PIX / memory states). 2/1.
set BLTPIX_SRC [get_registers {*|tms34010:*|blt_pix[*] *|tms34010:*|blt_dmask[*]}]
set_multicycle_path -setup 2 -from $BLTPIX_SRC -to $GSP_ALL
set_multicycle_path -hold  1 -from $BLTPIX_SRC -to $GSP_ALL

# ==============================================================================
# ADSP-2100. The sequencer loads ir once per instruction in S_LATCH and the
# DAG register files r_i/r_m/r_l/r_base are written ONLY in S_WB (direct
# writes and every WRITE_REG12 expansion -- verified mechanically), which is
# 3 states after S_LATCH (ISSUE -> MEM -> WB, MEM can stall longer on
# io_wait). ir -> DAG-file cones therefore have >=3 clocks. Other ir
# consumers (the S_ISSUE captures, 1 clock after S_LATCH) are NOT relaxed.
# ==============================================================================
set ADSP_DAG [get_registers {*|adsp2100:*|r_i[*][*] *|adsp2100:*|r_m[*][*] *|adsp2100:*|r_l[*][*] *|adsp2100:*|r_base[*][*]}]
# cntr -> the DAG files. The loop counter is written in S_ISSUE (the loop-end
# CE decrement) and in S_WB (a register move into CNTR, CNTR_PUSH/CNTR_POP,
# the conditional-CE decrement) -- every site checked mechanically -- and the
# DAG files r_i/r_m/r_l/r_base are written ONLY in S_WB. The read is the
# register-move source mux (read_reg3 -> mv_val) on S_WB's tick, so the
# tightest launch->capture is an S_ISSUE write to the same instruction's S_WB:
# S_ISSUE -> S_MEM -> S_WB, two clocks (S_MEM can only stall longer on
# io_wait); a previous instruction's S_WB write is >= 5 states away. 2/1.
# Failed by -0.064 ns on a balanced-fit placement (and in CI) without it.
set_multicycle_path -setup 2 -from [get_registers {*|adsp2100:*|cntr[*]}] -to $ADSP_DAG
set_multicycle_path -hold  1 -from [get_registers {*|adsp2100:*|cntr[*]}] -to $ADSP_DAG

set_multicycle_path -setup 3 -from [get_registers {*|adsp2100:*|ir[*]}] -to $ADSP_DAG
set_multicycle_path -hold  2 -from [get_registers {*|adsp2100:*|ir[*]}] -to $ADSP_DAG

# ir -> rf refinement: the rf write cone (decode -> 32:1 operand mux -> ALU
# setup -> write mux) measures ~37.8 ns, beyond the 3-cycle 31.2 ns. It has 4
# provable clocks: ir loads at the fetch-done tick, S_DECODE spends 2 mph
# ticks, S_EXEC 2 more, and every rfw_en site lies on or after S_EXEC's acting
# tick -- so the earliest rf capture is >=4 clocks after ir changes. Placed
# after the blanket ir->* 3/2 so it takes precedence for rf destinations.
set_multicycle_path -setup 4 -from [get_registers {*|tms34010:*|ir[*]}] -to [get_registers {*|tms34010:*|rf[*][*]}]
set_multicycle_path -hold  3 -from [get_registers {*|tms34010:*|ir[*]}] -to [get_registers {*|tms34010:*|rf[*][*]}]

# ADSP stack pointers (pc_sp/loop_sp/cntr_sp/stat_sp): written only in the
# cen-gated S_IDLE irq path, S_ISSUE (loop-end pop) and S_WB (call/ret and
# register-move push/pop); every capture of a pointer-derived value happens in
# S_ISSUE or S_WB. Nearest pairing is an S_ISSUE write captured in S_WB, 2
# clocks later (S_MEM between, longer under io_wait); all others are >=4. 2/1.
# astat -> the shifter's S_ISSUE captures. ASTAT is written ONLY in S_WB (the
# direct alu/mac/shifter/div flag writes, the WRITE_REG0 expansion for a
# register move into ASTAT, and both STAT_POP expansions -- every site checked
# mechanically) and at reset. The shifter pre-computes its result cone in
# S_ISSUE (clz_in uses astat[SS] for EXP; nsb/nse/sh_st are captured into
# sh_sb/sh_se/sh_sr0/sh_sr1/sh_astat on that tick) -- and S_ISSUE follows S_WB
# through S_IDLE (>=1 clock waiting for cen), S_WAIT, S_LATCH and S_DEC, so the
# capture is >=4 clocks after any astat write. Claimed 2/1. Placement variance
# on this cone cost 0.4 ns between otherwise identical builds; the margin was
# never real, it just used to land on the right side of zero.
set ADSP_SHCAP [get_registers {*|adsp2100:*|sh_sb[*] *|adsp2100:*|sh_se[*] *|adsp2100:*|sh_sr0[*] *|adsp2100:*|sh_sr1[*] *|adsp2100:*|sh_astat[*] *|adsp2100:*|sh_sb_we *|adsp2100:*|sh_se_we *|adsp2100:*|sh_sr_we}]
set_multicycle_path -setup 2 -from [get_registers {*|adsp2100:*|astat[*]}] -to $ADSP_SHCAP
set_multicycle_path -hold  1 -from [get_registers {*|adsp2100:*|astat[*]}] -to $ADSP_SHCAP

set ADSP_SP [get_registers {*|adsp2100:*|pc_sp[*] *|adsp2100:*|loop_sp[*] *|adsp2100:*|cntr_sp[*] *|adsp2100:*|stat_sp[*]}]
set_multicycle_path -setup 2 -from $ADSP_SP -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  1 -from $ADSP_SP -to [get_registers {*|adsp2100:*|*}]

# blt_dword: written on the acting ticks of the mph-gated S_BLT_PIX2 (and in
# the memory-return S_BLT_DSTW/DSTNW states, many clocks from any reader);
# read on the acting ticks of S_BLT_PIX2 and S_BLT_FLUSH (now mph-gated), and
# in S_BLT_FLUSHR only after a full S_W0 memory round trip. Every
# write->read pairing is >=2 clocks. 2/1.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|blt_dword[*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|blt_dword[*]}] -to $GSP_ALL

# pc_stack: pushed only in the cen-gated S_IDLE irq path and S_WB; its only
# readers (pc_top -> pcn in S_ISSUE, pc/TOPPCSTACK in S_WB) capture >=3 clocks
# after any push (IDLE->WAIT->LATCH->ISSUE the shortest). 2/1.
set_multicycle_path -setup 2 -from [get_registers {*|adsp2100:*|pc_stack[*][*]}] -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  1 -from [get_registers {*|adsp2100:*|pc_stack[*][*]}] -to [get_registers {*|adsp2100:*|*}]

# ADSP core register files. Every register below -- the compute set (r_ax0/1,
# r_ay0/1, r_mx0/1, r_my0/1, r_ar, r_af, r_mr0/1/2, r_mf, r_si, r_se, r_sb,
# r_sr0/1) and the DAG files (r_i, r_m, r_l, r_base) -- is written ONLY inside
# the S_WB branch, at these sites and no others (checked mechanically over the
# source): the ALU/MAC/shifter commits, the dual-fetch loads, the DAG
# post-modify `r_i[dagA_i] <= dagA_res` / `r_i[pdag_i_idx] <= dagB_res`, the
# WRITE_REG0 / WRITE_REG12 / WRITE_REG3 register-move expansions, and the MSTAT
# bank swap.
#
# Their readers are the register-read muxes (read_reg0/1/2/3), the shifter's
# count and exponent logic (sc, sh_v, clz32, nse/nsb), the DAG address
# generator (ea, pea) and the move-source mux, and every one of those is
# captured in S_ISSUE (sh_sr0/sh_sr1, sh_se, sh_sb, sh_astat, alu_res,
# mac_prod, dm_addr_lat, io_wdata) or later, in S_MEM / S_WB. The shortest
# write -> read distance is therefore
#   S_WB -> S_IDLE -> S_WAIT -> S_LATCH -> S_DEC -> S_ISSUE = 5 clocks,
# longer in practice because S_IDLE waits for cen_8m (12 clocks); the S_WB to
# S_WB pairings (r_i -> dagA_res -> r_i, r_si -> mv_val -> any register) are a
# whole instruction, 7. The cones measure 12.4-12.6 ns, which one clock cannot
# hold. 3/2, well inside the provable 5.
set ADSP_RF [get_registers {*|adsp2100:*|r_ax0[*] *|adsp2100:*|r_ax1[*] *|adsp2100:*|r_ay0[*] *|adsp2100:*|r_ay1[*]}]
set ADSP_RF [add_to_collection $ADSP_RF [get_registers {*|adsp2100:*|r_mx0[*] *|adsp2100:*|r_mx1[*] *|adsp2100:*|r_my0[*] *|adsp2100:*|r_my1[*]}]]
set ADSP_RF [add_to_collection $ADSP_RF [get_registers {*|adsp2100:*|r_ar[*] *|adsp2100:*|r_af[*] *|adsp2100:*|r_mf[*]}]]
set ADSP_RF [add_to_collection $ADSP_RF [get_registers {*|adsp2100:*|r_mr0[*] *|adsp2100:*|r_mr1[*] *|adsp2100:*|r_mr2[*]}]]
set ADSP_RF [add_to_collection $ADSP_RF [get_registers {*|adsp2100:*|r_si[*] *|adsp2100:*|r_se[*] *|adsp2100:*|r_sb[*] *|adsp2100:*|r_sr0[*] *|adsp2100:*|r_sr1[*]}]]
set ADSP_RF [add_to_collection $ADSP_RF $ADSP_DAG]
set_multicycle_path -setup 3 -from $ADSP_RF -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  2 -from $ADSP_RF -to [get_registers {*|adsp2100:*|*}]

# ADSP shifter result latches. sh_taken, sh_sr_we, sh_sr0/sh_sr1, sh_se_we,
# sh_se, sh_sb_we, sh_sb and sh_astat are assigned at exactly one site -- the
# compute-unit block of S_ISSUE -- and read at exactly one place, S_WB (the
# `if (sh_taken ...)` commit and the register-move source mux, which returns
# sh_sr0/sh_sr1/sh_se when the shifter is writing them). S_ISSUE -> S_MEM ->
# S_WB is 2 clocks, more when S_MEM stalls on io_wait. The cone that needed it
# is sh_sr_we/sh_sr0/sh_sr1 -> mv_val -> WRITE_REG12 -> r_base, 11 ns. 2/1.
set ADSP_SHRES [get_registers {*|adsp2100:*|sh_taken *|adsp2100:*|sh_sr_we *|adsp2100:*|sh_sr0[*] *|adsp2100:*|sh_sr1[*] *|adsp2100:*|sh_se_we *|adsp2100:*|sh_se[*] *|adsp2100:*|sh_sb_we *|adsp2100:*|sh_sb[*] *|adsp2100:*|sh_astat[*]}]
set_multicycle_path -setup 2 -from $ADSP_SHRES -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  1 -from $ADSP_SHRES -to [get_registers {*|adsp2100:*|*}]

# ADSP DAG post-modify selectors. dag_i_idx / dag_m_idx / pdag_i_idx /
# pdag_m_idx and their dag_do / pdag_do enables are assigned at exactly one
# site, the S_ISSUE memory-issue block, and read at exactly one site: the two
# `r_i` writes in S_WB, through dagA_i/dagA_m/dagA_do/dagA_res and dagB_res.
# S_ISSUE -> S_MEM -> S_WB is 2 clocks, more when S_MEM stalls on io_wait. 2/1;
# the cone measures 12.6 ns.
set ADSP_DAGIDX [get_registers {*|adsp2100:*|dag_i_idx[*] *|adsp2100:*|dag_m_idx[*] *|adsp2100:*|pdag_i_idx[*] *|adsp2100:*|pdag_m_idx[*] *|adsp2100:*|dag_do *|adsp2100:*|pdag_do}]
set_multicycle_path -setup 2 -from $ADSP_DAGIDX -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  1 -from $ADSP_DAGIDX -to [get_registers {*|adsp2100:*|*}]

# ADSP ir, blanket: with the S_DEC settle state between S_LATCH (ir load) and
# S_ISSUE, every capture of ir-derived data is >=2 clocks after ir changes
# (S_ISSUE the earliest; MEM/WB later still). 2/1 to the whole core; the
# earlier ir->DAG 3/2 is superseded by this later assignment, and 2 cycles
# (20.8 ns) still covers that 17.4 ns cone.
set_multicycle_path -setup 2 -from [get_registers {*|adsp2100:*|ir[*]}] -to [get_registers {*|adsp2100:*|*}]
set_multicycle_path -hold  1 -from [get_registers {*|adsp2100:*|ir[*]}] -to [get_registers {*|adsp2100:*|*}]

# ==============================================================================
# 68010 -> the bus FSM and the peripheral write registers.
#
# The justification this exception used to carry was wrong, in the same way the
# old rf -> rf one was. It said the kernel's outputs "sit in a long stable
# plateau" because clkena fires only once per ~45 clocks. They do -- but the
# capture is at the START of that plateau: the kernel's registers update on the
# edge that ends the clkena cycle, and the bus FSM sampled busstate on the very
# next clock. Every capture of a kernel output was therefore a ONE-clock path,
# and the widest of them (kernel state -> address decode -> the work-RAM write
# data port) measures 31.8 ns. The bst/tok/clkena half of that was even
# recognised and pinned at 1/0, where it sat at -2.07; the peripheral half was
# covered by a 4 nobody could justify.
#
# stunrun_main now provides the four clocks instead of claiming them: `step_gap`
# holds the B_IDLE sampling branch off for three clocks after the clkena cycle
# (which `!clkena` already blocked), so the sample -- and with it every write of
# a kernel-derived value: bst, tok, clkena, snd_cmd, host_*, som_*, dm_*, pm_*,
# zram_*, adc_*, the wram write ports -- lands four clocks after the kernel
# moved. The bus sub-states that also read the kernel (B_RAM_RD's rd_mux,
# B_DM_MERGE and B_PM_MERGE's data_write/uds/lds) run after that sample and are
# further away still. The 68010's speed is set by the token bucket (one step per
# 3.75 cen_8m, about 45 clocks), so a six-clock bus FSM costs nothing (the
# ADSP program/data RAMs and the SOM buffer take one extra state, B_RAM_RD1,
# because their address is registered here rather than taken live off the bus).
#
# One exception now covers the whole module; the 1/0 override is gone because
# the FSM no longer samples on the next clock.
# ==============================================================================
set K68 [get_registers {*|TG68KdotC_Kernel:*|*}]
set_multicycle_path -setup 4 -from $K68 -to [get_registers {*|stunrun_main:*|*}]
set_multicycle_path -hold  3 -from $K68 -to [get_registers {*|stunrun_main:*|*}]

# ==============================================================================
# JSA II board reset and the cen_cpu-paced sound latches.
#
# rst_cnt is loaded and decremented only on a cen_cpu tick (1.79 MHz, one pulse
# per ~53 clocks): the 68k's board-reset pulse arrives on an arbitrary clock, so
# it is latched into rst_pend and applied at the next tick (an RTL change made
# for this). wrio / ym_vol / oki_vol are written only by the 6502's cen_cpu-gated
# store. The one remaining arbitrary-clock write to any of them is the
# board_rst / reset load, and on those clocks board_rst is already forced high by
# its own `reset` term, so nothing rst_cnt- or wrio-derived is observable then.
#
# Every consumer -- T65's Res_n, jt51's and jt6295's rst, the jsa2 latches --
# therefore sees a source that has been still for a whole cen_cpu period. 8 is a
# sixth of that, the same number T65 and jt51 carry. The cone that needed it is
# rst_cnt -> board_rst -> jt51's envelope generator (eg_VII), 12.4 ns, of which
# 10.2 ns is inside the EG's rate adder and comparators -- splitting it with a
# register would not have brought either half under one clock.
# ==============================================================================
set JSA_SLOW [get_registers {*|jsa2:*|rst_cnt[*] *|jsa2:*|rst_pend *|jsa2:*|wrio[*] *|jsa2:*|ym_vol[*] *|jsa2:*|oki_vol}]
set_multicycle_path -setup 8 -from $JSA_SLOW -to [get_registers {*|jsa2:*|*}]
set_multicycle_path -hold  7 -from $JSA_SLOW -to [get_registers {*|jsa2:*|*}]

# jsa2 output mixer. ym_sum and oki_term are written on a cen_ym pulse (3.58
# MHz, one per ~26.8 clocks) and the stages after them fire off the mix_ph shift
# register, which now spends two clocks per stage instead of one: ym_prod is
# captured on mix_ph[1] (two clocks after ym_sum) and mix on mix_ph[3] (two
# after ym_prod, four after oki_term). The volume multiply
# `ym_sum * ym_vol * 1404` is a 17x3x31 cone measuring 12 ns, which one clock
# could not hold -- it was the -1.59 tier. 2/1 matches the RTL; the extra clocks
# fit inside the cen_ym period with 22 to spare.
set JSA_MIX [get_registers {*|jsa2:*|ym_sum[*] *|jsa2:*|ym_prod[*] *|jsa2:*|oki_term[*]}]
set_multicycle_path -setup 2 -from $JSA_MIX -to [get_registers {*|jsa2:*|*}]
set_multicycle_path -hold  1 -from $JSA_MIX -to [get_registers {*|jsa2:*|*}]


# GSP div_in -> state. div_in is loaded with the quotient in S_DIV1 (on
# div_done) and the only state transition that reads it is S_DIV2's overflow
# test, which is mph-gated: S_DIV1 act (T), S_DIV2 settle (T+1), S_DIV2 act
# (T+2) -- two clocks. Scoped to `state` deliberately: div_in is ALSO written
# in S_EXEC and read by div_num in S_DIV0 one clock later, so a blanket
# div_in -> * would be a genuine overclaim.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|div_in[*]}] -to [get_registers {*|tms34010:*|state*}]
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|div_in[*]}] -to [get_registers {*|tms34010:*|state*}]

# sdram_ctrl `ready` is the init-complete flag: it rises exactly once, at the
# end of the SDRAM power-up sequence, and never falls again in operation. The
# whole machine is held in synchronous reset until it does
# (mreset = ... | ~sd_ready | ..., stunrun_core.sv), so this is a reset-release
# path, not a data path -- nothing samples it again afterwards, and the first
# core activity is tens of clocks later (the 68k needs ~45 clocks per step and
# the GSP waits on cen_6m). 3/2 with margin to spare.
set_multicycle_path -setup 3 -from [get_registers {*|sdram_ctrl:*|ready}] -to [get_registers {*}]
set_multicycle_path -hold  2 -from [get_registers {*|sdram_ctrl:*|ready}] -to [get_registers {*}]

# GSP fw_addr -> the memory write registers. fw_addr is loaded on an S_EXEC /
# S_ALU / S_SH acting tick and the w_* registers that depend on it are written
# in S_FW1 / S_FW2, reached only through S_FW0 -> S_FW0B -> S_FW0C (the latter
# two mph-settled), i.e. at least five clocks later; the S_FW3 -> S_FW1 loop
# for multi-word writes advances fw_k only, leaving fw_addr untouched. 2/1 is
# well inside that. Scoped to the w_* destinations ONLY: S_FW0 reads
# fw_addr[3:0] into sh_k one clock after the load, so a blanket fw_addr -> *
# would be an overclaim.
set FW_DST [get_registers {*|tms34010:*|w_wdata[*] *|tms34010:*|w_addr[*] *|tms34010:*|w_we *|tms34010:*|w_srt *|tms34010:*|w_ret*}]
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|fw_addr[*]}] -to $FW_DST
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|fw_addr[*]}] -to $FW_DST

# fw_k -> the field-write data/address captures. fw_k is written in S_FW0 (=0)
# and S_FW3 (+1, the multi-word loop) -- both sites checked mechanically. Its
# consumers are S_FW1 (w_addr, w_wdata <= fw_dk) and S_FW2 (w_wdata from
# fw_dk/fw_mk). S_FW1 is mph-settled (RTL, above), so on the S_FW3 -> S_FW1
# loop its acting tick is 2 clocks after the write; the first pass goes
# through S_FW0B/S_FW0C (>=3), and S_FW2 sits behind S_FW1's memory cycle
# (>=3). 2/1. Failed by -0.10 ns at 99 % fit without it.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|fw_k[*]}] -to $FW_DST
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|fw_k[*]}] -to $FW_DST

# imm -> everything. The immediate words are written ONLY at the fetch ticks
# (S_FT1 on an icache hit, S_FT2 from memory; both sites checked mechanically)
# and every consumer is on S_EXEC's acting tick: S_FT1/S_FT2 -> S_FTDONE ->
# S_EXEC settle -> S_EXEC act is 3 clocks from the write edge. Nothing between
# reads imm (S_FTDONE compares immcnt/immn, not imm). Claimed 2/1. Failed by
# -0.10 ns (imm[12] -> alu_b[11]) at 99 % fit without it.
set_multicycle_path -setup 2 -from [get_registers {*|tms34010:*|imm[*]}] -to $GSP_ALL
set_multicycle_path -hold  1 -from [get_registers {*|tms34010:*|imm[*]}] -to $GSP_ALL

# JSA sound ROM loader port -> T65. The ROM's port B is the download port; the
# loader only writes it while dl_active is asserted, and dl_active holds the
# whole machine in reset (mreset in stunrun_core.sv), so the 6502 cannot
# capture anything from that port until the download has finished. After that
# the port is idle for the life of the session. 8/7, matching the T65 6502
# enable (1.79 MHz, 53 clocks).
set JSAROM [get_registers {*|jsa2:*|altsyncram:rom*|*}]
set_multicycle_path -setup 8 -from $JSAROM -to [get_registers {*|T65:*|*}]
set_multicycle_path -hold  7 -from $JSAROM -to [get_registers {*|T65:*|*}]

# GSP instruction-cache fill write -> the fetch capture registers. The tag/data
# RAMs are written only when ic_fill is asserted, which happens in S_FT2 (the
# miss path, after mem_ack). The soonest any lookup can USE the result of that
# write is the next fetch: S_FT2 -> S_FTDONE -> S_DECODE (settle + act) ->
# S_FT0 (which additionally waits for cen_6m) -> S_FT0B -> S_FT1, where ic_hit
# gates the ir/imm/imm2 capture. That is at least four clocks, never one, so
# the write-port-to-capture arcs Quartus reports through the RAM (fill enable
# -> tag output -> hit -> capture enable) have the whole miss turnaround. 2/1
# is conservative against that.
set ICFILL [get_registers {*|gsp_icache:*|altsyncram:mem_tag*|* *|gsp_icache:*|altsyncram:mem_data*|*}]
set_multicycle_path -setup 2 -from $ICFILL -to [get_registers {*|tms34010:*|*}]
set_multicycle_path -hold  1 -from $ICFILL -to [get_registers {*|tms34010:*|*}]
