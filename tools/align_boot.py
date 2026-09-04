#!/usr/bin/env python3
"""Line up boot phases: MAME's per-frame 68k PC (tools/trace_bootpc.lua) against the
RTL bench's per-frame `opc` (TG68K last_opc_pc). Phases are runs of frames whose PC
falls in the same 512-byte bucket; matched phases are compared by length.
usage: align_boot.py artifacts/bootpc_mame.txt artifacts/system_bootpc.log"""
import re, sys, difflib
def phases(path, pat):
    out=[]; prev=None
    for l in open(path):
        m=re.match(pat,l)
        if not m: continue
        f=int(m.group(1)); pc=int(m.group(2),16); key=pc>>9
        if key!=prev: out.append([f,pc,key]); prev=key
    return out
mame=phases(sys.argv[1], r"frame (\d+) 68k (\w+)")
ours=phases(sys.argv[2], r"frame (\d+) cyc \d+ 68k \w+ opc (\w+)")
def dur(ph): return [(ph[i][0], ph[i][1], (ph[i+1][0] if i+1<len(ph) else ph[i][0]+1)-ph[i][0]) for i in range(len(ph))]
md=dur(mame); od=dur(ours)
sm=difflib.SequenceMatcher(a=[p[2] for p in mame], b=[p[2] for p in ours], autojunk=False)
print(f"{'68k pc':>8} {'MAME':>10} {'ours':>10} {'delta':>6}   (matched phases with |delta|>=2, and unmatched stretches)")
cum=0
for tag,i1,i2,j1,j2 in sm.get_opcodes():
    if tag=="equal":
        for k in range(i2-i1):
            mf,mp,ml=md[i1+k]; of,op,ol=od[j1+k]; d=ol-ml; cum+=d
            if abs(d)>=2: print(f"{mp:08x} {mf:4d}/{ml:<5d} {of:4d}/{ol:<5d} {d:+6d}   cum {cum:+d}")
    else:
        mlen=sum(x[2] for x in md[i1:i2]); olen=sum(x[2] for x in od[j1:j2]); cum+=olen-mlen
        mdesc="/".join(f"{x[1]:05x}" for x in md[i1:i2][:3]); odesc="/".join(f"{x[1]:05x}" for x in od[j1:j2][:3])
        if abs(olen-mlen)>=2: print(f"[{tag:7s}] MAME {md[i1][0] if i1<len(md) else '-':>4}:{mdesc:<20s} len {mlen:3d}  ours {od[j1][0] if j1<len(od) else '-':>4}:{odesc:<20s} len {olen:3d}  {olen-mlen:+d}   cum {cum:+d}")
