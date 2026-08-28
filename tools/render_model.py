#!/usr/bin/env python3
"""Reference renderer: re-create a MAME frame from a dumped GSP state.

Reads the state dump written by tools/dumpstate.lua (IO registers, palette,
control latches, 512 KB VRAM) and produces the 512x240 frame exactly as
harddriv_v.cpp::scanline_multisync + tms34010.cpp's DPYADR bookkeeping would,
then diffs it against the MAME snapshot PNG taken at the same frame.

    render_model.py <state.txt> <state.vram> <mame.png> [out_prefix]

Writes <out_prefix>_model.png and <out_prefix>_diff.png and prints the number
of differing pixels. Pure Python (zlib only).
"""
import sys, zlib, struct

REG = ["HESYNC","HEBLNK","HSBLNK","HTOTAL","VESYNC","VEBLNK","VSBLNK","VTOTAL",
       "DPYCTL","DPYSTRT","DPYINT","CONTROL","HSTDATA","HSTADRL","HSTADRH","HSTCTLL",
       "HSTCTLH","INTENB","INTPEND","CONVSP","CONVDP","PSIZE","PMASK","U23","U24","U25","U26",
       "DPYTAP","HCOUNT","VCOUNT","DPYADR","REFCNT"]


def read_state(path):
    st = {"io": {}, "pal": [], "ctllo": []}
    sec = None
    with open(path) as f:
        for line in f:
            t = line.split()
            if not t:
                continue
            if t[0] in ("IOREGS", "PALETTE", "CTLLO"):
                sec = t[0]; idx = 0; continue
            if t[0] in ("PALBANK", "FINESCROLL", "SHIFTREG"):
                st[t[0].lower()] = int(t[1]); continue
            if sec == "IOREGS":
                st["io"][REG[idx]] = int(t[0], 16); idx += 1
            elif sec == "PALETTE":
                lo, hi = int(t[0], 16), int(t[1], 16)
                st["pal"].append(((lo >> 8) & 0xff, lo & 0xff, hi & 0xff))
            elif sec == "CTLLO":
                st["ctllo"].append(int(t[0], 16))
    return st


def render(st, vram):
    """Return list of rows, each a list of (r,g,b), for the visible lines."""
    io = st["io"]
    pixperclock = 2
    heblnk, hsblnk = io["HEBLNK"] * pixperclock, io["HSBLNK"] * pixperclock
    veblnk, vsblnk = io["VEBLNK"], io["VSBLNK"]
    dpyctl, dpystrt, dpytap = io["DPYCTL"], io["DPYSTRT"], io["DPYTAP"]
    fine = st.get("finescroll", 0) & 7
    palbase = st.get("palbank", 0) * 256
    vram_mask = len(vram) // 2 - 1
    # DPYADR is loaded from DPYSTRT at VSBLNK and stepped once per visible
    # line in tms34010's scanline_callback, *after* the line is drawn.
    dpyadr = dpystrt
    rows = []
    width = hsblnk - heblnk
    for y in range(veblnk, vsblnk):
        a = dpyadr if (dpyctl & 0x0400) else (dpyadr ^ 0xfffc)
        rowaddr = a >> 4
        coladdr = ((a & 0x007c) << 4) | (dpytap & 0x3fff)
        yoffset = (dpystrt - dpyadr) & 3
        base = (rowaddr << 10) & vram_mask          # 16-bit word index
        col = (yoffset << 9) + ((coladdr & 0xff) << 3) - 7 + fine
        row = []
        for x in range(width):
            ci = (col + x) & 0x7ff
            w = base + (ci >> 1)
            b = vram[w * 2 + 1] if (ci & 1) else vram[w * 2]
            row.append(st["pal"][palbase + b])
        rows.append(row)
        # advance for the next line
        if (dpyadr & 3) == 0:
            dpyadr = (((dpyadr & 0xfffc) - (dpyctl & 0x03fc)) & 0xffff) | (dpystrt & 3)
        else:
            dpyadr = (dpyadr & 0xfffc) | ((dpyadr - 1) & 3)
    return rows


# ---- minimal PNG I/O -------------------------------------------------------
def read_png(path):
    d = open(path, "rb").read()
    assert d[:8] == b"\x89PNG\r\n\x1a\n"
    p = 8; w = h = 0; idat = b""; bitdepth = 8; ctype = 2; plte = None
    while p < len(d):
        n = struct.unpack(">I", d[p:p+4])[0]; typ = d[p+4:p+8]; body = d[p+8:p+8+n]
        if typ == b"IHDR":
            w, h, bitdepth, ctype = struct.unpack(">IIBB", body[:10])
        elif typ == b"PLTE":
            plte = [tuple(body[i:i+3]) for i in range(0, len(body), 3)]
        elif typ == b"IDAT":
            idat += body
        p += 12 + n
    raw = zlib.decompress(idat)
    bpp = {2: 3, 6: 4, 3: 1, 0: 1}[ctype]
    stride = w * bpp
    rows = []; prev = bytearray(stride); p = 0
    for _ in range(h):
        ft = raw[p]; line = bytearray(raw[p+1:p+1+stride]); p += 1 + stride
        for i in range(stride):
            a = line[i-bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i-bpp] if i >= bpp else 0
            if ft == 1: line[i] = (line[i] + a) & 0xff
            elif ft == 2: line[i] = (line[i] + b) & 0xff
            elif ft == 3: line[i] = (line[i] + ((a + b) >> 1)) & 0xff
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2*c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        prev = line
        if ctype == 3:
            rows.append([plte[v] for v in line])
        else:
            rows.append([tuple(line[i*bpp:i*bpp+3]) for i in range(w)])
    return rows


def write_png(path, rows):
    h = len(rows); w = len(rows[0])
    raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in rows)
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    st = read_state(sys.argv[1])
    vram = open(sys.argv[2], "rb").read()
    ref = read_png(sys.argv[3])
    prefix = sys.argv[4] if len(sys.argv) > 4 else "out"
    model = render(st, vram)
    write_png(prefix + "_model.png", model)
    if len(model) != len(ref) or len(model[0]) != len(ref[0]):
        print(f"size mismatch: model {len(model[0])}x{len(model)} vs mame {len(ref[0])}x{len(ref)}")
    diff = 0; dimg = []
    for y in range(min(len(model), len(ref))):
        drow = []
        for x in range(min(len(model[0]), len(ref[0]))):
            if model[y][x] != ref[y][x]:
                diff += 1; drow.append((255, 0, 255))
            else:
                v = sum(ref[y][x]) // 6; drow.append((v, v, v))
        dimg.append(drow)
    write_png(prefix + "_diff.png", dimg)
    print(f"{sys.argv[1]}: {diff} differing pixels of {len(model)*len(model[0])}")
    return 0 if diff == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
