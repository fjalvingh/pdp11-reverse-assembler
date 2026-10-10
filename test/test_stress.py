#!/usr/bin/env python3
"""Longer randomized runs of the test program: DMA traffic, interrupts at
low and high vectors, both trap cycle orders, with and without the INTR
signal probed.  Reports the fraction of wrongly displayed lines and the
largest number of IAL instructions executed for one state (the analyzer
aborts a state after MAX_INSTRUCTION)."""
import contextlib
import io
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
import ialsim                                  # noqa: E402
import test_trace                              # noqa: E402
from unibus_sim import CPU                     # noqa: E402

MAXCOUNT = [0]
_exec1 = ialsim.Run.exec1
_run = ialsim.Run.run


def _counting_run(self):
    self.count = 0
    _run(self)
    MAXCOUNT[0] = max(MAXCOUNT[0], self.count)


def _counting_exec1(self, *a):
    self.count += 1
    return _exec1(self, *a)


ialsim.Run.run = _counting_run
ialsim.Run.exec1 = _counting_exec1


def run(n, seed, vector_first, intr_cycle, vec, dmarate):
    rnd = random.Random(seed)
    cpu = CPU(trap_vector_first=vector_first)
    a = test_trace.program()
    a.org(vec)
    a.word("clk_h", 0o340)
    a.load(cpu)
    cpu.r[7] = 0o4000
    for i in range(n):
        if i % 23 == 17:
            cpu.interrupt(vec, intr_cycle)
        if rnd.random() < dmarate:
            for _ in range(rnd.randint(1, 4)):
                cpu.dma(0o40000 + 2 * rnd.randint(0, 4000), rnd.random() < 0.5)
        cpu.step()
    return cpu


def main():
    runs = int(sys.argv[1]) if len(sys.argv) > 1 else 10
    worst = 0.0
    for label, vec, rate in [("vector 100, DMA 15%", 0o100, .15),
                             ("vector 100, DMA 40%", 0o100, .40),
                             ("vector 420, DMA 15%", 0o420, .15),
                             ("vector 770, DMA 15%", 0o770, .15)]:
        errs = instr = 0
        for seed in range(runs):
            cpu = run(1000, seed, seed % 2 == 0, seed % 3 != 0, vec, rate)
            with contextlib.redirect_stdout(io.StringIO()):
                e, _, nf = test_trace.check(cpu)
            errs += e
            instr += nf
        pct = 100.0 * errs / instr
        worst = max(worst, pct)
        print("%-22s %3d runs %6d instructions %5d wrong lines (%.2f%%)"
              % (label, runs, instr, errs, pct))
    print("most IAL instructions executed for one state: %d" % MAXCOUNT[0])
    return 0 if worst < 0.5 else 1


if __name__ == "__main__":
    sys.exit(main())
