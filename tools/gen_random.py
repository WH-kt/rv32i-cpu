#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""rv32i-cpu -- constrained random RV32I program generator.

Purpose: hit hazard combinations that hand written tests do not think of.  The
generator is deliberately narrow so that a failure is always explainable:

  * control flow is forward only (branches and jal), so the trailing halt is
    always reached and a run can never hang;
  * the data base register x8, the halt address register x28 and the putchar
    address register x30 are set up in the prologue and never written again, so
    every memory access stays inside a small aligned window;
  * destinations are never x8/x28/x30, but they may be x0 (which exercises the
    "write to x0 is discarded" path including forwarding);
  * the operand selector is *biased* towards the destinations of the previous
    one, two and three instructions, which is what creates the forwarding
    hazards H1 (distance 1), H2 (distance 2) and the register file
    write-through case H3 (distance 3).  Uniform random registers almost never
    produce distance 3 dependencies.

usage:
    gen_random.py --seed 1234 [--length 400] -o build/random/seed1234.hex [--asm out.S]
"""

import argparse
import random

# ---------------------------------------------------------------------------
# encoders
# ---------------------------------------------------------------------------
R = lambda f7, rs2, rs1, f3, rd, op: ((f7 << 25) | (rs2 << 20) | (rs1 << 15) |
                                      (f3 << 12) | (rd << 7) | op)
I = lambda imm, rs1, f3, rd, op: (((imm & 0xFFF) << 20) | (rs1 << 15) |
                                  (f3 << 12) | (rd << 7) | op)
S = lambda imm, rs2, rs1, f3, op: ((((imm >> 5) & 0x7F) << 25) | (rs2 << 20) |
                                   (rs1 << 15) | (f3 << 12) |
                                   ((imm & 0x1F) << 7) | op)
B = lambda imm, rs2, rs1, f3, op: ((((imm >> 12) & 1) << 31) |
                                   (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) |
                                   (rs1 << 15) | (f3 << 12) |
                                   (((imm >> 1) & 0xF) << 8) |
                                   (((imm >> 11) & 1) << 7) | op)
U = lambda imm20, rd, op: (((imm20 & 0xFFFFF) << 12) | (rd << 7) | op)
J = lambda imm, rd, op: ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) |
                         (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) |
                         (rd << 7) | op)

OP_R, OP_I, OP_LOAD, OP_STORE = 0x33, 0x13, 0x03, 0x23
OP_BRANCH, OP_JAL, OP_LUI, OP_AUIPC = 0x63, 0x6F, 0x37, 0x17

RESERVED_DST = {8, 28, 30}          # data base, halt address, putchar address
DATA_BASE = 0x4000                  # well past any generated program

# ALU ops: (funct3, funct7, name)
ALU_R = [(0, 0x00, "add"), (0, 0x20, "sub"), (1, 0x00, "sll"), (2, 0x00, "slt"),
         (3, 0x00, "sltu"), (4, 0x00, "xor"), (5, 0x00, "srl"), (5, 0x20, "sra"),
         (6, 0x00, "or"), (7, 0x00, "and")]
ALU_I = [(0, "addi"), (2, "slti"), (3, "sltiu"), (4, "xori"), (6, "ori"), (7, "andi")]
LOADS = [(0, "lb"), (1, "lh"), (2, "lw"), (4, "lbu"), (5, "lhu")]
STORES = [(0, "sb"), (1, "sh"), (2, "sw")]
BRANCHES = [(0, "beq"), (1, "bne"), (4, "blt"), (5, "bge"), (6, "bltu"), (7, "bgeu")]

# natural alignment per funct3: every access the generator emits must be
# aligned, because this core traps on misaligned accesses (dedicated tests
# cover that path on purpose)
ALIGN = {0: 1, 1: 2, 2: 4, 4: 1, 5: 2}


class Gen:
    def __init__(self, seed, length):
        self.rng = random.Random(seed)
        self.length = length
        self.words = []
        self.text = []
        self.recent = []            # destinations of the last few instructions

    # ---- operand helpers -------------------------------------------------
    def biased_reg(self):
        """A source register, biased towards recent destinations (hazards)."""
        r = self.rng.random()
        usable = list(self.recent)
        if r < 0.30 and usable:
            return usable[-1]                     # distance 1 -> H1
        if r < 0.55 and len(usable) >= 2:
            return usable[-2]                     # distance 2 -> H2
        if r < 0.75 and len(usable) >= 3:
            return usable[-3]                     # distance 3 -> H3 (write-through)
        return self.rng.randrange(0, 32)

    def cheap_reg(self):
        r = self.rng.random()
        if r < 0.6:
            return self.biased_reg()
        return self.rng.randrange(0, 32)

    def dst_reg(self):
        if self.rng.random() < 0.05:
            return 0                              # sometimes write x0 on purpose
        while True:
            d = self.rng.randrange(0, 32)
            if d not in RESERVED_DST:
                return d

    def note(self, rd, text):
        if rd is not None:
            self.recent.append(rd)
            if len(self.recent) > 8:
                self.recent.pop(0)
        self.text.append(text)

    # ---- instruction emitters -------------------------------------------
    def emit(self, word, rd, text):
        self.words.append(word & 0xFFFFFFFF)
        self.note(rd, text)

    def alu_r(self):
        f3, f7, nm = self.rng.choice(ALU_R)
        rd, rs1, rs2 = self.dst_reg(), self.cheap_reg(), self.cheap_reg()
        self.emit(R(f7, rs2, rs1, f3, rd, OP_R), rd,
                  "%s x%d, x%d, x%d" % (nm, rd, rs1, rs2))

    def alu_i(self):
        f3, nm = self.rng.choice(ALU_I)
        rd, rs1 = self.dst_reg(), self.cheap_reg()
        imm = self.rng.choice([0, 1, -1, 7, -8, 2047, -2048,
                               self.rng.randint(-2048, 2047)])
        self.emit(I(imm, rs1, f3, rd, OP_I), rd,
                  "%s x%d, x%d, %d" % (nm, rd, rs1, imm))

    def load(self):
        f3, nm = self.rng.choice(LOADS)
        rd = self.dst_reg()
        off = self.rng.randrange(0, 128) * ALIGN[f3]
        self.emit(I(off, 8, f3, rd, OP_LOAD), rd,
                  "%s x%d, %d(x8)" % (nm, rd, off))

    def store(self):
        f3, nm = self.rng.choice(STORES)
        rs2 = self.cheap_reg()
        off = self.rng.randrange(0, 128) * ALIGN[f3]
        self.emit(S(off, rs2, 8, f3, OP_STORE), None,
                  "%s x%d, %d(x8)" % (nm, rs2, off))

    def putchar(self):
        rs2 = self.cheap_reg()
        self.emit(S(0, rs2, 30, 0, OP_STORE), None, "sb x%d, 0(x30)" % rs2)

    def branch(self):
        """Forward branch over a random number of instructions."""
        f3, nm = self.rng.choice(BRANCHES)
        rs1, rs2 = self.cheap_reg(), self.cheap_reg()
        span = self.rng.choice([1, 1, 2, 3, 5])
        # placeholder, patched once the span is known; the span is filled with
        # simple instructions only, so the patch index stays exact
        self.words.append(0)
        self.text.append("__BRANCH__")
        for _ in range(span):
            self.simple()
        self.words[len(self.words) - span - 1] = B(span * 4, rs2, rs1, f3, OP_BRANCH)
        self.text[len(self.text) - span - 1] = "%s x%d, x%d, +%d" % (nm, rs1, rs2, span * 4)

    def jal(self):
        rd = 0 if self.rng.random() < 0.5 else self.dst_reg()
        span = self.rng.choice([1, 2, 3])
        self.words.append(0)
        self.text.append("__JAL__")
        for _ in range(span):
            self.simple()
        self.words[len(self.words) - span - 1] = J(span * 4, rd, OP_JAL)
        self.text[len(self.text) - span - 1] = "jal x%d, +%d" % (rd, span * 4)

    def upper(self):
        rd = self.dst_reg()
        if self.rng.random() < 0.5:
            imm20 = self.rng.randrange(0, 1 << 20)
            self.emit(U(imm20, rd, OP_LUI), rd, "lui x%d, 0x%x" % (rd, imm20))
        else:
            self.emit(U(0x10000, rd, OP_AUIPC), rd, "auipc x%d, 0x10000" % rd)

    def simple(self):
        """One instruction without control flow (used to fill branch spans)."""
        r = self.rng.random()
        if r < 0.40:
            self.alu_r()
        elif r < 0.65:
            self.alu_i()
        elif r < 0.80:
            self.load()
        elif r < 0.95:
            self.store()
        else:
            self.upper()

    def step(self):
        r = self.rng.random()
        if r < 0.32:
            self.alu_r()
        elif r < 0.52:
            self.alu_i()
        elif r < 0.66:
            self.load()
        elif r < 0.76:
            self.store()
        elif r < 0.82:
            self.putchar()
        elif r < 0.92:
            self.branch()
        elif r < 0.96:
            self.jal()
        else:
            self.upper()

    # ---- program ---------------------------------------------------------
    def build(self):
        # prologue: fixed registers, never written afterwards
        self.words.append(U(DATA_BASE >> 12, 8, OP_LUI))          # x8  = 0x4000
        self.text.append("lui x8, 0x%x" % (DATA_BASE >> 12))
        self.words.append(U(0x10000, 28, OP_LUI))                 # x28 = halt MMIO
        self.words.append(I(4, 28, 0, 28, OP_I))
        self.text.append("li x28, 0x10000004")
        self.words.append(U(0x10000, 30, OP_LUI))                 # x30 = putchar
        self.text.append("li x30, 0x10000000")
        self.recent = []

        while len(self.words) < self.length:
            self.step()

        # epilogue: halt with code 0
        self.words.append(S(0, 0, 28, 2, OP_STORE))                # sw x0, 0(x28)
        self.text.append("sw x0, 0(x28)      # halt 0")
        return self.words


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--length", type=int, default=400,
                    help="approximate number of instructions")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--asm", help="also write a readable assembly listing")
    args = ap.parse_args(argv)

    g = Gen(args.seed, args.length)
    words = g.build()

    with open(args.output, "w") as fh:
        for w in words:
            fh.write("%08x\n" % w)

    if args.asm:
        with open(args.asm, "w") as fh:
            fh.write("# seed %d, %d words\n" % (args.seed, len(words)))
            for i, t in enumerate(g.text):
                fh.write("%04x: %s\n" % (i * 4, t))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
