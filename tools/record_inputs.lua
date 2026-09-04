-- Record what you play: one line per frame with the yoke and buttons as the
-- game sees them, so the RTL bench (TB_INPUTS) and tools/replay_inputs.lua can
-- reproduce the run frame for frame.
--   OUT=artifacts/play_inputs.txt mame stunrun -rompath . -autoboot_script tools/record_inputs.lua
-- Play normally (throttled, with video and sound); quit MAME when done.
-- Line format:  frame x y fire boost coin start   (x/y 0-255, others 0/1)
local m = manager.machine
local ports = m.ioport.ports
local px, py, p80, pin0 = ports[":mainpcb:8BADC.0"], ports[":mainpcb:8BADC.2"], ports[":mainpcb:a80000"], ports[":mainpcb:IN0"]
local fire_m  = p80.fields["P1 Button 1"].mask
local boost_m = p80.fields["P1 Button 2"] and p80.fields["P1 Button 2"].mask or 0
local start_m = p80.fields["1 Player Start"].mask
local coin_m  = pin0.fields["Coin 1"].mask
local fh = io.open(os.getenv("OUT") or "play_inputs.txt", "w")
local frames = 0
emu.register_frame_done(function()
  frames = frames + 1
  local a80, in0 = p80:read(), pin0:read()
  fh:write(string.format("%d %d %d %d %d %d %d\n", frames, px:read() & 0xff, py:read() & 0xff,
    (a80 & fire_m) == 0 and 1 or 0, (boost_m ~= 0 and (a80 & boost_m) == 0) and 1 or 0,
    (in0 & coin_m) == 0 and 1 or 0, (a80 & start_m) == 0 and 1 or 0))
  fh:flush()
end)
