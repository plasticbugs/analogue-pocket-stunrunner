#!/usr/bin/env python3
"""List every FILL/PIXBLT in a tools/trace_gsp.lua trace with the B-file values
MAME logged just before executing it, in the same line format TB_BLITLOG writes.

    blits_from_trace.py <w.trace> [max_lines]
"""
import re, sys
regs = None; n = 0; lim = int(sys.argv[2]) if len(sys.argv) > 2 else 400
for line in open(sys.argv[1], errors="replace"):
    if line.startswith("PC="):
        regs = dict(re.findall(r"\b(B\d+|PC|ST)=([0-9A-F]+)", line)); continue
    m = re.match(r"([0-9A-F]{8}): (FILL|PIXBLT)\s+(\S+)", line)
    if m and regs:
        print(f"{m.group(2)} {m.group(3):<7} B0={int(regs.get('B0','0'),16):08x} B1={int(regs.get('B1','0'),16):08x} B2={int(regs.get('B2','0'),16):08x} B3={int(regs.get('B3','0'),16):08x} B7={int(regs.get('B7','0'),16):08x} B5={int(regs.get('B5','0'),16):08x} B6={int(regs.get('B6','0'),16):08x}")
        n += 1
        if n >= lim: break
