#!/usr/bin/env python3
"""rv32i-cpu -- differential architectural state comparison.

    check_equiv.py <image.hex> <state_file> [--max N] [--iss-dir DIR]

Runs the *independent* RV32I reference model on the same image and compares its
final architectural state (32 registers and the whole data memory) against the
state dump written by tb/tb_rv32i.v, word for word.

The event log comparison (`diff rtl_*.log iss_*.log`) already catches control
flow and MMIO differences; this catches data differences that never reach an
event, which is exactly the class of bug a forwarding or write-through mistake
produces.

Exit code 0 means the two states are identical.
"""

import argparse
import os
import sys

MEM_WORDS = 16384                     # must match rv32i_soc / tb_rv32i

DEFAULT_ISS_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                               "..", "..", "rvai", "sw")


def load_state(path):
    """Parse the RTL state dump: REGS <32 words> MEM <16384 words>."""
    regs, mem = [], []
    section = None
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            if line == "REGS":
                section = "regs"
                continue
            if line == "MEM":
                section = "mem"
                continue
            val = int(line, 16)
            if section == "regs":
                regs.append(val)
            elif section == "mem":
                mem.append(val)
    return regs, mem


def report(name, rtl, ref, limit=8):
    """Print the first few mismatches of two word lists."""
    bad = 0
    for i, (a, b) in enumerate(zip(rtl, ref)):
        if a != b:
            if bad < limit:
                print("  %s[%d]: rtl=%08x ref=%08x" % (name, i, a, b))
            bad += 1
    if len(rtl) != len(ref):
        print("  %s: length mismatch rtl=%d ref=%d" % (name, len(rtl), len(ref)))
        bad += abs(len(rtl) - len(ref))
    if bad:
        print("  %s: %d mismatching words" % (name, bad))
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("image")
    ap.add_argument("state")
    ap.add_argument("--max", type=int, default=4_000_000)
    ap.add_argument("--iss-dir", default=os.environ.get("RVAI_DIR", DEFAULT_ISS_DIR))
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    sys.path.insert(0, os.path.abspath(args.iss_dir))
    try:
        import iss as issc
    except ImportError as exc:
        print("check_equiv: cannot import the reference model from %s: %s"
              % (args.iss_dir, exc))
        return 2

    img = issc.load_hex(args.image)
    sim = issc.ISS(img)
    steps, code = sim.run(args.max)

    rtl_regs, rtl_mem = load_state(args.state)

    bad = 0
    bad += report("reg", rtl_regs, sim.reg)
    bad += report("mem", rtl_mem, sim.mem)

    if bad:
        print("check_equiv: FAIL (%d differences, model exit=%d steps=%d)"
              % (bad, code, steps))
        return 1

    if not args.quiet:
        print("check_equiv: PASS (regs + %d memory words identical, model exit=%d steps=%d)"
              % (len(sim.mem), code, steps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
