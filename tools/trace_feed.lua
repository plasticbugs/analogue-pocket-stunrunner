-- How much spare time does the 68k have each frame?
-- FrameUpdate (0x2c372) spins `while (ff9bb4 == 0) GspFeedDataStream(5)` until the
-- ADSP finishes the frame, and the starfield backdrop is painted only inside that
-- loop (through the GSP host port). GspFeedDataStream saves its stream pointer to
-- ff9bd0 on every call that returns 1, and FrameUpdate stores the wait length in
-- ff9ba6 (ticks of ff8014). Per frame: feed calls, wait ticks, host-port writes.
-- Run: LO=.. HI=.. OUT=.. mame stunrun -autoboot_script tools/trace_feed.lua -nothrottle -video none -sound none
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]
local sp = cpu.spaces["program"]
local lo = tonumber(os.getenv("LO") or "1490")
local hi = tonumber(os.getenv("HI") or "1600")
local outf = os.getenv("OUT")
local fh = outf and io.open(outf, "w") or nil
local function emit(s) if fh then fh:write(s .. "\n") fh:flush() else print(s) end end
local frames, feed, wait, hostw, feed_active = 0, 0, -1, 0, 0
feed_taps = {}   -- global on purpose (see trace_som.lua)
feed_taps[1] = sp:install_write_tap(0xff9bd0, 0xff9bd3, "feed", function(off, data, mask)
  feed = feed + 1
  if data ~= 0 then feed_active = 1 end
  return data
end)
feed_taps[2] = sp:install_write_tap(0xff9ba6, 0xff9ba7, "wait", function(off, data, mask)
  wait = data & 0xffff   -- second write of the frame is the elapsed value
  return data
end)
local feedw, wdk = 0, 0
feed_taps[3] = sp:install_write_tap(0xc00000, 0xc0000f, "host", function(off, data, mask)
  hostw = hostw + 1
  local pc = cpu.state["PC"].value
  if pc >= 0x2274a and pc < 0x22954 then feedw = feedw + 1 end
  return data
end)
-- the ADSP-wait loop in FrameUpdate kicks the watchdog (608000) once per iteration
feed_taps[4] = sp:install_write_tap(0x608000, 0x608001, "wd", function(off, data, mask)
  wdk = wdk + 1
  return data
end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi then
    emit(string.format("frame %4d: wd_kicks %4d  feed_calls %4d  feed_host_writes %5d  host_writes %5d  stream %s",
      frames, wdk, feed, feedw, hostw, sp:read_u32(0xff9bd0) ~= 0 and "active" or "idle"))
  end
  feed, wait, hostw, feed_active, feedw, wdk = 0, -1, 0, 0, 0, 0
  if frames > hi then if fh then fh:close() end m:exit() end
end)
