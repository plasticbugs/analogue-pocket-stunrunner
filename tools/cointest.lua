local frames=0
local m=manager.machine
emu.register_frame_done(function()
  frames=frames+1
  if frames==900 then
    for n,p in pairs(m.ioport.ports) do
      local s=n..":"
      for fn,f in pairs(p.fields) do s=s.." ["..fn.."]" end
      print(s)
    end
  end
  if frames==1200 then m.ioport.ports[":mainpcb:jsa:JSAII"].fields["Coin 1"]:set_value(1) end
  if frames==1215 then m.ioport.ports[":mainpcb:jsa:JSAII"].fields["Coin 1"]:set_value(0) end
  if frames==1500 then m.video:snapshot() end
  if frames==1502 then m:exit() end
end)
