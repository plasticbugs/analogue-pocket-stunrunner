-- Protocol-level oracle for the 68k <-> ADSP SOM handshake.
--
-- The three CPU cores are each verified instruction-exact against MAME, so an
-- instruction trace cannot say anything new. What is *not* verified is the glue
-- between them, and the attract-demo reboot lives there. This logs the handshake
-- itself, cheaply, so the RTL bench's TB_SOMTRACE output can be diffed against
-- it frame by frame.
--
-- The handshake (68k FrameUpdate 0x2c372 + AdspIrqService 0x2e418):
--   * ADSP fills the bank the 68k is NOT reading, then rewinds som_address with
--     /SOMCLK and writes word 0 -- the total length -- LAST, then raises /GINT.
--   * /GINT -> 68k IRQ2 -> AdspIrqService halts the ADSP with /BR, reads shared
--     data word 0x1fe3 (0x80bfc6); zero means "frame done" and sets ff9bb4.
--   * FrameUpdate spins on ff9bb4, then toggles the hardware bank (818006 /
--     818016) from its own shadow ff9bb2, kicks the next ADSP frame, and finally
--     SomCopyToGsp(0x810000) reads word 0 as a signed length.
-- So a bad length means the 68k looked at a bank the ADSP had not finished.
--
-- Run with:
--   mame stunrun -autoboot_script tools/trace_som.lua -nothrottle -video none ...
-- Environment:
--   LO, HI    frame range to print in detail (default 1..720)
--   OUT       file to write (default stdout)
local m = manager.machine
local cpu = m.devices[":mainpcb:maincpu"]
local adsp = m.devices[":mainpcb:adsp"]
local sp68 = cpu.spaces["program"]
local dsp = adsp.spaces["data"]

local lo = tonumber(os.getenv("LO") or "1")
local hi = tonumber(os.getenv("HI") or "720")
local outf = os.getenv("OUT")
local fh = outf and io.open(outf, "w") or nil
local function emit(s) if fh then fh:write(s .. "\n") fh:flush() else print(s) end end

local frames = 0
local bank = 0                 -- the bank the 68k reads (hardware latch)
local shadow = { [0] = {}, [1] = {} }   -- our reconstruction of both SOM banks
local som_ptr = 0
local wr = { [0] = 0, [1] = 0 }         -- total SOMLATCH words ever, per bank
local first_activity = nil

-- per-frame counters
local f = {}
local function reset_frame()
  f = { somlatch0 = 0, somlatch1 = 0, somclk = 0, gint = 0, xout = 0,
        trig = 0, irqclr = 0, bankw = 0, br = 0, events = {} }
end
reset_frame()

local function ev(s)
  if frames >= lo and frames <= hi then f.events[#f.events + 1] = s end
end

-- GLOBAL on purpose: a chunk-local table is garbage-collected once the script
-- chunk ends and every tap silently stops firing, reporting zeros that look
-- like real measurements.
som_taps = {}

-- ADSP side: data-space writes to the 0x2000 I/O block
som_taps[#som_taps + 1] = dsp:install_write_tap(0x2000, 0x2fff, "adsp_io", function(off, data, mask)
  -- the ADSP data space is word-addressed (addrbus shift -1), so the tap
  -- offset is already a word address; do NOT shift it like a 68k byte address
  local sel = off & 7
  if sel == 2 then                    -- SOMLATCH
    local b = bank ~ 1
    shadow[b][som_ptr & 0x1fff] = data
    som_ptr = (som_ptr + 1) & 0x1fff
    wr[b] = wr[b] + 1
    if b == 0 then f.somlatch0 = f.somlatch0 + 1 else f.somlatch1 = f.somlatch1 + 1 end
    if not first_activity then first_activity = frames end
  elseif sel == 3 then                -- /SOMCLK: rewind
    som_ptr = data & 0x1fff
    f.somclk = f.somclk + 1
    ev(string.format("SOMCLK ptr=%d (adsp fills bank %d)", som_ptr, bank ~ 1))
  elseif sel == 5 then
    f.xout = f.xout + 1
  elseif sel == 6 then
    f.gint = f.gint + 1
  end
  return data
end)

-- 68k side: ADSP control latch
som_taps[#som_taps + 1] = sp68:install_write_tap(0x818000, 0x81801f, "m68_actl", function(off, data, mask)
  local sel = (off >> 1) & 7
  local val = (off >> 4) & 1
  if sel == 3 then
    bank = val
    f.bankw = f.bankw + 1
    ev(string.format("68k BANK -> %d (68k reads bank %d, adsp fills bank %d)", val, val, val ~ 1))
  elseif sel == 5 then
    f.br = f.br + 1
    ev(string.format("68k /BR = %d %s", val, val == 0 and "(ADSP halted)" or "(ADSP released)"))
  elseif sel == 6 then
    ev(string.format("68k /HALT = %d", val))
  elseif sel == 7 then
    ev(string.format("68k ADSP reset = %d", val))
  end
  return data
end)

-- 68k clears the ADSP interrupt (818060)
som_taps[#som_taps + 1] = sp68:install_write_tap(0x818060, 0x818061, "m68_aclr", function(off, data, mask)
  f.irqclr = f.irqclr + 1
  return data
end)

-- 68k kicks the ADSP: any write to data word 0x1fff (0x80bffe)
som_taps[#som_taps + 1] = sp68:install_write_tap(0x808000, 0x80bfff, "m68_dram", function(off, data, mask)
  if ((off - 0x808000) >> 1) == 0x1fff then
    f.trig = f.trig + 1
    ev(string.format("68k TRIGGER (kick ADSP frame) data=%04x", data))
  end
  return data
end)

-- SomCopyToGsp stashes the length it read at ffdb4e; that is the failure point
som_taps[#som_taps + 1] = sp68:install_write_tap(0x00ffdb4e, 0x00ffdb4f, "m68_len", function(off, data, mask)
  local v = data & 0xffff
  local sv = v >= 0x8000 and v - 0x10000 or v
  local bad = (sv < 0 or v > 16000)
  ev(string.format("SomCopyToGsp len=%d (0x%04x)%s", sv, v, bad and "   <-- BAD" or ""))
  ev(string.format("   68k reads bank %d: w0=%04x w1=%04x (%d words ever)",
      bank, shadow[bank][0] or 0, shadow[bank][1] or 0, wr[bank]))
  ev(string.format("   adsp fills bank %d: w0=%04x w1=%04x (%d words ever)",
      bank ~ 1, shadow[bank ~ 1][0] or 0, shadow[bank ~ 1][1] or 0, wr[bank ~ 1]))
  return data
end)

emu.register_frame_done(function()
  frames = frames + 1
  local active = f.somlatch0 + f.somlatch1 + f.gint + f.trig + f.bankw + #f.events > 0
  if frames >= lo and frames <= hi and active then
    for _, e in ipairs(f.events) do emit(string.format("  f%3d %s", frames, e)) end
    emit(string.format(
      "frame %3d: somlatch b0=%-5d b1=%-5d  somclk=%-3d gint=%-4d xout=%-3d trig=%d irqclr=%-4d " ..
      "| 68k reads bank %d  ptr=%d  adsp_pc=%04x",
      frames, f.somlatch0, f.somlatch1, f.somclk, f.gint, f.xout, f.trig, f.irqclr,
      bank, som_ptr, adsp.state["PC"].value))
  end
  reset_frame()
  if frames > hi then
    emit(string.format("-- first ADSP SOM activity at frame %s", tostring(first_activity)))
    if fh then fh:close() end
    m:exit()
  end
end)
