-- Tally screen: per frame, the displayed buffer (DPYSTRT) and, for each of the two
-- frame buffers, the first VRAM write into the tally-box rows (y 44-60) with the
-- GSP PC and scan line, plus the write count. IN replays a recorded run; LO..HI.
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local lo, hi = tonumber(os.getenv("LO") or "4990"), tonumber(os.getenv("HI") or "5002")
local rec = {}
if os.getenv("IN") then for l in io.lines(os.getenv("IN")) do local f, x, y, fi, bo, co, st = l:match("(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)"); if f then rec[tonumber(f)] = {tonumber(x), tonumber(y), tonumber(fi), tonumber(bo), tonumber(co), tonumber(st)} end end end
local ports = m.ioport.ports
local function afield(p) for _, f in pairs(ports[p].fields) do return f end end
local function setb(field, v) if field then if v == 1 then field:set_value(1) else field:clear_value() end end end
local frames = 0
local st = { {n=0, first=nil, vcs={}}, {n=0, first=nil, vcs={}} }
tally_taps = {}
local function mk(b)
  local base = 0xffc00000 + b * 240 * 0x1000 + 44 * 0x1000
  return spg:install_write_tap(base, base + 16 * 0x1000 - 1, "tb" .. b, function(off, data, mask)
    local s = st[b + 1]; s.n = s.n + 1
    local vc = spg:read_u16(0xc00001d0)
    if not s.first then s.first = string.format("pc %08x vc %d", gsp.state["PC"].value, vc) end
    s.last = string.format("vc %d", vc)
    return data end)
end
tally_taps[1] = mk(0); tally_taps[2] = mk(1)
emu.register_frame_done(function()
  frames = frames + 1
  local r = rec[frames + 1]
  if r then afield(":mainpcb:8BADC.0"):set_value(r[1]); afield(":mainpcb:8BADC.2"):set_value(r[2]); local p80, pin0 = ports[":mainpcb:a80000"], ports[":mainpcb:IN0"]; setb(p80.fields["P1 Button 1"], r[3]); setb(p80.fields["P1 Button 2"], r[4]); setb(pin0.fields["Coin 1"], r[5]); setb(p80.fields["1 Player Start"], r[6]) end
  if frames >= lo and frames <= hi then
    print(string.format("frame %d: DPYSTRT %04x | buf0 writes %5d first %s last %s | buf1 writes %5d first %s last %s",
      frames, spg:read_u16(0xc0000090), st[1].n, st[1].first or "-", st[1].last or "-", st[2].n, st[2].first or "-", st[2].last or "-"))
  end
  st = { {n=0, first=nil}, {n=0, first=nil} }
  if frames > hi then m:exit() end
end)
