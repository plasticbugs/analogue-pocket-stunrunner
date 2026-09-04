-- GspWaitIrq3 phases: every 68k write to ffdb48 (0 = start waiting, ffff = IRQ3 tick seen)
-- with the frame, scan line and the writer's PC. LO/HI env.
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]; local sp = cpu.spaces["program"]
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local lo = tonumber(os.getenv("LO") or "170"); local hi = tonumber(os.getenv("HI") or "260")
local frames, ev = 0, {}
wf_taps = {}
wf_taps[1] = sp:install_write_tap(0xffdb48, 0xffdb49, "wf", function(off, data, mask)
  ev[#ev+1] = string.format("%s@%06x/vc%d", (data & 0xffff) == 0 and "wait" or "tick", cpu.state["PC"].value, spg:read_u16(0xc00001d0)); return data end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi and #ev > 0 then print(string.format("frame %d: %s", frames, table.concat(ev, " "))) end
  ev = {}
  if frames > hi then m:exit() end
end)
