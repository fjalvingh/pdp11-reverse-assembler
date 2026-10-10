#!/usr/bin/env python3
"""Decode every 16-bit opcode with the IAL inverse assembler and compare it
with the reference disassembler."""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from ialsim import Program, Analyzer          # noqa: E402
from pdp11dis import disasm                   # noqa: E402

SRC = os.path.join(os.path.dirname(__file__), "..", "src", "IPDP11.S")
DATI = 0


def main():
    prog = Program(open(SRC).read())
    a = 0o001000
    w1, w2 = 0o012345, 0o154321
    step = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    bad = 0
    for opc in range(0, 0o200000, step):
        trace = [(a, opc, DATI), (a + 2, w1, DATI), (a + 4, w2, DATI),
                 (a + 6, 0o000240, DATI)]
        an = Analyzer(prog, trace)
        an.sync(0)
        got, rf = an.call(0)
        want = disasm(a, opc, [w1, w2])
        if got != want or rf != 1:
            bad += 1
            if bad <= 30:
                print("%06o  got %-30r want %r rf=%d" % (opc, got, want, rf))
    print("opcodes checked: %d  mismatches: %d" % (len(range(0, 0o200000, step)), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
