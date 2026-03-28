#!/usr/bin/env python3
"""Convert a flat binary to Intel HEX format for Quartus FPGA memory init.

Usage: bin2hex.py <input.bin> <output.hex>

Replaces the checked-in C binary `bin2hex_2`.
"""
import sys, struct

def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} input.bin output.hex", file=sys.stderr)
        sys.exit(1)

    with open(sys.argv[1], "rb") as f:
        data = f.read()

    # Pad to 4-byte alignment
    pad = (4 - len(data) % 4) % 4
    data += b"\x00" * pad

    with open(sys.argv[2], "w") as f:
        addr = 0
        for i in range(0, len(data), 4):
            word = struct.unpack("<I", data[i:i+4])[0]
            # Intel HEX: 4 bytes of data per record, type 00
            byte_count = 4
            record_type = 0x00
            d = word.to_bytes(4, "big")
            checksum = (byte_count + (addr >> 8) + (addr & 0xFF)
                        + record_type + sum(d)) & 0xFF
            checksum = (~checksum + 1) & 0xFF
            f.write(f":{byte_count:02X}{addr:04X}{record_type:02X}"
                    f"{d[0]:02X}{d[1]:02X}{d[2]:02X}{d[3]:02X}"
                    f"{checksum:02X}\n")
            addr += 4

        # EOF record
        f.write(":00000001FF\n")

if __name__ == "__main__":
    main()
