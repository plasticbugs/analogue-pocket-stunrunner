#!/usr/bin/env python3
"""Instruction-class coverage of an ADSP-2100 MAME trace.

    adsp_coverage.py <adsp_start.txt> <trace.txt> [<trace.txt> ...]

Reads the program memory dump from adsp_start.txt, looks up the opcode of every
traced PC and tallies the instruction classes of MAME's decoder (switch on the
top opcode byte), plus the ALU / MAC / shifter function codes, the condition
codes and the register groups the trace exercised.
"""
import sys, re, collections

CLASSES = [
    (0x00, 0x00, "NOP"), (0x01, 0x01, "IO (218x only)"), (0x02, 0x02, "modify flag out / IDLE"),
    (0x03, 0x03, "jump/call on FLAG_IN"), (0x04, 0x04, "stack control"), (0x05, 0x05, "SAT MR"),
    (0x06, 0x06, "DIVS"), (0x07, 0x07, "DIVQ"), (0x08, 0x08, "reserved"), (0x09, 0x09, "MODIFY"),
    (0x0a, 0x0a, "cond RTS/RTI"), (0x0b, 0x0b, "cond jump/call indirect"), (0x0c, 0x0c, "mode control"),
    (0x0d, 0x0d, "internal data move"), (0x0e, 0x0e, "cond shift"), (0x0f, 0x0f, "shift immediate"),
    (0x10, 0x10, "shift + reg move"), (0x11, 0x11, "shift + PM read/write"), (0x12, 0x12, "shift + DM DAG1"),
    (0x13, 0x13, "shift + DM DAG2"), (0x14, 0x17, "DO UNTIL"), (0x18, 0x1b, "cond jump imm"),
    (0x1c, 0x1f, "cond call imm"), (0x20, 0x21, "cond MAC->MR"), (0x22, 0x23, "cond ALU->AR"),
    (0x24, 0x25, "cond MAC->MF"), (0x26, 0x27, "cond ALU->AF"), (0x28, 0x29, "MAC->MR + move"),
    (0x2a, 0x2b, "ALU->AR + move"), (0x2c, 0x2d, "MAC->MF + move"), (0x2e, 0x2f, "ALU->AF + move"),
    (0x30, 0x33, "load reg group0 imm14"), (0x34, 0x37, "load reg group1 imm14"), (0x38, 0x3b, "load reg group2 imm14"),
    (0x3c, 0x3f, "load reg group3 imm14"), (0x40, 0x4f, "load data reg imm16"),
    (0x50, 0x57, "unit + PM read"), (0x58, 0x5f, "unit + PM write"),
    (0x60, 0x67, "unit + DM read DAG1"), (0x68, 0x6f, "unit + DM write DAG1"),
    (0x70, 0x77, "unit + DM read DAG2"), (0x78, 0x7f, "unit + DM write DAG2"),
    (0x80, 0x8f, "DM read imm addr -> reg"), (0x90, 0x9f, "DM write imm addr <- reg"),
    (0xa0, 0xaf, "DM write imm data DAG1"), (0xb0, 0xbf, "DM write imm data DAG2"),
    (0xc0, 0xff, "dual fetch (ALU/MAC + DM + PM)"),
]
ALU_FN = ["Y", "Y+1", "X+Y+C", "X+Y", "NOT Y", "-Y", "X-Y+C-1", "X-Y", "Y-1", "Y-X", "Y-X+C-1", "NOT X", "X AND Y", "X OR Y", "X XOR Y", "ABS X"]
MAC_FN = ["nop", "X*Y RND", "MR+X*Y RND", "MR-X*Y RND", "X*Y SS", "X*Y SU", "X*Y US", "X*Y UU", "MR+X*Y SS", "MR+X*Y SU", "MR+X*Y US", "MR+X*Y UU", "MR-X*Y SS", "MR-X*Y SU", "MR-X*Y US", "MR-X*Y UU"]
SH_FN = ["LSHIFT HI", "LSHIFT HI OR", "LSHIFT LO", "LSHIFT LO OR", "ASHIFT HI", "ASHIFT HI OR", "ASHIFT LO", "ASHIFT LO OR", "NORM HI", "NORM HI OR", "NORM LO", "NORM LO OR", "EXP HI", "EXP HIX", "EXP LO", "EXPADJ"]
COND = ["EQ", "NE", "GT", "LE", "LT", "GE", "AV", "NOT AV", "AC", "NOT AC", "NEG", "POS", "MV", "NOT MV", "CE", "TRUE"]


def load_pmem(path):
    pm = []
    with open(path) as f:
        mode = None
        for line in f:
            line = line.strip()
            if line == "PMEM": mode = "p"; continue
            if line == "DMEM": mode = "d"; continue
            if mode == "p": pm.append(int(line, 16))
    return pm


def main():
    pm = load_pmem(sys.argv[1])
    cls = collections.Counter(); alu = collections.Counter(); mac = collections.Counter()
    sh = collections.Counter(); cond = collections.Counter(); grp = collections.Counter()
    pcs = collections.Counter()
    pat = re.compile(r'(?:^|\s)([0-9A-F]{4}): ')
    n = 0
    for tf in sys.argv[2:]:
        with open(tf) as f:
            for line in f:
                m = pat.search(line)
                if not m: continue
                pc = int(m.group(1), 16)
                op = pm[pc] if pc < len(pm) else 0
                n += 1
                pcs[pc] += 1
                top = op >> 16
                for lo, hi, name in CLASSES:
                    if lo <= top <= hi: cls[name] += 1; break
                fn = (op >> 13) & 15
                is_alu = (0x22 <= top <= 0x23) or (0x26 <= top <= 0x27) or (top in (0x2a, 0x2b, 0x2e, 0x2f)) or \
                         (0x50 <= top <= 0x7f and top & 2) or (top >= 0xc0 and top & 2)
                is_mac = (0x20 <= top <= 0x21) or (0x24 <= top <= 0x25) or (top in (0x28, 0x29, 0x2c, 0x2d)) or \
                         (0x50 <= top <= 0x7f and not top & 2) or (top >= 0xc0 and not top & 2)
                if is_alu: alu[ALU_FN[fn]] += 1
                if is_mac: mac[MAC_FN[fn]] += 1
                if top in (0x0e, 0x0f, 0x10, 0x11, 0x12, 0x13): sh[SH_FN[(op >> 11) & 15]] += 1
                if top in (0x0a, 0x0b, 0x0e) or 0x18 <= top <= 0x27 or top == 0x02: cond[COND[op & 15]] += 1
                if top == 0x0d: grp["move g%d->g%d" % ((op >> 8) & 3, (op >> 10) & 3)] += 1
                if 0x30 <= top <= 0x3f: grp["imm14 -> g%d" % ((top >> 2) & 3)] += 1
                if 0x80 <= top <= 0x8f: grp["DM imm -> g%d" % ((top >> 2) & 3)] += 1
                if 0x90 <= top <= 0x9f: grp["g%d -> DM imm" % ((top >> 2) & 3)] += 1
    print(f"instructions traced: {n}, distinct PCs: {len(pcs)}")
    def show(title, c, universe=None):
        print(f"\n{title}")
        keys = universe if universe else [k for k, _ in c.most_common()]
        for k in keys:
            print(f"  {c.get(k, 0):9d}  {k}")
        if universe:
            missing = [k for k in universe if c.get(k, 0) == 0]
            if missing: print("  NOT EXERCISED:", ", ".join(missing))
    show("instruction classes", cls, [name for _, _, name in CLASSES])
    show("ALU functions", alu, ALU_FN)
    show("MAC functions", mac, MAC_FN)
    show("shifter functions", sh, SH_FN)
    show("condition codes", cond, COND)
    show("register-group moves", grp)


if __name__ == "__main__":
    main()
