local frames = 0
local gsp = manager.machine.devices[":mainpcb:gsp"]
local cpu = manager.machine.devices[":mainpcb:maincpu"]
local names={"HESYNC","HEBLNK","HSBLNK","HTOTAL","VESYNC","VEBLNK","VSBLNK","VTOTAL","DPYCTL","DPYSTRT","DPYINT","CONTROL","HSTDATA","HSTADRL","HSTADRH","HSTCTLL","HSTCTLH","INTENB","INTPEND","CONVSP","CONVDP","PSIZE","PMASK","U23","U24","U25","U26","DPYTAP","HCOUNT","VCOUNT","DPYADR","REFCNT"}
local function dumpio()
  local sp = gsp.spaces["program"]
  local s = ""
  for i=0,31 do s = s .. string.format("%s=%04x ", names[i+1], sp:read_u16(0xC0000000 + i*16)) end
  print(s)
end
emu.register_frame_done(function()
  frames = frames + 1
  if frames % 120 == 0 then
    print("frame", frames, "68kPC", string.format("%06x", cpu.state["PC"].value), "gspPC", string.format("%08x", gsp.state["PC"].value))
    dumpio()
  end
  if frames == 900 then manager.machine:exit() end
end)
