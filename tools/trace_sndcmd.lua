-- MAME: every 68k -> sound-board command byte (write to 600000) with its frame,
-- every response read, and sound resets, for the bench's played-level stimulus
-- (coin 300, Start 360, yoke raised at 400, Fire at 480, yoke X = 48 from 500).
-- Diff against artifacts/snd_cmds_rtl.txt from TB_SNDCMD.
--   OUT=file FRAMES=n mame stunrun -autoboot_script tools/trace_sndcmd.lua ...
local m = manager.machine
local sp68 = m.devices[":mainpcb:maincpu"].spaces["program"]
local coin = m.ioport.ports[":mainpcb:IN0"].fields["Coin 1"]
local start = m.ioport.ports[":mainpcb:a80000"].fields["1 Player Start"]
local fire = m.ioport.ports[":mainpcb:a80000"].fields["P1 Button 1"]
local px = m.ioport.ports[":mainpcb:8BADC.0"]; local fx; for k,_ in pairs(px.fields) do fx = px.fields[k] end
local py = m.ioport.ports[":mainpcb:8BADC.2"]; local fy; for k,_ in pairs(py.fields) do fy = py.fields[k] end
local f = io.open(os.getenv("OUT") or "snd_cmds_mame.txt", "w")
local last = tonumber(os.getenv("FRAMES") or "4200")
local n = 0
sc_taps = {}
sc_taps[#sc_taps+1] = sp68:install_write_tap(0x600000, 0x600001, "cmd", function(off, data, mask)
  f:write(string.format("C %4d %02x\n", n, (data >> 8) & 0xff)) return data end)
sc_taps[#sc_taps+1] = sp68:install_read_tap(0x600000, 0x600001, "resp", function(off, data, mask)
  f:write(string.format("R %4d %02x\n", n, (data >> 8) & 0xff)) return data end)
sc_taps[#sc_taps+1] = sp68:install_write_tap(0x6c0000, 0x6c0001, "srst", function(off, data, mask)
  f:write(string.format("X %4d\n", n)) return data end)
emu.register_frame_done(function()
  n = n + 1
  if n == 300 then coin:set_value(1) end
  if n == 306 then coin:set_value(0) end
  if n == 360 then start:set_value(1) end
  if n == 366 then start:set_value(0) end
  if n == 400 then fy:set_value(240) end
  if n == 480 then fire:set_value(1) end
  if n == 486 then fire:set_value(0) end
  if n == 500 then fx:set_value(48) end
  if n > last then f:close() m:exit() end
end)
