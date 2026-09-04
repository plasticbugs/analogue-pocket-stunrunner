-- Who writes which VRAM rows: per frame, for each GSP PC that writes VRAM, the row
-- range (bit address >> 12, 512 px rows) and write count, plus the scan line of the
-- first and last write. IN replays; LO..HI (keep short: a tap on all of VRAM).
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local lo, hi = tonumber(os.getenv("LO") or "4993"), tonumber(os.getenv("HI") or "4995")
local rec = {}
if os.getenv("IN") then for l in io.lines(os.getenv("IN")) do local f, x, y, fi, bo, co, st = l:match("(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)"); if f then rec[tonumber(f)] = {tonumber(x), tonumber(y), tonumber(fi), tonumber(bo), tonumber(co), tonumber(st)} end end end
local ports = m.ioport.ports
local function afield(p) for _, f in pairs(ports[p].fields) do return f end end
local function setb(field, v) if field then if v == 1 then field:set_value(1) else field:clear_value() end end end
local frames, active = 0, false
local by = {}
rows_taps = {}
rows_taps[1] = spg:install_write_tap(0xff800000, 0xffffffff, "rows", function(off, data, mask)
  if not active then return data end
  local pc = gsp.state["PC"].value; local row = (off >> 12) & 0x3ff; local vc = spg:read_u16(0xc00001d0)
  local e = by[pc]
  if not e then e = {n=0, rmin=row, rmax=row, vc0=vc, vc1=vc}; by[pc] = e end
  e.n = e.n + 1; if row < e.rmin then e.rmin = row end; if row > e.rmax then e.rmax = row end; e.vc1 = vc
  return data end)
emu.register_frame_done(function()
  frames = frames + 1
  local r = rec[frames + 1]
  if r then afield(":mainpcb:8BADC.0"):set_value(r[1]); afield(":mainpcb:8BADC.2"):set_value(r[2]); local p80, pin0 = ports[":mainpcb:a80000"], ports[":mainpcb:IN0"]; setb(p80.fields["P1 Button 1"], r[3]); setb(p80.fields["P1 Button 2"], r[4]); setb(pin0.fields["Coin 1"], r[5]); setb(p80.fields["1 Player Start"], r[6]) end
  if active then
    print(string.format("frame %d: DPYSTRT %04x", frames, spg:read_u16(0xc0000090)))
    local ks = {}; for pc in pairs(by) do ks[#ks+1] = pc end; table.sort(ks, function(a, b) return by[a].n > by[b].n end)
    for i = 1, math.min(#ks, 14) do local e = by[ks[i]]; print(string.format("   pc %08x: %6d writes rows %3d-%3d  vc %d..%d", ks[i], e.n, e.rmin, e.rmax, e.vc0, e.vc1)) end
  end
  by = {}
  active = (frames + 1 >= lo and frames + 1 <= hi)
  if frames > hi then m:exit() end
end)
