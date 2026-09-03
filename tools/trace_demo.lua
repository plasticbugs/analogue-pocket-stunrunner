-- Attract-demo state per frame, to line up against the RTL's TB_DEMOSTATE.
-- The starfield backdrop is requested (FUN_2da6e -> ff9bcc = stream id) by the
-- track update FUN_31c8a when the car enters a segment flagged 0x20000, so what
-- matters is where the car is: ffdbee = track list node, ffdbfe = distance into
-- the segment, ff9578 = section counter, ff9550 = game state, ff9bcc/ff9bce =
-- backdrop stream requested/current, ff9bd0 = feed pointer (0 = idle).
-- Run: LO=.. HI=.. OUT=.. mame stunrun -autoboot_script tools/trace_demo.lua -nothrottle -video none -sound none
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]
local sp = cpu.spaces["program"]
local lo = tonumber(os.getenv("LO") or "540")
local hi = tonumber(os.getenv("HI") or "1900")
local outf = os.getenv("OUT")
local fh = outf and io.open(outf, "w") or nil
local function emit(s) if fh then fh:write(s .. "\n") fh:flush() else print(s) end end
local frames, req = 0, {}
demo_taps = {}
demo_taps[1] = sp:install_write_tap(0xff9bcc, 0xff9bcd, "req", function(off, data, mask)
  req[#req + 1] = string.format("req=%02x@%06x", data & 0xffff, cpu.state["PC"].value)
  return data
end)
emu.register_frame_done(function()
  frames = frames + 1
  if frames >= lo and frames <= hi then
    emit(string.format("frame %4d: state %02x sect %2d node %08x dist %5d bd %02x/%02x feed %08x %s",
      frames, sp:read_u16(0xff9550), sp:read_u16(0xff9578), sp:read_u32(0xffdbee), sp:read_i16(0xffdbfe),
      sp:read_u16(0xff9bcc) & 0xff, sp:read_u16(0xff9bce) & 0xff, sp:read_u32(0xff9bd0), table.concat(req, " ")))
  end
  req = {}
  if frames > hi then if fh then fh:close() end m:exit() end
end)
