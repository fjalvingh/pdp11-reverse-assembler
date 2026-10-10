"""Reference PDP-11 disassembler producing the same text layout as the
inverse assembler (mnemonic padded to 8 columns, octal operands).

Used only to check the IAL implementation.
"""

REGS = ["R0", "R1", "R2", "R3", "R4", "R5", "SP", "PC"]
A18 = 0o777777


def o6(v):
    return "%06o" % (v & 0xFFFF)


def p6(v):
    return "%06o" % (v & A18)


def pcrel(base, disp):
    """Bus address of PC relative target: base + signed 16 bit disp.

    Code in the I/O page (760000-777777) uses 16 bit virtual addresses
    with 160000-177777 mapped to the I/O page."""
    disp &= 0xFFFF
    if disp & 0x8000:
        disp -= 0x10000
    t = base + disp
    if base >= 0o760000:
        t &= 0xFFFF
        return t | 0o600000 if t >= 0o160000 else t
    return t & A18


def nwords(field):
    mode, reg = field >> 3, field & 7
    return 1 if mode >= 6 or (reg == 7 and mode in (2, 3)) else 0


class Words:
    def __init__(self, addr, words):
        self.addr, self.words, self.i = addr, words, 0

    def next(self):
        a = (self.addr + 2 + 2 * self.i) & A18
        w = self.words[self.i] if self.i < len(self.words) else None
        self.i += 1
        return a, w


def ea(field, ws):
    mode, reg = field >> 3, field & 7
    r = REGS[reg]
    if mode == 0:
        return r
    if mode == 1:
        return "(%s)" % r
    if mode in (2, 3):
        pre = "@" if mode == 3 else ""
        if reg == 7:
            _, w = ws.next()
            return pre + "#" + ("******" if w is None else o6(w))
        return pre + "(%s)+" % r
    if mode in (4, 5):
        return ("@" if mode == 5 else "") + "-(%s)" % r
    pre = "@" if mode == 7 else ""
    a, w = ws.next()
    if w is None:
        return pre + "******" + ("" if reg == 7 else "(%s)" % r)
    if reg == 7:
        return pre + p6(pcrel(a + 2, w))
    return pre + o6(w) + "(%s)" % r


def fea(field, ws):
    if field >> 3 == 0:
        return "AC%o" % (field & 7)
    return ea(field, ws)


def fmt(mn, ops=None):
    return mn if ops is None else mn.ljust(8) + ops


def disasm(addr, opc, words=()):
    """Disassemble opc at bus address addr; words are the extension words."""
    ws = Words(addr, list(words))
    dd = opc & 0o77
    ss = (opc >> 6) & 0o77
    r86 = REGS[(opc >> 6) & 7]
    top = opc >> 12

    def br(mn):
        off = opc & 0o377
        if off & 0o200:
            off -= 0o400
        return fmt(mn, p6(pcrel(addr + 2, 2 * off)))

    if top in (1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14):
        mn = {1: "MOV", 2: "CMP", 3: "BIT", 4: "BIC", 5: "BIS", 6: "ADD",
              9: "MOVB", 10: "CMPB", 11: "BITB", 12: "BICB", 13: "BISB", 14: "SUB"}[top]
        s = ea(ss, ws)
        return fmt(mn, s + "," + ea(dd, ws))
    if top == 0o17:
        return fpp(opc, ws)
    if top == 0o07:
        sub = (opc >> 9) & 7
        if sub < 4:
            mn = ["MUL", "DIV", "ASH", "ASHC"][sub]
            return fmt(mn, ea(dd, ws) + "," + r86)
        if sub == 4:
            return fmt("XOR", r86 + "," + ea(dd, ws))
        if sub == 5:
            if (opc >> 5) & 0o17:
                return ill(opc)
            return fmt(["FADD", "FSUB", "FMUL", "FDIV"][(opc >> 3) & 3], REGS[opc & 7])
        if sub == 6:
            return ill(opc)
        n = opc & 0o77
        return fmt("SOB", r86 + "," + p6(pcrel(addr + 2, -2 * n)))
    byte = top == 0o10
    hi = (opc >> 8) & 0o17
    if hi < 8 and not (not byte and hi == 0):
        names0 = [None, "BR", "BNE", "BEQ", "BGE", "BLT", "BGT", "BLE"]
        names1 = ["BPL", "BMI", "BHI", "BLOS", "BVC", "BVS", "BCC", "BCS"]
        return br(names1[hi] if byte else names0[hi])
    if byte:
        if hi == 8:
            return fmt("EMT", "%03o" % (opc & 0o377))
        if hi == 9:
            return fmt("TRAP", "%03o" % (opc & 0o377))
        q = (opc >> 6) & 3
        if hi in (10, 11, 12):
            mn = [["CLR", "COM", "INC", "DEC"], ["NEG", "ADC", "SBC", "TST"],
                  ["ROR", "ROL", "ASR", "ASL"]][hi - 10][q] + "B"
            return fmt(mn, ea(dd, ws))
        if hi == 13:
            return fmt(["MTPS", "MFPD", "MTPD", "MFPS"][q], ea(dd, ws))
        return ill(opc)
    # group 00xxxx, opc < 010000
    if hi == 0:
        q = (opc >> 6) & 3
        if q == 0:
            if opc > 7:
                return ill(opc)
            return ["HALT", "WAIT", "RTI", "BPT", "IOT", "RESET", "RTT", "MFPT"][opc]
        if q == 1:
            return fmt("JMP", ea(dd, ws))
        if q == 3:
            return fmt("SWAB", ea(dd, ws))
        sub = (opc >> 3) & 7
        if sub == 0:
            return fmt("RTS", REGS[opc & 7])
        if sub in (1, 2):
            return ill(opc)
        if sub == 3:
            return fmt("SPL", "%o" % (opc & 7))
        bits = opc & 0o17
        setf = opc & 0o20
        if bits == 0:
            return "NOP"
        if bits == 0o17:
            return "SCC" if setf else "CCC"
        return ("SE" if setf else "CL") + "".join(
            c for c, b in zip("NZVC", (8, 4, 2, 1)) if bits & b)
    if hi in (8, 9):
        return fmt("JSR", r86 + "," + ea(dd, ws))
    q = (opc >> 6) & 3
    if hi in (10, 11, 12):
        mn = [["CLR", "COM", "INC", "DEC"], ["NEG", "ADC", "SBC", "TST"],
              ["ROR", "ROL", "ASR", "ASL"]][hi - 10][q]
        return fmt(mn, ea(dd, ws))
    if hi == 13:
        if q == 0:
            return fmt("MARK", "%02o" % (opc & 0o77))
        return fmt(["", "MFPI", "MTPI", "SXT"][q], ea(dd, ws))
    if hi == 14:
        if q == 1:
            return ill(opc)
        return fmt(["CSM", "", "TSTSET", "WRTLCK"][q], ea(dd, ws))
    return ill(opc)


def ill(opc):
    return fmt(".WORD", o6(opc))


def fpp(opc, ws):
    hi = (opc >> 8) & 0o17
    ac = "AC%o" % ((opc >> 6) & 3)
    dd = opc & 0o77
    q = (opc >> 6) & 3
    if hi == 0:
        if q == 0:
            names = {0: "CFCC", 1: "SETF", 2: "SETI", 0o11: "SETD", 0o12: "SETL"}
            return names.get(dd) or ill(opc)
        return fmt(["", "LDFPS", "STFPS", "STST"][q], ea(dd, ws))
    if hi == 1:
        return fmt(["CLRF", "TSTF", "ABSF", "NEGF"][q], fea(dd, ws))
    mn = {2: "MULF", 3: "MODF", 4: "ADDF", 5: "LDF", 6: "SUBF", 7: "CMPF", 8: "STF",
          9: "DIVF", 10: "STEXP", 11: "STCFI", 12: "STCFD", 13: "LDEXP", 14: "LDCIF",
          15: "LDCDF"}[hi]
    if hi in (8, 12):
        return fmt(mn, ac + "," + fea(dd, ws))
    if hi in (10, 11):
        return fmt(mn, ac + "," + ea(dd, ws))
    if hi in (13, 14):
        return fmt(mn, ea(dd, ws) + "," + ac)
    return fmt(mn, fea(dd, ws) + "," + ac)


def length(opc):
    """Instruction length in words (each missing extension word prints as ******)."""
    return 1 + disasm(0, opc, []).count("******")
