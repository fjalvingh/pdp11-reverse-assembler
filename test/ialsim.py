"""Small interpreter for HP Inverse Assembler Language (IAL) source, plus a
model of the logic analyzer listing (Invasm sync, system and user tags).

It runs the .S source directly, so the inverse assembler logic can be
tested on a PC with synthetic traces.  Semantics follow the HP 10391B
reference manual.
"""
import re

M32 = 0xFFFFFFFF


class IALError(Exception):
    pass


def parse_number(tok):
    t = tok.upper()
    neg = t.startswith("-")
    if neg or t.startswith("+"):
        t = t[1:]
    if not t or not t[0].isdigit():
        return None
    try:
        if t.endswith("H"):
            v = int(t[:-1], 16)
        elif t.endswith("B") and re.fullmatch(r"[01]+B", t):
            v = int(t[:-1], 2)
        elif t.endswith("Q") or t.endswith("O"):
            v = int(t[:-1], 8)
        else:
            v = int(t, 10)
    except ValueError:
        return None
    return (-v) & M32 if neg else v


def split_fields(line):
    """Return (label, op, operand_text) for a source line (comments removed)."""
    # strip ';' comments outside of strings
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q:
                q = None
        elif ch in "\"'^":
            q = ch
            out.append(ch)
        elif ch == ";":
            break
        else:
            out.append(ch)
    line = "".join(out).rstrip()
    if not line.strip():
        return None, None, None
    label = None
    if not line[0].isspace():
        m = re.match(r"([A-Za-z][A-Za-z0-9_]*):?", line)
        label = m.group(1)
        line = line[m.end():]
    rest = line.strip()
    if not rest:
        return label, None, None
    m = re.match(r"(\S+)\s*(.*)", rest)
    return label, m.group(1), m.group(2).strip()


def first_operand(text):
    """Operand field ends at the first blank outside a string."""
    out, q = [], None
    for ch in text:
        if q:
            out.append(ch)
            if ch == q:
                q = None
        elif ch in "\"'^":
            q = ch
            out.append(ch)
        elif ch.isspace():
            break
        else:
            out.append(ch)
    return "".join(out)


PSEUDO_IGNORED = {"LABEL_TITLE", "BASE_TITLE", "DEFAULT_WIDTH", "MAX_INSTRUCTION",
                  "SEARCH_LIMIT", "QUALIFY_MASK", "QUALIFY_VALUE", "MAPPED_WIDTH"}
COMM_VARS = {"INITIAL_ADDRESS", "INITIAL_DATA", "INPUT_ADDRESS", "INPUT_DATA",
             "INPUT_STATUS", "INPUT_ERROR", "INPUT_TAG", "RETURN_FLAGS", "TASK",
             "QUALIFY_VALUE", "QUALIFY_MASK", "SEARCH_LIMIT", "INITIAL_FLAGS",
             "INITIAL_OPTIONS", "INPUT_ADDR_B", "INPUT_DATA_B"}


class Program:
    def __init__(self, text):
        lines = text.replace("\r", "").split("\n")
        if lines[0].strip() != '"IAL"':
            raise IALError('first line must be "IAL"')
        self.code = []          # list of (op, operand_text, lineno)
        self.labels = {}
        self.vars = {}
        self.consts = {}
        self.ascii = {}
        self.formats = {}
        self.max_instr = 10000
        pending = []
        for no, raw in enumerate(lines[1:], start=2):
            if raw.startswith("*"):
                continue
            label, op, opnd = split_fields(raw)
            if label is None and op is None:
                continue
            if op is None:
                pending.append(label)
                continue
            opu = op.upper()
            if opu in ("VARIABLE", "VAR"):
                v = first_operand(opnd) if opnd else ""
                self.vars[label] = self._num(v) if v else 0
                continue
            if opu in ("CONSTANT", "CONST"):
                self.consts[label] = self._num(first_operand(opnd))
                continue
            if opu in ("ASCII", "ASC"):
                self.ascii[label] = self._string(opnd)
                continue
            if opu == "FORMAT":
                self.formats[label] = self._format(first_operand(opnd))
                continue
            if opu in PSEUDO_IGNORED:
                if opu == "MAX_INSTRUCTION":
                    self.max_instr = self._num(first_operand(opnd))
                continue
            if label:
                pending.append(label)
            for lb in pending:
                if lb in self.labels:
                    raise IALError(f"duplicate label {lb}")
                self.labels[lb] = len(self.code)
            pending = []
            self.code.append((opu, opnd or "", no))
        for lb in pending:
            self.labels[lb] = len(self.code)
        self._link_cases()

    def _num(self, tok):
        v = parse_number(tok)
        if v is None:
            if tok in self.consts:
                return self.consts[tok]
            raise IALError(f"bad number {tok}")
        return v

    @staticmethod
    def _string(text):
        text = text.strip()
        q = text[0]
        end = text.index(q, 1)
        return text[1:end]

    def _format(self, op):
        parts = op.split(",")
        if parts[0].upper() == "ASCII":
            return ("ASCII", None, None, False)
        bits = int(parts[0])
        base = parts[1].upper()
        digits = None if parts[2].upper() == "LEFT_JUSTIFIED" else int(parts[2])
        disp = len(parts) > 3
        return (bits, base, digits, disp)

    def _link_cases(self):
        self.case_end = {}
        stack = []
        for i, (op, _, no) in enumerate(self.code):
            if op == "CASE_OF":
                stack.append(i)
            elif op == "CASE_END":
                if not stack:
                    raise IALError(f"CASE_END without CASE_OF line {no}")
                self.case_end[stack.pop()] = i
            elif stack and op in ("IF", "IF_NOT_MAPPED"):
                raise IALError(f"{op} inside CASE line {no}")
        if stack:
            raise IALError("unterminated CASE_OF")


class State:
    __slots__ = ("addr", "data", "stat", "tag", "sys")

    def __init__(self, addr, data, stat):
        self.addr, self.data, self.stat = addr, data, stat
        self.tag = 0
        self.sys = 0


class Run:
    """Executes the inverse assembler for one state."""

    def __init__(self, prog, states, index, mem):
        self.p = prog
        self.states = states
        self.cur = index
        self.mem = mem                     # persistent user variables
        self.acc = 0
        self.lines = [[]]
        self.col = 0
        s = states[index]
        self.cv = {"INITIAL_ADDRESS": s.addr, "INITIAL_DATA": s.data,
                   "RETURN_FLAGS": 0, "TASK": 5, "QUALIFY_VALUE": 0,
                   "QUALIFY_MASK": 0, "SEARCH_LIMIT": 16, "INITIAL_FLAGS": 0,
                   "INITIAL_OPTIONS": 0, "INPUT_ADDR_B": 0, "INPUT_DATA_B": 0}
        self.ptr = index
        self._load_state(index)

    def _load_state(self, i):
        s = self.states[i]
        self.cv.update(INPUT_ADDRESS=s.addr, INPUT_DATA=s.data, INPUT_STATUS=s.stat,
                       INPUT_TAG=s.tag | (s.sys << 16), INPUT_ERROR=0)
        self.ptr = i

    # operand helpers -------------------------------------------------
    def val(self, tok):
        tok = tok.strip()
        v = parse_number(tok)
        if v is not None:
            return v
        if tok in self.p.consts:
            return self.p.consts[tok]
        if tok in self.mem:
            return self.mem[tok]
        if tok in self.cv:
            return self.cv[tok]
        raise IALError(f"unknown operand {tok}")

    def store(self, name, v):
        v &= M32
        if name in self.mem:
            self.mem[name] = v
        elif name in self.cv:
            self.cv[name] = v
        else:
            raise IALError(f"cannot store to {name}")

    def write(self, text):
        line = self.lines[-1]
        while len(line) < self.col:
            line.append(" ")
        for ch in text:
            if self.col < len(line):
                line[self.col] = ch
            else:
                line.append(ch)
            self.col += 1

    def fmt(self, name):
        bits, base, digits, disp = self.p.formats[name]
        if bits == "ASCII":
            return chr(self.acc & 0x7F)
        v = self.acc & ((1 << bits) - 1)
        s = {"BIN": "{:b}", "OCT": "{:o}", "DEC": "{:d}", "HEX": "{:X}"}[base].format(v)
        if digits:
            s = s.rjust(digits, "0")
        if disp:
            s += {"BIN": "B", "OCT": "O", "DEC": "D", "HEX": "H"}[base]
        return s

    def cond(self, text):
        m = re.match(r"(\S+)\s*(<>|<=|>=|=|<|>)\s*(\S+)\s+THEN\s+(.*)$", text)
        if not m:
            raise IALError(f"bad IF {text}")
        lhs, rel, rhs, then = m.groups()
        if re.fullmatch(r"\d+,\d+", lhs):
            msb, lsb = map(int, lhs.split(","))
            a = (self.acc >> lsb) & ((1 << (msb - lsb + 1)) - 1)
        else:
            a = self.val(lhs)
        b = self.val(rhs)
        r = {"=": a == b, "<>": a != b, "<=": a <= b, ">=": a >= b,
             "<": a < b, ">": a > b}[rel]
        return r, then

    # execution ------------------------------------------------------
    def run(self):
        pc = 0
        stack = []
        count = 0
        code = self.p.code
        while True:
            count += 1
            if count > self.p.max_instr:
                raise IALError("instruction limit exceeded")
            op, opnd, no = code[pc]
            nxt = pc + 1
            if op == "CASE_OF":
                o = first_operand(opnd)
                if "," in o:
                    msb, lsb = map(int, o.split(","))
                    idx = (self.acc >> lsb) & ((1 << (msb - lsb + 1)) - 1)
                else:
                    idx = self.val(o)
                end = self.p.case_end[pc]
                if idx < end - pc - 1:
                    res = self.exec1(code[pc + 1 + idx][0], code[pc + 1 + idx][1], end + 1, stack)
                else:
                    res = end + 1
            elif op == "CASE_END":
                res = nxt
            else:
                res = self.exec1(op, opnd, nxt, stack)
            if res is None:
                return
            pc = res

    def exec1(self, op, opnd, nxt, stack):
        """Execute one instruction; return next pc or None to leave."""
        o = first_operand(opnd)
        if op == "IF":
            r, then = self.cond(opnd)
            if not r:
                return nxt
            top, rest = (then.split(None, 1) + [""])[:2]
            return self.exec1(top.upper(), rest, nxt, stack)
        if op == "IF_NOT_MAPPED":
            m = re.match(r"THEN\s+(\S+)\s*(.*)$", opnd)
            return self.exec1(m.group(1).upper(), m.group(2), nxt, stack)
        if op == "LOAD":
            self.acc = self.val(o)
        elif op == "STORE":
            self.store(o, self.acc)
        elif op == "ADD":
            self.acc = (self.acc + self.val(o)) & M32
        elif op == "SUBTRACT":
            self.acc = (self.acc - self.val(o)) & M32
        elif op == "AND":
            self.acc &= self.val(o)
        elif op == "INCLUSIVE_OR":
            self.acc |= self.val(o)
        elif op == "EXCLUSIVE_OR":
            self.acc ^= self.val(o)
        elif op == "COMPLEMENT":
            self.acc ^= M32
        elif op == "TWOS_COMPLEMENT":
            self.acc = (-self.acc) & M32
        elif op == "EXTRACT_BIT":
            self.acc = (self.acc >> self.val(o)) & 1
        elif op == "ROTATE":
            d, n = o.split(",")
            n = self.val(n) % 32
            a = self.acc
            if d.upper() == "LEFT":
                self.acc = ((a << n) | (a >> (32 - n))) & M32
            else:
                self.acc = ((a >> n) | (a << (32 - n))) & M32
        elif op == "INCREMENT":
            self.store(o, self.val(o) + 1)
        elif op == "DECREMENT":
            self.store(o, self.val(o) - 1)
        elif op == "SET":
            name, v = o.split(",")
            v = self.val(v)
            sv = v - (1 << 32) if v & 0x80000000 else v
            if not -8 <= sv <= 7:
                raise IALError(f"SET immediate out of range: {o}")
            if name == "RETURN_FLAGS":
                self.cv["RETURN_FLAGS"] = v & 1
            else:
                self.store(name, v)
        elif op == "GOTO":
            return self.p.labels[o]
        elif op == "CALL":
            if len(stack) >= 16:
                raise IALError("CALL nesting > 16")
            stack.append(nxt)
            return self.p.labels[o]
        elif op == "RETURN":
            return stack.pop() if stack else None
        elif op == "ABORT":
            return None
        elif op == "NOP":
            pass
        elif op == "OUTPUT":
            t = opnd.strip()
            if t[0] in "\"'^":
                self.write(Program._string(t))
            elif t.upper().startswith("ACCUMULATOR"):
                self.write(self.fmt(o.split(",")[1]))
            else:
                self.write(self.p.ascii[o])
        elif op == "POSITION":
            mode, n = o.split(",")
            n = self.val(n)
            if n & 0x80000000:
                n -= 1 << 32
            self.col = n - 1 if mode.upper() == "ABS" else self.col + n
            if self.col < 0:
                raise IALError("POSITION before column 1")
        elif op == "NEW_LINE":
            if len(self.lines) >= 4:
                raise IALError("more than 4 lines")
            self.lines.append([])
            self.col = 0
        elif op == "FETCH_POSITION":
            self.acc = self.col + 1
        elif op == "INPUT":
            parts = o.split(",")
            mode = parts[0].upper()
            v = self.val(parts[1])
            if mode == "REL":
                if v & 0x80000000:
                    v -= 1 << 32
                i = self.cur + v
                if 0 <= i < len(self.states):
                    self._load_state(i)
                else:
                    self.cv["INPUT_ERROR"] = 1
            else:
                raise IALError("INPUT ABS not modelled")
        elif op == "TAG_WITH":
            self.states[self.ptr].tag = self.val(o) & 0xFFFF
        else:
            raise IALError(f"unsupported instruction {op}")
        return nxt

    def text(self):
        return "\n".join("".join(l).rstrip() for l in self.lines)


class Analyzer:
    """Listing display with the Invasm field (download option B)."""

    def __init__(self, prog, trace):
        self.p = prog
        self.states = [State(a, d, s) for a, d, s in trace]
        self.mem = dict(prog.vars)

    def call(self, i):
        r = Run(self.p, self.states, i, self.mem)
        r.run()
        return r.text(), r.cv["RETURN_FLAGS"] & 1

    def sync(self, i):
        """Select the Invasm field with state i at the top of the screen."""
        self.states[i].sys = 1

    def listing(self, sync=0, upto=None):
        self.sync(sync)
        out = []
        n = len(self.states) if upto is None else upto
        for i in range(n):
            text, rf = self.call(i)
            if self.states[i].sys:
                self.states[i].sys = 2 | rf
                if i + 1 < len(self.states) and self.states[i + 1].sys == 0:
                    self.states[i + 1].sys = 1
            out.append(text)
        return out
