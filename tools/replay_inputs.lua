-- Replay a tools/record_inputs.lua file in MAME and take snapshots.
--   IN=artifacts/play_inputs.txt SNAP_FROM=2900 SNAP_EVERY=2 SNAP_TO=3200 \
--   mame stunrun ... -nothrottle -video none -snapshot_directory artifacts/snap_replay -autoboot_script tools/replay_inputs.lua
local m = manager.machine
local ports = m.ioport.ports
local function afield(p) for _, f in pairs(ports[p].fields) do return f end end
local fx, fy = afield(":mainpcb:8BADC.0"), afield(":mainpcb:8BADC.2")
local p80, pin0 = ports[":mainpcb:a80000"], ports[":mainpcb:IN0"]
local fire, boost, start, coin = p80.fields["P1 Button 1"], p80.fields["P1 Button 2"], p80.fields["1 Player Start"], pin0.fields["Coin 1"]
local rec = {}
local last = 0
for l in io.lines(os.getenv("IN") or "play_inputs.txt") do
  local f, x, y, fi, bo, co, st = l:match("(%d+) (%d+) (%d+) (%d+) (%d+) (%d+) (%d+)")
  if f then rec[tonumber(f)] = {tonumber(x), tonumber(y), tonumber(fi), tonumber(bo), tonumber(co), tonumber(st)}; last = tonumber(f) end
end
local sfrom, severy, sto = tonumber(os.getenv("SNAP_FROM") or "-1"), tonumber(os.getenv("SNAP_EVERY") or "1"), tonumber(os.getenv("SNAP_TO") or "-1")
local frames = 0
local sp = m.devices[":mainpcb:maincpu"].spaces["program"]
local pstate = -1
local function setb(field, v) if field then if v == 1 then field:set_value(1) else field:clear_value() end end end
emu.register_frame_done(function()
  frames = frames + 1
  if os.getenv("STATE_LOG") then local st = sp:read_u16(0xff9550); if st ~= pstate then print(string.format("state %d: %02x", frames, st)); pstate = st end end
  local r = rec[frames + 1]      -- apply the inputs recorded for the next frame
  if r then fx:set_value(r[1]); fy:set_value(r[2]); setb(fire, r[3]); setb(boost, r[4]); setb(coin, r[5]); setb(start, r[6]) end
  if sfrom >= 0 and frames >= sfrom and (sto < 0 or frames <= sto) and (frames - sfrom) % severy == 0 then m.video:snapshot() end
  if frames > last + 5 or (sto >= 0 and frames > sto) then m:exit() end
end)
