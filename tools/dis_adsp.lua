local m = manager.machine
local dbg = m.debugger
local frames = 0
emu.register_frame_done(function()
    frames = frames + 1
    if frames == 705 then
        dbg:command("dasm ../artifacts/adsp_150.txt,0x150,20,1,:mainpcb:adsp")
        m:exit()
    end
end)
