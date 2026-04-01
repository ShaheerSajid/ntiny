#!/bin/bash
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

# Extract full binary from ELF (unified RAM: .text + .data in one image)
${OBJCOPY} -O binary "$ELF" ram.bin

# Convert to hex text for $readmemh
python3 ${HEX_TEXT} ram.bin ram.hex

# Extract signature addresses from ELF
SIG_BEGIN=$(${NM} "$ELF" | grep " begin_signature" | cut -d" " -f1)
SIG_END=$(${NM} "$ELF" | grep " end_signature" | cut -d" " -f1)

if [ -z "$SIG_BEGIN" ] || [ -z "$SIG_END" ]; then
    echo "WARNING: Could not find signature symbols in ELF"
    SIG_BEGIN="0"
    SIG_END="0"
fi

# Run Verilator simulation
${VERILATOR_BIN} --timeout 10000000 \
    +sig_file=${SIG_FILE} \
    +sig_begin=${SIG_BEGIN} \
    +sig_end=${SIG_END} || true

# Compare DUT signature against Spike reference if it exists
REF_SIG="$(dirname "$WORK_DIR")/ref/Reference-spike.signature"
if [ -f "$REF_SIG" ] && [ -f "$SIG_FILE" ]; then
    if diff -q "$SIG_FILE" "$REF_SIG" > /dev/null 2>&1; then
        echo "SIG_COMPARE: PASS"
    else
        NDIFF=$(diff "$SIG_FILE" "$REF_SIG" | grep -c "^[<>]" || true)
        echo "SIG_COMPARE: FAIL (${NDIFF} differing lines)"
    fi
fi
