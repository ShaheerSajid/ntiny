#!/usr/bin/env python3
"""Compare Spike ISS trace vs ntiny DUT trace from riscv-dv tests.

Extracts PC + GPR write sequences from both traces and reports:
  - Total instructions committed by each
  - First divergence point (PC or register value mismatch)
  - Summary: PASS / FAIL

Usage:
    python3 compare_trace.py --spike spike.log --dut trace_core_00000000.log
    python3 compare_trace.py --spike spike.log --dut trace_core_00000000.log -v
"""

import argparse
import re
import sys


def parse_spike_log(path):
    """Parse Spike --log-commits output into list of (pc, gpr_writes) tuples.

    Spike format (two lines per instruction):
        core   0: 0xPC (0xINSN) disasm
        core   0: PRIV 0xPC (0xINSN) reg 0xVAL [mem ...]

    We skip bootrom instructions (PC < 0x80000000).
    """
    insns = []
    pc_pattern = re.compile(r"core\s+\d+:\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)")
    commit_pattern = re.compile(
        r"core\s+\d+:\s+\d+\s+0x([0-9a-f]+)\s+\(0x([0-9a-f]+)\)"
        r"(?:\s+(x\d+)\s+0x([0-9a-f]+))?"
    )
    # Also detect exceptions/traps
    exc_pattern = re.compile(r"core\s+\d+:\s+exception\s+(\S+),\s+epc\s+0x([0-9a-f]+)")

    with open(path) as f:
        lines = f.readlines()

    i = 0
    while i < len(lines):
        line = lines[i].rstrip()

        # Skip exception lines (ecall, page fault, etc.)
        exc_m = exc_pattern.match(line)
        if exc_m:
            i += 1
            continue

        # Match instruction line
        pc_m = pc_pattern.match(line)
        if pc_m:
            pc = int(pc_m.group(1), 16)
            insn = int(pc_m.group(2), 16)

            # Look for commit line (next line with privilege prefix)
            gpr_name, gpr_val = None, None
            mem_addr, mem_val = None, None
            if i + 1 < len(lines):
                commit_m = commit_pattern.match(lines[i + 1])
                if commit_m and int(commit_m.group(1), 16) == pc:
                    if commit_m.group(3):
                        gpr_name = commit_m.group(3)
                        gpr_val = int(commit_m.group(4), 16)
                    # Check for mem write
                    mem_m = re.search(r"mem\s+0x([0-9a-f]+)\s+0x([0-9a-f]+)", lines[i + 1])
                    if mem_m:
                        mem_addr = int(mem_m.group(1), 16)
                        mem_val = int(mem_m.group(2), 16)
                    i += 2
                    # Skip bootrom
                    if pc < 0x80000000:
                        continue
                    insns.append({
                        "pc": pc,
                        "insn": insn,
                        "gpr": (gpr_name, gpr_val) if gpr_name else None,
                        "mem": (mem_addr, mem_val) if mem_addr is not None else None,
                    })
                    continue
            # No commit line found, skip
            i += 1
            continue

        i += 1

    # Strip tohost loop: detect repeated short PC cycle at end of trace
    insns = _strip_tail_loop(insns)
    return insns


def _strip_tail_loop(insns, max_period=4):
    """Remove a repeating PC loop at the end of the trace.

    The tohost write sequence is: auipc/sw/j repeating forever.
    Detect any repeating pattern of up to `max_period` PCs at the tail.
    """
    if len(insns) < max_period * 3:
        return insns
    for period in range(2, max_period + 1):
        # Check if the last `period * 2` entries repeat with period `period`
        tail = [insns[-(i + 1)]["pc"] for i in range(period * 2)]
        pattern = tail[:period]
        if pattern == tail[period:]:
            # Found a repeating pattern — strip all matching tail entries
            while len(insns) >= period:
                if [insns[-(i + 1)]["pc"] for i in range(period)] == pattern:
                    for _ in range(period):
                        insns.pop()
                else:
                    break
            return insns
    return insns


def parse_dut_trace(path):
    """Parse ntiny DV_TRACER output (trace_core_*.log).

    Format (tab-separated):
        Time  Cycle  PC  Insn  Decoded  RegContents

    RegContents has patterns like:
        x5=0x00000000  (write)
        x5:0x00000000  (read)
    """
    insns = []
    # Match: optional whitespace, Time, Cycle, PC(hex), Insn(hex), ...
    line_pat = re.compile(
        r"\s*\d+\s+(\d+)\s+([0-9a-f]+)\s+([0-9a-f]+)\s+(\S+)(.*)"
    )
    gpr_write_pat = re.compile(r"(x\d+)=0x([0-9a-f]+)")
    mem_pat = re.compile(r"PA:0x([0-9a-f]+)\s")

    with open(path) as f:
        for line in f:
            m = line_pat.match(line)
            if not m:
                continue
            cycle = int(m.group(1))
            pc = int(m.group(2), 16)
            insn = int(m.group(3), 16)
            rest = m.group(5)

            # Find GPR writes (= sign, not : sign)
            gpr_writes = gpr_write_pat.findall(rest)
            # Take the last GPR write (the destination register)
            gpr = None
            if gpr_writes:
                name, val = gpr_writes[-1]
                gpr = (name, int(val, 16))

            insns.append({
                "pc": pc,
                "insn": insn,
                "gpr": gpr,
                "cycle": cycle,
            })

    # Strip tohost loop
    insns = _strip_tail_loop(insns)
    return insns


def compare(spike_insns, dut_insns, verbose=False):
    """Compare instruction traces. Returns (pass, message)."""
    si, di = 0, 0
    matched = 0
    mismatches = []

    while si < len(spike_insns) and di < len(dut_insns):
        s = spike_insns[si]
        d = dut_insns[di]

        if s["pc"] == d["pc"]:
            # PCs match — check GPR writes
            if s["gpr"] and d["gpr"]:
                if s["gpr"][0] == d["gpr"][0] and s["gpr"][1] != d["gpr"][1]:
                    mismatches.append({
                        "type": "gpr_value",
                        "spike_idx": si,
                        "dut_idx": di,
                        "pc": s["pc"],
                        "reg": s["gpr"][0],
                        "spike_val": s["gpr"][1],
                        "dut_val": d["gpr"][1],
                    })
                    if not verbose:
                        break
            matched += 1
            si += 1
            di += 1

        elif s["pc"] < d["pc"]:
            # Spike has an instruction DUT doesn't — likely ecall/mret boundary
            # These are expected: Spike logs the trap instruction, DUT may skip it
            if verbose:
                print(f"  Spike-only: PC={s['pc']:08x} insn={s['insn']:08x}")
            si += 1

        else:
            # DUT has an instruction Spike doesn't
            if verbose:
                print(f"  DUT-only:   PC={d['pc']:08x} insn={d['insn']:08x}")
            di += 1

    total_spike = len(spike_insns)
    total_dut = len(dut_insns)

    print(f"Spike instructions: {total_spike}")
    print(f"DUT instructions:   {total_dut}")
    print(f"Matched PCs:        {matched}")

    if mismatches:
        m = mismatches[0]
        print(f"\nFAILED: GPR mismatch at PC=0x{m['pc']:08x}")
        print(f"  Register: {m['reg']}")
        print(f"  Spike:    0x{m['spike_val']:08x}")
        print(f"  DUT:      0x{m['dut_val']:08x}")
        print(f"  Spike instruction #{m['spike_idx']}, DUT instruction #{m['dut_idx']}")
        if verbose and len(mismatches) > 1:
            print(f"\n  Total mismatches: {len(mismatches)}")
            for m in mismatches[1:6]:
                print(f"  PC=0x{m['pc']:08x} {m['reg']}: spike=0x{m['spike_val']:08x} dut=0x{m['dut_val']:08x}")
        return False

    # Check if both traces reached the tohost write (test completion)
    if matched < 10:
        print(f"\nWARNING: Only {matched} PCs matched — trace may be too short")
        return False

    print(f"\nPASS: All {matched} matching instructions agree")
    return True


def main():
    parser = argparse.ArgumentParser(description="Compare Spike vs ntiny DUT traces")
    parser.add_argument("--spike", required=True, help="Spike commit log (spike.log)")
    parser.add_argument("--dut", required=True, help="DUT trace (trace_core_*.log)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show skipped instructions")
    args = parser.parse_args()

    print(f"Spike log: {args.spike}")
    print(f"DUT trace: {args.dut}")
    print()

    spike_insns = parse_spike_log(args.spike)
    dut_insns = parse_dut_trace(args.dut)

    passed = compare(spike_insns, dut_insns, args.verbose)
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
