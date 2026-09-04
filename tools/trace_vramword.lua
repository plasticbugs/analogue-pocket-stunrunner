-- Who writes one VRAM word: GSP writes (PC, data) and host writes to the 16-bit word at
-- GSP bit address ADDR (hex), per frame in LO..HI, replaying IN inputs.
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]; local spg = gsp.spaces["program"]
local addr = tonumber(os.getenv("ADDR") or "ffd05580", 16)
local lo, hi = tonumber(os.getenv("LO") or "5019"), tonumber(os.getenv("HI") or "5033")
local rec = {}
if os.getenv("IN") then for l in io.lines(os.getenv("IN")) do local f, x, y, fi, bo, co, st = l:match("(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)"); if f then rec[tonumber(f)] = {tonumber(x), tonumber(y), tonumber(fi), tonumber(bo), tonumber(co), tonumber(st)} end end end
local ports = m.ioport.ports
local function afield(p) for _, f in pairs(ports[p].fields) do return f end end
local function setb(field, v) if field then if v == 1 then field:set_value(1) else field:clear_value() end end end
local frames, ev = 0, {}
vw_taps = {}
local function tap(a, tag)
  return spg:install_write_tap(a, a + 15, tag, function(off, data, mask)
    ev[#ev+1] = string.format("%s:%08x=%04x/%04x@vc%d", tag, gsp.state["PC"].value, data & 0xffff, mask & 0xffff, spg:read_u16(0xc00001d0)); return data end)
end
-- both VRAM aliases of the same word (ff800000 + off and ffc00000 + off)
local off = addr & 0x3fffff
vw_taps[1] = tap(0xff800000 + off, "lo"); vw_taps[2] = tap(0xffc00000 + off, "hi")
emu.register_frame_done(function()
  frames = frames + 1
  local r = rec[frames + 1]
  if r then afield(":mainpcb:8BADC.0"):set_value(r[1]); afield(":mainpcb:8BADC.2"):set_value(r[2]); local p80, pin0 = ports[":mainpcb:a80000"], ports[":mainpcb:IN0"]; setb(p80.fields["P1 Button 1"], r[3]); setb(p80.fields["P1 Button 2"], r[4]); setb(pin0.fields["Coin 1"], r[5]); setb(p80.fields["1 Player Start"], r[6]) end
  if frames >= lo and frames <= hi then print(string.format("frame %d: %s", frames, table.concat(ev, " "))) end
  ev = {}
  if frames > hi then m:exit() end
end)
