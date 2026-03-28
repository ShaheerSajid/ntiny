#!/bin/bash
# Usage: run_test.sh <elf> <sig_file> <toolchain_path> <verilator_bin> <hex_text> <split>
set -e

ELF=$1
SIG_FILE=$2
TOOLCHAIN=$3
VERILATOR_BIN=$4
HEX_TEXT=$5
SPLIT=$6
WORK_DIR=$(dirname "$ELF")

NM="${TOOLCHAIN}/riscv64-unknown-elf-nm"
OBJCOPY="${TOOLCHAIN}/riscv64-unknown-elf-objcopy"

cd "$WORK_DIR"

# Extract IMEM and DMEM directly from ELF sections (avoids huge flat binary)
${OBJCOPY} -O binary -j .text.init -j .text "$ELF" imem.bin
${OBJCOPY} -O binary -j .data -j .sdata "$ELF" dmem.bin

# Convert each region to hex text for $readmemh
python3 ${HEX_TEXT} imem.bin imem.text
python3 ${HEX_TEXT} dmem.bin dmem.text
touch boot.text

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
