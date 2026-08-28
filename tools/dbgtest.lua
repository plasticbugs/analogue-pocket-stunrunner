local frames=0
local dbg = manager.machine.debugger
print("debugger:", dbg)
emu.register_frame_done(function()
  frames=frames+1
  if frames==500 then
    dbg:command("trace gsp_trace.txt,:mainpcb:gsp,noloop,{tracelog \"A0=%08X A1=%08X B0=%08X SP=%08X ST=%08X \",a0,a1,b0,sp,st}")
    dbg:command("go")
  end
  if frames==502 then dbg:command("trace off,:mainpcb:gsp"); dbg:command("go") end
  if frames==505 then manager.machine:exit() end
end)
