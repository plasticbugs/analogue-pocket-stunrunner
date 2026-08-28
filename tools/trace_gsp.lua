-- MAME instruction trace + memory image capture for the TMS34010 (GSP) bench.
--
--   OUT=artifacts/gsp/w2 START=1500 STOP=1503 mame stunrun ... -debug -debugger none -autoboot_script tools/trace_gsp.lua
--
-- At frame START: dump VRAM (512 KB, little-endian words), the 32 I/O
-- registers, the GSP register file, then start a per-instruction trace
-- (PC, ST, SP, A0-A14, B0-B14 and H = number of 68k host-interface accesses
-- performed so far).  Every 68k access to the GSP host interface is logged
-- with the same counter so the bench can replay it at the right instruction.
-- At frame STOP: stop the trace and dump VRAM + registers again.
local m = manager.machine
local dbg = m.debugger
local gsp = m.devices[":mainpcb:gsp"]
local m68 = m.devices[":mainpcb:maincpu"]
local gspsp = gsp.spaces["program"]
local out = os.getenv("OUT") or "gsp_window"
local start = tonumber(os.getenv("START") or "1500")
local stop = tonumber(os.getenv("STOP") or tostring(start + 3))
local frames = 0
local hostcount = 0
local hostlog = nil
local active = false

local regnames = {"A0","A1","A2","A3","A4","A5","A6","A7","A8","A9","A10","A11","A12","A13","A14",
                  "B0","B1","B2","B3","B4","B5","B6","B7","B8","B9","B10","B11","B12","B13","B14"}

-- control_hi latches (palette bank, fine scroll, shift-register enable) are
-- decoded from the *offset* of the write, so reconstruct them with a tap
local palbank, finescroll, shiftreg_en = 0, 0, 0
_G.taps = _G.taps or {}
_G.taps[3] = gspsp:install_write_tap(0xf4800000, 0xf48000ff, "ctlhi", function(offset, data, mask)
  local off = (offset - 0xf4800000) // 16
  local val = (off >> 3) & 1
  local sel = off & 7
  if sel == 0 then shiftreg_en = val
  elseif sel == 1 then finescroll = data & 7
  elseif sel == 2 then palbank = (palbank & ~1) | val
  elseif sel == 3 then palbank = (palbank & ~2) | (val << 1)
  end
end)

local function dump(tag)
  local f = io.open(string.format("%s_%s.regs", out, tag), "w")
  f:write(string.format("PC %08x\nST %08x\nSP %08x\n", gsp.state["PC"].value, gsp.state["ST"].value, gsp.state["SP"].value))
  for _, r in ipairs(regnames) do f:write(string.format("%s %08x\n", r, gsp.state[r].value)) end
  f:write("IOREGS\n")
  for i = 0, 31 do f:write(string.format("%04x\n", gspsp:read_u16(0xC0000000 + i*16))) end
  f:write(string.format("HOSTCOUNT %d\n", hostcount))
  local clo = m.memory.shares[":mainpcb:gsp_control_lo"]
  local chi = m.memory.shares[":mainpcb:gsp_control_hi"]
  f:write("CTLLO\n")
  for i = 0, 15 do f:write(string.format("%04x\n", clo:read_u16(i*2))) end
  f:write("CTLHI\n")
  for i = 0, 15 do f:write(string.format("%04x\n", chi:read_u16(i*2))) end
  f:write(string.format("LATCH %d %d %d\n", palbank, finescroll, shiftreg_en))
  local plo = m.memory.shares[":mainpcb:gsp_palram_lo"]
  local phi = m.memory.shares[":mainpcb:gsp_palram_hi"]
  f:write("PALETTE\n")
  for i = 0, 1023 do f:write(string.format("%04x %04x\n", plo:read_u16(i*2), phi:read_u16(i*2))) end
  f:close()
  local vram = m.memory.shares[":mainpcb:gsp_vram"]
  local vf = io.open(string.format("%s_%s.vram", out, tag), "wb")
  local chunk = {}
  for i = 0, vram.size - 1, 2 do
    local w = vram:read_u16(i)
    chunk[#chunk+1] = string.char(w & 0xff, w >> 8)
    if #chunk >= 4096 then vf:write(table.concat(chunk)); chunk = {} end
  end
  vf:write(table.concat(chunk)); vf:close()
end

-- 68k host interface accesses: c00000-c03fff, word offset i -> host reg (i>>1)^1
local m68sp = m68.spaces["program"]
local wtap = m68sp:install_write_tap(0xc00000, 0xc03fff, "hostw", function(offset, data, mask)
  if active then
    hostcount = hostcount + 1
    gspsp:write_u16(0xC0000170, hostcount & 0xffff)   -- UNK23: visible to the trace as w@C0000170
    local reg = ((offset - 0xc00000) // 4) ~ 1
    hostlog:write(string.format("%d W %d %04x\n", hostcount, reg, data & 0xffff))
  end
end)
_G.taps[1] = wtap
local rtap = m68sp:install_read_tap(0xc00000, 0xc03fff, "hostr", function(offset, data, mask)
  if active then
    hostcount = hostcount + 1
    gspsp:write_u16(0xC0000170, hostcount & 0xffff)
    local reg = ((offset - 0xc00000) // 4) ~ 1
    hostlog:write(string.format("%d R %d %04x\n", hostcount, reg, data & 0xffff))
  end
end)

-- tracelog writes to the debugger's "visible" CPU, which is whichever CPU last
-- stopped in the debugger. The console command "next" (go until the next
-- device starts executing) stops the GSP - the device after the 68010 in the
-- scheduler - and the "none" debugger OSD resumes it immediately, leaving the
-- GSP visible. Issued one frame before the window so the trace command at
-- the window start applies to the GSP. (device_debug:bpset from Lua hangs
-- MAME 0.288 with -debugger none, so breakpoints are not an option.)
local armed = false      -- true once the GSP is the visible CPU
local finished = false
local tries = 0
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= start - 1 and not armed and not active then
    -- Probe which CPU is visible; "next" walks to the next device. Repeat
    -- until it is the GSP (the scheduler order is 68010, GSP, ADSP, 6502).
    dbg:command("trace /dev/null,,noloop")
    local c = dbg.consolelog
    local last = c[#c]
    dbg:command("trace off")
    if string.find(last, ":mainpcb:gsp") then
      armed = true
    else
      tries = tries + 1
      if tries > 40 then print("ERROR: could not make the GSP visible: " .. last); m:exit() end
      dbg:command("next")
    end
  end
  if armed and not active and not finished then
    -- window starts at this frame
    stop = frames + (stop - start)
    start = frames
    hostlog = io.open(out .. ".host", "w")
    dump("start")
    active = true
    local fmt = "PC=%08X ST=%08X SP=%08X"
    local args = "pc,st,sp"
    for _, r in ipairs(regnames) do fmt = fmt .. " " .. r .. "=%08X"; args = args .. "," .. string.lower(r) end
    fmt = fmt .. " H=%04X\\n"
    args = args .. ",w@C0000170"
    dbg:command(string.format("trace %s.trace,,noloop,{tracelog \"%s\",%s}", out, fmt, args))
    local c = dbg.consolelog
    print("trace:", c[#c], "start frame", frames)
    return
  end
  if active and frames == stop then
    dbg:command("trace off,:mainpcb:gsp")
    dbg:command("go")
    active = false
    hostlog:close()
    dump("end")
    print("trace window done, host accesses:", hostcount)
    finished = true
  end
  if finished and frames >= stop + 1 then m:exit() end
end)
