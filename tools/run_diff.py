#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""rv32i-cpu -- decide every test program's outcome.

Two kinds of program live in tb/programs:

  * differential tests: correctness is decided by comparing the RTL event log
    line by line with the independent reference model, plus a word-for-word
    comparison of the architectural state (registers + memory).
    A log that matches the model but reports a self-check failure ("HALT 01")
    is still a FAILURE: the model would agree on the wrong answer.

  * expected-file tests (a .expected file exists): the RTL log must match the
    checked in expectation exactly.  These cover the cases where the RTL and
    the reference model intentionally differ (misaligned accesses trap in the
    core, the model is byte granular; the cycle counter is not modelled).

usage:
    run_diff.py --build build --names "smoke isa_alu ..." [--iss-dir DIR]
exit 0 = every program passed.
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def read_lines(path):
    if not os.path.exists(path):
        return None
    with open(path) as fh:
        return [l.rstrip("\n") for l in fh if l.strip() != ""]


def terminal_ok(lines):
    """True when the program ended in a successful halt or an expected trap."""
    for l in lines:
        if l.startswith("HALT") and l != "HALT 00":
            return False, "self-check reported %s" % l
    for l in lines:
        if l == "HALT 00" or l.startswith("TRAP "):
            return True, ""
    return False, "no terminal HALT/TRAP event"


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--names", required=True)
    ap.add_argument("--iss-dir", default=os.path.join(ROOT, "..", "rvai", "sw"))
    ap.add_argument("--prog-dir", default=os.path.join(ROOT, "tb", "programs"))
    args = ap.parse_args(argv)

    names = args.names.split()
    failures = []
    checked = 0

    for name in names:
        rtl_path = os.path.join(args.build, "rtl_%s.log" % name)
        rtl = read_lines(rtl_path)
        if rtl is None:
            failures.append((name, "missing RTL log %s" % rtl_path))
            print("  %-22s FAIL  (no RTL log)" % name)
            continue

        exp_path = os.path.join(args.prog_dir, "%s.expected" % name)

        if os.path.exists(exp_path):
            # ---- expected-file test ----------------------------------
            exp = read_lines(exp_path)
            if rtl == exp:
                print("  %-22s PASS  (expected log matched)" % name)
            else:
                diff = [(-1, -1)] if len(rtl) != len(exp) else []
                for i, (a, b) in enumerate(zip(rtl, exp)):
                    if a != b:
                        diff.append((i, i))
                msg = "expected log mismatch at line %s" % (
                    ",".join(str(i) for i, _ in diff[:5]) if diff else "?")
                failures.append((name, msg))
                print("  %-22s FAIL  (%s)" % (name, msg))
                for i in range(min(len(rtl), len(exp))):
                    if rtl[i] != exp[i]:
                        print("        rtl: %s" % rtl[i])
                        print("        exp: %s" % exp[i])
                        break
            checked += 1
            continue

        # ---- differential test ---------------------------------------
        iss_path = os.path.join(args.build, "iss_%s.log" % name)
        iss = read_lines(iss_path)
        if iss is None:
            failures.append((name, "missing model log %s" % iss_path))
            print("  %-22s FAIL  (no model log)" % name)
            continue

        ok, why = terminal_ok(rtl)
        if rtl != iss:
            n = 0
            for a, b in zip(rtl, iss):
                if a != b:
                    break
                n += 1
            failures.append((name, "log differs from the model at line %d" % n))
            print("  %-22s FAIL  (log differs at line %d)" % (name, n))
            for i in range(n, min(n + 3, max(len(rtl), len(iss)))):
                r = rtl[i] if i < len(rtl) else "<eof>"
                m = iss[i] if i < len(iss) else "<eof>"
                print("        rtl: %-30s model: %s" % (r, m))
            continue
        if not ok:
            failures.append((name, why))
            print("  %-22s FAIL  (%s, and the model agrees)" % (name, why))
            continue

        # ---- architectural state ------------------------------------
        state_path = os.path.join(args.build, "rtl_%s.state" % name)
        img_path = os.path.join(args.build, "%s.hex" % name)
        proc = subprocess.run(
            [sys.executable, os.path.join(HERE, "check_equiv.py"),
             img_path, state_path, "--iss-dir", args.iss_dir, "--quiet"],
            capture_output=True, text=True)
        if proc.returncode != 0:
            failures.append((name, "architectural state differs"))
            print("  %-22s FAIL  (state differs)" % name)
            print(proc.stdout.rstrip())
            continue

        checked += 1
        print("  %-22s PASS  (log + state identical to the model)" % name)

    print("")
    if failures:
        print("diff: %d of %d programs FAILED" % (len(failures), len(names)))
        for name, why in failures:
            print("   - %-22s %s" % (name, why))
        return 1
    print("diff: all %d programs passed" % checked)
    return 0


if __name__ == "__main__":
    sys.exit(main())
