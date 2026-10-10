"""Minimal PDP-11 CPU model that records the Unibus cycles it performs,
used to generate realistic logic analyzer traces for the tests.

Not a complete or cycle-exact PDP-11: it implements the instructions used
by the test programs, with the bus cycles a non-cached, non-prefetching
Unibus CPU (11/04, 11/34, 11/40 ...) makes.
"""
from pdp11dis import disasm, length

DATI, DATIP, DATO, DATOB = 0, 1, 2, 3
INTR = 4                                   # STAT bit 2
M16 = 0xFFFF


def phys(va):
    """18 bit Unibus address with memory management off."""
    va &= M16
    return va | 0o600000 if va >= 0o160000 else va


class Halt(Exception):
    pass


class CPU:
    def __init__(self, trap_vector_first=True):
        self.mem = {}                      # physical word address -> word
        self.r = [0] * 8
        self.ps = 0o340
        self.cycles = []                   # (addr, data, stat)
        self.fetches = {}                  # cycle index -> expected text
        self.vector_first = trap_vector_first

    # memory ----------------------------------------------------------
    def load(self, addr, words):
        for i, w in enumerate(words):
            self.mem[phys(addr + 2 * i)] = w & M16

    def peek(self, va):
        return self.mem.get(phys(va) & ~1, 0)

    def read(self, va, byte=False, ctype=DATI):
        pa = phys(va)
        w = self.mem.get(pa & ~1, 0)
        self.cycles.append((pa, w, ctype))
        if byte:
            return (w >> 8) & 0xFF if pa & 1 else w & 0xFF
        if pa & 1:
            raise Halt("odd address %06o" % va)
        return w

    def write(self, va, v, byte=False):
        pa = phys(va)
        if byte:
            v &= 0xFF
            w = self.mem.get(pa & ~1, 0)
            w = (w & 0xFF) | (v << 8) if pa & 1 else (w & 0xFF00) | v
            self.mem[pa & ~1] = w
            self.cycles.append((pa, v << 8 if pa & 1 else v, DATOB))
        else:
            self.mem[pa] = v & M16
            self.cycles.append((pa, v & M16, DATO))

    def fetchw(self):
        w = self.read(self.r[7])
        self.r[7] = (self.r[7] + 2) & M16
        return w

    def push(self, v):
        self.r[6] = (self.r[6] - 2) & M16
        self.write(self.r[6], v)

    def pop(self):
        v = self.read(self.r[6])
        self.r[6] = (self.r[6] + 2) & M16
        return v

    # operands ----------------------------------------------------------
    def addr(self, field, byte):
        mode, reg = field >> 3, field & 7
        inc = 1 if byte and reg < 6 else 2
        r = self.r
        if mode == 1:
            return r[reg]
        if mode == 2:
            a = r[reg]
            r[reg] = (a + inc) & M16
            return a
        if mode == 3:
            a = r[reg]
            r[reg] = (a + 2) & M16
            return self.read(a)
        if mode == 4:
            r[reg] = (r[reg] - inc) & M16
            return r[reg]
        if mode == 5:
            r[reg] = (r[reg] - 2) & M16
            return self.read(r[reg])
        x = self.fetchw()
        a = (x + r[reg]) & M16
        return a if mode == 6 else self.read(a)

    def get(self, field, byte):
        if field >> 3 == 0:
            v = self.r[field & 7]
            return v & 0xFF if byte else v
        return self.read(self.addr(field, byte), byte)

    def rmw(self, field, byte, fn):
        """Read-modify-write destination (DATIP + DATO)."""
        if field >> 3 == 0:
            reg = field & 7
            old = self.r[reg] & (0xFF if byte else M16)
            new = fn(old)
            if byte:
                self.r[reg] = (self.r[reg] & 0xFF00) | (new & 0xFF)
            else:
                self.r[reg] = new & M16
            return
        a = self.addr(field, byte)
        old = self.read(a, byte, DATIP)
        self.write(a, fn(old), byte)

    def put(self, field, byte, v):
        if field >> 3 == 0:
            reg = field & 7
            if byte:
                v = v & 0xFF
                v = v | 0xFF00 if v & 0x80 else v      # MOVB to register sign extends
            self.r[reg] = v & M16
            return
        self.write(self.addr(field, byte), v, byte)

    # flags -------------------------------------------------------------
    def nz(self, v, byte, v_flag=0, c=None):
        m = 0xFF if byte else M16
        sign = 0x80 if byte else 0x8000
        v &= m
        ps = self.ps & ~0o17
        if v & sign:
            ps |= 8
        if v == 0:
            ps |= 4
        if v_flag:
            ps |= 2
        if c is None:
            ps |= self.ps & 1
        elif c:
            ps |= 1
        self.ps = ps
        return v

    def cond(self, code):
        n, z, v, c = (self.ps >> 3) & 1, (self.ps >> 2) & 1, (self.ps >> 1) & 1, self.ps & 1
        return [None, True, not z, z, not (n ^ v), bool(n ^ v), not (z or (n ^ v)),
                bool(z or (n ^ v)), not n, bool(n), not (c or z), bool(c or z), not v,
                bool(v), not c, bool(c)][code]

    # traps -------------------------------------------------------------
    def trap(self, vec):
        ops, opc = self.ps, self.r[7]
        if self.vector_first:
            npc = self.read(vec)
            nps = self.read(vec + 2)
            self.push(ops)
            self.push(opc)
        else:
            self.push(ops)
            self.push(opc)
            npc = self.read(vec)
            nps = self.read(vec + 2)
        self.r[7], self.ps = npc, nps

    def interrupt(self, vec, intr_cycle=True):
        if intr_cycle:
            self.cycles.append((0, vec, INTR))
        self.trap(vec)

    def dma(self, addr, write=False, data=0o125252):
        if write:
            self.mem[addr & ~1] = data
            self.cycles.append((addr, data, DATO))
        else:
            self.cycles.append((addr, self.mem.get(addr & ~1, 0), DATI))

    # execution ---------------------------------------------------------
    def step(self):
        pc = self.r[7]
        opc = self.peek(pc)
        n = length(opc)
        words = [self.peek(pc + 2 * i) for i in range(1, n)]
        self.fetches[len(self.cycles)] = disasm(phys(pc), opc, words)
        self.fetchw()
        self.execute(opc)

    def execute(self, opc):
        r = self.r
        top = opc >> 12
        byte = bool(opc & 0x8000)
        ss, dd = (opc >> 6) & 0o77, opc & 0o77
        m = 0xFF if byte else M16
        if top & 7 in (1, 2, 3, 4, 5) or top in (6, 0o16):
            op = top & 7
            if top == 0o16:
                op = 7
            s = self.get(ss, byte)
            if op == 1:                                  # MOV
                self.nz(s, byte, 0, None)
                self.put(dd, byte, s)
            elif op == 2:                                # CMP
                d = self.get(dd, byte)
                res = (s - d) & m
                sign = 0x80 if byte else 0x8000
                v = ((s ^ d) & (s ^ res) & sign) != 0
                self.nz(res, byte, v, s < d)
            elif op == 3:                                # BIT
                self.nz(s & self.get(dd, byte), byte, 0, None)
            elif op == 4:                                # BIC
                self.rmw(dd, byte, lambda d: self.nz(d & ~s, byte, 0, None))
            elif op == 5:                                # BIS
                self.rmw(dd, byte, lambda d: self.nz(d | s, byte, 0, None))
            elif op == 6:                                # ADD
                self.rmw(dd, False, lambda d: self.nz(d + s, False, 0, d + s > M16))
            else:                                        # SUB
                self.rmw(dd, False, lambda d: self.nz(d - s, False, 0, d < s))
            return
        if top == 0o07:
            sub = (opc >> 9) & 7
            reg = (opc >> 6) & 7
            if sub == 0:                                 # MUL
                s = self.get(dd, False)
                res = (r[reg] * s) & 0xFFFFFFFF
                r[reg], r[reg | 1] = (res >> 16) & M16, res & M16
                return
            if sub == 4:                                 # XOR
                self.rmw(dd, False, lambda d: self.nz(d ^ r[reg], False, 0, None))
                return
            if sub == 7:                                 # SOB
                r[reg] = (r[reg] - 1) & M16
                if r[reg]:
                    r[7] = (r[7] - 2 * (opc & 0o77)) & M16
                return
            raise Halt("unimplemented %06o" % opc)
        hi = (opc >> 8) & 0o17
        if hi < 8 and (byte or hi):                      # branches
            code = hi + (8 if byte else 0)
            if self.cond(code):
                off = opc & 0o377
                off = off - 0o400 if off & 0o200 else off
                r[7] = (r[7] + 2 * off) & M16
            return
        if byte and hi == 8:
            return self.trap(0o30)
        if byte and hi == 9:
            return self.trap(0o34)
        q = (opc >> 6) & 3
        if not byte and hi == 0:
            if q == 0:
                if opc == 0:
                    raise Halt("HALT")
                if opc in (2, 6):                        # RTI RTT
                    r[7] = self.pop()
                    self.ps = self.pop()
                    return
                if opc == 3:
                    return self.trap(0o14)
                if opc == 4:
                    return self.trap(0o20)
                if opc in (1, 5):                        # WAIT RESET
                    return
                raise Halt("unimplemented %06o" % opc)
            if q == 1:                                   # JMP
                r[7] = self.addr(dd, False)
                return
            if q == 3:                                   # SWAB
                def swab(d):
                    v = ((d >> 8) | (d << 8)) & M16
                    self.nz(v & 0xFF, True, 0, 0)
                    return v
                self.rmw(dd, False, swab)
                return
            sub = (opc >> 3) & 7
            if sub == 0:                                 # RTS
                reg = opc & 7
                r[7] = r[reg]
                r[reg] = self.pop()
                return
            if sub >= 4:                                 # condition codes
                bits = opc & 0o17
                self.ps = self.ps | bits if opc & 0o20 else self.ps & ~bits
                return
            raise Halt("unimplemented %06o" % opc)
        if not byte and hi in (8, 9):                    # JSR
            reg = (opc >> 6) & 7
            a = self.addr(dd, False)
            self.push(r[reg])
            r[reg] = r[7]
            r[7] = a
            return
        if hi == 10 or hi == 11 or hi == 12:
            idx = (hi - 10) * 4 + q
            sign = 0x80 if byte else 0x8000
            if idx == 0:                                 # CLR
                if dd >> 3:
                    self.rmw(dd, byte, lambda d: self.nz(0, byte, 0, 0))
                else:
                    self.put(dd, byte, self.nz(0, byte, 0, 0))
                return
            if idx == 7:                                 # TST
                self.nz(self.get(dd, byte), byte, 0, 0)
                return
            fns = {
                1: lambda d: self.nz(~d, byte, 0, 1),                       # COM
                2: lambda d: self.nz(d + 1, byte, (d & m) == sign - 1, None),  # INC
                3: lambda d: self.nz(d - 1, byte, (d & m) == sign, None),      # DEC
                4: lambda d: self.nz(-d, byte, (d & m) == sign, (d & m) != 0),  # NEG
                5: lambda d: self.nz(d + (self.ps & 1), byte, 0, None),        # ADC
                6: lambda d: self.nz(d - (self.ps & 1), byte, 0, None),        # SBC
                8: lambda d: self.nz((d >> 1) | ((self.ps & 1) * sign), byte, 0, d & 1),  # ROR
                9: lambda d: self.nz((d << 1) | (self.ps & 1), byte, 0, d & sign),        # ROL
                10: lambda d: self.nz((d >> 1) | (d & sign), byte, 0, d & 1),             # ASR
                11: lambda d: self.nz(d << 1, byte, 0, d & sign),                         # ASL
            }
            self.rmw(dd, byte, fns[idx])
            return
        if not byte and hi == 13 and q == 3:             # SXT
            self.put(dd, False, M16 if self.ps & 8 else 0)
            return
        raise Halt("unimplemented %06o" % opc)


# ---------------------------------------------------------------------------
# A tiny two-pass assembler for the test programs
# ---------------------------------------------------------------------------
class Op:
    def __init__(self, field, word=None, kind=None):
        self.field, self.word, self.kind = field, word, kind


def R(n): return Op(n)
def DEF(n): return Op(0o10 | n)
def AINC(n): return Op(0o20 | n)
def AINCD(n): return Op(0o30 | n)
def ADEC(n): return Op(0o40 | n)
def ADECD(n): return Op(0o50 | n)
def IDX(n, x): return Op(0o60 | n, x, "val")
def IDXD(n, x): return Op(0o70 | n, x, "val")
def IMM(v): return Op(0o27, v, "val")
def ABS(a): return Op(0o37, a, "val")
def REL(a): return Op(0o67, a, "rel")
def RELD(a): return Op(0o77, a, "rel")


SP, PC = 6, 7
DBL = {"MOV": 0o010000, "CMP": 0o020000, "BIT": 0o030000, "BIC": 0o040000,
       "BIS": 0o050000, "ADD": 0o060000, "MOVB": 0o110000, "CMPB": 0o120000,
       "BITB": 0o130000, "BICB": 0o140000, "BISB": 0o150000, "SUB": 0o160000}
SGL = {"CLR": 0o005000, "COM": 0o005100, "INC": 0o005200, "DEC": 0o005300,
       "NEG": 0o005400, "ADC": 0o005500, "SBC": 0o005600, "TST": 0o005700,
       "ROR": 0o006000, "ROL": 0o006100, "ASR": 0o006200, "ASL": 0o006300,
       "SWAB": 0o000300, "SXT": 0o006700, "JMP": 0o000100,
       "CLRB": 0o105000, "INCB": 0o105200, "TSTB": 0o105700}
BR = {"BR": 0o000400, "BNE": 0o001000, "BEQ": 0o001400, "BGE": 0o002000,
      "BLT": 0o002400, "BGT": 0o003000, "BLE": 0o003400, "BPL": 0o100000,
      "BMI": 0o100400, "BHI": 0o101000, "BLOS": 0o101400, "BCC": 0o103000,
      "BCS": 0o103400}


class Asm:
    def __init__(self):
        self.items = []       # (addr, kind, args)
        self.labels = {}
        self.pc = 0

    def org(self, a):
        self.pc = a

    def label(self, name):
        self.labels[name] = self.pc

    def _add(self, n, fn):
        self.items.append((self.pc, fn))
        self.pc += 2 * n

    def _ops(self, ops):
        return sum(1 for o in ops if o.word is not None)

    def _words(self, a, opc, ops):
        out = [opc]
        for o in ops:
            if o.word is None:
                continue
            v = self.labels.get(o.word, o.word) if isinstance(o.word, str) else o.word
            wa = a + 2 * len(out)
            out.append((v - (wa + 2)) & M16 if o.kind == "rel" else v & M16)
        return out

    def dbl(self, mn, s, d):
        self._add(1 + self._ops([s, d]),
                  lambda a: self._words(a, DBL[mn] | s.field << 6 | d.field, [s, d]))

    def sgl(self, mn, d):
        self._add(1 + self._ops([d]), lambda a: self._words(a, SGL[mn] | d.field, [d]))

    def jsr(self, reg, d):
        self._add(1 + self._ops([d]), lambda a: self._words(a, 0o004000 | reg << 6 | d.field, [d]))

    def xor(self, reg, d):
        self._add(1 + self._ops([d]), lambda a: self._words(a, 0o074000 | reg << 6 | d.field, [d]))

    def mul(self, s, reg):
        self._add(1 + self._ops([s]), lambda a: self._words(a, 0o070000 | reg << 6 | s.field, [s]))

    def br(self, mn, target):
        def enc(a):
            off = (self.labels[target] - (a + 2)) // 2
            assert -128 <= off < 128
            return [BR[mn] | (off & 0o377)]
        self._add(1, enc)

    def sob(self, reg, target):
        self._add(1, lambda a: [0o077000 | reg << 6 | ((a + 2 - self.labels[target]) // 2)])

    def word(self, *ws):
        for w in ws:
            self._add(1, lambda a, w=w: [self.labels.get(w, w) if isinstance(w, str) else w])

    def op(self, opc):
        self._add(1, lambda a: [opc])

    def rts(self, reg):
        self.op(0o000200 | reg)

    def emt(self, n):
        self.op(0o104000 | n)

    def trap(self, n):
        self.op(0o104400 | n)

    def load(self, cpu):
        for a, fn in self.items:
            cpu.load(a, fn(a))
