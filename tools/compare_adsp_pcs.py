#!/usr/bin/env python3
"""Find the first instruction where the RTL's ADSP parts company with MAME's.

    compare_adsp_pcs.py <mame adsp_trace_pc.txt> <rtl_adsp_pc.txt> [start_pc_hex]

MAME's PC-only trace (tools/trace_adsp.lua PCFRAMES) has "PPPP: disassembly"
per line; the RTL's TB_ADSPPC file has one PC per line. Both are aligned on the
first occurrence of start_pc (default 0013, the top of the idle loop `AR =
DM($1FFF)`), then compared in order. Prints the first divergence with context.
"""
import sys, re

def mame_pcs(p):
    out = []
    for line in open(p):
        m = re.match(r"([0-9A-Fa-f]{4}):", line)
        if m: out.append(int(m.group(1), 16))
    return out

def rtl_pcs(p):
    return [int(l, 16) for l in open(p) if l.strip()]

def main():
    a = mame_pcs(sys.argv[1]); b = rtl_pcs(sys.argv[2])
    start = int(sys.argv[3], 16) if len(sys.argv) > 3 else 0x13
    # align: skip the idle loop -- find the first PC outside 0x13..0x15 in each
    def first_work(seq):
        for i, pc in enumerate(seq):
            if not (0x13 <= pc <= 0x15): return i
        return None
    ia, ib = first_work(a), first_work(b)
    print(f"mame: {len(a)} pcs, first non-idle at #{ia} (pc {a[ia]:04x})" if ia is not None else f"mame: {len(a)} pcs, never leaves idle")
    print(f"rtl : {len(b)} pcs, first non-idle at #{ib} (pc {b[ib]:04x})" if ib is not None else f"rtl : {len(b)} pcs, never leaves idle")
    if ia is None or ib is None: return 1
    a, b = a[ia:], b[ib:]
    n = min(len(a), len(b))
    for k in range(n):
        if a[k] != b[k]:
            lo = max(0, k - 12)
            print(f"\nFIRST DIVERGENCE at instruction #{k} after leaving idle:")
            print("   idx   mame  rtl")
            for j in range(lo, min(n, k + 6)):
                mark = " <==" if j == k else ""
                print(f"  {j:6d}  {a[j]:04x}  {b[j]:04x}{mark}")
            return 2
    print(f"\nidentical for {n} instructions (mame has {len(a)}, rtl has {len(b)})")
    return 0

if __name__ == "__main__":
    sys.exit(main())
