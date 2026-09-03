-- Who paints the starfield backdrop, and how fast?
-- The demo's horizon band is two PIXBLT L,XY from an off-screen VRAM region
-- (GSP bit addresses ffe00000..fff21000, dump rows 512-800). During the title
-- screen that region holds the title art; before the open section of the demo
-- the game overwrites it with a starfield. This logs, per frame, every write
-- into the lower part of that region (rows 633-800, where the RTL still shows
-- title art at the aligned frame): count, distinct rows, and the first few
-- writers (GSP PC + 68k PC), plus 68k host-interface writes, so the writer
-- and its rate can be read off.
-- Run: LO=1490 HI=1840 OUT=... mame stunrun -autoboot_script tools/trace_backdrop.lua -nothrottle -video none -sound none
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]
local cpu = m.devices[":mainpcb:maincpu"]
local sp = gsp.spaces["program"]
local sp68 = cpu.spaces["program"]
local lo = tonumber(os.getenv("LO") or "1490")
local hi = tonumber(os.getenv("HI") or "1840")
local outf = os.getenv("OUT")
local fh = outf and io.open(outf, "w") or nil
local function emit(s) if fh then fh:write(s .. "\n") fh:flush() else print(s) end end
local frames = 0
local n, rows, first, hostw = 0, {}, {}, 0
local ROW0 = 0xffe00000
backdrop_taps = {}   -- global: a local table is collected and the taps die
backdrop_taps[1] = sp:install_write_tap(0xffe79000, 0xfff20fff, "bd_w", function(off, data, mask)
  n = n + 1
  local r = (off - ROW0) // 0x1000
  rows[r] = (rows[r] or 0) + 1
  if #first < 4 then
    first[#first + 1] = string.format("gsp=%08x 68k=%06x @%08x d=%04x", gsp.state["PC"].value, cpu.state["PC"].value, off, data)
  end
  return data
end)
backdrop_taps[2] = sp68:install_write_tap(0xc00000, 0xc0000f, "host_w", function(off, data, mask)
  hostw = hostw + 1
  return data
end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi and (n > 0 or hostw > 0) then
    local rl = {}
    for r in pairs(rows) do rl[#rl + 1] = r end
    table.sort(rl)
    emit(string.format("frame %4d: %5d writes to rows 633-800, %3d rows (%s..%s), 68k host writes %d",
      frames, n, #rl, tostring(rl[1] and rl[1] + 512), tostring(rl[#rl] and rl[#rl] + 512), hostw))
    for _, s in ipairs(first) do emit("   " .. s) end
  end
  n, rows, first, hostw = 0, {}, {}, 0
  if frames > hi then if fh then fh:close() end m:exit() end
end)
