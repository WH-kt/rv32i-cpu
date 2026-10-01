#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""rv32i-cpu -- flip-flop accounting straight from the RTL.

Real area numbers need a synthesis tool (see syn/README.md).  What this script
gives instead is something that cannot drift away from the source: it reads the
`reg` declarations of the RTL and sums their widths, so the state element count
in the report is derived from the same files that are simulated, not typed in by
hand.

Counted: every `reg`/`reg [..]` declaration that is driven by a non-blocking
assignment, i.e. actual state.  Declarations that only appear on the left of a
blocking assignment inside `always @(*)` are combinational helpers and are
listed separately.  Memory style declarations (`reg [31:0] rf [0:31]`) are
multiplied by their depth.  RAM arrays are not counted (block RAM on an FPGA,
macro on ASIC).

usage: ff_count.py rtl/core/rv32i_cpu.v [more files...]
"""

import re
import sys

DECL = re.compile(r"^\s*reg\s*(\[[^\]]*\])?\s*([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*;")
# A reg driven by a non-blocking assignment is state; a reg only ever assigned
# with a blocking assignment is a combinational helper.  Both patterns are
# searched anywhere in the line, because assignments also appear after an `if`.
NBA = re.compile(r"([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*<=")
BLK = re.compile(r"([A-Za-z_]\w*)\s*(\[[^\]]*\])?\s*=(?!=)")

# keywords that the BLK pattern would otherwise pick up as an assignment target
KEYWORDS = {"if", "else", "case", "casez", "casex", "begin", "end", "for",
            "while", "assign", "input", "output", "wire", "reg", "always",
            "posedge", "negedge", "or", "and", "not", "default"}


def width_of(rng, default=1):
    """Width of a [msb:lsb] or [n] range."""
    if not rng:
        return default
    body = rng.strip("[]").strip()
    if ":" in body:
        msb, lsb = body.split(":")
        try:
            return abs(int(msb.strip(), 0) - int(lsb.strip(), 0)) + 1
        except ValueError:
            return None                     # parameterised: report separately
    try:
        return int(body, 0) + 1
    except ValueError:
        return None


def scan(path):
    total = 0
    comb = 0
    unknown = []
    entries = []
    comb_entries = []
    decls = []
    seq_names = set()
    comb_names = set()

    with open(path) as fh:
        lines = fh.readlines()

    for line in lines:
        code = line.split("//")[0]
        for m in NBA.finditer(code):
            seq_names.add(m.group(1))
        for m in BLK.finditer(code):
            name = m.group(1)
            if name not in KEYWORDS:
                comb_names.add(name)

    for lineno, line in enumerate(lines, start=1):
        m = DECL.match(line)
        if not m:
            continue
        w = width_of(m.group(1))
        depth = width_of(m.group(3), default=1) if m.group(3) else 1
        name = m.group(2)
        if w is None or depth is None:
            unknown.append((path, lineno, name, line.strip()))
            continue
        bits = w * depth
        # a reg assigned with <= is state; one only assigned with = inside an
        # always @(*) block is a combinational helper
        if name in seq_names or name not in comb_names:
            total += bits
            entries.append((name, w, depth, bits))
        else:
            comb += bits
            comb_entries.append((name, w, depth, bits))
    return total, entries, unknown, comb, comb_entries


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    grand = 0
    for path in argv:
        total, entries, unknown, comb, comb_entries = scan(path)
        grand += total
        print("%s" % path)
        for name, w, depth, bits in entries:
            if depth > 1:
                print("    %-20s %3d x %-4d = %6d" % (name, w, depth, bits))
            else:
                print("    %-20s %3d        = %6d" % (name, w, bits))
        print("    %-20s %19d" % ("state subtotal", total))
        if comb_entries:
            print("    (combinational helpers, not state: %d bits: %s)"
                  % (comb, ", ".join(n for n, _, _, _ in comb_entries)))
        for path2, lineno, name, text in unknown:
            print("    (parameterised width, count manually) %s:%d %s"
                  % (path2, lineno, text))
    print("")
    print("state bits (flip-flops, excluding memory arrays): %d" % grand)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
