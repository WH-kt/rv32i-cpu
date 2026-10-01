#!/usr/bin/env python3
"""rv32i-cpu -- dynamic instruction coverage from the RTL's retire port.

`make sim` can be run with tracing enabled; the testbench then writes one line
per retired instruction using the core's own retire port:

    <pc> <instruction>
    trap <cause> <tval>          (instructions that trapped instead of retiring)

This script replays every program with tracing on, decodes the executed
encodings and reports which RV32I instructions were never executed.  Coverage
is measured on what the hardware actually retired, not on what the assembler
put in the image, so an instruction that is present but never reached does not
count as covered.

usage:
    coverage.py [--build build] [--names "a b c"] [--vvp "vvp build/tb_rv32i.vvp"]
                [--min 100]
exit 0 when every RV32I encoding has been executed at least once.
"""

import argparse
import os
import subprocess
import sys

# ---------------------------------------------------------------------------
# the RV32I instruction set, keyed by (opcode, funct3, funct7)
# funct7 is None where the field is part of the immediate
# ---------------------------------------------------------------------------
ISA = {}


def add(name, op, f3, f7=None):
    ISA[(op, f3, f7)] = name


for f3, f7, nm in [(0, 0x00, "ADD"), (0, 0x20, "SUB"), (1, 0x00, "SLL"),
                   (2, 0x00, "SLT"), (3, 0x00, "SLTU"), (4, 0x00, "XOR"),
                   (5, 0x00, "SRL"), (5, 0x20, "SRA"), (6, 0x00, "OR"),
                   (7, 0x00, "AND")]:
    add(nm, 0x33, f3, f7)

for f3, nm in [(0, "ADDI"), (2, "SLTI"), (3, "SLTIU"), (4, "XORI"),
               (6, "ORI"), (7, "ANDI")]:
    add(nm, 0x13, f3, None)
add("SLLI", 0x13, 1, 0x00)
add("SRLI", 0x13, 5, 0x00)
add("SRAI", 0x13, 5, 0x20)

for f3, nm in [(0, "LB"), (1, "LH"), (2, "LW"), (4, "LBU"), (5, "LHU")]:
    add(nm, 0x03, f3, None)

for f3, nm in [(0, "SB"), (1, "SH"), (2, "SW")]:
    add(nm, 0x23, f3, None)

for f3, nm in [(0, "BEQ"), (1, "BNE"), (4, "BLT"), (5, "BGE"), (6, "BLTU"),
               (7, "BGEU")]:
    add(nm, 0x63, f3, None)

# U/J type and FENCE/SYSTEM: funct3 is not a discriminator (it is part of the
# immediate for U and J type), so the key normalises it to zero
add("LUI", 0x37, 0, None)
add("AUIPC", 0x17, 0, None)
add("JAL", 0x6F, 0, None)
add("JALR", 0x67, 0, None)
add("FENCE", 0x0F, 0, None)
add("ECALL", 0x73, 0, None)
add("EBREAK", 0x73, 1, None)


def decode(insn):
    """Return the coverage key of an encoding, or a key ending in 'illegal'."""
    op = insn & 0x7F
    f3 = (insn >> 12) & 0x7
    f7 = (insn >> 25) & 0x7F
    imm12 = (insn >> 20) & 0xFFF

    if op == 0x33:                                   # R type
        return (op, f3, f7 if f3 in (0, 5) else 0x00)
    if op == 0x13:                                   # I type ALU / shifts
        if f3 in (1, 5):
            top = imm12 >> 5                         # funct7 position
            if top == 0x00:
                return (op, f3, 0x00)
            if top == 0x20:
                return (op, f3, 0x20)
            return (op, f3, "illegal")
        return (op, f3, None)
    if op in (0x03, 0x23):                           # loads / stores
        return (op, f3, None)
    if op == 0x63:                                   # branches
        return (op, f3, None) if f3 not in (2, 3) else (op, f3, "illegal")
    if op == 0x67:                                   # JALR
        return (op, 0, None) if f3 == 0 else (op, f3, "illegal")
    if op in (0x37, 0x17, 0x6F, 0x0F):               # LUI/AUIPC/JAL/FENCE
        return (op, 0, None)
    if op == 0x73:                                   # SYSTEM
        if insn == 0x00000073:
            return (op, 0, None)
        if insn == 0x00100073:
            return (op, 1, None)
        return (op, f3, "illegal")
    return (op, f3, "illegal")


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--names", required=True)
    ap.add_argument("--vvp", default=None)
    ap.add_argument("--min", type=int, default=1,
                    help="minimum executions for an instruction to count")
    args = ap.parse_args(argv)

    names = args.names.split()
    vvp = args.vvp or ("vvp " + os.path.join(args.build, "tb_rv32i.vvp"))
    work = os.path.join(args.build, "cov")
    os.makedirs(work, exist_ok=True)

    counts = {}
    traps = {}
    total = 0
    executed_illegal = 0

    for name in names:
        hex_path = os.path.join(args.build, "%s.hex" % name)
        subprocess.run(["cp", hex_path, os.path.join(args.build, "image.hex")],
                       check=True)
        trace_path = os.path.join(work, "%s.trace" % name)
        proc = subprocess.run(
            vvp.split() + ["+log=" + os.path.join(work, "%s.log" % name),
                           "+state=" + os.path.join(work, "%s.state" % name),
                           "+trace=" + trace_path, "+max_cycles=400000"],
            capture_output=True, text=True)
        if proc.returncode != 0:
            print("coverage: RTL run of %s failed" % name)
            print(proc.stdout)
            return 2
        with open(trace_path) as fh:
            for line in fh:
                parts = line.split()
                if not parts:
                    continue
                if parts[0] == "trap":
                    cause = int(parts[1])
                    traps[cause] = traps.get(cause, 0) + 1
                    # An instruction that traps never retires, so it would be
                    # invisible to retire based coverage.  ECALL and EBREAK are
                    # real RV32I instructions and must still count as executed.
                    if cause == 11:
                        counts[(0x73, 0, None)] = counts.get((0x73, 0, None), 0) + 1
                        total += 1
                    elif cause == 3:
                        counts[(0x73, 1, None)] = counts.get((0x73, 1, None), 0) + 1
                        total += 1
                    elif cause == 2:
                        executed_illegal += 1
                    continue
                insn = int(parts[1], 16)
                key = decode(insn)
                counts[key] = counts.get(key, 0) + 1
                total += 1

    # ---- report ----------------------------------------------------------
    print("instruction coverage (from the RTL retire port)")
    print("  programs      : %d" % len(names))
    print("  retired insns : %d" % total)
    print("  traps         : %s" % (", ".join("cause %d x%d" % (k, v)
                                              for k, v in sorted(traps.items()))
                                    or "none"))
    missing = []
    for key, nm in sorted(ISA.items(), key=lambda kv: kv[1]):
        n = counts.get(key, 0)
        if n < args.min:
            missing.append((nm, key, n))
    print("  distinct RV32I instructions executed: %d / %d"
          % (len(ISA) - len(missing), len(ISA)))
    if missing:
        print("  NOT COVERED:")
        for nm, key, n in missing:
            print("    %-12s opcode=%02x funct3=%d funct7=%s (executed %d)"
                  % (nm, key[0], key[1], key[2], n))
    unknown = [k for k in counts if k not in ISA]
    if unknown:
        print("  WARNING illegal encodings counted as executed: %s" % unknown)
    if executed_illegal:
        print("  illegal instruction traps observed: %d" % executed_illegal)

    if missing:
        print("coverage: INCOMPLETE")
        return 1
    print("coverage: COMPLETE (every RV32I encoding executed at least %d time(s))"
          % args.min)
    return 0


if __name__ == "__main__":
    sys.exit(main())
