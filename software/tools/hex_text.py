#!/usr/bin/env python3
"""Convert a flat binary to one 32-bit hex word per line (for $readmemh).

Usage: hex_text.py <input.bin> <output.text>

Replaces the checked-in C binary `hex_text`.
"""
import sys, struct

def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} input.bin output.text", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    # Pad to 4-byte alignment
    pad = (4 - len(data) % 4) % 4
    data += b"\x00" * pad

    with open(sys.argv[2], "w") as f:
        for i in range(0, len(data), 4):
            word = struct.unpack("<I", data[i:i+4])[0]
            f.write(f"{word:08X}\n")

if __name__ == "__main__":
    main()
