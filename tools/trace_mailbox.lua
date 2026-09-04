-- Who writes the GSP's boot-loop mailbox (FFF716A0) and how often per frame. LO/HI env.
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local lo = tonumber(os.getenv("LO") or "200"); local hi = tonumber(os.getenv("HI") or "212")
local frames, ev = 0, {}
mb_taps = {}
mb_taps[1] = spg:install_write_tap(0xfff716a0, 0xfff716af, "mb", function(off, data, mask)
  ev[#ev+1] = string.format("%08x=%04x@vc%d", gsp.state["PC"].value, data & 0xffff, spg:read_u16(0xc00001d0)); return data end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi then print(string.format("frame %d: DI pending/enabled %04x/%04x  writes: %s", frames, spg:read_u16(0xc0000120), spg:read_u16(0xc0000110), table.concat(ev, " "))) end
  ev = {}
  if frames > hi then m:exit() end
end)
