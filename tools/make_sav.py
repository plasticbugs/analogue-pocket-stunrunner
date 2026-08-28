#!/usr/bin/env python3
"""Build a stunrun.sav (the core's 4 KB ZRAM image) from MAME's NVRAM files.

The 68k sees the 200E timekeeper on D15:8 and the 210E EEPROM on D7:0 of one
16-bit word, and that is the layout of the save file: byte 2w = 200E[w],
byte 2w+1 = 210E[w]. MAME keeps them as two 2 KB files under
nvram/stunrun/ (names `mainpcb_200e` and `mainpcb_210e`; the timekeeper file may carry an
extra 8-byte clock header depending on the MAME version -- the last 2048
bytes are the RAM).

    make_sav.py <mame nvram dir>/stunrun out.sav

A save made from a MAME session that has already run once skips the game's
factory EEPROM initialisation (several seconds of ZramService at first boot).
"""
import sys, os

def main():
    d, out = sys.argv[1], sys.argv[2]
    tk = open(os.path.join(d, "mainpcb_200e"), "rb").read()[-2048:]
    ee = open(os.path.join(d, "mainpcb_210e"), "rb").read()[-2048:]
    img = bytearray(4096)
    for w in range(2048):
        img[2*w] = tk[w]; img[2*w+1] = ee[w]
    open(out, "wb").write(img)
    print(f"wrote {out}: {len(img)} bytes")

if __name__ == "__main__":
    main()
