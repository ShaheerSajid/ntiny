#!/bin/bash
# Run save_context test + RISCOF regression
set -e

TOOLCHAIN=/opt/riscv/bin/riscv64-unknown-elf
TEST_SRC=../../software/tests/priv_boot/save_context_test.S
LINK_LD=../../software/common/link.ld

echo "=== Building save_context test ==="
${TOOLCHAIN}-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
    -nostdlib -nostartfiles -static -T "$LINK_LD" "$TEST_SRC" \
    -o /tmp/save_context_test.elf 2>&1 | tail -1
${TOOLCHAIN}-objcopy -O binary /tmp/save_context_test.elf /tmp/save_context_test.bin

echo "=== Running save_context test ==="
python3 ../../software/tools/hex_text.py /tmp/save_context_test.bin ram.hex
rm -f uart.log
RESULT=$(./Vtb_soc_top --timeout 50000 2>&1 | grep -E "^(ALL PASS|TEST PASSED|TEST FAILED|FAIL)" | head -1)
echo "save_context: $RESULT"
if [[ "$RESULT" != *"PASS"* ]]; then
    echo "--- uart.log ---"
    cat uart.log
    echo "save_context FAILED — skipping RISCOF"
    exit 1
fi

echo ""
echo "=== Running RISCOF ==="
make riscof_run 2>&1 | tail -5
