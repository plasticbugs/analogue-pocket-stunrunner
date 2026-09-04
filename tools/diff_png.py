#!/usr/bin/env python3
"""Pixel diff of two PNGs of the same size (RTL snapshot vs MAME reference).
   usage: diff_png.py a.png b.png   -> prints differing-pixel count and the first few."""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from render_model import read_png
a = read_png(sys.argv[1]); b = read_png(sys.argv[2])
if len(a) != len(b) or len(a[0]) != len(b[0]):
    print(f"size mismatch: {len(a[0])}x{len(a)} vs {len(b[0])}x{len(b)}"); sys.exit(1)
diff = 0; first = []
for y in range(len(a)):
    for x in range(len(a[0])):
        if a[y][x] != b[y][x]:
            diff += 1
            if len(first) < 5: first.append((x, y, a[y][x], b[y][x]))
print(f"{sys.argv[1]} vs {sys.argv[2]}: {diff} differing pixels of {len(a)*len(a[0])}")
for f in first: print("  x=%d y=%d a=%s b=%s" % f)
sys.exit(1 if diff else 0)
