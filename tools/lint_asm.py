#!/usr/bin/env python3
"""rv32i-cpu -- immediate range linter for the assembly test programs.

The bundled assembler encodes I/S type immediates without range checking, so
`andi x7, x1, 0xF0F` is silently truncated to a 12 bit signed field and the test
program then checks the wrong value.  That is a test bug, not a core bug, and it
is exactly the kind of thing that hides a real failure, so the programs are
linted before they are assembled.

Checked:
  I type ALU  (addi slti sltiu xori ori andi)       imm in [-2048, 2047]
  shifts      (slli srli srai)                      imm in [0, 31]
  loads       (lb lh lw lbu lhu)                    offset in [-2048, 2047]
  stores      (sb sh sw)                            offset in [-2048, 2047]
  jalr with 3 operands                              imm in [-2048, 2047]

Anything symbolic (a label, an .equ) is skipped: the assembler resolves those
and reports out of range references itself.

usage:  lint_asm.py <file.S> [...]
exit 0 = clean, 1 = at least one out of range immediate
"""

import re
import sys

I_ALU = {"addi", "slti", "sltiu", "xori", "ori", "andi"}
SHIFT = {"slli", "srli", "srai"}
LOADS = {"lb", "lh", "lw", "lbu", "lhu"}
STORES = {"sb", "sh", "sw"}

LABEL = re.compile(r"^\s*[A-Za-z_.$][\w.$]*\s*:")
MEMOP = re.compile(r"^\s*(-?(?:0[xX][0-9a-fA-F]+|\d+))\s*\(\s*[A-Za-z_][\w]*\s*\)\s*$")


def parse_int(tok):
    """Return the integer value of a plain literal, or None if symbolic."""
    tok = tok.strip()
    try:
        return int(tok, 0)
    except ValueError:
        return None


def split_ops(text):
    """Split an operand list on commas, tolerating the off(reg) form."""
    return [p.strip() for p in text.split(",")]


def check_line(text, path, lineno, problems):
    ops = split_ops(text)
    if not ops:
        return
    head = ops[0].split()
    if not head:
        return
    mn = head[0].lower()
    args = [head[1]] if len(head) > 1 else []
    args += ops[1:]
    args = [a for a in args if a != ""]

    def bad(val, lo, hi, what):
        problems.append("%s:%d: %s immediate %d out of range [%d, %d]"
                        % (path, lineno, what, val, lo, hi))

    if mn in I_ALU or mn in SHIFT:
        if len(args) >= 3:
            v = parse_int(args[2])
            if v is not None:
                if mn in SHIFT:
                    if not 0 <= v <= 31:
                        bad(v, 0, 31, mn)
                elif not -2048 <= v <= 2047:
                    bad(v, -2048, 2047, mn)
    elif mn in LOADS:
        if len(args) >= 2:
            m = MEMOP.match(args[1])
            if m:
                v = parse_int(m.group(1))
                if v is not None and not -2048 <= v <= 2047:
                    bad(v, -2048, 2047, mn)
    elif mn in STORES:
        if len(args) >= 2:
            m = MEMOP.match(args[1])
            if m:
                v = parse_int(m.group(1))
                if v is not None and not -2048 <= v <= 2047:
                    bad(v, -2048, 2047, mn)
    elif mn == "jalr" and len(args) == 3:
        v = parse_int(args[2])
        if v is not None and not -2048 <= v <= 2047:
            bad(v, -2048, 2047, mn)


def strip_comment(line):
    for c in ("#", "//", ";"):
        i = line.find(c)
        if i >= 0:
            line = line[:i]
    return line


def check_file(path):
    problems = []
    with open(path) as fh:
        for lineno, raw in enumerate(fh, start=1):
            text = strip_comment(raw)
            while True:
                m = LABEL.match(text)
                if not m:
                    break
                text = text[m.end():]
            text = text.strip()
            if not text or text.startswith("."):
                continue
            check_line(text, path, lineno, problems)
    return problems


def main(argv):
    if not argv:
        print("usage: lint_asm.py <file.S> [...]")
        return 2
    all_problems = []
    for path in argv:
        all_problems += check_file(path)
    for p in all_problems:
        print(p)
    if all_problems:
        print("lint_asm: %d immediate range problem(s)" % len(all_problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
