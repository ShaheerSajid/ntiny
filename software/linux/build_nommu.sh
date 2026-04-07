#!/bin/bash
# Build the rv32ima NoMMU Linux kernel and run it directly (no OpenSBI).
# Usage: ./build_nommu.sh [timeout_seconds] [skip_verilator]
#
# The kernel runs entirely in M-mode. There's no privilege transition, no
# Sv32 MMU, no SRET. The pipeline only exercises basic instruction execution
# and trap handling. If this boots cleanly the bug is in the MMU/priv path;
# if it also fails, the bug is more fundamental.
set -e
export PATH=/opt/riscv-linux/bin:$PATH

NTINY=/home/shaheer/Documents/github/ntiny
LINUX=/home/shaheer/Downloads/linux
TIMEOUT=${1:-1200}
SKIP_VERILATOR=${2:-0}

# ── 0. Verilator (rebuild if RTL changed) ──────────────────────
if [ "$SKIP_VERILATOR" != "1" ]; then
    cd $NTINY/flows/simulation
    if [ ! -x Vtb_soc_top ]; then
        echo "--- 0/4 Verilator rebuild (--trace) ---"
        rm -rf obj_dir Vtb_soc_top
        verilator -Wno-UNOPTFLAT -Wno-INITIALDLY -Wno-UNUSED -Wno-WIDTH \
            -Wno-CASEINCOMPLETE -Wno-PINMISSING -Wno-MULTIDRIVEN -Wno-STMTDLY \
            -Wno-UNPACKED -Wno-UNSIGNED -Wno-LITENDIAN -Wno-MODDUP -Wno-MISINDENT \
            --no-timing --timescale-override 1ns/10ps -O3 --threads 4 --trace \
            -DVERILATOR_SIM -sv --top-module tb_soc_top --cc \
            +define+RAM_SIZE_BYTES=134217728 \
            +incdir+../../design/common/ \
            +incdir+../../design/uncore/i2c/src/ +incdir+../../design/uncore/timer/src/ \
            +incdir+../../design/uncore/pwm/src/ +incdir+../../design/uncore/spi/src/ \
            +incdir+../../design/uncore/uart/src/ +incdir+../../design/core/fpu/PakFPU/src/ \
            -f src.args \
            ../../verification/dv/src/pkg.sv ../../verification/dv/src/tracer_pkg.sv \
            ../../verification/dv/src/tracer.sv testbench/uartdpi.c testbench/uartdpi.sv \
            testbench/tb_soc_top.v --exe testbench/main.cpp 2>&1 | tail -3
        make -j$(nproc) -C obj_dir/ -f Vtb_soc_top.mk Vtb_soc_top 2>&1 | tail -3
        cp obj_dir/Vtb_soc_top ./
    else
        echo "--- 0/4 Vtb_soc_top exists, skipping Verilator rebuild ---"
    fi
fi

# ── 1. DTB (NoMMU variant) ─────────────────────────────────────
cd $NTINY/software/linux
echo "--- 1/4 dtc → ntiny_nommu.dtb (standalone, for reference) ---"
dtc -I dts -O dtb -o ntiny_nommu.dtb ntiny_nommu.dts 2>&1

# Sync the DTS into the kernel tree so CONFIG_BUILTIN_DTB picks it up at the
# kernel link step. The kernel's arch/riscv/boot/dts/ntiny/Makefile already
# adds ntiny_nommu.dtb to dtb-y, but the .dts file must be present in that
# directory for the kernel build to find it.
mkdir -p $LINUX/arch/riscv/boot/dts/ntiny
cp $NTINY/software/linux/ntiny_nommu.dts $LINUX/arch/riscv/boot/dts/ntiny/ntiny_nommu.dts

# ── 2. Kernel (ntiny_nommu_defconfig) ──────────────────────────
cd $LINUX
cp $NTINY/software/linux/ntiny_nommu_defconfig .config
echo "--- 2/4 kernel olddefconfig ---"
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- olddefconfig 2>&1 | tail -3
# Sanity-check
if grep -q "^CONFIG_MMU=y" .config; then
    echo "FAIL: CONFIG_MMU is still =y after olddefconfig"
    exit 1
fi
if ! grep -q "^CONFIG_RISCV_M_MODE=y" .config; then
    echo "FAIL: RISCV_M_MODE not set (should auto-set when MMU=n)"
    grep "M_MODE\|MMU" .config
    exit 1
fi
if ! grep -q "^CONFIG_BUILTIN_DTB=y" .config; then
    echo "FAIL: BUILTIN_DTB not enabled — kernel will boot with no DT and panic in setup_arch"
    grep "BUILTIN_DTB" .config
    exit 1
fi
echo "  ✓ MMU disabled, RISCV_M_MODE auto-enabled, BUILTIN_DTB enabled"

echo "--- 2/4 kernel build ---"
make ARCH=riscv CROSS_COMPILE=riscv32-unknown-linux-gnu- -j$(nproc) 2>&1 | tail -5

KERNEL_IMAGE=$LINUX/arch/riscv/boot/Image
ls -la $KERNEL_IMAGE

# ── 3. Convert kernel directly to ram.hex (no OpenSBI) ─────────
cd $NTINY/flows/simulation
echo "--- 3/4 hex_text kernel directly ---"
python3 ../../software/tools/hex_text.py "$KERNEL_IMAGE" ram.hex
ls -la ram.hex

# ── 4. Run sim ──────────────────────────────────────────────────
rm -f uart.log
echo "--- 4/4 sim (${TIMEOUT}s wall, 500M cycles) ---"
timeout $TIMEOUT ./Vtb_soc_top --timeout 500000000 > /dev/null 2>&1 &
PID=$!
echo "PID $PID — monitor: tail -f $NTINY/flows/simulation/uart.log"

INTERVAL=10
N=$((TIMEOUT / INTERVAL))
for ((i=1; i<=N; i++)); do
    sleep $INTERVAL
    if ! kill -0 $PID 2>/dev/null; then echo "done at t=$((i*INTERVAL))s"; break; fi
    LATEST_CYCLE=$(grep "PC\[" uart.log 2>/dev/null | tail -1 | grep -oP "PC\[\K[0-9]+" || echo "?")
    LAST=$(tail -1 uart.log 2>/dev/null || echo "?")
    echo "  t=$((i*INTERVAL))s  cycle=$LATEST_CYCLE  $LAST"
done

kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true

echo ""
echo "--- uart.log: $(wc -l < uart.log) lines ---"
echo "--- last 20 lines ---"
tail -20 uart.log
