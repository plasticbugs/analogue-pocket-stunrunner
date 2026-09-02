-- tools/trace_snd.lua -- run: mame stunrun -autoboot_script tools/trace_snd.lua -nothrottle -video none -sound none
-- MAME: 68k -> sound commands (writes to 600000) and sound -> 68k responses
-- (68k reads of 600000) per frame, plus YM2151 register writes by the 6502,
-- through the attract demo. The reference for "did the pipeline stall?".
local m = manager.machine
local sp68 = m.devices[":mainpcb:maincpu"].spaces["program"]
local snd = m.devices[":mainpcb:jsa:cpu"]
local sp6502 = snd.spaces["program"]
local n, cmd, resp, ym, oki = 0, 0, 0, 0, 0
snd_taps = {}
snd_taps[#snd_taps+1] = sp68:install_write_tap(0x600000, 0x600001, "cmd", function(off, data, mask) cmd = cmd + 1 return data end)
snd_taps[#snd_taps+1] = sp68:install_read_tap(0x600000, 0x600001, "resp", function(off, data, mask) resp = resp + 1 return data end)
snd_taps[#snd_taps+1] = sp6502:install_write_tap(0x2000, 0x2001, "ym", function(off, data, mask) ym = ym + 1 return data end)
snd_taps[#snd_taps+1] = sp6502:install_write_tap(0x2800, 0x2bff, "oki", function(off, data, mask) oki = oki + 1 return data end)
emu.register_frame_done(function()
  n = n + 1
  if n % 30 == 0 and n >= 540 then
    print(string.format("frames %4d-%4d: cmd=%3d resp=%3d ym_writes=%5d oki_writes=%3d  6502 pc=%04x", n-29, n, cmd, resp, ym, oki, snd.state["PC"].value))
    cmd, resp, ym, oki = 0, 0, 0, 0
  end
  if n > 2100 then m:exit() end
end)
