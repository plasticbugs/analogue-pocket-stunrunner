-- Disassemble GSP code ranges once the program is loaded (frame FR), via the debugger.
-- Run with: -debug -debugger none.  RANGES="fff40f40,40 fff414a0,30" OUT=file
local m = manager.machine
local fr = tonumber(os.getenv("FR") or "200")
local frames = 0
emu.register_frame_done(function()
  frames = frames + 1
  if frames == fr then
    local dbg = m.debugger
    for r in string.gmatch(os.getenv("RANGES") or "fff40f40,40", "%S+") do
      local a, n = r:match("(%x+),(%d+)")
      dbg:command(string.format("dasm %s_%s.txt,0x%s,%s,1,:mainpcb:gsp", os.getenv("OUT") or "artifacts/gspdasm", a, a, n))
    end
    m:exit()
  end
end)
