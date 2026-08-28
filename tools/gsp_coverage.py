#!/usr/bin/env python3
"""Opcode coverage of the TMS34010 trace windows.

    tools/gsp_coverage.py artifacts/gsp/w1.trace artifacts/gsp/w2.trace ...

Prints, per mnemonic (with the addressing-mode shape of the operands), how
many times the game executed it across the given MAME traces. The bench
(sim/run_gsp.sh) checks every one of these executions against the RTL, so the
table is also the list of what has been verified.
"""
import re, sys, collections

def shape(operands):
    # collapse register numbers and immediates so MOVE *A3+,A4,1 and MOVE *A0+,A1,1 count together
    s = re.sub(r'[0-9A-F]{4,8}h', 'imm', operands)
    s = re.sub(r'\bA1[0-4]\b|\bA[0-9]\b', 'An', s)
    s = re.sub(r'\bB1[0-4]\b|\bB[0-9]\b', 'Bn', s)
    s = re.sub(r'\bSP\b', 'An', s)
    s = re.sub(r'\b[0-9A-F]+h\b', 'k', s)
    s = re.sub(r'\b\d+\b', 'k', s)
    return s.strip()

def main():
    total = collections.Counter()
    bymnem = collections.Counter()
    n = 0
    for path in sys.argv[1:]:
        with open(path, errors='replace') as f:
            for line in f:
                m = re.match(r'[0-9A-F]{8}: (\S+)\s*(.*)$', line)
                if not m:
                    continue
                mnem, ops = m.group(1), m.group(2)
                total[(mnem, shape(ops))] += 1
                bymnem[mnem] += 1
                n += 1
    print(f"{n} instruction executions in {len(sys.argv) - 1} trace(s), {len(bymnem)} mnemonics, {len(total)} mnemonic/operand shapes\n")
    print(f"{'mnemonic':10s} {'count':>9s}")
    for k, v in bymnem.most_common():
        print(f"{k:10s} {v:9d}")
    print()
    print(f"{'shape':40s} {'count':>9s}")
    for (k, sh), v in sorted(total.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"{(k + ' ' + sh):40s} {v:9d}")

if __name__ == '__main__':
    main()
