-- One 68k PC sample per frame from power-on, to line up boot phases with the
-- RTL bench's per-frame "68k <pc>" log. OUT=file HI=frames.
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]
local gsp = m.devices[":mainpcb:gsp"]
local hi = tonumber(os.getenv("HI") or "600")
local fh = io.open(os.getenv("OUT") or "bootpc.txt", "w")
local frames = 0
emu.register_frame_done(function()
  frames = frames + 1
  fh:write(string.format("frame %d 68k %08x gsp %08x\n", frames, cpu.state["PC"].value, gsp.state["PC"].value))
  if frames >= hi then fh:close() m:exit() end
end)
