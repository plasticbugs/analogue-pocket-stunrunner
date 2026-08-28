#!/usr/bin/env python3
"""Compare the 68010 instruction streams of MAME and the RTL around an anchor.

    compare_pcs.py <mame_trace.txt> <rtl_pcs.txt> <anchor_pc_hex>

mame_trace.txt: MAME debugger trace ("PC: mnemonic ..."). rtl_pcs.txt: one PC
per line from the bench's ring buffer, with a "---SNDCMD---" marker at the
anchor event. The anchor instruction (the one writing the sound command) is
located in both, then the streams are walked backwards and forwards from it
and the first divergence on each side is reported with context.
"""
import sys, re

def mame_pcs(path):
    out = []
    for line in open(path):
        m = re.match(r'^([0-9A-Fa-f]{6}):', line)
        if m: out.append(int(m.group(1), 16))
    return out

def rtl_pcs(path):
    before, after = [], []; cur = before
    for line in open(path):
        line = line.strip()
        if line.startswith('---'): cur = after; continue
        if line: cur.append(int(line, 16))
    return before, after

def dedupe_runs(seq):
    """MAME lists every executed instruction; the RTL list only records PC
    changes, so collapse consecutive duplicates on the MAME side too."""
    out = []
    for p in seq:
        if not out or out[-1] != p: out.append(p)
    return out

def main():
    mame = dedupe_runs(mame_pcs(sys.argv[1]))
    before, after = rtl_pcs(sys.argv[2])
    anchor = int(sys.argv[3], 16)
    # anchor in MAME: last occurrence before the end that also appears in RTL's `before` tail
    m_idx = [i for i, p in enumerate(mame) if p == anchor]
    r_idx = [i for i, p in enumerate(before) if p == anchor]
    if not m_idx or not r_idx:
        print(f"anchor {anchor:06x}: mame hits {len(m_idx)}, rtl hits {len(r_idx)}"); return 1
    mi, ri = m_idx[0], r_idx[-1]
    print(f"anchor {anchor:06x} at mame index {mi} (of {len(mame)}), rtl index {ri} (of {len(before)})")
    # backwards
    k = 0
    while mi - k >= 0 and ri - k >= 0 and mame[mi - k] == before[ri - k]: k += 1
    print(f"identical for {k} instructions before the anchor")
    if mi - k >= 0 and ri - k >= 0:
        print("  divergence (older first):")
        for j in range(k + 12, k - 1, -1):
            if mi - j >= 0 and ri - j >= 0:
                print(f"    -{j:5d}: mame {mame[mi-j]:06x}  rtl {before[ri-j]:06x}{'   <<<' if j == k else ''}")
    # forwards
    fw = mame[mi+1:]; k2 = 0
    while k2 < len(fw) and k2 < len(after) and fw[k2] == after[k2]: k2 += 1
    print(f"identical for {k2} instructions after the anchor")
    if k2 < len(fw) and k2 < len(after):
        for j in range(max(0, k2 - 6), min(k2 + 8, len(fw), len(after))):
            print(f"    +{j:5d}: mame {fw[j]:06x}  rtl {after[j]:06x}{'   <<<' if j == k2 else ''}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
