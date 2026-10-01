#!/usr/bin/env python3
"""rvai ISS -- an independent RV32I + Xai instruction-set simulator.

This is the third implementation of the same architecture, and the point is
that all three are written from the specification rather than from each other:

    int8mac (C)      ground truth for the dot-product arithmetic
    this ISS         ground truth for the RV32I + Xai instruction semantics
    rvai_soc (RTL)   the device under test

The ISS runs the same image as the RTL and emits the same event log (putchar,
marker, halt), so `diff` between the two logs is a full-system equivalence
check: any instruction whose semantics differ, any addressing mistake, any
divergent control flow shows up as a differing event stream or a differing
final memory checksum.

The simulation-control region is modelled exactly as rvai_soc implements it:

    0x1000_0000  W  putchar bits[7:0]
    0x1000_0004  W  halt, bits[7:0] = exit code
    0x1000_0008  W  marker
    0x1000_000c  R  cycle count -- returns 0 here, because cycle-accurate timing
                    is exactly what the ISS does NOT model.  Firmware that
                    prints it is a benchmark, not an equivalence test.

Usage:  iss.py image.hex [--max 2000000] [--trace] [--dump-mem words]
"""

import argparse
import sys

# --------------------------------------------------------------------------
# constants
# --------------------------------------------------------------------------
MEM_WORDS = 16384                      # 64 KiB, matching rvai_soc
RAM_LIMIT = MEM_WORDS * 4

SIM_BASE = 0x1000_0000
SIM_PUTCHAR = SIM_BASE + 0x0
SIM_HALT = SIM_BASE + 0x4
SIM_MARKER = SIM_BASE + 0x8
SIM_CYCLES = SIM_BASE + 0xc

ACCEL_BASE = 0x2000_0000               # modelled in soc mode only

XAI_OP, XAI_F7 = 0b0001011, 0b0001000


def sx(v, bits):
    """Sign-extend the low `bits` bits of v."""
    m = 1 << (bits - 1)
    v &= (1 << bits) - 1
    return (v ^ m) - m


def u32(v):
    return v & 0xFFFFFFFF


class Halt(Exception):
    def __init__(self, code):
        self.code = code


class Trap(Exception):
    pass


# --------------------------------------------------------------------------
# ISS
# --------------------------------------------------------------------------
class ISS:
    def __init__(self, image, verbose=False, accel=None):
        self.mem = [0] * MEM_WORDS
        for i, w in enumerate(image):
            if i < MEM_WORDS:
                self.mem[i] = u32(w)
        self.reg = [0] * 32
        self.pc = 0
        self.cycle = 0            # instruction count; not RTL-accurate
        self.events = []
        self.verbose = verbose
        self.trace = []
        self.accel = accel        # None => accelerator reads as zero

        # ---- accelerator register file (mirrors rvai_accel) ----
        self.a_acc = 0
        self.a_n = 0
        self.a_store_a = [0] * 16
        self.a_store_b = [0] * 16
        self.a_busy = 0
        self.a_done = 0
        self.a_cycles = 0
        self.a_src_mem = 0
        self.a_addr = 0
        self.b_addr = 0

    # ---- memory ---------------------------------------------------------
    def rd(self, addr, size, signed):
        addr &= 0xFFFFFFFF
        if addr < RAM_LIMIT:
            raw = 0
            for k in range(size):
                a = addr + k
                if a < RAM_LIMIT:
                    raw |= ((self.mem[a >> 2] >> (8 * (a & 3))) & 0xFF) << (8 * k)
        elif (addr & 0xFFFF0000) == SIM_BASE:
            raw = 0
            if addr == SIM_CYCLES:
                raw = 0                       # timing is not modelled
        elif (addr & 0xFFFF0000) == ACCEL_BASE:
            raw = self._accel_read(addr & 0xFFF)
        else:
            raw = 0
        if signed:
            return sx(raw, size * 8)
        return raw & ((1 << (size * 8)) - 1)

    def wr(self, addr, size, val):
        addr &= 0xFFFFFFFF
        val &= 0xFFFFFFFF
        if addr < RAM_LIMIT:
            for k in range(size):
                a = addr + k
                if a < RAM_LIMIT:
                    sh = 8 * (a & 3)
                    self.mem[a >> 2] = u32((self.mem[a >> 2] & ~(0xFF << sh)) |
                                           (((val >> (8 * k)) & 0xFF) << sh))
        elif (addr & 0xFFFF0000) == SIM_BASE:
            if addr == SIM_PUTCHAR:
                ch = val & 0xFF
                # The log format is deliberately identical to what tb_soc.v
                # writes, so comparing the two is a plain line diff rather than
                # a translation that could itself be wrong.
                self.events.append("PUTC %02x" % ch)
                if self.verbose:
                    sys.stderr.write(chr(ch))
            elif addr == SIM_HALT:
                raise Halt(val & 0xFF)
            elif addr == SIM_MARKER:
                self.events.append("MARK %08x" % (val & 0xFFFFFFFF))
        elif (addr & 0xFFFF0000) == ACCEL_BASE:
            self._accel_write(addr & 0xFFF, val)

    # ---- accelerator model ---------------------------------------------
    def _accel_read(self, off):
        if self.accel is None:
            return 0
        if off == 0x000:
            return (((self.a_src_mem & 1) << 2) |
                    ((self.a_done & 1) << 1) | (self.a_busy & 1))
        if off == 0x004:
            return self.a_n
        if off == 0x008:
            return u32(self.a_acc)
        if off == 0x00c:
            return self.a_cycles
        if off == 0x010:
            return self.a_addr
        if off == 0x014:
            return self.b_addr
        if 0x100 <= off < 0x100 + 64:
            return self.a_store_a[(off - 0x100) >> 2]
        if 0x200 <= off < 0x200 + 64:
            return self.a_store_b[(off - 0x200) >> 2]
        return 0

    def _accel_write(self, off, val):
        if self.accel is None:
            return
        if off == 0x000:
            self.a_src_mem = (val >> 1) & 1
            if val & 1:
                # The engine runs to completion in zero simulated time: its
                # latency is not modelled, only its result.  What IS modelled is
                # the DMA path, because it changes the result -- if the fetch
                # addresses or count were wrong, the RTL and the ISS would
                # disagree on the answer, which is exactly the point.
                if self.a_src_mem:
                    nw = min((self.a_n + 3) // 4, len(self.a_store_a))
                    for i in range(nw):
                        self.a_store_a[i] = self.rd(self.a_addr + 4 * i, 4, False)
                        self.a_store_b[i] = self.rd(self.b_addr + 4 * i, 4, False)
                n = min(self.a_n, len(self.a_store_a) * 4)
                total = self.a_acc
                for i in range(n):
                    a = sx((self.a_store_a[i >> 2] >> (8 * (i & 3))) & 0xFF, 8)
                    b = sx((self.a_store_b[i >> 2] >> (8 * (i & 3))) & 0xFF, 8)
                    total += a * b
                self.a_acc = u32(total)
                self.a_done = 1
                self.a_busy = 0
                self.a_cycles = 0
        elif off == 0x004:
            self.a_n = val
        elif off == 0x008:
            self.a_acc = u32(val)
        elif off == 0x010:
            self.a_addr = u32(val)
        elif off == 0x014:
            self.b_addr = u32(val)
        elif 0x100 <= off < 0x100 + 64:
            self.a_store_a[(off - 0x100) >> 2] = u32(val)
        elif 0x200 <= off < 0x200 + 64:
            self.a_store_b[(off - 0x200) >> 2] = u32(val)

    # ---- fetch ----------------------------------------------------------
    def fetch(self):
        return self.rd(self.pc, 4, signed=False)

    # ---- Xai ------------------------------------------------------------
    @staticmethod
    def xai_dot(rs1, rs2, lanes=4):
        total = 0
        for i in range(lanes):
            a = sx((rs1 >> (8 * i)) & 0xFF, 8)
            b = sx((rs2 >> (8 * i)) & 0xFF, 8)
            total += a * b
        return u32(total)

    @staticmethod
    def xai_requant(acc, params):
        """Round half AWAY FROM ZERO, then saturate -- matching
        int8mac_requantize_fx().  Adding the bias to a signed value and
        arithmetic-shifting would round half UP instead, which differs on every
        exact tie."""
        m = sx(params & 0xFFFF, 16)
        shift = (params >> 16) & 0x3F
        zp = sx((params >> 22) & 0xFF, 8)
        p = sx(acc, 32) * m
        mag = -p if p < 0 else p
        bias = 0 if shift == 0 else (1 << (shift - 1))
        q = (mag + bias) >> shift
        v = (-q if p < 0 else q) + zp
        if v > 127:
            v = 127
        if v < -128:
            v = -128
        return v

    # ---- RV32M ----------------------------------------------------------
    @staticmethod
    def _muldiv(f3, a, b, sa, sb):
        if f3 == 0:                                   # mul
            return u32(sa * sb)
        if f3 == 1:                                   # mulh
            return u32((sa * sb) >> 32)
        if f3 == 2:                                   # mulhsu
            return u32((sa * b) >> 32)
        if f3 == 3:                                   # mulhu
            return u32((a * b) >> 32)
        if f3 == 4:                                   # div
            if b == 0:
                return 0xFFFFFFFF
            q = abs(sa) // abs(sb)
            return u32(-q if (sa < 0) != (sb < 0) else q)
        if f3 == 5:                                   # divu
            return 0xFFFFFFFF if b == 0 else u32(a // b)
        if f3 == 6:                                   # rem
            if b == 0:
                return u32(sa)
            r = abs(sa) % abs(sb)
            return u32(-r if sa < 0 else r)
        if f3 == 7:                                   # remu
            return u32(a) if b == 0 else u32(a % b)
        raise Trap("muldiv funct3=%d" % f3)

    # ---- step -----------------------------------------------------------
    def step(self):
        pc = self.pc
        insn = self.fetch()
        opcode = insn & 0x7F
        rd = (insn >> 7) & 31
        f3 = (insn >> 12) & 7
        rs1 = (insn >> 15) & 31
        rs2 = (insn >> 20) & 31
        f7 = (insn >> 25) & 0x7F
        a = self.reg[rs1]
        b = self.reg[rs2]

        def w(v):
            if rd:
                self.reg[rd] = u32(v)

        if self.verbose:
            self.trace.append((pc, insn))

        self.cycle += 1
        self.pc = u32(self.pc + 4)          # default: fall through
        next_pc = self.pc

        # ---------------- Xai (custom-0) ----------------
        if opcode == XAI_OP and f7 == XAI_F7:
            if f3 == 0:                                   # ai.clr
                self.xacc = 0
                w(0)
            elif f3 == 1:                                 # ai.dot
                self.xacc = u32(self.xacc + self.xai_dot(a, b))
                w(self.xacc)
            elif f3 == 2:                                 # ai.dotr
                w(self.xai_dot(a, b))
            elif f3 == 3:                                 # ai.acc
                w(self.xacc)
            elif f3 == 4:                                 # ai.rq
                w(sx(self.xai_requant(a, b), 8) & 0xFFFFFFFF)
            else:
                raise Trap("xai funct3=%d" % f3)
            self.pc = next_pc
            return

        # ---------------- LUI / AUIPC ----------------
        if opcode == 0b0110111:                            # lui
            w(insn & 0xFFFFF000)
        elif opcode == 0b0010111:                          # auipc
            w(pc + (insn & 0xFFFFF000))

        # ---------------- JAL ----------------
        elif opcode == 0b1101111:
            imm = sx(((insn >> 31) << 20) | (((insn >> 12) & 0xFF) << 12) |
                     (((insn >> 20) & 1) << 11) | (((insn >> 21) & 0x3FF) << 1), 21)
            w(pc + 4)
            next_pc = u32(pc + imm)

        # ---------------- JALR ----------------
        elif opcode == 0b1100111:
            if f3 != 0:
                raise Trap("jalr funct3")
            imm = sx(insn >> 20, 12)
            t = u32(a + imm)
            w(pc + 4)
            next_pc = t & ~1

        # ---------------- branches ----------------
        elif opcode == 0b1100011:
            imm = sx(((insn >> 31) << 12) | (((insn >> 7) & 1) << 11) |
                     (((insn >> 25) & 0x3F) << 5) | (((insn >> 8) & 0xF) << 1), 13)
            sa, sb = sx(a, 32), sx(b, 32)
            take = {0: a == b, 1: a != b, 4: sa < sb, 5: sa >= sb,
                    6: a < b, 7: a >= b}.get(f3)
            if take is None:
                raise Trap("branch funct3=%d" % f3)
            if take:
                next_pc = u32(pc + imm)

        # ---------------- loads ----------------
        elif opcode == 0b0000011:
            imm = sx(insn >> 20, 12)
            addr = u32(a + imm)
            if f3 == 0:
                w(self.rd(addr, 1, True))
            elif f3 == 1:
                w(self.rd(addr, 2, True))
            elif f3 == 2:
                w(self.rd(addr, 4, True))
            elif f3 == 4:
                w(self.rd(addr, 1, False))
            elif f3 == 5:
                w(self.rd(addr, 2, False))
            else:
                raise Trap("load funct3=%d" % f3)

        # ---------------- stores ----------------
        elif opcode == 0b0100011:
            imm = sx(((insn >> 25) << 5) | ((insn >> 7) & 0x1F), 12)
            addr = u32(a + imm)
            if f3 == 0:
                self.wr(addr, 1, b)
            elif f3 == 1:
                self.wr(addr, 2, b)
            elif f3 == 2:
                self.wr(addr, 4, b)
            else:
                raise Trap("store funct3=%d" % f3)

        # ---------------- OP-IMM ----------------
        elif opcode == 0b0010011:
            imm = sx(insn >> 20, 12)
            sh = (insn >> 20) & 0x1F
            if f3 == 0:
                w(a + imm)
            elif f3 == 2:
                w(1 if sx(a, 32) < imm else 0)
            elif f3 == 3:
                w(1 if a < u32(imm) else 0)
            elif f3 == 4:
                w(a ^ u32(imm))
            elif f3 == 6:
                w(a | u32(imm))
            elif f3 == 7:
                w(a & u32(imm))
            elif f3 == 1:
                w(a << sh)
            elif f3 == 5:
                if f7 == 0:
                    w(a >> sh)
                elif f7 == 0b0100000:
                    w(sx(a, 32) >> sh)
                else:
                    raise Trap("srai funct7")

        # ---------------- OP ----------------
        elif opcode == 0b0110011:
            sa, sb = sx(a, 32), sx(b, 32)
            if f7 == 0b0000000:
                w({0: a + b, 1: a << (b & 31), 2: 1 if sa < sb else 0,
                   3: 1 if a < b else 0, 4: a ^ b, 5: a >> (b & 31),
                   6: a | b, 7: a & b}[f3])
            elif f7 == 0b0100000:
                w({0: a - b, 5: sa >> (b & 31)}[f3])
            elif f7 == 0b0000001:
                w(self._muldiv(f3, a, b, sa, sb))
            else:
                raise Trap("op funct7=%02x" % f7)

        # ---------------- SYSTEM / misc ----------------
        elif opcode == 0b1110011:
            fs12 = (insn >> 20) & 0xFFF
            if fs12 == 0x000:
                raise Trap("ecall")
            if fs12 == 0x001:
                raise Halt(0)
            if fs12 == 0xC00:
                w(self.cycle)          # rdcycle: instruction count, not cycles
            elif fs12 == 0xC02:
                w(self.cycle)          # rdinstret
            elif fs12 == 0xC01:
                w(0)                   # rdtime
            elif fs12 in (0xC80, 0xC81, 0xC82):
                w(0)                   # rdcycleh / rdtimeh / rdinstreth
            else:
                raise Trap("system csr %03x" % fs12)
        elif opcode == 0b0001111:
            pass                       # fence
        else:
            raise Trap("opcode %02x (insn %08x)" % (opcode, insn))

        self.pc = next_pc
        self.xacc = getattr(self, "xacc", 0)

    # ---- run ------------------------------------------------------------
    def run(self, max_steps=2_000_000):
        self.xacc = 0
        steps = 0
        try:
            while steps < max_steps:
                self.step()
                steps += 1
                if self.pc >= RAM_LIMIT and not (SIM_BASE <= self.pc < SIM_BASE + 0x1000):
                    pass
        except Halt as h:
            self.events.append("HALT %02x" % h.code)
            return steps, h.code
        except Trap as t:
            self.events.append("TRAP %s" % t)
            return steps, -1
        self.events.append("TIMEOUT")
        return steps, -2

    def checksum(self):
        """Order-sensitive memory checksum, ignoring the zero tail.

        A plain sum would be insensitive to byte order and to two words
        swapping; this mixes position and value, so any divergence in the data
        region changes it.
        """
        h = 2166136261
        for i, w in enumerate(self.mem):
            h = ((h ^ (w & 0xFF)) * 16777619) & 0xFFFFFFFF
            h = ((h ^ ((w >> 8) & 0xFF)) * 16777619) & 0xFFFFFFFF
            h = ((h ^ ((w >> 16) & 0xFF)) * 16777619) & 0xFFFFFFFF
            h = ((h ^ ((w >> 24) & 0xFF)) * 16777619) & 0xFFFFFFFF
        return h


def _printable(ch):
    if 32 <= ch < 127:
        return "'%s'" % chr(ch)
    if ch == 10:
        return "'\\n'"
    return "'.'"


def load_hex(path):
    words = []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("//") or line.startswith("@"):
                continue
            words.append(int(line, 16))
    return words


def main(argv=None):
    ap = argparse.ArgumentParser(description="RV32I + Xai instruction set simulator")
    ap.add_argument("image")
    ap.add_argument("--max", type=int, default=4_000_000)
    ap.add_argument("--trace", action="store_true")
    ap.add_argument("--accel", action="store_true",
                    help="model the memory-mapped accelerator")
    ap.add_argument("--dump-mem", type=int, default=0,
                    help="print the first N RAM words")
    ap.add_argument("--mem-dump", help="write the final RAM image here, one word per line")
    ap.add_argument("--log", help="write the event log here (default stdout)")
    args = ap.parse_args(argv)

    img = load_hex(args.image)
    sim = ISS(img, verbose=args.trace, accel=(True if args.accel else None))
    steps, code = sim.run(args.max)

    out = []
    out.extend(sim.events)
    out.append("CHECKSUM %08x" % sim.checksum())
    out.append("STEPS %d" % steps)
    text = "\n".join(out)

    if args.log:
        with open(args.log, "w") as fh:
            fh.write(text + "\n")
    print(text)
    if args.mem_dump:
        with open(args.mem_dump, "w") as fh:
            for w in sim.mem:
                fh.write("%08x\n" % w)
    if args.dump_mem:
        for i in range(args.dump_mem):
            print("%04x: %08x" % (i, sim.mem[i]))
    return 0 if code == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
