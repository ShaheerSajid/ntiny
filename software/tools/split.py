#!/usr/bin/env python3
"""Split mem.text into imem.text + dmem.text at the IMEM word boundary.

Usage: split.py <mem.text> <imem.text> <dmem.text> [--mem-map <mem_map.json>]

Reads IMEM_SIZE_BYTES from mem_map.json (default profile) to compute the
split point in 32-bit words.  Replaces the checked-in C binary `split`.
"""
import sys, json, os, argparse

def main():
    parser = argparse.ArgumentParser(description="Split mem.text into imem + dmem")
    parser.add_argument("input", help="Combined mem.text file")
    parser.add_argument("imem", help="Output imem.text")
    parser.add_argument("dmem", help="Output dmem.text")
    parser.add_argument("--mem-map", default=None,
                        help="Path to mem_map.json (default: auto-detect)")
    args = parser.parse_args()

    # Auto-detect mem_map.json relative to repo root
    if args.mem_map is None:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        args.mem_map = os.path.join(script_dir, "..", "..", "design", "common", "mem_map.json")

    with open(args.mem_map) as f:
        mem_map = json.load(f)

    imem_size = int(mem_map["profiles"]["default"]["IMEM_SIZE_BYTES"], 16)
    imem_words = imem_size // 4

    with open(args.input) as f:
        lines = f.readlines()

    print(f"size: {len(lines) * 4} bytes")

    with open(args.imem, "w") as f:
        f.writelines(lines[:imem_words])

    with open(args.dmem, "w") as f:
        f.writelines(lines[imem_words:])

if __name__ == "__main__":
    main()
