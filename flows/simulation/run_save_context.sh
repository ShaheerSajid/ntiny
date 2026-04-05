#!/bin/bash
# Build and run save_context test
set -e
cd "$(dirname "$0")"

TOOLCHAIN=/opt/riscv/bin/riscv64-unknown-elf
TEST_SRC=../../software/tests/priv_boot/save_context_test.S
LINK_LD=../../software/common/link.ld

echo "=== Building save_context test ==="
${TOOLCHAIN}-gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 \
    -nostdlib -nostartfiles -static -T "$LINK_LD" "$TEST_SRC" \
    -o /tmp/save_context_test.elf
${TOOLCHAIN}-objcopy -O binary /tmp/save_context_test.elf /tmp/save_context_test.bin

# Build Verilator model if needed (default RAM, no traces)
if [ ! -f Vtb_soc_top ]; then
    echo "No Vtb_soc_top — run make riscof_run or run_linux.sh first to build"
    exit 1
fi

echo "=== Running save_context test ==="
python3 ../../software/tools/hex_text.py /tmp/save_context_test.bin ram.hex
rm -f uart.log
./Vtb_soc_top --timeout 50000 2>&1 | tail -3
echo "--- uart.log ---"
cat uart.log
