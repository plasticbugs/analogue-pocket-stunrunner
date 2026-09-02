-- How fast does the GSP complete command buffers? Count the 68k's IRQ3
-- acknowledgements (writes to c00008, which clear INTOUT) per 20-frame block.
-- Tap table MUST be global or it is garbage-collected and reports zeros.
local m = manager.machine
local sp68 = m.devices[":mainpcb:maincpu"].spaces["program"]
local frames, acks, blockacks = 0, 0, 0
mytaps = {}
mytaps[#mytaps+1] = sp68:install_write_tap(0xc00008, 0xc00009, "irq3ack", function(off, data, mask)
    acks = acks + 1; blockacks = blockacks + 1
end)
emu.register_frame_done(function()
    frames = frames + 1
    if frames % 20 == 0 and frames >= 400 and frames <= 580 then
        print(string.format("MAME frames %d-%d: gsp buffers completed = %d", frames-19, frames, blockacks))
        blockacks = 0
    elseif frames % 20 == 0 then blockacks = 0 end
    if frames > 581 then print(string.format("MAME total acks to 580: %d", acks)); m:exit() end
end)
