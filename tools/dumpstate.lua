-- Dump GSP VRAM, IO regs, palette, control latches at given frames + snapshot
local frames = 0
local m = manager.machine
local gsp = m.devices[":mainpcb:gsp"]
local sp = gsp.spaces["program"]
local outdir = os.getenv("OUTDIR") or "."
local targets = {}
for t in string.gmatch(os.getenv("FRAMES") or "600", "%d+") do targets[tonumber(t)] = true end
local palbank, finescroll, shiftreg_en = 0, 0, 0
-- tap control_hi writes to reconstruct the latched bits
local tap = sp:install_write_tap(0xf4800000, 0xf48000ff, "ctlhi", function(offset, data, mask)
  local off = (offset - 0xf4800000) // 16
  local val = (off >> 3) & 1
  local sel = off & 7
  if sel == 0 then shiftreg_en = val
  elseif sel == 1 then finescroll = data & 7
  elseif sel == 2 then palbank = (palbank & ~1) | val
  elseif sel == 3 then palbank = (palbank & ~2) | (val << 1)
  end
end)
local function dump(tag)
  local f = io.open(string.format("%s/%s.txt", outdir, tag), "w")
  f:write("IOREGS\n")
  for i = 0, 31 do f:write(string.format("%04x\n", sp:read_u16(0xC0000000 + i*16))) end
  f:write(string.format("PALBANK %d\nFINESCROLL %d\nSHIFTREG %d\n", palbank, finescroll, shiftreg_en))
  local plo = m.memory.shares[":mainpcb:gsp_palram_lo"]
  local phi = m.memory.shares[":mainpcb:gsp_palram_hi"]
  f:write("PALETTE\n")
  for i = 0, 1023 do f:write(string.format("%04x %04x\n", plo:read_u16(i*2), phi:read_u16(i*2))) end
  local clo = m.memory.shares[":mainpcb:gsp_control_lo"]
  f:write("CTLLO\n")
  for i = 0, 15 do f:write(string.format("%04x\n", clo:read_u16(i*2))) end
  f:close()
  -- VRAM: 512 KB as raw little-endian words, via the memory share
  local vram = m.memory.shares[":mainpcb:gsp_vram"]
  local vf = io.open(string.format("%s/%s.vram", outdir, tag), "wb")
  local chunk = {}
  for i = 0, vram.size - 1, 2 do
    local w = vram:read_u16(i)
    chunk[#chunk+1] = string.char(w & 0xff, w >> 8)
    if #chunk >= 4096 then vf:write(table.concat(chunk)); chunk = {} end
  end
  vf:write(table.concat(chunk)); vf:close()
  print("dumped", tag, "vram bytes", vram.size, "palbank", palbank, "fine", finescroll)
end
emu.register_frame_done(function()
  frames = frames + 1
  if targets[frames] then
    dump(string.format("f%05d", frames))
    m.video:snapshot()
  end
  -- input driving (MAME Lua: set_value(1) = active, clear_value() = released)
  local coin_f, start_f = tonumber(os.getenv("COIN") or "-1"), tonumber(os.getenv("START") or "-1")
  if frames == coin_f then m.ioport.ports[":mainpcb:IN0"].fields["Coin 1"]:set_value(1) end
  if frames == coin_f + 10 then m.ioport.ports[":mainpcb:IN0"].fields["Coin 1"]:clear_value() end
  if frames == start_f then m.ioport.ports[":mainpcb:a80000"].fields["1 Player Start"]:set_value(1) end
  if frames == start_f + 10 then m.ioport.ports[":mainpcb:a80000"].fields["1 Player Start"]:clear_value() end
  -- optional played level, same knobs as tools/trace_jsa.lua: RAISE_FRAME raises the
  -- yoke (Y = 240) to pick a level, FIRE_FRAME presses the trigger, STICKX holds X from then
  local raise_f, fire_f, stickx = tonumber(os.getenv("RAISE_FRAME") or "-1"), tonumber(os.getenv("FIRE_FRAME") or "-1"), tonumber(os.getenv("STICKX") or "-1")
  if frames == raise_f then for k,_ in pairs(m.ioport.ports[":mainpcb:8BADC.2"].fields) do m.ioport.ports[":mainpcb:8BADC.2"].fields[k]:set_value(240) end end
  if frames == fire_f then m.ioport.ports[":mainpcb:a80000"].fields["P1 Button 1"]:set_value(1) end
  if frames == fire_f + 10 then m.ioport.ports[":mainpcb:a80000"].fields["P1 Button 1"]:clear_value() end
  if frames == fire_f and stickx >= 0 then for k,_ in pairs(m.ioport.ports[":mainpcb:8BADC.0"].fields) do m.ioport.ports[":mainpcb:8BADC.0"].fields[k]:set_value(stickx) end end
  -- hold the stick up-left from frame START+120 to see the ship move
  if start_f > 0 and frames == start_f + 120 then m.ioport.ports[":mainpcb:8BADC.0"].fields["AD Stick X"]:set_value(0x40) end
  local last = 0
  for k in pairs(targets) do if k > last then last = k end end
  if frames > last + 2 then m:exit() end
end)
