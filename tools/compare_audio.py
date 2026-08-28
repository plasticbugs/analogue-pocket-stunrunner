#!/usr/bin/env python3
"""JSA II board against MAME: the YM2151 register-write stream and the audio.

  python3 tools/compare_audio.py <rtl.wav> <mame.wav> <rtl_events.txt> <mame_events.txt> [seconds]

Event files are "time frame KIND value" lines (tools/trace_jsa.lua and the
bench write the same format). The register-write check is exact: the
sequence of (YM0/YM1, byte) writes must be identical -- it does not depend on
how the FM chip sounds, only on the 6502, its ROM/RAM, the latches and the
interrupt timing. The audio check is statistical: RMS per half-second window,
the ratio over windows where MAME is not silent, and the energy split into
three bands (a 4096-point FFT in plain Python).

Exit code 0 = PASS (register sequence identical, median envelope ratio within
+-1.5 dB), 1 otherwise.
"""
import sys, math, struct, cmath


def read_wav(path):
    w = open(path, 'rb').read()
    ch = struct.unpack_from('<H', w, 22)[0]
    rate = struct.unpack_from('<I', w, 24)[0]
    i = w.find(b'data')
    n = struct.unpack_from('<I', w, i + 4)[0]
    pcm = w[i + 8:i + 8 + n]
    s = struct.unpack('<%dh' % (n // 2), pcm)
    if ch > 1:
        s = s[::ch]
    return list(s), rate


def events(path, kinds):
    out = []
    for line in open(path):
        p = line.split()
        if len(p) >= 4 and p[2] in kinds:
            out.append((float(p[0]), p[2], int(p[3], 16)))
    return out


def fft(x):
    n = len(x)
    if n == 1:
        return x
    even = fft(x[0::2]); odd = fft(x[1::2])
    out = [0] * n
    for k in range(n // 2):
        t = cmath.exp(-2j * math.pi * k / n) * odd[k]
        out[k] = even[k] + t
        out[k + n // 2] = even[k] - t
    return out


def bands(sig, rate):
    """Energy in <500 Hz, 500-2000 Hz, >2000 Hz over 4096-sample blocks."""
    N = 4096
    e = [0.0, 0.0, 0.0]
    for b in range(0, len(sig) - N, N * 4):
        blk = [float(v) for v in sig[b:b + N]]
        X = fft(blk)
        for k in range(1, N // 2):
            f = k * rate / N
            p = abs(X[k]) ** 2
            e[0 if f < 500 else 1 if f < 2000 else 2] += p
    return e


def rms(x):
    return math.sqrt(sum(v * v for v in x) / max(1, len(x)))


def main():
    rtl_wav, mame_wav, rtl_ev, mame_ev = sys.argv[1:5]
    secs = float(sys.argv[5]) if len(sys.argv) > 5 else 30.0
    ok = True

    a = [e for e in events(rtl_ev, ('YM0', 'YM1')) if e[0] <= secs]
    b = [e for e in events(mame_ev, ('YM0', 'YM1')) if e[0] <= secs]
    print(f"YM2151 writes within {secs:.1f} s: rtl {len(a)}, mame {len(b)}")
    n = min(len(a), len(b)); first = None
    for i in range(n):
        if a[i][1:] != b[i][1:]:
            first = i; break
    if first is None and len(a) == len(b):
        print("  register/data sequence: IDENTICAL")
    else:
        i = first if first is not None else n
        print(f"  register/data sequence: FIRST DIFFERENCE at write #{i}: rtl {a[i] if i < len(a) else None}  mame {b[i] if i < len(b) else None}")
        ok = False
    if n:
        d = sorted(a[i][0] - b[i][0] for i in range(min(n, first or n)))
        print(f"  timing offset rtl-mame over the matching prefix: median {d[len(d)//2]*1e3:+.3f} ms, min {d[0]*1e3:+.3f}, max {d[-1]*1e3:+.3f}")

    for kind in ('WRIO', 'MIX', 'OKI', 'WRP'):
        x = [e[2] for e in events(rtl_ev, (kind,)) if e[0] <= secs]
        y = [e[2] for e in events(mame_ev, (kind,)) if e[0] <= secs]
        same = x == y
        print(f"  {kind:4s} writes: rtl {len(x)}, mame {len(y)}, {'identical' if same else 'DIFFERENT'}")
        if not same and kind != 'WRIO':
            ok = False

    r, rr = read_wav(rtl_wav); m, mr = read_wav(mame_wav)
    print(f"audio: rtl {len(r)/rr:.2f} s @ {rr} Hz, mame {len(m)/mr:.2f} s @ {mr} Hz")
    win = 0.5
    rows = []
    t = 0.0
    while t + win <= min(secs, len(r) / rr, len(m) / mr):
        ra = r[int(t * rr):int((t + win) * rr)]; mb = m[int(t * mr):int((t + win) * mr)]
        rows.append((t, rms(ra), rms(mb)))
        t += win
    active = [x for x in rows if x[2] > 100]
    ratios = sorted(x[1] / x[2] for x in active)
    print(f"  peak: rtl {max(abs(v) for v in r)}, mame {max(abs(v) for v in m)}")
    if ratios:
        med = ratios[len(ratios) // 2]
        print(f"  envelope ratio rtl/mame over {len(ratios)} active {win}s windows: median {med:.3f} ({20*math.log10(med):+.2f} dB), min {ratios[0]:.3f}, max {ratios[-1]:.3f}")
        if abs(20 * math.log10(med)) > 1.5:
            ok = False
    else:
        print("  MAME reference is silent in this range")
        if rms(r) > 100:
            ok = False
    print("  t(s)   rtl_rms  mame_rms")
    for t, x, y in rows[::4]:
        print(f"  {t:5.1f}  {x:8.0f}  {y:8.0f}")
    if active:
        t0 = active[0][0]; t1 = active[-1][0] + win
        er = bands(r[int(t0 * rr):int(t1 * rr)], rr); em = bands(m[int(t0 * mr):int(t1 * mr)], mr)
        tr = sum(er) or 1; tm = sum(em) or 1
        print("  band energy share  <500Hz  500-2k  >2k")
        print(f"    rtl  {er[0]/tr:6.3f} {er[1]/tr:6.3f} {er[2]/tr:6.3f}")
        print(f"    mame {em[0]/tm:6.3f} {em[1]/tm:6.3f} {em[2]/tm:6.3f}")
    print("PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
