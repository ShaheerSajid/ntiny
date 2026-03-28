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

# RISCOF memory layout (must match linker script and Verilator build defines)
IMEM_SIZE_BYTES=2097152   # 2MB
DMEM_BASE=3145728         # 0x300000
DMEM_SIZE_BYTES=16384     # 16KB

NM="${TOOLCHAIN}/riscv64-unknown-elf-nm"
OBJCOPY="${TOOLCHAIN}/riscv64-unknown-elf-objcopy"

cd "$WORK_DIR"

# Convert ELF to flat binary (gap-filled with zeros)
${OBJCOPY} -O binary --gap-fill 0 "$ELF" test.bin

# Extract IMEM and DMEM regions using dd (skips gap between them)
dd if=test.bin of=imem.bin bs=1 count=${IMEM_SIZE_BYTES} 2>/dev/null
dd if=test.bin of=dmem.bin bs=1 skip=${DMEM_BASE} count=${DMEM_SIZE_BYTES} 2>/dev/null

# Convert each region to hex text for $readmemh
${HEX_TEXT} imem.bin imem_raw.text
sed 's/0x//' imem_raw.text > imem.text
${HEX_TEXT} dmem.bin dmem_raw.text
sed 's/0x//' dmem_raw.text > dmem.text
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
