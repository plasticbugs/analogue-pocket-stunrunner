#!/usr/bin/env python3
"""Compare the 68k -> sound-board command streams of MAME and the RTL for the
same stimulus (tools/trace_sndcmd.lua vs TB_SNDCMD): the command BYTES in
order, ignoring frame numbers (the RTL's timeline lags MAME's).

    compare_sndcmds.py <snd_cmds_mame.txt> <snd_cmds_rtl.txt>

Prints the first index where the sequences part, with context and the frame
each side sent it in; identical prefixes of different length are reported as
"rtl stopped after N" / "mame stopped after N".
"""
import sys

def load(p):
    cmds, resets = [], []
    for l in open(p):
        t = l.split()
        if not t: continue
        if t[0] == 'C': cmds.append((int(t[1]), int(t[2], 16)))
        elif t[0] == 'X': resets.append(int(t[1]))
    return cmds, resets

a, ra = load(sys.argv[1]); b, rb = load(sys.argv[2])
print(f"mame: {len(a)} commands, resets at {ra[:6]}   rtl: {len(b)} commands, resets at {rb[:6]}")
n = min(len(a), len(b))
for i in range(n):
    if a[i][1] != b[i][1]:
        lo = max(0, i - 8)
        print(f"\nFIRST DIFFERENT COMMAND at index {i}:")
        print("   idx  mame(frame:cmd)  rtl(frame:cmd)")
        for j in range(lo, min(n, i + 5)):
            print(f"  {j:4d}  {a[j][0]:5d}:{a[j][1]:02x}        {b[j][0]:5d}:{b[j][1]:02x}{'  <==' if j == i else ''}")
        sys.exit(2)
print(f"\nidentical for {n} commands", end="")
if len(a) > len(b): print(f"; rtl stopped after {n} (mame continued to frame {a[-1][0]}, rtl's last at frame {b[-1][0]})")
elif len(b) > len(a): print(f"; mame stopped after {n}")
else: print()
