-- Instruction-level trace of the ADSP-2100 for the RTL bench (sim/run_adsp.sh).
--
-- Run with:  mame stunrun -debug -debugger none -autoboot_script tools/trace_adsp.lua ...
-- Environment:
--   OUT      output directory (default .)
--   START    "reset"  : window starts when the 68k releases the ADSP reset
--            "trig"   : window starts at the first 68k trigger write (0x80bffe) after
--                       frame MINFRAME while the ADSP has empty stacks (SSTAT=0x55, PCSP=0)
--   MINFRAME frame after which START=trig may fire (default 900)
--   PCFRAMES frames traced PC-only (adsp_trace_pc.txt) before the register trace (default 0)
--   FRAMES   frames traced with full registers (adsp_trace.txt) after that (default 1)
--
-- Files written to OUT:
--   adsp_start.txt   registers at the start (name=value per line), plus PMEM/DMEM hex dumps
--   adsp_trace_pc.txt MAME trace of the PC-only stretch (PC + disassembly per line)
--   adsp_mid.txt     registers + memories at the PC-only -> register trace switch (frame boundary)
--   adsp_trace.txt   MAME trace, one line per instruction: registers (before execution) then PC + disassembly
--   adsp_io.txt      ordered log of ADSP data-space accesses in the window:
--                      R addr val    ADSP read  (addr < 0x2000 = RAM, >= 0x2000 = I/O)
--                      W addr val    ADSP write
--                      X addr val    68k write to ADSP data RAM (ordered by preceding ADSP accesses)
--                      P addr val    68k write to ADSP program RAM (half-word, 68k word offset)
--                      C sel val     68k ADSP control latch write
--                      M             marker: switch from the PC-only to the register trace
--   adsp_end.txt     registers + memories at the end
local m = manager.machine
local out = os.getenv("OUT") or "."
local mode = os.getenv("START") or "trig"
local minframe = tonumber(os.getenv("MINFRAME") or "900")
local nframes = tonumber(os.getenv("FRAMES") or "1")
local pcframes = tonumber(os.getenv("PCFRAMES") or "0")
local phase = 0   -- 1 = PC-only trace, 2 = register trace
local dbg = m.debugger
local cpu = m.devices[":mainpcb:maincpu"]
local adsp = m.devices[":mainpcb:adsp"]
local sp68 = cpu.spaces["program"]
local dsp = adsp.spaces["data"]
local frames = 0
local active = false
local done = false
local frames_after = 0
local iolog = nil
local ncount = 0
adsp_taps = {}   -- GLOBAL on purpose: a chunk-local table is garbage-collected after the script runs and the taps silently vanish with it

local regnames = {"AX0","AX1","AY0","AY1","AR","AF","MX0","MX1","MY0","MY1","MR0","MR1","MR2","MF",
  "SI","SE","SB","SR0","SR1","AX0_SEC","AX1_SEC","AY0_SEC","AY1_SEC","AR_SEC","AF_SEC","MX0_SEC","MX1_SEC",
  "MY0_SEC","MY1_SEC","MR0_SEC","MR1_SEC","MR2_SEC","MF_SEC","SI_SEC","SE_SEC","SB_SEC","SR0_SEC","SR1_SEC",
  "I0","I1","I2","I3","I4","I5","I6","I7","L0","L1","L2","L3","L4","L5","L6","L7",
  "M0","M1","M2","M3","M4","M5","M6","M7","PX","CNTR","ASTAT","SSTAT","MSTAT","PCSP","CNTRSP","STATSP","LOOPSP",
  "IMASK","ICNTL","FLAGIN","FLAGOUT","PC"}

local function dump_state(fname, extra)
  local f = io.open(out .. "/" .. fname, "w")
  for _, n in ipairs(regnames) do
    f:write(string.format("%s=%x\n", n, adsp.state[n].value))
  end
  if extra then for k, v in pairs(extra) do f:write(string.format("%s=%x\n", k, v)) end end
  local pm = m.memory.shares[":mainpcb:adsp_pgm_memory"]
  f:write("PMEM\n")
  for i = 0, 0x1fff do f:write(string.format("%06x\n", pm:read_u32(i * 4) & 0xffffff)) end
  local dm = m.memory.shares[":mainpcb:adsp_data"]
  f:write("DMEM\n")
  for i = 0, 0x1fff do f:write(string.format("%04x\n", dm:read_u16(i * 2))) end
  f:close()
end

local tracefmt = "{tracelog \"" ..
  "ax0=%04X ax1=%04X ay0=%04X ay1=%04X ar=%04X af=%04X mx0=%04X mx1=%04X my0=%04X my1=%04X " ..
  "mr0=%04X mr1=%04X mr2=%04X mf=%04X si=%04X se=%04X sb=%04X sr0=%04X sr1=%04X " ..
  "i0=%04X i1=%04X i2=%04X i3=%04X i4=%04X i5=%04X i6=%04X i7=%04X " ..
  "l0=%04X l1=%04X l2=%04X l3=%04X l4=%04X l5=%04X l6=%04X l7=%04X " ..
  "m0=%04X m1=%04X m2=%04X m3=%04X m4=%04X m5=%04X m6=%04X m7=%04X " ..
  "px=%02X cntr=%04X astat=%02X sstat=%02X mstat=%02X pcsp=%X cntrsp=%X statsp=%X loopsp=%X imask=%X icntl=%X\"," ..
  "ax0,ax1,ay0,ay1,ar,af,mx0,mx1,my0,my1,mr0,mr1,mr2,mf,si,se,sb,sr0,sr1," ..
  "i0,i1,i2,i3,i4,i5,i6,i7,l0,l1,l2,l3,l4,l5,l6,l7,m0,m1,m2,m3,m4,m5,m6,m7," ..
  "px,cntr,astat,sstat,mstat,pcsp,cntrsp,statsp,loopsp,imask,icntl}"

local function start_register_trace()
  phase = 2
  -- tracelog prints through the debugger's *visible* CPU, so point it at the
  -- ADSP right here (set at script load it gets reset) or the register text
  -- silently goes nowhere: the 68k has no trace file open.
  dbg.visible_cpu = adsp
  dbg:command("trace " .. out .. "/adsp_trace.txt,:mainpcb:adsp,noloop," .. tracefmt)
  dbg:command("go")
end

local function start_window(extra)
  dump_state("adsp_start.txt", extra)
  iolog = io.open(out .. "/adsp_io.txt", "w")
  active = true
  if pcframes > 0 then
    phase = 1
    dbg:command("trace " .. out .. "/adsp_trace_pc.txt,:mainpcb:adsp,noloop")
    dbg:command("go")
  else
    start_register_trace()
  end
  print(string.format("f%d trace started (mode %s) adspPC=%04x", frames, mode, adsp.state["PC"].value))
end

local function switch_phase()
  dbg:command("trace off,:mainpcb:adsp")
  iolog:write("M\n")
  dump_state("adsp_mid.txt")
  start_register_trace()
  print(string.format("f%d switched to register trace adspPC=%04x", frames, adsp.state["PC"].value))
end

local function stop_window()
  dbg:command("trace off,:mainpcb:adsp")
  dbg:command("go")
  active = false
  done = true
  iolog:close()
  dump_state("adsp_end.txt")
  print(string.format("f%d trace stopped, %d adsp accesses logged", frames, ncount))
end

-- ADSP data-space accesses (RAM and the special I/O at 0x2000-0x2fff)
adsp_taps[#adsp_taps+1] = dsp:install_read_tap(0x0000, 0x2fff, "adsp_rd", function(off, data, mask)
  if active then ncount = ncount + 1; iolog:write(string.format("R %04x %04x\n", off, data)) end
end)
adsp_taps[#adsp_taps+1] = dsp:install_write_tap(0x0000, 0x2fff, "adsp_wr", function(off, data, mask)
  if active then ncount = ncount + 1; iolog:write(string.format("W %04x %04x\n", off, data)) end
end)
-- 68k side
adsp_taps[#adsp_taps+1] = sp68:install_write_tap(0x808000, 0x80bfff, "m68_dram", function(off, data, mask)
  local a = (off - 0x808000) >> 1
  if active then iolog:write(string.format("X %04x %04x\n", a, data)) end
  if not active and not done and mode == "trig" and a == 0x1fff and frames >= minframe
     and adsp.state["SSTAT"].value == 0x55 and adsp.state["PCSP"].value == 0 then
    -- the tap runs before the write lands: record it so the bench applies it
    start_window({TRIGVAL = data})
    iolog:write(string.format("X %04x %04x\n", a, data))
  end
end)
adsp_taps[#adsp_taps+1] = sp68:install_write_tap(0x800000, 0x807fff, "m68_pram", function(off, data, mask)
  if active then iolog:write(string.format("P %04x %04x\n", (off - 0x800000) >> 1, data)) end
end)
adsp_taps[#adsp_taps+1] = sp68:install_write_tap(0x818000, 0x81801f, "m68_actl", function(off, data, mask)
  local w = (off - 0x818000) >> 1
  local sel, val = w & 7, (w >> 3) & 1
  if active then iolog:write(string.format("C %d %d\n", sel, val)) end
  print(string.format("f%d ADSP control sel=%d val=%d", frames, sel, val))
  if not active and not done and mode == "reset" and sel == 7 and val == 1 then
    start_window(nil)
  end
end)

emu.register_frame_done(function()
  frames = frames + 1
  if active then
    frames_after = frames_after + 1
    if phase == 1 and frames_after == pcframes then switch_phase() end
    if frames_after >= pcframes + nframes then stop_window() end
  end
  if done and frames_after >= pcframes + nframes + 1 then m:exit() end
  if frames > 3000 then print("gave up waiting for the window"); m:exit() end
end)
