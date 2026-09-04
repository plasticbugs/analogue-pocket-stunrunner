-- What does the game make of the yoke Y at rest?  Coin at 300, Start at 360,
-- then at the level-select screen read the derived yoke value ffdd84 (0..31,
-- level = (v-14)/6) and its calibration record (ffdda6: +2 raw, +3 centre,
-- +4 max, +10 min) with the stick at MAME's rest value, then with Y forced.
local m = manager.machine
local sp = m.devices[":mainpcb:maincpu"].spaces["program"]
local ports = m.ioport.ports
local coin = ports[":mainpcb:IN0"].fields["Coin 1"]
local start = ports[":mainpcb:a80000"].fields["1 Player Start"]
local ystick
for n, p in pairs(ports) do for fn, f in pairs(p.fields) do if fn:find("Stick Y") or fn:find("AD Stick Y") then ystick = f end end end
local frames = 0
local function report(tag)
  local b = 0xffdda6
  print(string.format("%s frame %d: raw ff8002=%02x  ffdd84=%d  calib raw=%02x centre=%02x max=%02x min=%02x  X ffdd82=%d",
    tag, frames, sp:read_u8(0xff8002), sp:read_u8(0xffdd84), sp:read_u8(b+2), sp:read_u8(b+3), sp:read_u8(b+4), sp:read_u8(b+10), sp:read_u8(0xffdd82)))
end
emu.register_frame_done(function()
  frames = frames + 1
  if frames == 300 then coin:set_value(1) elseif frames == 310 then coin:clear_value() end
  if frames == 360 then start:set_value(1) elseif frames == 370 then start:clear_value() end
  if frames == 420 then report("rest") end
  if frames == 430 and ystick then ystick:set_value(0xf0) end
  if frames == 450 then report("Y=f0") end
  if frames == 455 and ystick then ystick:set_value(0xa8) end
  if frames == 475 then report("Y=a8") end
  if frames == 480 and ystick then ystick:set_value(0x80) end
  if frames == 500 then report("Y=80"); if not ystick then print("no Y stick field found") end m:exit() end
end)
