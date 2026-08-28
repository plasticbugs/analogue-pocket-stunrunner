#!/usr/bin/env python3
"""Compare a raw RGB frame (512x240x3, from the RTL bench) with a PNG (the
reference renderer's *_model.png or a MAME snapshot). Prints the number of
differing pixels, the first few, and writes a diff image.

    diff_frames.py <frame.rgb> <reference.png> [diff.png]
"""
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from render_model import read_png, write_png

def main():
    raw = open(sys.argv[1], "rb").read()
    ref = read_png(sys.argv[2])
    h, w = len(ref), len(ref[0])
    # the RTL frame is always 512x240; a reference with fewer lines (an early
    # boot state with VSBLNK < 0x103) is compared over its own height
    if len(raw) < w * h * 3 or w != 512:
        print(f"size mismatch: raw {len(raw)} bytes vs {w}x{h}x3"); return 1
    diff = 0; first = []; dimg = []
    for y in range(h):
        row = []
        for x in range(w):
            o = (y * w + x) * 3
            px = (raw[o], raw[o+1], raw[o+2])
            if px != ref[y][x]:
                diff += 1
                if len(first) < 8: first.append((x, y, px, ref[y][x]))
                row.append((255, 0, 255))
            else:
                v = sum(px) // 6; row.append((v, v, v))
        dimg.append(row)
    if len(sys.argv) > 3:
        write_png(sys.argv[3], dimg)
    print(f"{sys.argv[1]} vs {sys.argv[2]}: {diff} differing pixels of {w*h}")
    for f in first: print("  x=%d y=%d rtl=%s ref=%s" % f)
    return 0 if diff == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
