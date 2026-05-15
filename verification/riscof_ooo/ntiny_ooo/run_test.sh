#!/bin/bash
# OoO core RISCOF runner.
# Usage: run_test.sh <elf> <sig_file> <toolchain_path> <verilator_bin> <hex_text>
set -e

ELF=$1
SIG_FILE=$2
TOOLCHAIN=$3
VERILATOR_BIN=$4
HEX_TEXT=$5
WORK_DIR=$(dirname "$ELF")

NM="${TOOLCHAIN}/riscv64-unknown-elf-nm"
OBJCOPY="${TOOLCHAIN}/riscv64-unknown-elf-objcopy"

cd "$WORK_DIR"

# Strip ELF to a flat binary that lands in the tb's RAM image. The
# in-order flow uses the same trick — `objcopy -O binary` collects
# all allocatable sections starting from the lowest address; the
# tb_ooo's $readmemh loads it at mem[0..]. Address-wraparound
# (`addr[31:2] % RAM_WORDS`) maps the program's 0x80000000+ accesses
# back to mem[0..].
${OBJCOPY} -O binary "$ELF" ram.bin
python3 ${HEX_TEXT} ram.bin ram.hex

# Pull begin_signature / end_signature from the ELF — the OoO tb
# walks this range on halt and dumps it.
SIG_BEGIN=$(${NM} "$ELF" | grep " begin_signature" | cut -d" " -f1)
SIG_END=$(${NM}   "$ELF" | grep " end_signature"   | cut -d" " -f1)

if [ -z "$SIG_BEGIN" ] || [ -z "$SIG_END" ]; then
    echo "WARNING: signature symbols missing in ELF $ELF"
    SIG_BEGIN="0"
    SIG_END="0"
fi

# tohost is at 0x0F000000 (matches the in-order flow's model_test.h
# convention; the OoO tb's `+tohost=` plusarg points there too).
# Reset PC at 0x80000000 — the test's link.ld puts .text.init there.
${VERILATOR_BIN} \
    +ram_hex=ram.hex \
    +reset_pc=80000000 \
    +tohost=0F000000 \
    +sig_file=${SIG_FILE} \
    +sig_begin=${SIG_BEGIN} \
    +sig_end=${SIG_END} \
    +max_cycles=10000000 || true

# Spike-vs-DUT diff (printed for visibility; RISCOF also computes
# its own pass/fail summary later).
REF_SIG="$(dirname "$WORK_DIR")/ref/Reference-spike.signature"
if [ -f "$REF_SIG" ] && [ -f "$SIG_FILE" ]; then
    if diff -q "$SIG_FILE" "$REF_SIG" > /dev/null 2>&1; then
        echo "SIG_COMPARE: PASS"
    else
        NDIFF=$(diff "$SIG_FILE" "$REF_SIG" | grep -c "^[<>]" || true)
        echo "SIG_COMPARE: FAIL (${NDIFF} differing lines)"
    fi
fi
