local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]
local frames = 0
emu.register_frame_done(function()
    frames = frames + 1
    if frames >= 552 and frames <= 566 then
        print(string.format("MAME frame %d: 68k pc=%06x", frames, cpu.state["PC"].value))
    end
    if frames > 567 then m:exit() end
end)
