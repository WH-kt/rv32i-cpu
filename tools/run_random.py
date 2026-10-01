#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""rv32i-cpu -- constrained random differential regression.

For every seed: generate a random program, run it on the RTL and on the
independent reference model, and require

  * an identical event log (including the memory checksum and the instruction
    count), and
  * an identical architectural state (32 registers + the whole data memory).

Failing seeds are kept as build/random/fail_<seed>.hex and .S so the case can be
replayed and inspected.

usage:
    run_random.py --seeds 200 [--length 400] [--start 0]
                  [--build build] [--vvp "vvp build/tb_rv32i.vvp"]
                  [--iss-dir ../rvai/sw] [--stop-on-fail]
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def rtl_log_text(sim_events, checksum, steps):
    out = list(sim_events)
    out.append("CHECKSUM %08x" % checksum)
    out.append("STEPS %d" % steps)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--seeds", type=int, default=100)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--length", type=int, default=400)
    ap.add_argument("--build", default="build")
    ap.add_argument("--vvp", default=None)
    ap.add_argument("--iss-dir", default=os.path.join(ROOT, "..", "rvai", "sw"))
    ap.add_argument("--stop-on-fail", action="store_true")
    ap.add_argument("--keep", action="store_true", help="keep every generated program")
    args = ap.parse_args(argv)

    work = os.path.join(args.build, "random")
    os.makedirs(work, exist_ok=True)

    vvp = args.vvp or ("vvp " + os.path.join(args.build, "tb_rv32i.vvp"))

    sys.path.insert(0, os.path.abspath(args.iss_dir))
    sys.path.insert(0, HERE)
    import iss as issc
    import check_equiv as ce
    import gen_random as gr

    failed = []
    print("random: seeds %d..%d, length ~%d instructions"
          % (args.start, args.start + args.seeds - 1, args.length))

    for seed in range(args.start, args.start + args.seeds):
        hex_path = os.path.join(work, "seed%d.hex" % seed)
        asm_path = os.path.join(work, "seed%d.S" % seed)
        g = gr.Gen(seed, args.length)
        words = g.build()
        with open(hex_path, "w") as fh:
            for w in words:
                fh.write("%08x\n" % w)
        if args.keep:
            with open(asm_path, "w") as fh:
                fh.write("# seed %d\n" % seed)
                for i, t in enumerate(g.text):
                    fh.write("%04x: %s\n" % (i * 4, t))

        # ---- RTL ----
        subprocess.run(["cp", hex_path, os.path.join(args.build, "image.hex")],
                       check=True)
        log_path = os.path.join(work, "seed%d.log" % seed)
        state_path = os.path.join(work, "seed%d.state" % seed)
        proc = subprocess.run(vvp.split() +
                              ["+log=" + log_path, "+state=" + state_path,
                               "+max_cycles=400000"],
                              capture_output=True, text=True)
        if proc.returncode != 0:
            failed.append((seed, "RTL run failed: " + proc.stdout.strip()))
            print("  seed %-6d FAIL  (simulator error)" % seed)
            if args.stop_on_fail:
                break
            continue
        rtl_log = [l.rstrip("\n") for l in open(log_path) if l.strip()]

        # ---- reference model ----
        img = issc.load_hex(hex_path)
        sim = issc.ISS(img)
        steps, code = sim.run(4_000_000)
        ref_log = rtl_log_text(sim.events, sim.checksum(), steps)

        if rtl_log != ref_log:
            n = 0
            while n < min(len(rtl_log), len(ref_log)) and rtl_log[n] == ref_log[n]:
                n += 1
            r = rtl_log[n] if n < len(rtl_log) else "<eof>"
            m = ref_log[n] if n < len(ref_log) else "<eof>"
            failed.append((seed, "log line %d: rtl=%r model=%r" % (n, r, m)))
            print("  seed %-6d FAIL  (log: rtl=%r model=%r)" % (seed, r, m))
            os.rename(hex_path, os.path.join(work, "fail_seed%d.hex" % seed))
            with open(os.path.join(work, "fail_seed%d.S" % seed), "w") as fh:
                fh.write("# seed %d\n" % seed)
                for i, t in enumerate(g.text):
                    fh.write("%04x: %s\n" % (i * 4, t))
            if args.stop_on_fail:
                break
            continue

        # ---- architectural state ----
        rtl_regs, rtl_mem = ce.load_state(state_path)
        if rtl_regs != sim.reg or rtl_mem != sim.mem:
            msg = []
            for i, (a, b) in enumerate(zip(rtl_regs, sim.reg)):
                if a != b:
                    msg.append("x%d rtl=%08x model=%08x" % (i, a, b))
            for i, (a, b) in enumerate(zip(rtl_mem, sim.mem)):
                if a != b:
                    msg.append("mem[%04x] rtl=%08x model=%08x" % (i * 4, a, b))
            failed.append((seed, "; ".join(msg[:4])))
            print("  seed %-6d FAIL  (state: %s)" % (seed, "; ".join(msg[:2])))
            os.rename(hex_path, os.path.join(work, "fail_seed%d.hex" % seed))
            if args.stop_on_fail:
                break
            continue

        if not args.keep:
            os.remove(hex_path)
        if (seed - args.start + 1) % 25 == 0:
            print("  ... %d seeds done" % (seed - args.start + 1))

    print("")
    if failed:
        print("random: %d of %d seeds FAILED (kept under %s)"
              % (len(failed), args.seeds, work))
        for seed, why in failed[:10]:
            print("   - seed %d: %s" % (seed, why))
        return 1
    print("random: all %d seeds identical to the reference model" % args.seeds)
    return 0


if __name__ == "__main__":
    sys.exit(main())
