#!/usr/bin/env python3
"""Compare the palette section of two state dumps (RTL bench vs MAME).
    compare_pal.py rtl_dump.txt mame_state.txt [max_report]"""
import sys
def pal(path):
    out=[]; sec=False
    for line in open(path):
        t=line.split()
        if not t: continue
        if t[0]=="PALETTE": sec=True; continue
        if t[0] in ("CTLLO","IOREGS"): sec=False; continue
        if sec and len(t)==2: out.append((int(t[0],16), int(t[1],16)))
    return out
a, b = pal(sys.argv[1]), pal(sys.argv[2])
n = int(sys.argv[3]) if len(sys.argv) > 3 else 24
diff = [i for i in range(min(len(a),len(b))) if a[i] != b[i]]
print(f"{len(a)} vs {len(b)} entries, {len(diff)} differ")
for i in diff[:n]:
    print(f"  {i:4d}: rtl lo={a[i][0]:04x} hi={a[i][1]:04x}   mame lo={b[i][0]:04x} hi={b[i][1]:04x}")
