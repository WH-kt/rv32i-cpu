#!/usr/bin/env python3
"""rvai assembler -- RV32I + the Xai INT8 tensor extension.

Assembles a flat bare-metal image and writes one 32-bit word per line, which is
what Verilog's $readmemh wants:

    asm.py firmware.S -o image.hex [--base 0x0] [--map symbols.json]

Why hand-written rather than a GCC toolchain
--------------------------------------------
The custom opcodes have no upstream assembler, so any toolchain would need a
.out-of-tree patch before the first instruction could be tested.  A ~400-line
assembler with no dependencies makes the whole project reproducible from a
clean checkout, and it doubles as the golden model's front end.  The dialect is
deliberately a subset: labels, the RV32I base set, the Xai instructions, and
just enough directives to lay out data.

Xai instructions (opcode custom-0, funct7 0001000)
--------------------------------------------------
    ai.clr                  acc <- 0
    ai.dot   rd, rs1, rs2   acc <- acc + dot4(rs1, rs2);  rd <- acc
    ai.dotr  rd, rs1, rs2   rd  <- dot4(rs1, rs2)          (acc unchanged)
    ai.acc   rd             rd  <- acc
    ai.rq    rd, rs1, rs2   rd  <- sat8(round_half_away((rs1 * M) / 2^shift) + zp)
                            where rs2 = {zp[7:0], shift[5:0], M[15:0]}

Lane i of a dot product is byte i of the 32-bit register (bit 8*i), i.e. the
little-endian byte order a `lw` of a byte array produces.
"""

import argparse
import json
import re
import sys

# --------------------------------------------------------------------------
# registers
# --------------------------------------------------------------------------
ABI = {
    "zero": 0, "ra": 1, "sp": 2, "gp": 3, "tp": 4,
    "t0": 5, "t1": 6, "t2": 7,
    "s0": 8, "fp": 8, "s1": 9,
    "a0": 10, "a1": 11, "a2": 12, "a3": 13, "a4": 14, "a5": 15,
    "a6": 16, "a7": 17,
    "s2": 18, "s3": 19, "s4": 20, "s5": 21, "s6": 22, "s7": 23,
    "s8": 24, "s9": 25, "s10": 26, "s11": 27,
    "t3": 28, "t4": 29, "t5": 30, "t6": 31,
}
for _i in range(32):
    ABI["x%d" % _i] = _i


def reg(tok):
    t = tok.strip().lower()
    if t not in ABI:
        raise AsmError("unknown register %r" % tok)
    return ABI[t]


class AsmError(Exception):
    pass


class _Cont:
    """Marks the second word of a lui+addi expansion in the layout list.

    See Asm.insn_words: pass 1 records the slots and pass 2 fills them, so the
    continuation slots must be visible to the layout but silent when emitting.
    """

    def __repr__(self):
        return "<continuation>"


CONT = _Cont()


# --------------------------------------------------------------------------
# encoders
# --------------------------------------------------------------------------
def r_type(f7, rs2, rs1, f3, rd, op):
    return ((f7 & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((rd & 31) << 7) | (op & 0x7F)


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | ((rs1 & 31) << 15) | ((f3 & 7) << 12) | \
           ((rd & 31) << 7) | (op & 0x7F)


def s_type(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return (((imm >> 5) & 0x7F) << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | ((imm & 0x1F) << 7) | (op & 0x7F)


def b_type(imm, rs2, rs1, f3, op):
    imm &= 0x1FFF
    b12 = (imm >> 12) & 1
    b11 = (imm >> 11) & 1
    b10_5 = (imm >> 5) & 0x3F
    b4_1 = (imm >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | ((rs2 & 31) << 20) | ((rs1 & 31) << 15) | \
           ((f3 & 7) << 12) | (b4_1 << 8) | (b11 << 7) | (op & 0x7F)


def u_type(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | ((rd & 31) << 7) | (op & 0x7F)


def j_type(imm, rd, op):
    imm &= 0x1FFFFF
    b20 = (imm >> 20) & 1
    b19_12 = (imm >> 12) & 0xFF
    b11 = (imm >> 11) & 1
    b10_1 = (imm >> 1) & 0x3FF
    return (b20 << 31) | (b10_1 << 21) | (b11 << 20) | (b19_12 << 12) | \
           ((rd & 31) << 7) | (op & 0x7F)


# Xai
XAI_OP, XAI_F7 = 0b0001011, 0b0001000
F3_CLR, F3_DOT, F3_DOTR, F3_ACC, F3_RQ = 0, 1, 2, 3, 4


def xai(f3, rd=0, rs1=0, rs2=0):
    return r_type(XAI_F7, rs2, rs1, f3, rd, XAI_OP)


# --------------------------------------------------------------------------
# expression evaluation: label arithmetic like `end - start`
# --------------------------------------------------------------------------
_EXPR_OK = re.compile(r"^[0-9a-fA-FxX_+\-*/() <>&|~']+$")


def parse_int(tok):
    t = tok.strip().replace("_", "")
    try:
        return int(t, 0)
    except ValueError:
        raise AsmError("bad number %r" % tok)


# --------------------------------------------------------------------------
# assembler
# --------------------------------------------------------------------------
def preprocess(lines, defines):
    """Strip .ifdef/.ifndef/.else/.endif blocks whose condition is false.

    Needed because a firmware that prints cycle counts cannot also be part of a
    bit-exact RTL-vs-ISS comparison: the ISS models instruction semantics, not
    timing, so `rdcycle` returns a different number there by construction.  The
    same source therefore has to assemble twice -- once for the equivalence
    test, once for the benchmark -- and a conditional is the only honest way to
    do that without maintaining two copies of the firmware that drift apart.

    Line numbers are preserved so diagnostics still point at the real file.
    """
    # compare case-insensitively: the directive text is lowercased for
    # matching, so a -D PRINT_CYCLES would otherwise never match .ifdef
    # PRINT_CYCLES
    defines = {d.lower() for d in defines}
    out = []
    active = []
    for lineno, raw in lines:
        stripped = strip_comment(raw).strip().lower()
        if stripped.startswith(".ifdef ") or stripped.startswith(".ifndef "):
            negate = stripped.startswith(".ifndef")
            name = stripped.split(None, 1)[1].strip().lower()
            active.append((name not in defines) if negate else (name in defines))
            continue
        if stripped.startswith(".else") and active:
            active[-1] = not active[-1]
            continue
        if stripped.startswith(".endif"):
            if active:
                active.pop()
            continue
        if all(active):
            out.append((lineno, raw))
    return out


class Asm:
    def __init__(self, base=0):
        self.base = base
        self.words = []          # list of (addr, value_or_None, srcline)
        self.labels = {}
        self.equ = {}
        self.src = []            # (lineno, text)

    # -- helpers ----------------------------------------------------------
    def eval_expr(self, e, pc=0):
        e = e.strip()
        if e in self.equ:
            return self.equ[e]
        # Substitute .equ symbols first, then labels, longest name first so
        # `loop10` is not eaten by `loop1`.
        for name in sorted(self.equ, key=len, reverse=True):
            if re.search(r"\b%s\b" % re.escape(name), e):
                e = re.sub(r"\b%s\b" % re.escape(name), str(self.equ[name]), e)
        if self.labels:
            for name in sorted(self.labels, key=len, reverse=True):
                if name in e and re.search(r"\b%s\b" % re.escape(name), e):
                    e = re.sub(r"\b%s\b" % re.escape(name), str(self.labels[name]), e)
        sym = {
            ".": pc,
            "here": pc,
        }
        try:
            return int(eval(e, {"__builtins__": {}}, sym))  # noqa: S307
        except Exception:
            raise AsmError("cannot evaluate expression %r" % e)

    def try_const(self, e):
        """Evaluate an expression that cannot depend on a label.

        Both passes must agree on whether `li` is one word or two, so the size
        decision may only use information available in pass 1 -- numbers and
        .equ symbols.  Returning None for anything label-dependent is what keeps
        the two passes consistent; see insn_words().
        """
        s = e.strip()
        for name in sorted(self.equ, key=len, reverse=True):
            s = re.sub(r"\b%s\b" % re.escape(name), str(self.equ[name]), s)
        if not _EXPR_OK.match(s):
            return None
        try:
            return int(eval(s, {"__builtins__": {}}, {}))  # noqa: S307
        except Exception:
            return None

    # -- pass 0: constants -------------------------------------------------
    def collect_equ(self, lines):
        """Hoist every .equ/.set definition ahead of layout.

        A constant used by an instruction that appears earlier in the file must
        still be known when that instruction is *sized*.  Otherwise `li rd,SYM`
        is laid out as the two-word form and emitted as one word, and every
        label after it shifts by four bytes -- which surfaces as a jump into
        the middle of an instruction, not as an assembler error.  Constants are
        order-independent in every real assembler, so evaluating them up front
        is both correct and unsurprising.

        An .equ whose value depends on a label cannot be hoisted and is
        rejected rather than silently mis-sized.
        """
        for lineno, raw in lines:
            text = strip_comment(raw).strip()
            while True:
                m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", text)
                if not m:
                    break
                text = m.group(2).strip()
            low = text.lower()
            if not (low.startswith(".equ ") or low.startswith(".set ") or
                    low.startswith(".equ\t") or low.startswith(".set\t")):
                continue
            arg = text.split(None, 1)[1]
            name, _, val = arg.partition(",")
            name = name.strip()
            try:
                self.equ[name] = self.eval_expr(val.strip())
            except AsmError:
                raise AsmError("line %d: .equ %s must be a constant expression "
                               "(labels are not available yet)" % (lineno, name))

    # -- pass 1: layout ---------------------------------------------------
    def insn_words(self, text, pc):
        """How many 32-bit words this instruction assembles to.

        `la`, and `li` with a value that does not fit in 12 signed bits, expand
        to a lui+addi pair.  The layout pass MUST agree with the emit pass about
        this or every label after such an instruction is 4 bytes out -- and the
        symptom is a branch into the middle of an instruction, which is about
        the least diagnosable failure there is.

        A symbolic operand is always sized as the 2-word form: whether a label
        turns out to be small is not known until pass 2, so sizing it by value
        would let the two passes disagree.
        """
        parts = text.replace(",", " ").split()
        if not parts:
            return 1
        op = parts[0].lower()
        a = parts[1:]
        if op == "la":
            return 2
        if op == "li" and len(a) == 2:
            v = self.try_const(a[1])
            if v is None:
                return 2
            return 1 if -2048 <= v <= 2047 else 2
        return 1

    def pass1(self, lines):
        pc = self.base
        for lineno, raw in lines:
            text = strip_comment(raw).strip()
            if not text:
                continue
            # labels (possibly several, possibly followed by an instruction)
            while True:
                m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", text)
                if not m:
                    break
                name, text = m.group(1), m.group(2).strip()
                if name in self.labels:
                    raise AsmError("line %d: duplicate label %r" % (lineno, name))
                self.labels[name] = pc
            if not text:
                continue
            if text.startswith("."):
                pc = self.directive_layout(text, pc, lineno)
                continue
            n = self.insn_words(text, pc)
            self.words.append((pc, None, lineno))
            for _ in range(n - 1):
                pc += 4
                self.words.append((pc, CONT, lineno))
            pc += 4
        self.end = pc

    def directive_layout(self, text, pc, lineno):
        parts = text.split(None, 1)
        d = parts[0].lower()
        arg = parts[1].strip() if len(parts) > 1 else ""
        if d in (".text", ".data", ".section", ".rodata", ".globl", ".global",
                 ".align", ".p2align", ".type", ".size"):
            if d in (".align", ".p2align") and arg:
                n = self.eval_expr(arg) if not arg.isdigit() else int(arg)
                a = 1 << n
                # pad with real words: an .align that only moved the PC would
                # leave the gap unfilled and shift every later label
                while pc % a:
                    self.words.append((pc, 0, lineno))
                    pc += 4
            return pc
        if d == ".org":
            target = self.eval_expr(arg)
            if target < pc:
                raise AsmError("line %d: .org moves backwards" % lineno)
            while pc < target:
                self.words.append((pc, 0, lineno))
                pc += 4
            return pc
        if d == ".word" or d == ".long":
            n = len(split_args(arg))
            for _ in range(n):
                self.words.append((pc, None, lineno))
                pc += 4
            return pc
        if d == ".byte":
            raise AsmError("line %d: .byte needs .align/.org padding; use .word"
                           % lineno)
        if d in (".ascii", ".asciz", ".string"):
            # Packed little-endian into words so a label can point straight at
            # the text and `lbu` walks it byte by byte.  The content is fully
            # known here, so the slot values are filled in during layout and
            # pass 2 has nothing left to do for them.
            data = parse_cstring(arg, lineno)
            if d != ".ascii":
                data += b"\x00"
            for k in range(0, len(data), 4):
                chunk = data[k:k + 4].ljust(4, b"\x00")
                self.words.append((pc, int.from_bytes(chunk, "little"), lineno))
                pc += 4
            return pc
        if d == ".equ" or d == ".set":
            # already hoisted by collect_equ(); nothing to lay out here
            return pc
        if d == ".space" or d == ".zero":
            n = self.eval_expr(arg)
            for _ in range(n):
                self.words.append((pc, 0, lineno))
                pc += 4
            return pc
        raise AsmError("line %d: unknown directive %r" % (lineno, d))

    # -- pass 2: emit -----------------------------------------------------
    def pass2(self):
        out = []
        for addr, val, lineno in self.words:
            if val is CONT:
                continue                       # second word of a lui+addi pair
            if val is not None:
                out.append(val & 0xFFFFFFFF)
                continue
            text = strip_comment(self.src[lineno - 1]).strip()
            # drop leading labels
            while True:
                m = re.match(r"^([A-Za-z_.$][\w.$]*)\s*:\s*(.*)$", text)
                if not m:
                    break
                text = m.group(2).strip()
            if text.startswith("."):
                parts = text.split(None, 1)
                arg = parts[1] if len(parts) > 1 else ""
                out.append(self.emit_data(parts[0].lower(), arg, addr))
                continue
            w = self.emit_insn(text, addr, lineno)
            if isinstance(w, tuple) and w[0] == "PAIR":
                _, rd, hi, lo = w
                out.append(u_type(hi, rd, 0b0110111))            # lui  rd, hi
                out.append(i_type(lo, rd, 0, rd, 0b0010011))     # addi rd, rd, lo
            else:
                out.append(w & 0xFFFFFFFF)

        # Every slot pass 1 reserved must produce exactly one word here, and a
        # lui+addi pair must fill both its own slot and its CONT slot.  If the
        # two passes ever disagree about instruction size, this fires instead
        # of silently misplacing every later label.
        if len(out) != len(self.words):
            raise AsmError("internal: emitted %d words for %d slots"
                           % (len(out), len(self.words)))
        return out

    def emit_data(self, d, arg, addr):
        if d in (".word", ".long"):
            vals = [self.eval_expr(a, addr) for a in split_args(arg)]
            if len(vals) != 1:
                raise AsmError(".word takes exactly one value per slot here")
            return vals[0] & 0xFFFFFFFF
        if d in (".space", ".zero"):
            return 0
        if d == ".org":
            return 0
        return 0

    # -- instruction encoding --------------------------------------------
    def lui_addi_pair(self, rd, v, lineno):
        """Encode an arbitrary 32-bit constant as lui+addi.

        addi sign-extends its 12-bit immediate, so a plain bit split of the
        constant is wrong: (v + 0x800) >> 12 rounds the upper half up whenever
        bit 11 is set, so the negative low half cancels it exactly.  Getting
        this wrong shows up as addresses that are 0x1000 too high only for
        constants whose bit 11 happens to be set -- a classic intermittent bug.
        """
        if not -(1 << 31) <= v < (1 << 32):
            raise AsmError("line %d: constant %d out of 32-bit range" % (lineno, v))
        hi = (v + 0x800) >> 12
        lo = v - (hi << 12)
        return ("PAIR", rd, hi & 0xFFFFF, lo & 0xFFF)

    def emit_insn(self, text, pc, lineno):
        parts = text.replace(",", " ").split()
        if not parts:
            raise AsmError("line %d: empty instruction" % lineno)
        op = parts[0].lower()
        a = parts[1:]

        def need(n):
            if len(a) != n:
                raise AsmError("line %d: %s takes %d operands, got %d"
                               % (lineno, op, n, len(a)))

        # ---- Xai --------------------------------------------------------
        if op == "ai.clr":
            need(0)
            return xai(F3_CLR)
        if op == "ai.acc":
            need(1)
            return xai(F3_ACC, rd=reg(a[0]))
        if op in ("ai.dot", "ai.dotr"):
            need(3)
            f3 = F3_DOT if op == "ai.dot" else F3_DOTR
            return xai(f3, rd=reg(a[0]), rs1=reg(a[1]), rs2=reg(a[2]))
        if op == "ai.rq":
            # ai.rq rd, rs1, rs2   rs1 = value, rs2 = packed {zp, shift, M}
            need(3)
            return xai(F3_RQ, rd=reg(a[0]), rs1=reg(a[1]), rs2=reg(a[2]))

        # ---- pseudo -----------------------------------------------------
        if op == "nop":
            need(0)
            return i_type(0, 0, 0, 0, 0b0010011)
        if op == "mv":
            need(2)
            return i_type(0, reg(a[1]), 0, reg(a[0]), 0b0010011)
        if op == "not":
            need(2)
            return i_type(-1, reg(a[1]), 4, reg(a[0]), 0b0010011)
        if op == "neg":
            need(2)
            return r_type(0b0100000, reg(a[1]), 0, 0, reg(a[0]), 0b0110011)
        if op == "seqz":
            need(2)
            return i_type(1, reg(a[1]), 3, reg(a[0]), 0b0010011)
        if op == "snez":
            need(2)
            return r_type(0, reg(a[1]), 0, 3, reg(a[0]), 0b0110011)
        if op == "j":
            need(1)
            return j_type(self.eval_expr(a[0], pc) - pc, 0, 0b1101111)
        if op == "jr":
            need(1)
            return i_type(0, reg(a[0]), 0, 0, 0b1100111)
        if op == "ret":
            need(0)
            return i_type(0, 1, 0, 0, 0b1100111)
        if op in ("beqz", "bnez"):
            need(2)
            f3 = 0 if op == "beqz" else 1
            return b_type(self.eval_expr(a[1], pc) - pc, 0, reg(a[0]), f3, 0b1100011)
        if op in ("bgez", "bltz", "blez", "bgtz"):
            need(2)
            # compare against x0, swapping operands where the sense is reversed
            off = self.eval_expr(a[1], pc) - pc
            r = reg(a[0])
            if op == "bgez":
                return b_type(off, 0, r, 5, 0b1100011)
            if op == "bltz":
                return b_type(off, 0, r, 4, 0b1100011)
            if op == "blez":
                return b_type(off, r, 0, 5, 0b1100011)
            return b_type(off, r, 0, 4, 0b1100011)
        if op == "li":
            need(2)
            rd = reg(a[0])
            v = self.try_const(a[1])
            if v is None:
                # symbolic: insn_words() has already committed to the 2-word form
                return self.lui_addi_pair(rd, self.eval_expr(a[1], pc), lineno)
            if -2048 <= v <= 2047:
                return i_type(v, 0, 0, rd, 0b0010011)
            return self.lui_addi_pair(rd, v, lineno)
        if op == "la":
            # absolute address; the low 12 bits are sign-adjusted so that the
            # addi's sign extension lands on the right address (the standard
            # lui+addi split, not a plain bit split).
            need(2)
            return self.lui_addi_pair(reg(a[0]), self.eval_expr(a[1], pc), lineno)

        # ---- real instructions ------------------------------------------
        if op not in ISA:
            raise AsmError("line %d: unknown instruction %r" % (lineno, op))
        kind, f3, f7 = ISA[op]

        if kind == "R":
            need(3)
            return r_type(f7, reg(a[2]), reg(a[1]), f3, reg(a[0]), 0b0110011)
        if kind == "M":                      # RV32M, same OP opcode, funct7=1
            need(3)
            return r_type(f7, reg(a[2]), reg(a[1]), f3, reg(a[0]), 0b0110011)
        if kind == "I":
            need(3)
            return i_type(self.eval_expr(a[2], pc), reg(a[1]), f3, reg(a[0]),
                          0b0010011)
        if kind == "SH":                       # shift-immediate
            need(3)
            sh = self.eval_expr(a[2], pc)
            if not 0 <= sh <= 31:
                raise AsmError("line %d: shift %d out of range" % (lineno, sh))
            return i_type((f7 << 5) | sh, reg(a[1]), f3, reg(a[0]), 0b0010011)
        if kind == "LOAD":
            need(2)
            off, base = split_mem(a[1], self, pc, lineno)
            return i_type(off, reg(base), f3, reg(a[0]), 0b0000011)
        if kind == "STORE":
            need(2)
            off, base = split_mem(a[1], self, pc, lineno)
            return s_type(off, reg(a[0]), reg(base), f3, 0b0100011)
        if kind == "B":
            need(3)
            return b_type(self.eval_expr(a[2], pc) - pc, reg(a[1]), reg(a[0]),
                          f3, 0b1100011)
        if kind == "J":
            need(2)
            return j_type(self.eval_expr(a[1], pc) - pc, reg(a[0]), 0b1101111)
        if kind == "JALR":
            # both `jalr rd, off(rs1)` and `jalr rd, rs1, imm` are accepted
            if len(a) == 3:
                return i_type(self.eval_expr(a[2], pc), reg(a[1]), 0, reg(a[0]),
                              0b1100111)
            need(2)
            off, base = split_mem(a[1], self, pc, lineno)
            return i_type(off, reg(base), 0, reg(a[0]), 0b1100111)
        if kind == "U":
            need(2)
            v = self.eval_expr(a[1], pc)
            # `lui rd, imm` puts imm itself in bits 31:12; the operand is the
            # upper immediate, NOT a full value to be rounded.  (The rounding
            # belongs to la/li, which must produce an exact 32-bit constant.)
            if not -(1 << 19) <= v < (1 << 20):
                raise AsmError("line %d: %s immediate %d does not fit in 20 bits"
                               % (lineno, op, v))
            return u_type(v, reg(a[0]), 0b0110111 if op == "lui" else 0b0010111)
        if kind == "SYS":
            need(0)
            return {"ecall": 0x00000073, "ebreak": 0x00100073}.get(op, 0x0000000F)
        if kind == "CSR":
            need(1)
            # csrrs rd, csr, x0 -- PicoRV32 implements these when
            # ENABLE_COUNTERS=1, with no memory-mapped counter needed
            return i_type(f3, 0, 0b010, reg(a[0]), 0b1110011)
        raise AsmError("line %d: unhandled %r" % (lineno, op))


def split_mem(tok, asm, pc, lineno):
    m = re.match(r"^(-?[\w.$()+\-*/ ]*?)\s*\(\s*([\w.$]+)\s*\)$", tok.strip())
    if not m:
        raise AsmError("line %d: bad memory operand %r" % (lineno, tok))
    off = asm.eval_expr(m.group(1), pc)
    return off, m.group(2)


def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def strip_comment(s):
    for c in ("#", "//", ";"):
        i = s.find(c)
        if i >= 0:
            s = s[:i]
    return s


_ESCAPES = {"n": 10, "t": 9, "r": 13, "0": 0, "\\": 92, '"': 34, "'": 39}


def parse_cstring(arg, lineno):
    """Parse a double-quoted string literal into bytes, with escapes."""
    s = arg.strip()
    if len(s) < 2 or not (s.startswith('"') and s.endswith('"')):
        raise AsmError("line %d: expected a \"quoted\" string, got %r"
                       % (lineno, arg))
    body = s[1:-1]
    out = bytearray()
    i = 0
    while i < len(body):
        c = body[i]
        if c == "\\":
            i += 1
            if i >= len(body):
                raise AsmError("line %d: trailing backslash" % lineno)
            e = body[i]
            if e == "x":
                h = body[i + 1:i + 3]
                try:
                    out.append(int(h, 16))
                except ValueError:
                    raise AsmError("line %d: bad hex escape \\x%s" % (lineno, h))
                i += 2
            elif e in _ESCAPES:
                out.append(_ESCAPES[e])
            else:
                raise AsmError("line %d: unknown escape \\%s" % (lineno, e))
        else:
            out.append(ord(c) & 0xFF)
        i += 1
    return bytes(out)


# --------------------------------------------------------------------------
# instruction table:  mnemonic -> (kind, funct3, funct7)
# --------------------------------------------------------------------------
ISA = {
    # R-type
    "add":  ("R", 0, 0b0000000), "sub": ("R", 0, 0b0100000),
    "sll":  ("R", 1, 0b0000000), "slt": ("R", 2, 0b0000000),
    "sltu": ("R", 3, 0b0000000), "xor": ("R", 4, 0b0000000),
    "srl":  ("R", 5, 0b0000000), "sra": ("R", 5, 0b0100000),
    "or":   ("R", 6, 0b0000000), "and": ("R", 7, 0b0000000),
    # I-type ALU
    "addi": ("I", 0, 0), "slti": ("I", 2, 0), "sltiu": ("I", 3, 0),
    "xori": ("I", 4, 0), "ori": ("I", 6, 0), "andi": ("I", 7, 0),
    # shift-immediate
    "slli": ("SH", 1, 0b0000000), "srli": ("SH", 5, 0b0000000),
    "srai": ("SH", 5, 0b0100000),
    # loads / stores
    "lb":  ("LOAD", 0, 0), "lh": ("LOAD", 1, 0), "lw": ("LOAD", 2, 0),
    "lbu": ("LOAD", 4, 0), "lhu": ("LOAD", 5, 0),
    "sb":  ("STORE", 0, 0), "sh": ("STORE", 1, 0), "sw": ("STORE", 2, 0),
    # branches
    "beq": ("B", 0, 0), "bne": ("B", 1, 0), "blt": ("B", 4, 0),
    "bge": ("B", 5, 0), "bltu": ("B", 6, 0), "bgeu": ("B", 7, 0),
    # M extension (PicoRV32 ENABLE_MUL).  funct7 here is the R-type funct7.
    "mul":    ("M", 0, 0b0000001), "mulh":  ("M", 1, 0b0000001),
    "mulhsu": ("M", 2, 0b0000001), "mulhu": ("M", 3, 0b0000001),
    "div":    ("M", 4, 0b0000001), "divu":  ("M", 5, 0b0000001),
    "rem":    ("M", 6, 0b0000001), "remu":  ("M", 7, 0b0000001),
    # upper immediate
    "lui": ("U", 0, 0), "auipc": ("U", 0, 0),
    # jumps and system
    "jal": ("J", 0, 0), "jalr": ("JALR", 0, 0),
    "ecall": ("SYS", 0, 0), "ebreak": ("SYS", 0, 0),
    "fence": ("SYS", 0, 0), "fence.i": ("SYS", 0, 0),
    # counters (PicoRV32 ENABLE_COUNTERS); f3 here is the CSR number, not funct3
    "rdcycle":   ("CSR", 0xC00, 0),
    "rdtime":    ("CSR", 0xC01, 0),
    "rdinstret": ("CSR", 0xC02, 0),
}


def assemble(path, base=0, defines=()):
    a = Asm(base)
    with open(path) as fh:
        raw = fh.readlines()
    a.src = raw
    lines = preprocess(list(enumerate(raw, start=1)), set(defines))
    a.collect_equ(lines)
    a.pass1(lines)
    words = a.pass2()
    return words, a

def main(argv=None):
    ap = argparse.ArgumentParser(description="RV32I + Xai assembler")
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--base", default="0x0")
    ap.add_argument("--map", dest="mapfile")
    ap.add_argument("-D", dest="defines", action="append", default=[],
                    help="define a symbol for .ifdef (repeatable)")
    args = ap.parse_args(argv)

    base = int(args.base, 0)
    try:
        words, asm = assemble(args.source, base, args.defines)
    except AsmError as e:
        print("asm: %s" % e, file=sys.stderr)
        return 1

    with open(args.output, "w") as fh:
        for w in words:
            fh.write("%08x\n" % (w & 0xFFFFFFFF))

    # byte offset -> word index, for the testbench and the ISS
    if args.mapfile:
        sym = {k: v for k, v in asm.labels.items()}
        sym.update(asm.equ)
        with open(args.mapfile, "w") as fh:
            json.dump({"base": base, "words": len(words), "symbols": sym,
                       "end": asm.end}, fh, indent=2, sort_keys=True)

    print("asm: %s -> %s  (%d words, %d bytes, end 0x%x)"
          % (args.source, args.output, len(words), len(words) * 4, asm.end))
    return 0


if __name__ == "__main__":
    sys.exit(main())
