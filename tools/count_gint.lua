-- Per frame: sample MAME's ADSP PC (does it move => is it running?), count the
-- 68k's ADSP control-latch writes and its ADSP trigger writes.
local m = manager.machine
local adsp = m.devices[":mainpcb:adsp"]
local sp68 = m.devices[":mainpcb:maincpu"].spaces["program"]
local frames, ctl, trig = 0, 0, 0
local pcs = {}
local taps = {}
taps[#taps+1] = sp68:install_write_tap(0x818000, 0x81801f, "actl", function(off, data, mask)
    ctl = ctl + 1
end)
taps[#taps+1] = sp68:install_write_tap(0x808000, 0x80bfff, "trig", function(off, data, mask)
    if ((off - 0x808000) >> 1) == 0x1fff then trig = trig + 1 end
end)
emu.register_frame_done(function()
    frames = frames + 1
    local pc = adsp.state["PC"].value
    if frames >= 700 and frames <= 712 then
        print(string.format("MAME frame %d: adsp_pc=%04x ctl_writes=%d trig=%d", frames, pc, ctl, trig))
    end
    ctl, trig = 0, 0
    if frames > 713 then m:exit() end
end)
