-- Log every 68k<->JSA II exchange and every 6502 write to the YM2151, with
-- the machine time, while MAME records the audio with -wavwrite. Coins up and
-- starts a game so the sound board has something to play.
--   FRAMES=<n> OUT=<dir> [TAPS=all|m|s1|s2|s3|none] mame stunrun ... -wavwrite OUT/mame.wav -autoboot_script tools/trace_jsa.lua
-- Taps must be kept referenced (a global), otherwise Lua collects them and the
-- tap silently disappears after the first event or two.
-- Note: write/read taps on the 6502's mirrored I/O ranges (2800-29ff, 2a00-2bff)
-- crash MAME 0.288; only the YM2151 range (2000-2001) can be tapped.
local m = manager.machine
local nframes = tonumber(os.getenv("FRAMES") or "1800")
local out = os.getenv("OUT") or "artifacts/jsa"
local which = os.getenv("TAPS") or "all"
local coin_frame = tonumber(os.getenv("COIN") or "900")
f_events = io.open(out .. "/events.txt", "w")
f_events:setvbuf("line")
local f = f_events
frame = 0
local function now() return m.time:as_double() end
local mcpu = m.devices[":mainpcb:maincpu"].spaces["program"]
local scpu = m.devices[":mainpcb:jsa:cpu"].spaces["program"]
taps = {}
if which == "all" or which == "m" then
  taps[#taps+1] = mcpu:install_write_tap(0x600000, 0x603fff, "cmd", function(off, data, mask)
    f:write(string.format("%.7f %d CMD %02x\n", now(), frame, (data >> 8) & 0xff))
  end)
  taps[#taps+1] = mcpu:install_read_tap(0x600000, 0x603fff, "resp", function(off, data, mask)
    f:write(string.format("%.7f %d RESP %02x\n", now(), frame, (data >> 8) & 0xff))
  end)
  taps[#taps+1] = mcpu:install_read_tap(0x604000, 0x607fff, "sreset", function(off, data, mask)
    f:write(string.format("%.7f %d SRESET\n", now(), frame))
  end)
end
if which == "all" or which == "s1" then
  taps[#taps+1] = scpu:install_write_tap(0x2000, 0x2001, "ym", function(off, data, mask)
    f:write(string.format("%.7f %d YM%d %02x\n", now(), frame, off & 1, data & 0xff))
  end)
end
if which == "s4" then
  taps[#taps+1] = scpu:install_read_tap(0x2000, 0x2001, "ymrd", function(off, data, mask)
    local t = now(); if t > 9.85 and t < 10.0 then f:write(string.format("%.7f %d YMRD%d %02x\n", t, frame, off & 1, data & 0xff)) end
  end)
  taps[#taps+1] = scpu:install_write_tap(0x2000, 0x2001, "ymw", function(off, data, mask)
    local t = now(); if t > 9.85 and t < 10.0 then f:write(string.format("%.7f %d YM%d %02x\n", t, frame, off & 1, data & 0xff)) end
  end)
end
if which == "all" or which == "s2" then
  taps[#taps+1] = scpu:install_write_tap(0x2a00, 0x2a00, "oki", function(off, data, mask)
    f:write(string.format("%.7f %d OKI %02x\n", now(), frame, data & 0xff))
  end)
  taps[#taps+1] = scpu:install_write_tap(0x2a02, 0x2a02, "wrp", function(off, data, mask)
    f:write(string.format("%.7f %d WRP %02x\n", now(), frame, data & 0xff))
  end)
  taps[#taps+1] = scpu:install_write_tap(0x2a04, 0x2a04, "wrio", function(off, data, mask)
    f:write(string.format("%.7f %d WRIO %02x\n", now(), frame, data & 0xff))
  end)
end
if which == "all" or which == "s3" then
  taps[#taps+1] = scpu:install_read_tap(0x2802, 0x2802, "rdp", function(off, data, mask)
    f:write(string.format("%.7f %d RDP %02x\n", now(), frame, data & 0xff))
  end)
  taps[#taps+1] = scpu:install_read_tap(0x2800, 0x2800, "okird", function(off, data, mask)
    f:write(string.format("%.7f %d OKIRD %02x\n", now(), frame, data & 0xff))
  end)
  taps[#taps+1] = scpu:install_write_tap(0x2a06, 0x2a06, "mix", function(off, data, mask)
    f:write(string.format("%.7f %d MIX %02x\n", now(), frame, data & 0xff))
  end)
end
local in0 = m.ioport.ports[":mainpcb:IN0"]
local start = m.ioport.ports[":mainpcb:a80000"].fields["1 Player Start"]
local fire = m.ioport.ports[":mainpcb:a80000"].fields["P1 Button 1"]
local raise_frame = tonumber(os.getenv("RAISE_FRAME"))
local fire_frame = tonumber(os.getenv("FIRE_FRAME"))
local stickx = tonumber(os.getenv("STICKX"))
local px_field, py_field
for k,_ in pairs(m.ioport.ports[":mainpcb:8BADC.0"].fields) do px_field = m.ioport.ports[":mainpcb:8BADC.0"].fields[k] end
for k,_ in pairs(m.ioport.ports[":mainpcb:8BADC.2"].fields) do py_field = m.ioport.ports[":mainpcb:8BADC.2"].fields[k] end
emu.register_frame_done(function()
  frame = frame + 1
  if frame == 1 then f:write(string.format("%.7f 1 FRAME0\n", now())) end
  if frame == coin_frame then in0.fields["Coin 1"]:set_value(1); f:write(string.format("%.7f %d COIN1_DOWN\n", now(), frame)) end
  if frame == coin_frame + 12 then in0.fields["Coin 1"]:clear_value() end
  if frame == coin_frame + 200 then start:set_value(1); f:write(string.format("%.7f %d START_DOWN\n", now(), frame)) end
  if frame == coin_frame + 215 then start:clear_value() end
  -- optional: reach a played level (RAISE_FRAME raises the yoke to pick a
  -- level, FIRE_FRAME presses the trigger, STICKX holds the yoke X from then)
  if raise_frame and frame == raise_frame then py_field:set_value(240); f:write(string.format("%.7f %d RAISE\n", now(), frame)) end
  if fire_frame and frame == fire_frame then fire:set_value(1); f:write(string.format("%.7f %d FIRE_DOWN\n", now(), frame)) end
  if fire_frame and frame == fire_frame + 6 then fire:clear_value() end
  if stickx and frame == (fire_frame or 0) + 20 then px_field:set_value(stickx) end
  if frame >= nframes then f:close(); m:exit() end
end)
