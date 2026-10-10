#!/usr/bin/env python3
"""Run a PDP-11 program on the bus model, capture the Unibus cycles as a
logic analyzer would, and check the inverse assembler listing:

  - every instruction fetch is decoded to the right instruction
  - no other cycle is shown as an instruction
"""
import os
import random
import sys

sys.path.insert(0, os.path.dirname(__file__))
from ialsim import Program, Analyzer                         # noqa: E402
from unibus_sim import (CPU, Asm, Halt, R, DEF, AINC, AINCD, ADEC, IDX,  # noqa: E402
                        IDXD, IMM, ABS, REL, RELD, SP, PC, INTR)

SRC = os.path.join(os.path.dirname(__file__), "..", "src", "IPDP11.S")
CYC = {0: "DATI ", 1: "DATIP", 2: "DATO ", 3: "DATOB"}


def program():
    a = Asm()
    # vectors
    a.org(0o30)
    a.word("emt_h", 0o340)
    a.org(0o100)
    a.word("clk_h", 0o340)

    a.org(0o2000)
    a.label("buf")
    a.word(1, 2, 3, 0o100004, 5, 6)
    a.label("sum")
    a.word(0)
    a.label("cnt")
    a.word(0)
    a.label("ticks")
    a.word(0)
    a.label("tbl")
    a.word("lab1", "lab2")
    a.label("ptr")
    a.word("sub1")
    a.label("arg")
    a.word(0o777)

    a.org(0o4000)
    a.label("start")
    a.dbl("MOV", IMM(0o1000), R(SP))
    a.dbl("MOV", IMM("buf"), R(1))
    a.dbl("MOV", IMM(5), R(2))
    a.label("loop")
    a.dbl("MOV", AINC(1), R(3))
    a.dbl("ADD", R(3), ABS("sum"))
    a.dbl("MOVB", IDX(1, 1), R(4))
    a.sgl("CLR", ADEC(SP))
    a.sgl("TST", AINC(SP))
    a.sgl("INC", REL("cnt"))
    a.dbl("BIT", IMM(1), R(3))
    a.br("BEQ", "even")
    a.sgl("COM", R(3))
    a.label("even")
    a.sob(2, "loop")
    a.jsr(PC, REL("sub1"))
    a.jsr(5, REL("sub2"))
    a.word("arg")
    a.dbl("MOV", IMM("tbl"), R(0))
    a.sgl("JMP", AINCD(0))                 # JMP @(R0)+  -> lab1
    a.label("lab1")
    a.jsr(PC, ABS("sub1"))
    a.dbl("MOV", IMM("lab2"), R(0))
    a.sgl("JMP", DEF(0))                   # JMP (R0)
    a.label("lab2")
    a.emt(0o17)
    a.jsr(PC, RELD("ptr"))                 # JSR PC,@ptr
    a.dbl("CMP", IMM(3), R(2))
    a.br("BNE", "fwd")
    a.op(0o000240)
    a.label("fwd")
    a.dbl("MOV", IMM(0o177777), R(0))
    a.xor(0, REL("cnt"))
    a.mul(IMM(3), 3)
    a.sgl("JMP", REL("lab3"))
    a.op(0o000000)                         # never executed
    a.label("lab3")
    a.dbl("MOV", IMM("ret1"), ADEC(SP))
    a.rts(PC)
    a.op(0o000000)
    a.label("ret1")
    a.dbl("MOV", IMM("rom"), R(0))
    a.sgl("JMP", DEF(0))                   # into the I/O page
    a.label("back")
    a.dbl("MOVB", REL("arg"), REL("cnt"))
    a.sgl("SWAB", REL("cnt"))
    a.sgl("ASL", IDX(1, -2))
    a.dbl("MOV", IMM("next"), R(0))
    a.dbl("MOV", R(0), R(PC))              # MOV R0,PC
    a.op(0o000000)
    a.label("next")
    a.dbl("MOV", IMM("done"), ADEC(SP))
    a.dbl("MOV", AINC(SP), R(PC))          # MOV (SP)+,PC
    a.label("done")
    a.br("BR", "start")

    a.label("sub1")
    a.sgl("INC", R(4))
    a.rts(PC)
    a.label("sub2")
    a.dbl("MOV", AINCD(5), R(0))           # MOV @(R5)+,R0
    a.rts(5)
    a.label("emt_h")
    a.dbl("ADD", IMM(2), R(4))
    a.op(0o000002)                         # RTI
    a.label("clk_h")
    a.sgl("INC", REL("ticks"))
    a.op(0o000002)

    a.org(0o173000)                        # code in the I/O page
    a.label("rom")
    a.dbl("MOV", IMM(4), R(1))
    a.label("rloop")
    a.sgl("DEC", R(1))
    a.br("BNE", "rloop")
    a.dbl("MOV", IMM("buf"), R(1))
    a.sgl("JMP", ABS("back"))
    return a


def run(ninstr, seed, vector_first, intr_cycle):
    rnd = random.Random(seed)
    cpu = CPU(trap_vector_first=vector_first)
    program().load(cpu)
    cpu.r[7] = 0o4000
    for i in range(ninstr):
        if i % 23 == 17:                          # clock interrupt
            cpu.interrupt(0o100, intr_cycle)
        if rnd.random() < 0.15:                   # DMA traffic
            for _ in range(rnd.randint(1, 3)):
                cpu.dma(0o40000 + 2 * rnd.randint(0, 100), rnd.random() < 0.5)
        try:
            cpu.step()
        except Halt as e:
            print("halt:", e)
            break
    return cpu


def check(cpu, verbose=False):
    prog = Program(open(SRC).read())
    first = min(cpu.fetches)
    an = Analyzer(prog, cpu.cycles)
    an.sync(first)
    errors = 0
    rows = []
    for i, (addr, data, stat) in enumerate(cpu.cycles):
        text, rf = an.call(i)
        if an.states[i].sys:
            an.states[i].sys = 2 | rf
            if i + 1 < len(an.states) and an.states[i + 1].sys == 0:
                an.states[i + 1].sys = 1
        want = cpu.fetches.get(i)
        if i < first:
            ok = rf == 0
        elif want is not None:
            ok = text == want and rf == 1
        else:
            ok = rf == 0
        cyc = "INTR " if stat & INTR else CYC[stat & 3]
        rows.append("%5d %06o %06o %s  %-34s %s" % (i, addr, data, cyc, text,
                                                    "" if ok else "<-- want %r" % want))
        errors += not ok
    if verbose or errors:
        print("\n".join(rows if verbose else [r for r in rows if "<--" in r][:40]))
    return errors, len(cpu.cycles), len(cpu.fetches)


def main():
    verbose = "-v" in sys.argv
    total = 0
    for seed, vf, ic in [(1, True, True), (2, False, True), (3, True, False), (4, False, False)]:
        cpu = run(400, seed, vf, ic)
        err, ncyc, nf = check(cpu, verbose and seed == 1)
        print("seed %d vector_first=%s intr_cycle=%s: %d cycles, %d instructions, %d errors"
              % (seed, vf, ic, ncyc, nf, err))
        total += err
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
