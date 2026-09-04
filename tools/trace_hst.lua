-- Host-control handshake per frame: 68k writes to HSTCTL (c0000e), GSP writes to
-- HSTCTLL (INTOUT/MSGOUT), 68k IRQ3 vector entries are visible as reads of the
-- GSP's HSTCTL by the handler. LO/HI/OUT env.
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]; local gsp = m.devices[":mainpcb:gsp"]
local sp68 = cpu.spaces["program"]; local spg = gsp.spaces["program"]
local lo = tonumber(os.getenv("LO") or "170"); local hi = tonumber(os.getenv("HI") or "245")
local fh = io.open(os.getenv("OUT") or "hst.txt", "w")
local frames, w68, wg, r68 = 0, 0, 0, 0
local last68, lastg = "", ""
hst_taps = {}
hst_taps[1] = sp68:install_write_tap(0xc0000e, 0xc0000f, "h68w", function(off, data, mask) w68 = w68 + 1; last68 = string.format("%04x", data & 0xffff); return data end)
hst_taps[2] = sp68:install_read_tap(0xc0000e, 0xc0000f, "h68r", function(off, data, mask) r68 = r68 + 1; return data end)
hst_taps[3] = spg:install_write_tap(0xc00000f0, 0xc00000ff, "hgw", function(off, data, mask) wg = wg + 1; lastg = string.format("%04x", data & 0xffff); return data end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi then
    fh:write(string.format("frame %4d: 68k HSTCTL writes %3d (last %s) reads %4d | GSP HSTCTLL writes %3d (last %s) | 68k pc %06x gsp pc %08x\n",
      frames, w68, last68, r68, wg, lastg, cpu.state["PC"].value, gsp.state["PC"].value))
  end
  w68, wg, r68 = 0, 0, 0
  if frames > hi then fh:close() m:exit() end
end)
