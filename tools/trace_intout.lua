-- Who raises INTOUT: GSP PCs writing HSTCTLL (c00000f0) per frame, LO..HI.
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local lo = tonumber(os.getenv("LO") or "170"); local hi = tonumber(os.getenv("HI") or "200")
local frames, ev = 0, {}
io_taps = {}
io_taps[1] = spg:install_write_tap(0xc00000f0, 0xc00000ff, "hgw", function(off, data, mask)
  ev[#ev+1] = string.format("%08x=%04x@vc%d", gsp.state["PC"].value, data & 0xffff, spg:read_u16(0xc00001d0))
  return data
end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi then print(string.format("frame %d: %s", frames, table.concat(ev, " "))) end
  ev = {}
  if frames > hi then m:exit() end
end)
